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
    let got = cleanIdeas("Here you go\n- Add 2FA login\n2. Dark mode — per page\n\n* " + String(repeating: "x", count: 95))
    if got != ["Here you go", "Add 2FA login", "Dark mode: per page"] { fail("cleanIdeas -> \(got)") }
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
    print("ok")
}
