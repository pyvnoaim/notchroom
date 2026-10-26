// The sun and weather outside the windows, for where your time zone says you are.
import Foundation

/// Where the clock says you are: the main city of your time zone, from zone.tab. No location permission, no network.
func homeCoords() -> (lat: Double, lon: Double)? {
    let tab = (try? String(contentsOfFile: "/usr/share/zoneinfo/zone.tab", encoding: .utf8)) ?? ""
    for line in tab.split(separator: "\n") where !line.hasPrefix("#") {
        let f = line.split(separator: "\t")
        if f.count >= 3, f[2] == TimeZone.current.identifier { return iso6709(String(f[1])) }
    }
    return nil
}

/// "+5230+01322" or "+404251-0740023" (±DDMM[SS]±DDDMM[SS]) -> degrees.
func iso6709(_ s: String) -> (lat: Double, lon: Double)? {
    guard let cut = s.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
    func deg(_ part: Substring, _ n: Int) -> Double? {
        let d = Array(part.dropFirst()).map(String.init)
        guard d.count >= n + 2, let dd = Double(d[0..<n].joined()), let mm = Double(d[n..<n + 2].joined()) else { return nil }
        let ss = d.count >= n + 4 ? Double(d[n + 2..<n + 4].joined()) ?? 0 : 0
        return (part.first == "-" ? -1 : 1) * (dd + mm / 60 + ss / 3600)
    }
    guard let lat = deg(s[..<cut], 2), let lon = deg(s[cut...], 3) else { return nil }
    return (lat, lon)
}

/// Degrees the sun stands above the horizon (the usual low-precision solar position, good to a fraction of a degree).
func sunElevation(lat: Double, lon: Double, at date: Date) -> Double {
    let n = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0, r = Double.pi / 180
    let L = 280.460 + 0.9856474 * n, g = (357.528 + 0.9856003 * n) * r
    let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * r, eps = (23.439 - 0.0000004 * n) * r
    let dec = asin(sin(eps) * sin(lambda)), ra = atan2(cos(eps) * sin(lambda), cos(lambda))
    let ha = (280.46061837 + 360.98564736629 * n + lon) * r - ra
    return asin(sin(lat * r) * sin(dec) + cos(lat * r) * cos(dec) * cos(ha)) / r
}

struct Weather { var rain = false, snow = false, cloudy = false }

/// The weather at the time-zone city, from open-meteo (no key). Coordinates go out rounded to a tenth of a degree.
func fetchWeather(_ c: (lat: Double, lon: Double), done: @escaping (Weather) -> Void) {
    let q = String(format: "latitude=%.1f&longitude=%.1f", c.lat, c.lon)
    guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?\(q)&current=weather_code,cloud_cover") else { return }
    URLSession.shared.dataTask(with: url) { data, _, _ in
        guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let now = j["current"] as? [String: Any], let code = now["weather_code"] as? Int else { return }
        let w = Weather(rain: (51...67).contains(code) || (80...82).contains(code) || code >= 95,
                        snow: (71...77).contains(code) || (85...86).contains(code),
                        cloudy: (now["cloud_cover"] as? Int ?? 0) >= 70 || (45...48).contains(code))
        DispatchQueue.main.async { done(w) }
    }.resume()
}
