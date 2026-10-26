// Today's numbers for the clock's card and the collapsed notch, from the hook's event log.
import Foundation

struct Stats { var tools = 0, sessions = 0, active: TimeInterval = 0, perProject: [String: Int] = [:] }

/// Today's log -> tool calls, sessions, and active time: gaps under five minutes between one session's events.
func stats(_ text: String) -> Stats {
    var s = Stats(), last: [String: Double] = [:]
    for line in text.split(separator: "\n") {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard f.count >= 5, let t = Double(f[0]) else { continue }
        let id = String(f[1])
        if f[3] == "PreToolUse" { s.tools += 1; s.perProject[String(f[2]), default: 0] += 1 }
        if let prev = last[id], t - prev < 300 { s.active += t - prev }
        last[id] = t
    }
    s.sessions = last.count
    return s
}

func hm(_ t: TimeInterval) -> String { "\(Int(t) / 3600)h\(String(format: "%02d", Int(t) % 3600 / 60))m" }
