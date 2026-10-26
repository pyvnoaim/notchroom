// Where notchroom keeps its state, its settings, and small file helpers shared by the hook and the app.
import Foundation

let home = FileManager.default.homeDirectoryForCurrentUser
let dir = home.appendingPathComponent(".claude/notchroom")
let ideasDir = dir.appendingPathComponent("ideas")
let logDir = dir.appendingPathComponent("log")
let answerDir = dir.appendingPathComponent("answers")
let aliveFile = dir.appendingPathComponent("alive")
let partyFile = dir.appendingPathComponent("party")

/// Settings from ~/.claude/notchroom/config, one `key = value` per line, `#` for comments:
///   projects = ~/dev           the folder that holds your repos; each recently touched one gets a desk
///   skip = old-thing, scratch  repos that never get a desk
let config: [String: String] = {
    let text = (try? String(contentsOf: dir.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    var out: [String: String] = [:]
    for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
        let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if kv.count == 2 { out[kv[0]] = kv[1] }
    }
    return out
}()
let devDir = URL(fileURLWithPath: ((config["projects"] ?? "~/dev") as NSString).expandingTildeInPath)
let skipProjects = Set((config["skip"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
let approveWait: TimeInterval = 20 // ponytail: how long a permission request waits for the notch before the terminal gets it

func mtime(_ path: String) -> Date? { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date }
func json(_ url: URL) -> [String: Any]? { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
