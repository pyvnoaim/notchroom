// Answering a permission request from the notch. The waiting hook listens on a Unix socket and takes an answer only
// from a process running the notchroom binary itself, and only for the request it is holding (a random id). So no
// other process running as you, a background command an agent started included, can approve anything, and a late
// click can't answer a newer request than the one it was shown.
import Foundation
import Darwin

let askLimit = 300 // longer commands are shown cut short, and then only Deny / Terminal are offered

/// What a permission request asks, and whether it may be approved from the notch: only when the card can show all
/// of it (a Bash command up to `askLimit`, a file tool with its full path). Anything else is answered in the terminal.
func askText(_ tool: String, _ input: [String: Any]) -> (text: String, approvable: Bool) {
    if tool == "Bash", let c = input["command"] as? String {
        return ("Bash: " + (c.count > askLimit ? c.prefix(askLimit) + "…" : c), c.count <= askLimit)
    }
    if ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool),
       let f = (input["file_path"] ?? input["notebook_path"]) as? String { return ("\(tool): \(f)", true) }
    return (doing(tool, input), false)
}

func unixAddress(_ path: String) -> sockaddr_un? {
    var a = sockaddr_un()
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { return nil }
    a.sun_family = sa_family_t(AF_UNIX)
    a.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &a.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
    return a
}

func withSockaddr<T>(_ a: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
}

/// Holds one request open on `sock` until the room answers it or `timeout` runs out. Connections from anything that
/// isn't this very binary, and answers for any other request, are dropped. nil: leave it to the terminal.
func listenForAnswer(_ sock: String, _ request: String, timeout: TimeInterval) -> String? {
    guard var addr = unixAddress(sock) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd); unlink(sock) }
    unlink(sock)
    guard withSockaddr(&addr, { bind(fd, $0, $1) }) == 0, chmod(sock, 0o600) == 0, listen(fd, 4) == 0 else { return nil }
    let me = procInfo(getpid())?.path
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let left = Int32(deadline.timeIntervalSinceNow * 1000)
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard left > 0, poll(&p, 1, left) > 0 else { return nil }
        let c = accept(fd, nil, nil)
        guard c >= 0 else { continue }
        defer { close(c) }
        var pid: pid_t = 0, len = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(c, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) == 0, me != nil, procInfo(pid)?.path == me else { continue }
        var wait = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](repeating: 0, count: 128)
        let n = read(c, &buf, buf.count)
        let words = n > 0 ? String(decoding: buf[..<n], as: UTF8.self).split(separator: " ").map(String.init) : []
        guard words.count == 2, words[0] == request, ["allow", "deny", "terminal"].contains(words[1]) else { continue }
        return words[1] == "terminal" ? nil : words[1]
    }
}

/// The hook's side: wait for the room only while it is running, so with notchroom closed prompts are as before.
func awaitAnswer(_ sock: String, _ request: String) -> String? {
    guard let alive = mtime(aliveFile.path), Date().timeIntervalSince(alive) < 3 else { return nil }
    return listenForAnswer(sock, request, timeout: approveWait)
}

/// The room's side: Allow / Deny / Terminal, sent to the hook holding that request.
func answer(_ sock: String, _ request: String, _ word: String) {
    DispatchQueue.global(qos: .userInitiated).async {
        guard var addr = unixAddress(sock) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        guard withSockaddr(&addr, { connect(fd, $0, $1) }) == 0 else { return }
        _ = "\(request) \(word)".withCString { write(fd, $0, strlen($0)) }
        // stay connected until the hook hangs up: it can only check who is asking while we're still here
        var wait = timeval(tv_sec: 2, tv_usec: 0), byte: UInt8 = 0
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        _ = read(fd, &byte, 1)
    }
}
