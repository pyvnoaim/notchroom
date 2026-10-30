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
    env["ENABLE_CLAUDEAI_MCP_SERVERS"] = "false" // claude.ai connectors aren't used here, and connecting them costs a second
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

/// The stash MCP server as Claude Code keeps it in ~/.claude.json: its address and the headers that sign in. User scope
/// first, else any folder's local scope (where `claude mcp add` puts it by default). Read once; a new one needs a restart.
// ponytail: HTTP servers with plain headers only, the way stash installs; no .mcp.json, stdio, OAuth or ${VAR}
let stashMCP: (url: URL, headers: [String: String])? = {
    guard let name = stashServer, let cfg = json(home.appendingPathComponent(".claude.json")) else { return nil }
    let scopes = [cfg["mcpServers"]] + ((cfg["projects"] as? [String: Any])?.values.map { ($0 as? [String: Any])?["mcpServers"] } ?? [])
    guard let s = scopes.lazy.compactMap({ ($0 as? [String: Any])?[name] as? [String: Any] }).first(where: { $0["type"] as? String == "http" }),
          let url = (s["url"] as? String).flatMap(URL.init(string:)) else { return nil }
    return (url, s["headers"] as? [String: String] ?? [:])
}()
var stashReady: Bool { stashMCP != nil }

/// What a stash tool answered, from the JSON-RPC reply (plain, or as a server-sent event's `data:` line): its result's
/// text parsed as JSON; nil for an error.
func stashResult(_ data: Data) -> [String: Any]? {
    let body = String(decoding: data, as: UTF8.self)
    let rpc = body.split(separator: "\n").first { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)) } ?? body
    guard let reply = try? JSONSerialization.jsonObject(with: Data(rpc.utf8)) as? [String: Any],
          let result = reply["result"] as? [String: Any], result["isError"] as? Bool != true,
          let content = result["content"] as? [[String: Any]] else { return nil }
    let text = content.compactMap { $0["text"] as? String }.joined()
    return try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
}

/// One stash tool call, straight to the stash MCP server with the sign-in Claude Code already keeps: no model, no
/// cost, well under a second. Hands back what stash answered, nil if it never did.
// ponytail: no initialize handshake or session id, stash answers stateless calls; add them if a server insists
func stashCall(_ tool: String, _ args: [String: Any], done: @escaping ([String: Any]?) -> Void) {
    guard let mcp = stashMCP else { return done(nil) }
    var req = URLRequest(url: mcp.url, timeoutInterval: 20)
    req.httpMethod = "POST"
    for (k, v) in mcp.headers { req.setValue(v, forHTTPHeaderField: k) }
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    req.setValue("notchroom", forHTTPHeaderField: "User-Agent") // Cloudflare in front of stash turns away some default ones
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                                                 "params": ["name": tool, "arguments": args]])
    URLSession.shared.dataTask(with: req) { data, _, _ in
        let out = data.flatMap(stashResult)
        DispatchQueue.main.async { done(out) }
    }.resume()
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
/// `@` can reach; the answer comes back as `pick`, and is only remembered once a filing there worked. After that a
/// repo's place is known, and filing is a single call.
/// Once stash has added it, it leaves the desk even if stash read it differently (`misfiled`): a retry would only
/// add a second copy.
// ponytail: stash's capture parser also reads `today`, `fri`, `!`, `#x`, `@x` inside the idea; needs a raw-text
// option on stash_capture to stop
func fileIdea(_ project: String, _ idea: String, pick: (place: String, names: [String])? = nil, done: @escaping (Filed) -> Void) {
    let type = stashType(idea)
    func capture(_ proj: String?) {
        stashCall("stash_capture", ["text": idea + (proj.map { " @\($0)" } ?? ""), "type": type]) { got in
            guard let item = (got?["added"] as? [[String: Any]])?.first else { return done(.no) }
            dropIdea(project, idea)
            let landed = item["project"] as? String
            // where it landed is where the next one goes, without reading the project list again; a place that
            // stash no longer has (deleted, renamed) is forgotten, so the next one asks
            if landed?.lowercased() == proj?.lowercased() { rememberPlace(project, landed ?? "") }
            else if proj != nil, landed == nil { rememberPlace(project, nil) }
            done(item["type"] as? String == type && landed?.lowercased() == proj?.lowercased() ? .yes : .misfiled)
        }
    }
    if let (p, names) = pick {
        if p.isEmpty { return capture(nil) }
        if let have = names.first(where: { $0.lowercased() == p.lowercased() }) { return capture(have) }
        return stashCall("stash_project", ["name": p]) { $0 == nil ? done(.no) : capture(p) } // picked as a new project
    }
    // a known place needs no project list: one call instead of two
    if let p = stashPlaces[project] { return capture(p.isEmpty ? nil : p) }
    stashCall("stash_read", ["view": "inbox", "limit": 0]) { read in
        guard let all = (read?["projects"] as? [[String: Any]])?.compactMap({ $0["name"] as? String }) else { return done(.no) }
        let names = all.filter(stashWord)
        if let p = stashProject(project, in: names) { capture(p) } else { done(.ask(names)) }
    }
}

/// Takes an idea off its desk's list for good.
func dropIdea(_ project: String, _ idea: String) {
    let rest = ideas(project).filter { $0 != idea }
    try? (rest.joined(separator: "\n") + (rest.isEmpty ? "" : "\n")).write(to: ideasFile(project), atomically: true, encoding: .utf8)
}
