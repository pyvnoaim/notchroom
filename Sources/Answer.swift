// Answering a permission request from the notch, over XPC. The room offers a Mach service that only launchd can
// hand out (declared in its LaunchAgent), and both ends insist the other is this very build by code signature,
// checked by macOS against the running process (exec-safe; the build has the hardened runtime, so nothing can be
// injected into it either). The question travels with the request, and the card's question and buttons come from
// there alone, never from files anything could write. Each answer is the reply to its own request.
import Foundation
import Security

let answerService = "xyz.pyvno.notchroom.answers" // must match MachServices in the LaunchAgent (Makefile)
let askLimit = 200 // a command longer than this, once made visible, is answered in the terminal

@objc protocol AnswerService {
    func ask(_ request: String, session: String, text: String, approvable: Bool, withReply reply: @escaping (String) -> Void)
}

/// A code requirement that only this exact build meets: its own code directory hash.
let selfRequirement: String? = {
    var code: SecCode?, stat: SecStaticCode?, info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat,
          SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
    return "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
}()

/// The text exactly as it will run, in printable ASCII: newlines as ⏎, everything else outside ASCII (accents,
/// combining marks, invisible and direction-changing characters alike) spelled out as \u{…}. What is shown can't
/// hide or reorder anything, and its length is its real length.
func visible(_ s: String) -> String {
    s.unicodeScalars.map { u -> String in
        if u == "\n" { return "⏎ " }
        return (0x20...0x7E).contains(u.value) ? String(u) : String(format: "\\u{%04X}", u.value)
    }.joined()
}

/// What a permission request asks, and whether it may be approved from the notch: only when the card shows all of
/// it (a Bash command up to `askLimit` once made visible, a file tool with its full path). Anything else is answered
/// in the terminal.
func askText(_ tool: String, _ input: [String: Any]) -> (text: String, approvable: Bool) {
    if tool == "Bash", let c = input["command"] as? String {
        let v = visible(c)
        return ("Bash: " + (v.count > askLimit ? v.prefix(askLimit) + "…" : v), v.count <= askLimit)
    }
    if ["Read", "Edit", "Write", "MultiEdit", "NotebookEdit"].contains(tool),
       let f = (input["file_path"] ?? input["notebook_path"]) as? String { return ("\(tool): \(visible(f))", true) }
    return (doing(tool, input), false)
}

/// The hook's side: ask the room and wait for the click. nil (room not running, not reachable, no answer in time,
/// or "terminal") leaves it to the terminal's prompt.
func awaitAnswer(_ request: String, session: String, text: String, approvable: Bool,
                 via connect: () -> NSXPCConnection = { NSXPCConnection(machServiceName: answerService) },
                 timeout: TimeInterval = approveWait) -> String? {
    guard let requirement = selfRequirement else { return nil }
    let conn = connect()
    conn.remoteObjectInterface = NSXPCInterface(with: AnswerService.self)
    conn.setCodeSigningRequirement(requirement)
    conn.resume()
    defer { conn.invalidate() }
    let done = DispatchSemaphore(value: 0)
    var result: String?
    let proxy = conn.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? AnswerService
    proxy?.ask(request, session: session, text: text, approvable: approvable) { word in result = word; done.signal() }
    _ = done.wait(timeout: .now() + timeout)
    return result == "deny" || (result == "allow" && approvable) ? result : nil
}

/// An open permission request, as the waiting hook sent it.
struct Question { let request: String, session: String, text: String, approvable: Bool, since: Date; let reply: (String) -> Void }

/// The room's side: holds each open request until one of its buttons is clicked.
final class Answers: NSObject, NSXPCListenerDelegate, AnswerService {
    private var waiting: [String: Question] = [:]

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard let requirement = selfRequirement else { return false }
        c.setCodeSigningRequirement(requirement)
        c.exportedInterface = NSXPCInterface(with: AnswerService.self)
        c.exportedObject = self
        c.resume()
        return true
    }

    func ask(_ request: String, session: String, text: String, approvable: Bool, withReply reply: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            self.waiting = self.waiting.filter { Date().timeIntervalSince($0.value.since) < approveWait + 5 }
            self.waiting[request] = Question(request: request, session: session, text: text, approvable: approvable, since: Date(), reply: reply)
        }
    }

    func isWaiting(_ request: String) -> Bool { waiting[request] != nil }

    /// The newest open request from a session, if its hook asked us.
    func question(for session: String) -> Question? { waiting.values.filter { $0.session == session }.max { $0.since < $1.since } }

    /// Allow / Deny / Terminal for one request; a request whose hook gave up is gone and the click does nothing.
    func answer(_ request: String, _ word: String) { waiting.removeValue(forKey: request)?.reply(word) }
}

let answers = Answers()

/// Offers the service; only works when launchd started the room from its LaunchAgent (make install).
func listenForAnswers() -> NSXPCListener {
    let l = NSXPCListener(machServiceName: answerService)
    l.delegate = answers
    l.resume()
    return l
}
