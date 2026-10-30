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

/// Bugs and security issues are work to do, so they go in as tasks; everything else is an idea.
// ponytail: keyword match, have the idea prompt tag its lines if this misses too often
func stashType(_ idea: String) -> String {
    idea.range(of: #"\b(bugs?|fix(es|ed|ing)?|crash(es|ed|ing)?|security|vulnerab\w*|exploits?|leak(s|ed|ing)?|xss|csrf|injection|sanitiz\w*)\b"#,
               options: [.regularExpression, .caseInsensitive]) == nil ? "idea" : "task"
}

/// Whether stash's `@` can reach a project by this name: a single word.
func stashWord(_ name: String) -> Bool { name.range(of: #"^[\p{L}\p{M}\p{N}_-]+$"#, options: .regularExpression) != nil }

/// The stash project a repo's ideas go under: named like the repo (`group/repo` -> `repo`), if stash can reach it.
func repoProject(_ project: String) -> String? {
    let repo = String(project.split(separator: "/").last ?? "")
    return stashWord(repo) ? repo : nil
}

/// The existing stash project named exactly like the repo, or none (Inbox).
func stashProject(_ project: String, in names: [String]) -> String? {
    guard let repo = repoProject(project)?.lowercased() else { return nil }
    return names.first { $0.lowercased() == repo }
}

/// Whether the configured stash MCP server is set up in Claude Code; checked once at launch, a new one needs a restart.
/// Until the check answers, clicks file (and fail plainly if it isn't there), so a quick click is never just copied.
var stashReady: Bool? = stashServer == nil ? false : nil
func checkStash() {
    guard let server = stashServer else { return }
    _ = claudeRun(["claude", "mcp", "get", server]) { ok, _ in stashReady = ok }
}

/// The parsed JSON of each tool result in a `--output-format stream-json` run, errors left out.
func toolResults(_ stream: String) -> [[String: Any]] {
    func json(_ s: String) -> [String: Any]? { try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] }
    return stream.split(separator: "\n").flatMap { line -> [[String: Any]] in
        guard let ev = json(String(line)), ev["type"] as? String == "user",
              let content = (ev["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return [] }
        return content.filter { $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool != true }.compactMap { r in
            json(r["content"] as? String ?? (r["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? "")
        }
    }
}

/// One stash tool call through the stash MCP that Claude Code already signs into, with exactly these arguments;
/// only that one tool is allowed. Hands back what stash answered, nil if it never did.
func stashCall(_ tool: String, _ args: [String: Any], done: @escaping ([String: Any]?) -> Void) {
    guard let server = stashServer else { return done(nil) }
    let json = String(decoding: (try? JSONSerialization.data(withJSONObject: args, options: .sortedKeys)) ?? Data(), as: UTF8.self)
    _ = claudeRun(["claude", "-p", "--model", "haiku", "--tools", "", "--allowedTools", "mcp__\(server)__\(tool)",
                   "--output-format", "stream-json", "--verbose", "--no-session-persistence",
                   "Call \(tool) once with exactly these arguments, then reply ok: \(json)"]) { ok, out in
        done(ok ? toolResults(out).first : nil)
    }
}

/// Where each repo's ideas go in stash, as picked in its card: a stash project, or "" for Inbox.
let placesFile = dir.appendingPathComponent("stash-places.json")
var stashPlaces = json(placesFile) as? [String: String] ?? [:]
func rememberPlace(_ project: String, _ place: String?) {
    stashPlaces[project] = place
    try? JSONSerialization.data(withJSONObject: stashPlaces, options: .sortedKeys).write(to: placesFile)
}

enum Filed { case yes, misfiled, no, ask([String]) }

/// Files an idea in stash: as an idea (a task if it's a bug or security issue), where its repo's ideas were picked to
/// go, else under the stash project named like the repo. With neither, it asks, handing back the project names stash's
/// `@` can reach. `names` skips reading them again when the caller just had them.
/// Once stash has added it, it leaves the desk even if stash read it differently (`misfiled`): a retry would only
/// add a second copy.
// ponytail: stash's capture parser also reads `today`, `fri`, `!`, `#x`, `@x` inside the idea; needs a raw-text
// option on stash_capture to stop
func fileIdea(_ project: String, _ idea: String, names: [String]? = nil, done: @escaping (Filed) -> Void) {
    let type = stashType(idea)
    func capture(_ proj: String?) {
        stashCall("stash_capture", ["text": idea + (proj.map { " @\($0)" } ?? ""), "type": type]) { got in
            guard let item = (got?["added"] as? [[String: Any]])?.first else { return done(.no) }
            dropIdea(project, idea)
            done(item["type"] as? String == type && (item["project"] as? String)?.lowercased() == proj?.lowercased() ? .yes : .misfiled)
        }
    }
    if stashPlaces[project] == "" { return capture(nil) } // Inbox needs no project list
    func place(_ names: [String]) {
        let names = names.filter(stashWord)
        if let p = stashPlaces[project], let have = names.first(where: { $0.lowercased() == p.lowercased() }) { return capture(have) }
        // picked as a new project: made the first time (or again, if it was deleted in stash since)
        if let p = stashPlaces[project], p == repoProject(project) { return stashCall("stash_project", ["name": p]) { $0 == nil ? done(.no) : capture(p) } }
        if let p = stashProject(project, in: names) { capture(p) } else { done(.ask(names)) }
    }
    if let names { return place(names) }
    stashCall("stash_read", ["view": "inbox", "limit": 0]) { read in
        guard let names = (read?["projects"] as? [[String: Any]])?.compactMap({ $0["name"] as? String }) else { return done(.no) }
        place(names)
    }
}

/// Takes an idea off its desk's list for good.
func dropIdea(_ project: String, _ idea: String) {
    let rest = ideas(project).filter { $0 != idea }
    try? (rest.joined(separator: "\n") + (rest.isEmpty ? "" : "\n")).write(to: ideasFile(project), atomically: true, encoding: .utf8)
}
