// The sessions the hook recorded, the projects they belong to, and reaching their terminals.
import AppKit

struct Agent {
    let id: String, state: String, project: String, seed: Int, pid: Int32?, doing: String?, seen: Double
    var ask: String? = nil // a permission request, if one is open: for placing the session only, never for answering it
}

/// The project a session belongs to: the outermost git repo under ~/dev (so ~/dev/group/repo is "group/repo",
/// and a worktree or submodule stays with its repo), else the folder right under ~/dev, else the cwd's own name.
func project(of cwd: String, in root: String = devDir.path) -> String {
    let dev = root + "/"
    guard cwd.hasPrefix(dev) else { return (cwd as NSString).lastPathComponent }
    let parts = cwd.dropFirst(dev.count).split(separator: "/")
    let n = (1..<max(parts.count, 1) + 1).first {
        FileManager.default.fileExists(atPath: dev + parts.prefix($0).joined(separator: "/") + "/.git")
    } ?? 1
    return parts.prefix(n).joined(separator: "/")
}

func loadAgents() -> [Agent] {
    let fm = FileManager.default
    let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { f in
        guard let j = json(f) else { return nil }
        // ponytail: pid liveness only, a reused pid keeps a ghost around until that process exits too
        if let pid = j["pid"] as? Int, kill(Int32(pid), 0) != 0, errno == ESRCH { try? fm.removeItem(at: f); return nil }
        let id = f.deletingPathExtension().lastPathComponent
        return Agent(id: id, state: j["state"] as? String ?? "idle", project: project(of: j["cwd"] as? String ?? ""),
                     seed: id.utf8.reduce(7) { abs($0 &* 31 &+ Int($1)) }, pid: (j["pid"] as? Int).map(Int32.init),
                     doing: j["doing"] as? String, seen: j["seen"] as? Double ?? 0, ask: j["ask"] as? String,
)
    }
}

/// Git repos in ~/dev, most recently touched first.
func recentProjects() -> [String] {
    let fm = FileManager.default
    func touched(_ name: String) -> Date? {
        ["index", "logs/HEAD", "HEAD"].compactMap { mtime("\(devDir.path)/\(name)/.git/\($0)") }.max()
    }
    let names = ((try? fm.contentsOfDirectory(atPath: devDir.path)) ?? []).filter { !skipProjects.contains($0) }
    return names.compactMap { n in touched(n).map { (n, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
}

/// Projects with agents in them get desks first, the rest go to recent work; alphabetical so desks don't hop around.
// ponytail: more than Room.desks projects with live agents and the extra agents only show in the collapsed notch
func deskProjects(_ agents: [Agent], _ recent: [String]) -> [String] {
    var out: [String] = []
    for p in agents.map(\.project) + recent where !p.isEmpty && !out.contains(p) { out.append(p) }
    return out.prefix(Room.desks).sorted()
}

/// Runs a command and returns its stdout; for git, which is quick.
func capture(_ args: [String]) -> String {
    let run = Process(), out = Pipe()
    run.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    run.arguments = args
    run.standardOutput = out
    run.standardError = FileHandle.nullDevice
    guard (try? run.run()) != nil else { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    run.waitUntilExit()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// How grown-up a project is, for the desk decor: commit count, and whether it has a v1 (or later) tag.
func growth(_ project: String) -> (commits: Int, released: Bool) {
    let path = "\(devDir.path)/\(project)"
    return (Int(capture(["git", "-C", path, "rev-list", "--count", "HEAD"])) ?? 0,
            !capture(["git", "-C", path, "tag", "-l", "v[1-9]*"]).isEmpty)
}

/// Opens a new Claude Code session in a project: a Ghostty tab (or window) that starts in the project and types
/// `claude` into your shell, so the tab stays a normal shell afterwards; Terminal.app when Ghostty isn't installed.
/// When the project already runs in a VS Code-family editor, there instead: its window, then a Claude Code tab.
func newSession(_ project: String, in app: NSRunningApplication? = nil) {
    let path = "\(devDir.path)/\(project)"
    if let bundle = app?.bundleURL, let scheme = editorScheme(bundle) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: bundle, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            // the extension opens its tab in whichever window has focus, so ask once the project's window has it
            // ponytail: a fixed second for the window to come forward, poll the frontmost window if that proves short
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let u = URL(string: "\(scheme)://anthropic.claude-code/open") { NSWorkspace.shared.open(u) }
            }
        }
        return
    }
    let ghostty = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.mitchellh.ghostty") != nil
    let script = ghostty
        ? ["on run argv", "tell application \"Ghostty\"", "set cfg to new surface configuration",
           "set initial working directory of cfg to item 1 of argv", "set initial input of cfg to \"claude\" & linefeed",
           "if (count of windows) > 0 then", "new tab in front window with configuration cfg", "else",
           "new window with configuration cfg", "end if", "activate", "end tell", "end run"]
        : ["on run argv", "tell application \"Terminal\"", "do script \"cd \" & quoted form of (item 1 of argv) & \" && claude\"",
           "activate", "end tell", "end run"]
    let run = Process()
    run.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    run.arguments = script.flatMap { ["-e", $0] } + [path] // the path as an argument, never spliced into the script
    try? run.run()
}

/// VS Code, when installed.
let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")

/// Opens a project's folder in an app; VS Code reuses the folder's window when it has one.
func openIn(_ project: String, _ app: URL) {
    NSWorkspace.shared.open([devDir.appendingPathComponent(project)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
}

/// A process's parent, from the kernel's process table. Unlike proc_pidinfo this also works across processes owned
/// by root, such as the `login` that sits between a terminal app and its shells.
func parent(_ pid: Int32) -> Int32? { kinfo(pid)?.kp_eproc.e_ppid }

func kinfo(_ pid: Int32) -> kinfo_proc? {
    var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride, mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info
}

/// The terminal device a process writes to, such as /dev/ttys003; nil for one without a terminal.
func tty(_ pid: Int32) -> String? {
    guard let dev = kinfo(pid)?.kp_eproc.e_tdev, dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
    return "/dev/" + String(cString: name)
}

/// The URL scheme of a VS Code-family editor (VS Code, Cursor, Windsurf, VSCodium…), from its product.json; nil for
/// any other app.
func editorScheme(_ bundle: URL) -> String? {
    guard let d = try? Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/app/product.json")),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return j["urlProtocol"] as? String
}

/// The app a session runs in: the first ancestor with a Dock icon, so VS Code's terminal resolves to VS Code
/// rather than to the Code Helper that owns its shells.
func hostApp(_ pid: Int32) -> NSRunningApplication? {
    var p = pid
    while p > 1 {
        if let a = NSRunningApplication(processIdentifier: p), a.activationPolicy == .regular { return a }
        guard let up = parent(p) else { return nil }
        p = up
    }
    return nil
}

/// Brings the terminal of a session to the front: in Ghostty the very terminal, in a VS Code-family editor the
/// window holding that folder, anywhere else the app itself. Ghostty can't tell which terminal holds a process, so
/// when several share the session's directory, the session's own tty gets a marker title for a moment to find it.
// ponytail: the marker can land mid-way through Claude's own output; a stray frame at worst, the next redraw fixes it
func focusTerminal(_ pid: Int32) {
    guard let app = hostApp(pid) else { return }
    var vinfo = proc_vnodepathinfo()
    let cwd = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vinfo, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0
        ? withUnsafeBytes(of: vinfo.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : ""
    if let bundle = app.bundleURL, editorScheme(bundle) != nil, !cwd.isEmpty {
        NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: bundle, configuration: NSWorkspace.OpenConfiguration()) // reuses the folder's window
        return
    }
    guard app.bundleIdentifier == "com.mitchellh.ghostty", !cwd.isEmpty else { app.activate(); return }
    let script = ["on run argv", "set {dir, dev, mark, osc} to argv", "tell application \"Ghostty\"", "set ts to {}",
                  "repeat with t in terminals", "if working directory of t is dir then set end of ts to contents of t", "end repeat",
                  "if (count of ts) is 0 then", "activate", "return", "end if",
                  "if (count of ts) is 1 or dev is \"\" then", "focus item 1 of ts", "return", "end if",
                  "set olds to {}", "repeat with t in ts", "set end of olds to name of t", "end repeat", "end tell",
                  "do shell script \"printf \" & quoted form of osc & \" \" & quoted form of mark & \" > \" & quoted form of dev",
                  "delay 0.2", "tell application \"Ghostty\"", "repeat with i from 1 to count of ts",
                  "if name of item i of ts is mark then", "focus item i of ts",
                  "do shell script \"printf \" & quoted form of osc & \" \" & quoted form of (item i of olds) & \" > \" & quoted form of dev",
                  "return", "end if", "end repeat", "focus item 1 of ts", "end tell", "end run"]
    let run = Process()
    run.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    // everything as arguments, never spliced into the script; osc is the set-title escape, printf's format
    run.arguments = script.flatMap { ["-e", $0] } + [cwd, tty(pid) ?? "", "notchroom-\(pid)", "\u{1b}]2;%s\u{07}"]
    try? run.run()
}

/// The card's button for a session's app: "Open VS Code", "Open Ghostty", "Open terminal" when unknown.
func openLabel(_ pid: Int32) -> String {
    hostApp(pid)?.localizedName.map { $0 == "Code" ? "Open VS Code" : "Open \($0)" } ?? "Open terminal"
}
