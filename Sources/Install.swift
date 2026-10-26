// `notchroom --install-hooks` and `--uninstall-hooks`: adds or removes notchroom's hooks in
// ~/.claude/settings.json and leaves every other setting and hook as it was (a backup goes next to it first).
import Foundation

let hookEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
                  "PermissionRequest", "Notification", "Stop"]

func isOurs(_ group: [String: Any]) -> Bool {
    (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String ?? "").hasSuffix("notchroom --hook") }
}

func setHooks(install: Bool) {
    let fm = FileManager.default, file = home.appendingPathComponent(".claude/settings.json")
    let exists = fm.fileExists(atPath: file.path)
    guard !exists || json(file) != nil else { print("~/.claude/settings.json is not valid JSON; leaving it alone"); exit(1) }
    var settings = json(file) ?? [:]
    let me = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? "notchroom"
    let command = me.contains(" ") ? "\"\(me)\" --hook" : "\(me) --hook"

    var hooks = settings["hooks"] as? [String: Any] ?? [:]
    for event in hookEvents {
        var groups = (hooks[event] as? [[String: Any]] ?? []).filter { !isOurs($0) } // replaces an older install's path too
        // the permission hook may wait for an answer from the notch, so it gets longer than the rest
        if install { groups.append(["hooks": [["type": "command", "command": command, "timeout": event == "PermissionRequest" ? 30 : 5]]]) }
        hooks[event] = groups.isEmpty ? nil : groups
    }
    settings["hooks"] = hooks.isEmpty ? nil : hooks

    do {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if exists {
            let backup = file.appendingPathExtension("bak-notchroom")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: file, to: backup)
        }
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: file)
        print(install ? "hooks added to ~/.claude/settings.json (\(hookEvents.count) events)" : "hooks removed from ~/.claude/settings.json")
    } catch {
        print("could not write ~/.claude/settings.json: \(error.localizedDescription)"); exit(1)
    }
}
