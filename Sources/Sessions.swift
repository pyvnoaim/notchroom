// The sessions the hook recorded, the projects they belong to, and reaching their terminals.
import AppKit

struct Agent {
    let id: String, state: String, project: String, seed: Int, pid: Int32?, doing: String?, seen: Double
    var ask: String? = nil // a permission request, if one is open: for placing the session only, never for answering it
}

/// The project a session belongs to: the folder right under ~/dev, else the cwd's own name.
func project(of cwd: String) -> String {
    let dev = devDir.path + "/"
    guard cwd.hasPrefix(dev) else { return (cwd as NSString).lastPathComponent }
    return String(cwd.dropFirst(dev.count).split(separator: "/").first ?? "")
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

/// Brings the terminal of a session to the front: in Ghostty the very terminal (matched by the session's
/// directory), anywhere else the terminal app itself.
// ponytail: two sessions started in the same directory, and Ghostty picks the first of them
func focusTerminal(_ pid: Int32) {
    var p = pid, app: NSRunningApplication?
    while p > 1, let i = procInfo(p) {
        if let a = NSRunningApplication(processIdentifier: p) { app = a; break }
        p = i.ppid
    }
    guard let app else { return }
    var vinfo = proc_vnodepathinfo()
    let cwd = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vinfo, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0
        ? withUnsafeBytes(of: vinfo.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : ""
    guard app.bundleIdentifier == "com.mitchellh.ghostty", !cwd.isEmpty else { app.activate(); return }
    let script = ["on run argv", "tell application \"Ghostty\"", "repeat with t in terminals",
                  "if working directory of t is item 1 of argv then", "focus t", "return", "end if", "end repeat", "activate",
                  "end tell", "end run"]
    let run = Process()
    run.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    run.arguments = script.flatMap { ["-e", $0] } + [cwd] // the directory as an argument, never spliced into the script
    try? run.run()
}

