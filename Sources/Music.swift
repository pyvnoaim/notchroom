// What resona is playing, for the record player.
import Foundation

struct Song { let title: String, artist: String, cover: String?, playing: Bool }

var runningChecked: (name: String, at: Date, result: Bool)?
/// Whether a process of that name runs (also command-line ones, which the app list doesn't have). Reading every
/// process's name isn't free, so the answer is kept for ten seconds.
func running(_ name: String) -> Bool {
    if let c = runningChecked, c.name == name, Date().timeIntervalSince(c.at) < 10 { return c.result }
    let result = scanFor(name)
    runningChecked = (name, Date(), result)
    return result
}

func scanFor(_ name: String) -> Bool {
    var pids = [Int32](repeating: 0, count: 4096)
    let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size)))
    return pids.prefix(max(n, 0)).contains { pid in
        var buf = [CChar](repeating: 0, count: 64)
        proc_name(pid, &buf, 64)
        return String(cString: buf) == name
    }
}

/// What resona is playing, from the file it keeps in ~/.resona (only while it runs: the file outlives it).
func nowPlaying() -> Song? {
    guard let j = json(home.appendingPathComponent(".resona/now-playing")), let title = j["title"] as? String, running("resona") else { return nil }
    return Song(title: title, artist: j["artist"] as? String ?? "", cover: j["cover"] as? String, playing: j["playing"] as? Bool ?? false)
}

