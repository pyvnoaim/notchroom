// `make screenshots`: draws the pictures in docs/ offscreen, from made-up projects, so they never show anyone's
// real repos. Built together with Sources/ (minus main.swift) as .build/screenshots, which writes to the folder it is given.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs")
let notchHeight: CGFloat = 28

func person(_ id: String, _ state: String, _ project: String, doing: String? = nil, ask: String? = nil) -> Agent {
    Agent(id: id, state: state, project: project, seed: id.utf8.reduce(7) { abs($0 &* 31 &+ Int($1)) }, pid: 1,
          doing: doing, ask: ask, seen: Date().timeIntervalSince1970)
}

let demoIdeas: [String: [String]] = [
    "api": ["Rate-limit the public endpoints per key", "Return ETags on list responses", "A /health endpoint with the build"],
    "app": ["Remember the last opened tab", "Offline banner when the API is down", "Haptic tick on pull to refresh"],
    "blog": ["An RSS feed per tag", "Reading time under each title", "Dark mode that follows the system"],
    "cli": ["--json output for every command", "Shell completions for zsh and fish", "A --dry-run flag for deploy"],
    "site": ["Lazy-load the screenshots", "A changelog page from git tags", "Copy button on code blocks"],
    "notchroom": ["A sound when an agent needs you", "Weekly totals on Friday's whiteboard", "Hats for long-running sessions"],
]

func demoRoom() -> Room {
    let v = Room(frame: NSRect(x: 0, y: 0, width: CGFloat(Room.cols) * Room.p + 28, height: notchHeight + CGFloat(Room.rows) * Room.p + 16))
    v.desks = demoIdeas.keys.sorted()
    v.ideas = demoIdeas
    v.recentRank = Dictionary(uniqueKeysWithValues: ["api", "app", "notchroom", "site", "cli", "blog"].enumerated().map { ($1, $0) })
    v.growth = ["api": (340, true), "app": (120, false), "blog": (60, false), "cli": (30, false), "site": (210, false), "notchroom": (80, false)]
    v.agents = [person("a1", "working", "api", doing: "Running make test"), person("a2", "working", "app", doing: "Editing Settings.swift"),
                person("a3", "waiting", "site", ask: "Bash: npm run deploy -- --prod"), person("a4", "idle", "blog"),
                person("a5", "working", "notchroom", doing: "Editing Room.swift")]
    v.sun = 35
    v.song = Song(title: "Night Drive", artist: "Neon Hills", cover: nil, playing: true)
    let art = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { r in
        NSGradient(colors: [.systemPink, .systemIndigo, .systemTeal])!.draw(in: r, angle: 45)
        NSColor.white.withAlphaComponent(0.9).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 22, dy: 22)).fill()
        return true
    }
    v.cover = pixelated(art, 16)
    var today = Stats()
    today.active = 4 * 3600 + 23 * 60; today.tools = 512; today.sessions = 7
    today.perProject = ["api": 190, "app": 140, "notchroom": 120, "site": 62]
    let hour = Calendar.current.component(.hour, from: Date())
    for (i, n) in [4, 9, 22, 30, 18, 26, 41, 35, 20, 12, 28, 16].enumerated() { today.hourly[(hour - 11 + i + 24) % 24] = n }
    v.today = today
    v.cat = Cat(x: 60, y: 33, tx: 60, ty: 33, mode: "sit", until: .distantFuture, place: "the floor")
    v.expanded = true
    for _ in 0..<200 { v.step() } // everyone has walked in and sat down
    return v
}

/// The view as it sits on a screen: a wallpaper, a menu bar, and the notch hanging from the top. The GIF gets a flat
/// background instead: gradients dither badly in 256 colors and bloat the file.
func framed(_ v: Room, canvas: NSSize, flat: Bool = false) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
    rep.size = canvas
    // drawn into a bitmap of our own so the rounded corners stay see-through
    let view = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(v.bounds.width * 2), pixelsHigh: Int(v.bounds.height * 2),
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
    view.size = v.bounds.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: view)
    v.draw(v.bounds)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // over the background, not copied onto it: a copy would punch the corners' transparency through the wallpaper
    func place() {
        view.draw(in: NSRect(x: (canvas.width - v.bounds.width) / 2, y: canvas.height - v.bounds.height, width: v.bounds.width, height: v.bounds.height),
                  from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    if flat {
        hex(0x1b1630).setFill(); NSRect(origin: .zero, size: canvas).fill()
        place()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
    NSGradient(colors: [hex(0x2a1f4d), hex(0x1b2b4f), hex(0x123a44)])!.draw(in: NSRect(origin: .zero, size: canvas), angle: -30)
    let bar = NSRect(x: 0, y: canvas.height - notchHeight, width: canvas.width, height: notchHeight)
    NSColor(white: 0, alpha: 0.35).setFill(); bar.fill()
    let menu: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.85)]
    NSAttributedString(string: "Terminal    Shell    Edit    View    Window", attributes: menu).draw(at: NSPoint(x: 18, y: bar.minY + 6))
    let clock = NSAttributedString(string: "Mon 14:08", attributes: menu)
    clock.draw(at: NSPoint(x: canvas.width - clock.size().width - 18, y: bar.minY + 6))
    place()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func png(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
    print("wrote docs/\(name)")
}

try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let canvas = NSSize(width: 940, height: 300)

// the hero: a few seconds of the room; someone new walks in, ideas get pitched, tests pass
do {
    let v = demoRoom()
    v.bubble = ("cli", demoIdeas["cli"]![0])
    let url = out.appendingPathComponent("room.gif")
    let frames = 80
    let gif = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
    CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for f in 0..<frames {
        if f == 6 { v.agents.append(person("a6", "working", "cli", doing: "Running cargo build")) }
        if f == 30 { v.bubble = ("api", demoIdeas["api"]![1]) }
        if f == 52 { v.throwParty("api", "tests green!") }
        v.step()
        CGImageDestinationAddImage(gif, framed(v, canvas: NSSize(width: v.bounds.width + 24, height: v.bounds.height + 12), flat: true).cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
    }
    CGImageDestinationFinalize(gif)
    print("wrote docs/room.gif")
}

// a permission request, answered from the notch
do {
    let v = demoRoom()
    v.mouse = NSPoint(x: 14 + 116 * 3, y: 10 + 10 * 3)
    png(framed(v, canvas: canvas), "permission.png")
}

// a desk's card: what is going on, the ideas, the growth
do {
    let v = demoRoom()
    v.mouse = NSPoint(x: 14 + 20 * 3, y: 10 + 45 * 3)
    png(framed(v, canvas: canvas), "card.png")
}

// a rainy night, right after a push
do {
    let v = demoRoom()
    v.sun = -14
    v.weather = Weather(rain: true, snow: false, cloudy: true)
    v.throwParty("app", "pushed!")
    for _ in 0..<14 { v.step() }
    png(framed(v, canvas: canvas), "night.png")
}

// collapsed: heads on the left, the latest news on the right
do {
    let v = demoRoom()
    v.expanded = false
    v.notchWidth = 180
    v.frame = NSRect(x: 0, y: 0, width: 180 + 2 * v.earWidth(), height: notchHeight)
    png(framed(v, canvas: NSSize(width: 940, height: 64)), "collapsed.png")
}
