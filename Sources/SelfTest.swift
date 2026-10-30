// `notchroom --test`: the logic that is easy to get wrong, checked without a window.
import Foundation

func test() {
    func fail(_ s: String) -> Never { print("FAIL " + s); exit(1) }
    let cases: [([String: Any], String?)] = [
        (["hook_event_name": "UserPromptSubmit"], "working"),
        (["hook_event_name": "PreToolUse"], "working"),
        (["hook_event_name": "PostToolUseFailure"], "working"),
        (["hook_event_name": "Stop"], "idle"),
        (["hook_event_name": "PermissionRequest"], "waiting"),
        (["hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "x"], "waiting"),
        (["hook_event_name": "Notification", "notification_type": "idle_prompt", "message": "x"], "idle"),
        (["hook_event_name": "Notification", "notification_type": "auth_success", "message": "x"], nil),
        (["hook_event_name": "Notification", "message": "Claude needs your permission to use Bash"], "waiting"),
        (["hook_event_name": "Notification", "message": "Claude is waiting for your input"], "idle"),
    ]
    for (ev, want) in cases where state(for: ev) != want { fail("state(for: \(ev)) -> \(state(for: ev) ?? "nil")") }
    let projects = [(devDir.path + "/kova/src/app", "kova"), (devDir.path + "/cue", "cue"), (devDir.path, "dev"), ("/tmp/x", "x")]
    for (cwd, want) in projects where project(of: cwd) != want { fail("project(of: \(cwd)) -> \(project(of: cwd))") }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("notchroom-test-\(getpid())").path
    for repo in ["group/repo", "kova", "kova/.claude/worktrees/feat"] {
        try? FileManager.default.createDirectory(atPath: "\(tmp)/\(repo)/.git", withIntermediateDirectories: true)
    }
    let nested = [("group/repo/src", "group/repo"), ("group/other", "group"), ("kova/.claude/worktrees/feat/x", "kova")]
    for (cwd, want) in nested where project(of: "\(tmp)/\(cwd)", in: tmp) != want { fail("project(of: \(cwd)) -> \(project(of: "\(tmp)/\(cwd)", in: tmp))") }
    try? FileManager.default.removeItem(atPath: tmp)
    let got = cleanIdeas("Here you go\n- Add 2FA login\n2. Dark mode — per page\n\n* " + String(repeating: "x", count: 95))
    if got != ["Here you go", "Add 2FA login", "Dark mode: per page"] { fail("cleanIdeas -> \(got)") }
    for (idea, want) in [("Dark mode per page", "idea"), ("Fix crash on empty README", "task"), ("Add XSS checks", "task"),
                         ("Prefix search", "idea"), ("Secure share links", "idea"), ("Test fixtures", "idea")] where stashType(idea) != want { fail("stashType(\(idea))") }
    if stashProject("group/Repo", in: ["repo-old", "repo"]) != "repo" { fail("stashProject nested") }
    if stashProject("notchroom", in: ["notch", "Notch Room"]) != nil { fail("stashProject none") }
    if repoProject("group/my.repo") != nil || repoProject("group/my-repo") != "my-repo" { fail("repoProject") }
    let reply = #"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"{\"added\":[]}"}]%@}}"#
    if stashResult(Data(String(format: reply, "").utf8))?["added"] == nil { fail("stashResult ok") }
    if stashResult(Data(("event: message\ndata: " + String(format: reply, "") + "\n\n").utf8))?["added"] == nil { fail("stashResult sse") }
    if stashResult(Data(String(format: reply, #","isError":true"#).utf8)) != nil || stashResult(Data("{}".utf8)) != nil { fail("stashResult error") }
    if doing("Edit", ["file_path": "/a/b/main.swift"]) != "Editing main.swift" { fail("doing Edit") }
    if doing("Bash", ["command": "make test\nmore"]) != "Running make test" { fail("doing Bash") }
    if doing("mcp__stash__stash_capture", [:]) != "Using stash_capture" { fail("doing mcp") }
    if partyKind("git push origin main") != "pushed!" || partyKind("git push --dry-run") != nil { fail("partyKind push") }
    if partyKind("cd x && cargo test --release") != "tests green!" || partyKind("make") != nil { fail("partyKind tests") }
    guard let b = iso6709("+5230+01322"), abs(b.lat - 52.5) < 0.01, abs(b.lon - 13.3667) < 0.01,
          let ny = iso6709("+404251-0740023"), abs(ny.lat - 40.714) < 0.01, abs(ny.lon + 74.0064) < 0.01 else { fail("iso6709") }
    let noon = Date(timeIntervalSince1970: 1782039600), midnight = Date(timeIntervalSince1970: 1782082800) // 2026-06-21 11:00, 23:00 UTC
    let up = sunElevation(lat: 52.5, lon: 13.37, at: noon), down = sunElevation(lat: 52.5, lon: 13.37, at: midnight)
    if abs(up - 61) > 1.5 || down > -5 { fail("sunElevation noon \(up), midnight \(down)") }
    let s = stats("100\ta\tkova\tPreToolUse\tBash\n160\ta\tkova\tPostToolUse\tBash\n1000\ta\tkova\tPreToolUse\tRead\n1010\tb\tcue\tStop\t\n")
    if s.tools != 2 || s.sessions != 2 || s.active != 60 || s.perProject["kova"] != 2 { fail("stats \(s)") }
    if askText("Bash", ["command": "ls"]) != ("Bash: ls", true) { fail("askText short") }
    if askText("Bash", ["command": String(repeating: "x", count: askLimit + 1)]).approvable { fail("askText long command approvable") }
    if askText("WebFetch", ["url": "https://x"]).approvable || !askText("Edit", ["file_path": "/a/b"]).approvable { fail("askText tools") }

    if visible("ls\u{202E}txt.exe\nrm") != "ls\\u{202E}txt.exe⏎ rm" { fail("visible -> \(visible("ls\u{202E}txt.exe\nrm"))") }
    if visible("e\u{0301}ü") != "e\\u{0301}\\u{00FC}" { fail("visible combining -> \(visible("e\u{0301}ü"))") }
    if askText("Bash", ["command": "a" + String(repeating: "\u{0301}", count: 300)]).approvable { fail("askText stacked marks") }
    if askText("Bash", ["command": "x" + String(repeating: "\u{200B}", count: 30)]).approvable { fail("askText hidden characters") }

    // the answer channel, over a real in-process XPC connection: a wrong request id is ignored, the right one gets
    // through, and a listener that wants another binary's signature is refused
    guard selfRequirement != nil else { fail("selfRequirement: this binary has no code signature") }
    let listener = NSXPCListener.anonymous()
    listener.delegate = answers
    listener.resume()
    let req = UUID().uuidString
    var answered: String?
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        answered = awaitAnswer(req, session: "s1", text: "Bash: ls", approvable: true,
                               via: { NSXPCConnection(listenerEndpoint: listener.endpoint) }, timeout: 5); done.signal()
    }
    func spin(until ok: () -> Bool) { let end = Date().addingTimeInterval(5); while !ok() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) } }
    spin { answers.isWaiting(req) }
    if answers.question(for: "s1")?.text != "Bash: ls" { fail("question(for:) doesn't carry the hook's own text") }
    answers.answer("not-" + req, "deny")
    answers.answer(req, "allow")
    spin { done.wait(timeout: .now()) == .success }
    if answered != "allow" { fail("answer channel -> \(answered ?? "nil"), want allow") }

    let strict = NSXPCListener.anonymous(), stranger = Stranger()
    strict.delegate = stranger
    strict.resume()
    var refused: String? = "unset"
    let done2 = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { refused = awaitAnswer("r", session: "s2", text: "x", approvable: true, via: { NSXPCConnection(listenerEndpoint: strict.endpoint) }, timeout: 3); done2.signal() }
    spin { done2.wait(timeout: .now()) == .success }
    if refused != nil || stranger.asked { fail("answer channel talked to a peer with another signature") }
    // the walk from a session up to its terminal app crosses root-owned processes (login); parent() must get through
    var ancestor = getpid(), steps = 0
    while ancestor > 1, let next = parent(ancestor), steps < 64 { ancestor = next; steps += 1 }
    if ancestor != 1 { fail("parent() stopped at \(ancestor) before launchd") }
    print("ok")
}

/// A listener that wants a signature this binary doesn't have: the hook must get nothing through to it.
final class Stranger: NSObject, NSXPCListenerDelegate, AnswerService {
    var asked = false
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.setCodeSigningRequirement("cdhash H\"" + String(repeating: "0", count: 40) + "\"")
        c.exportedInterface = NSXPCInterface(with: AnswerService.self)
        c.exportedObject = self
        c.resume()
        return true
    }
    func ask(_ request: String, session: String, text: String, approvable: Bool, withReply reply: @escaping (String) -> Void) { asked = true; reply("allow") }
}
