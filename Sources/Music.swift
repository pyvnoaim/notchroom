// What resona is playing, for the record player.
import Foundation

struct Song { let title: String, artist: String, cover: String?, playing: Bool }

func running(_ name: String) -> Bool {
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
    guard running("resona"), let j = json(home.appendingPathComponent(".resona/now-playing")), let title = j["title"] as? String else { return nil }
    return Song(title: title, artist: j["artist"] as? String ?? "", cover: j["cover"] as? String, playing: j["playing"] as? Bool ?? false)
}

