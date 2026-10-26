// `notchroom --hook`: Claude Code runs this on every hook event. It records each session's state in
// ~/.claude/notchroom/<session>.json, logs the event for the whiteboard, flags parties, and holds a
// permission request open while the notch can answer it (see Answer.swift).
import Foundation

/// Hook event -> character state; nil leaves the state as it was (SessionEnd is handled before this).
func state(for ev: [String: Any]) -> String? {
    switch ev["hook_event_name"] as? String {
    case "SessionStart", "Stop": return "idle"
    case "PermissionRequest": return "waiting"
    case "Notification":
        let type = ev["notification_type"] as? String ?? "", msg = ev["message"] as? String ?? ""
        if ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(type) { return "waiting" }
        if ["idle_prompt", "agent_completed"].contains(type) { return "idle" }
        if type.isEmpty { return msg.contains("permission") ? "waiting" : msg.contains("waiting for your input") ? "idle" : nil } // older versions
        return nil // auth_success, quota notices and the like say nothing about what the agent does
    case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure": return "working"
    default: return nil
    }
}

/// What a tool call is doing, in a few words: "Editing main.swift", "Running make test".
func doing(_ tool: String, _ input: [String: Any]) -> String {
    let s = { (k: String) in input[k] as? String ?? "" }
    let file = (s("file_path").isEmpty ? s("notebook_path") : s("file_path")) as NSString
    let what: String
    switch tool {
    case "Bash": what = "Running " + (s("description").isEmpty ? s("command") : s("description"))
    case "Read": what = "Reading " + file.lastPathComponent
    case "Edit", "Write", "MultiEdit", "NotebookEdit": what = "Editing " + file.lastPathComponent
    case "Grep", "Glob": what = "Searching " + s("pattern")
    case "WebFetch": what = "Reading " + (URL(string: s("url"))?.host ?? "the web")
    case "WebSearch": what = "Searching the web for " + s("query")
    case "Agent", "Task": what = "Delegating: " + s("description")
    default: what = tool.hasPrefix("mcp__") ? "Using " + (tool.components(separatedBy: "__").last ?? tool) : tool
    }
    let line = what.split(separator: "\n").first.map(String.init) ?? what
    return line.count > 60 ? line.prefix(59) + "…" : line
}

/// A Bash command worth a party when it succeeds (PostToolUse only fires on success): a push or a test run.
func partyKind(_ command: String) -> String? {
    if command.range(of: #"\bgit\s+push\b"#, options: .regularExpression) != nil, !command.contains("--dry-run") { return "pushed!" }
    let tests = #"\b(make test|(npm|pnpm|yarn|bun)( run)? test|cargo test|swift test|go test|pytest|vitest|jest)\b"#
    return command.range(of: tests, options: .regularExpression) != nil ? "tests green!" : nil
}

func procInfo(_ pid: Int32) -> (ppid: Int32, path: String)? {
    var i = proc_bsdinfo()
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &i, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: 4096) // PROC_PIDPATHINFO_MAXSIZE
    proc_pidpath(pid, &buf, UInt32(buf.count))
    return (Int32(i.pbi_ppid), String(cString: buf))
}

/// The claude process this hook runs under, so the room can drop sessions that died without a SessionEnd.
/// Matched by path: the native install runs as ~/.local/share/claude/versions/<version>, named after the version.
func claudePid() -> Int32? {
    var pid = getppid()
    while pid > 1, let i = procInfo(pid) {
        if i.path.hasSuffix("/claude") || i.path.contains("/claude/versions/") { return pid }
        pid = i.ppid
    }
    return nil
}

func dayFile(_ d: Date) -> URL {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return logDir.appendingPathComponent(f.string(from: d) + ".tsv")
}

/// One line per hook event for the whiteboard: time, session, project, event, tool. O_APPEND keeps parallel hooks whole.
func log(_ fields: [String]) {
    try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    let fd = open(dayFile(Date()).path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    let line = fields.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") + "\n"
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

func hook() {
    // the room's own `claude -p` runs (ideas, filing to stash) must not show up as agents
    guard ProcessInfo.processInfo.environment["NOTCHROOM_NO_HOOK"] == nil,
          let ev = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
          let raw = ev["session_id"] as? String else { return }
    let id = String(raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }.prefix(64))
    guard !id.isEmpty else { return }
    let fm = FileManager.default, file = dir.appendingPathComponent(id + ".json")
    let event = ev["hook_event_name"] as? String ?? "", cwd = ev["cwd"] as? String ?? ""
    let tool = ev["tool_name"] as? String ?? "", input = ev["tool_input"] as? [String: Any] ?? [:]
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    log([String(Int(Date().timeIntervalSince1970)), id, project(of: cwd), event, tool])
    if event == "SessionEnd" { try? fm.removeItem(at: file); return }

    var out = json(file) ?? [:]
    if let s = state(for: ev) { out["state"] = s }
    out["cwd"] = cwd
    out["seen"] = Date().timeIntervalSince1970
    if let pid = claudePid() { out["pid"] = Int(pid) }
    switch event {
    case "UserPromptSubmit", "PreToolUse":
        out["doing"] = event == "PreToolUse" ? doing(tool, input) : "Thinking"
        for k in ["ask", "askId", "askSocket", "askAllow"] { out[k] = nil }
    case "PostToolUse", "PostToolUseFailure":
        for k in ["ask", "askId", "askSocket", "askAllow"] { out[k] = nil }
        if event == "PostToolUse", tool == "Bash", let kind = partyKind(input["command"] as? String ?? "") {
            try? "\(Date().timeIntervalSince1970)\t\(project(of: cwd))\t\(kind)".write(to: partyFile, atomically: true, encoding: .utf8)
        }
    case "Stop", "SessionStart": for k in ["doing", "ask", "askId", "askSocket", "askAllow"] { out[k] = nil }
    case "PermissionRequest":
        let (text, approvable) = askText(tool, input)
        try? fm.createDirectory(at: answerDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        out["ask"] = text; out["askAllow"] = approvable
        out["askId"] = UUID().uuidString
        out["askSocket"] = answerDir.appendingPathComponent(String(id.prefix(12)) + ".sock").path
    default: break
    }
    try? JSONSerialization.data(withJSONObject: out).write(to: file, options: .atomic)

    if event == "PermissionRequest", let sock = out["askSocket"] as? String, let request = out["askId"] as? String,
       let answer = awaitAnswer(sock, request), answer == "deny" || out["askAllow"] as? Bool == true {
        let decision: [String: Any] = answer == "allow" ? ["behavior": "allow"] : ["behavior": "deny", "message": "Denied from the notch."]
        let reply: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        if let d = try? JSONSerialization.data(withJSONObject: reply) { FileHandle.standardOutput.write(d) }
        out["state"] = "working"
        for k in ["ask", "askId", "askSocket", "askAllow"] { out[k] = nil }
        try? JSONSerialization.data(withJSONObject: out).write(to: file, options: .atomic)
    }
}
