// Ideas for each desk, written once a day per project by `claude -p` (Haiku, no tools), and filing one in stash.
import Foundation

/// One file per project; a nested project's slash would be a folder that isn't there.
func ideasFile(_ project: String) -> URL { ideasDir.appendingPathComponent(project.replacingOccurrences(of: "/", with: ":") + ".txt") }

func ideas(_ project: String) -> [String] {
    let s = (try? String(contentsOf: ideasFile(project), encoding: .utf8)) ?? ""
    return s.split(separator: "\n").map(String.init)
}

/// Model output -> idea lines: list markers and em dashes out, overlong lines dropped.
func cleanIdeas(_ s: String) -> [String] {
    s.split(separator: "\n").map {
        $0.replacingOccurrences(of: #"^\s*([-*•]|\d+[.)])\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: " — ", with: ": ").replacingOccurrences(of: "—", with: ", ")
            .trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty && $0.count <= 90 }.prefix(6).map { $0 }
}

let ideaScript = """
cd "$1" || exit 1
{ printf 'Project: %s\\n\\nREADME:\\n' "$2"; head -c 3000 README.md 2>/dev/null; printf '\\n\\nRecent commits:\\n'; git log -12 --format=%s 2>/dev/null; } |
claude -p --model haiku --tools "" --no-session-persistence "You are brainstorming for a solo developer. Based on the project info on stdin, \
suggest 5 small, concrete features or improvements they could add next. Each under 60 characters, plain text, one per line, \
no numbering, no bullets, no intro, no em dashes."
"""

/// A `claude -p` run that the room's own hook ignores, with the usual places claude lives on PATH.
func claudeRun(_ args: [String], done: @escaping (Bool, String) -> Void) -> Process? {
    let run = Process(), out = Pipe()
    run.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    run.arguments = args
    run.currentDirectoryURL = home
    var env = ProcessInfo.processInfo.environment
    env["NOTCHROOM_NO_HOOK"] = "1"
    env["PATH"] = "\(home.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    run.environment = env
    run.standardOutput = out
    run.standardError = FileHandle.nullDevice
    run.terminationHandler = { r in
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        DispatchQueue.main.async { done(r.terminationStatus == 0, text) }
    }
    guard (try? run.run()) != nil else { return nil }
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) { if run.isRunning { run.terminate() } }
    return run
}

var ideaRun: Process?
var lastTry: [String: Date] = [:]

/// Asks for ideas for one desk at a time: each project at most once a day, and once an hour after a failure.
func refreshIdeas(_ projects: [String]) {
    guard ideaRun == nil else { return }
    let stale = projects.first { p in
        guard FileManager.default.fileExists(atPath: "\(devDir.path)/\(p)/.git"),
              Date().timeIntervalSince(lastTry[p] ?? .distantPast) > 3600 else { return false }
        return Date().timeIntervalSince(mtime(ideasFile(p).path) ?? .distantPast) > 86400
    }
    guard let p = stale else { return }
    lastTry[p] = Date()
    try? FileManager.default.createDirectory(at: ideasDir, withIntermediateDirectories: true)
    // the project path as an argument, never spliced into the script
    ideaRun = claudeRun(["sh", "-c", ideaScript, "sh", "\(devDir.path)/\(p)", p]) { ok, text in
        let lines = cleanIdeas(text)
        if ok, !lines.isEmpty {
            try? (lines.joined(separator: "\n") + "\n").write(to: ideasFile(p), atomically: true, encoding: .utf8)
        }
        ideaRun = nil
    }
}

/// Files an idea as a stash item through the stash MCP that Claude Code already signs into; only that one tool is allowed.
/// A filed idea leaves the desk.
func fileIdea(_ project: String, _ idea: String, done: @escaping (Bool) -> Void) {
    let line = "\(idea) @\(project) #idea"
    _ = claudeRun(["claude", "-p", "--model", "haiku", "--tools", "", "--allowedTools", "mcp__stash__stash_capture",
                   "--no-session-persistence", "Call stash_capture once to add exactly this one line to stash, then reply ok. The line: \(line)"]) { ok, _ in
        if ok { dropIdea(project, idea) }
        done(ok)
    }
}

/// Takes an idea off its desk's list for good.
func dropIdea(_ project: String, _ idea: String) {
    let rest = ideas(project).filter { $0 != idea }
    try? (rest.joined(separator: "\n") + (rest.isEmpty ? "" : "\n")).write(to: ideasFile(project), atomically: true, encoding: .utf8)
}
