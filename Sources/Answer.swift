// Answering a permission request from the notch, over XPC. The room offers a Mach service that only launchd can
// hand out (declared in its LaunchAgent), and both ends insist the other is this very binary by code signature,
// checked by macOS against the running process (exec-safe). So nothing else running as you, a background command
// an agent started included, can answer, and each answer is the reply to its own request, never a newer one.
import Foundation
import Security

let answerService = "xyz.pyvno.notchroom.answers" // must match MachServices in the LaunchAgent (Makefile)
let askLimit = 200 // a command longer than this, once made visible, is answered in the terminal

@objc protocol AnswerService {
    func ask(_ request: String, withReply reply: @escaping (String) -> Void)
}

/// A code requirement that only this exact build meets: its own code directory hash.
let selfRequirement: String? = {
    var code: SecCode?, stat: SecStaticCode?, info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat,
          SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return nil }
    return "cdhash H\"" + hash.map { String(format: "%02x", $0) }.joined() + "\""
}()

/// The text as it will really run: control, format and bidi characters spelled out as \u{…}, newlines as ⏎,
/// so the card can't show something other than the command.
func visible(_ s: String) -> String {
    s.unicodeScalars.map { u -> String in
        if u == "\n" { return "⏎ " }
        switch u.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
            return String(format: "\\u{%04X}", u.value)
        default: return String(u)
        }
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
func awaitAnswer(_ request: String, via connect: () -> NSXPCConnection = { NSXPCConnection(machServiceName: answerService) },
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
    proxy?.ask(request) { word in result = word; done.signal() }
    _ = done.wait(timeout: .now() + timeout)
    return result == "allow" || result == "deny" ? result : nil
}

/// The room's side: holds each open request's reply until its button is clicked.
final class Answers: NSObject, NSXPCListenerDelegate, AnswerService {
    private var waiting: [String: (reply: (String) -> Void, since: Date)] = [:]

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard let requirement = selfRequirement else { return false }
        c.setCodeSigningRequirement(requirement)
        c.exportedInterface = NSXPCInterface(with: AnswerService.self)
        c.exportedObject = self
        c.resume()
        return true
    }

    func ask(_ request: String, withReply reply: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            self.waiting = self.waiting.filter { Date().timeIntervalSince($0.value.since) < approveWait + 5 }
            self.waiting[request] = (reply, Date())
        }
    }

    func isWaiting(_ request: String) -> Bool { waiting[request] != nil }

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
