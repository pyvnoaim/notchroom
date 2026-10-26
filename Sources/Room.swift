// The room: who is where, how they move, and drawing it, open or collapsed into the notch.
import AppKit

struct Walker { var x: Double, y: Double, agent: Agent, goal: (Int, Int)? = nil, path: [(Double, Double)] = [], leaving = false
    var arrived: Bool { path.isEmpty } }

struct Cat { var x = 120.0, y = 20.0, tx = 120.0, ty = 20.0, mode = "sit", until = Date(), meow = Date.distantPast, place = "the floor" }

struct Particle { var x: Double, y: Double, vx: Double, vy: Double, color: UInt32 }

/// What a hover card is about.
enum Target: Equatable { case desk(String), agent(String), clock, player, cat, pin }

/// A hover card: a title with a status chip, an optional picture, lines (some clickable) and buttons.
struct Card {
    var title: String, chip: (String, UInt32)
    var image: NSImage? = nil
    var lines: [(text: String, color: UInt32, bullet: UInt32?, action: (() -> Void)?)] = []
    var buttons: [(label: String, color: UInt32, action: () -> Void)] = []
}

final class Room: NSView {
    var agents: [Agent] = []
    var desks: [String] = []
    var recentRank: [String: Int] = [:]
    var ideas: [String: [String]] = [:]
    var filing: [String: String] = [:] // idea -> "filing…" / "filed" / "couldn't file"
    var growth: [String: (commits: Int, released: Bool)] = [:]
    var bubble: (project: String, text: String)?
    var sun = 30.0, weather = Weather()
    var song: Song?, cover: NSImage?
    var today = Stats()
    var party: (project: String, kind: String, until: Date)?
    var confetti: [Particle] = []
    var walkers: [String: Walker] = [:]
    var cat = Cat()
    var expanded = false
    var keptOpen = false // clicked open: stays open without hovering
    var autoCard: Target? // shown without hovering, while the room peeks open for a permission request
    var tick = 0
    var mouse: NSPoint?
    static let p: CGFloat = 3, cols = 216, rows = 72, desks = 6, maxHeads = 5
    static let door = (-8.0, 31.0), aisle = 31.0
    var ox: CGFloat = 0, oy: CGFloat = 0, scale: CGFloat = 3
    var targets: [(rect: NSRect, target: Target)] = []
    var clicks: [(rect: NSRect, action: () -> Void)] = []
    var pinned: (target: Target, card: NSRect)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func px(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: UInt32) {
        hex(c).setFill()
        NSRect(x: ox + CGFloat(x) * scale, y: oy + CGFloat(y) * scale, width: CGFloat(w) * scale, height: CGFloat(h) * scale).fill()
    }

    func pt(_ x: Int, _ y: Int) -> NSPoint { NSPoint(x: ox + CGFloat(x) * scale, y: oy + CGFloat(y) * scale) }
    func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> NSRect { NSRect(origin: pt(x, y), size: NSSize(width: CGFloat(w) * scale, height: CGFloat(h) * scale)) }

    func sprite(_ rows: [String], _ x: Int, _ y: Int, _ a: Agent?, glyph: UInt32 = 0xffffff, flip: Bool = false) {
        let s = a?.seed ?? 0
        let pal: [Character: UInt32] = ["h": hairs[s / 7 % hairs.count], "f": skins[s / 3 % skins.count], "s": shirts[s % shirts.count],
                                        "e": 0x1a1a1a, "l": 0x3a3f5c, "k": 0x222222, "o": 0xe0905d, "d": 0xa8582e,
                                        "y": 0xffe066, "g": 0x8a8a8a, "z": glyph, "!": glyph]
        for (r, row) in rows.enumerated() {
            for (c, ch) in (flip ? Array(row.reversed()) : Array(row)).enumerated() {
                if let col = pal[ch] { px(x + c, y + rows.count - 1 - r, 1, 1, col) }
            }
        }
    }

    // MARK: layout of the room

    func deskOrigin(_ d: Int) -> (Int, Int) { (6 + d % 3 * 46, d < 3 ? 44 : 18) }

    /// A desk's hover zone. The six cells tile the work area edge to edge, so moving between desks never drops the card.
    func cell(_ d: Int) -> NSRect { d < 3 ? box(1 + d % 3 * 46, 31, 46, 29) : box(1 + d % 3 * 46, 0, 46, 31) }

    /// Where each agent belongs right now: its desk chair, beside its desk (waving), or a spot on the couch.
    func stations() -> [String: (Int, Int)] {
        var out: [String: (Int, Int)] = [:]
        for (d, proj) in desks.enumerated() {
            let (dx, dy) = deskOrigin(d)
            for (k, a) in agents.filter({ $0.project == proj && $0.state == "working" }).enumerated() { out[a.id] = (dx + 7 + k * 3, dy - 4) }
            for (k, a) in agents.filter({ $0.project == proj && $0.state == "waiting" }).enumerated() { out[a.id] = (dx + 17 + k * 11, dy - 12) }
        }
        for (i, a) in agents.filter({ out[$0.id] == nil }).enumerated() { out[a.id] = (157 + i % 3 * 17, 45 + i / 3 * 2) } // idle, or no desk
        return out
    }

    // MARK: motion, once a tick

    func step() {
        tick += 1
        let goals = stations()
        for a in agents {
            if walkers[a.id] == nil { walkers[a.id] = Walker(x: Room.door.0, y: Room.door.1, agent: a) }
            walkers[a.id]!.agent = a
            walkers[a.id]!.leaving = false
        }
        for id in walkers.keys where !agents.contains(where: { $0.id == id }) { walkers[id]!.leaving = true }
        for id in Array(walkers.keys) {
            var w = walkers[id]!
            let goal = w.leaving ? (Int(Room.door.0), Int(Room.door.1)) : goals[id]
            if let goal, w.goal == nil || w.goal! != goal {
                // up or down to the aisle between the rows, along it, then straight to the spot
                w.goal = goal
                w.path = abs(w.y - Room.aisle) < 1 && abs(Double(goal.1) - Room.aisle) < 1 ? [(Double(goal.0), Double(goal.1))]
                    : [(w.x, Room.aisle), (Double(goal.0), Room.aisle), (Double(goal.0), Double(goal.1))]
            }
            var budget = 2.0
            while budget > 0, let (tx, ty) = w.path.first {
                let dx = tx - w.x, dy = ty - w.y, d = (dx * dx + dy * dy).squareRoot()
                if d <= budget { w.x = tx; w.y = ty; budget -= d; w.path.removeFirst() }
                else { w.x += dx / d * budget; w.y += dy / d * budget; budget = 0 }
            }
            walkers[id] = w.leaving && w.arrived ? nil : w
        }
        stepCat()
        confetti = confetti.compactMap { p in
            var p = p
            p.x += p.vx + sin(Double(tick) / 3 + p.y) * 0.2; p.y += p.vy; p.vy -= 0.03
            return p.y < 0 ? nil : p
        }
    }

    func stepCat() {
        let dx = cat.tx - cat.x, dy = cat.ty - cat.y, d = (dx * dx + dy * dy).squareRoot()
        if d > 1 { cat.x += dx / d; cat.y += dy / d; return }
        guard Date() > cat.until else { return }
        let roll = Double.random(in: 0..<1)
        let free = desks.indices.filter { d in !agents.contains { $0.project == desks[d] && $0.state == "working" } }
        if roll < 0.3, let d = free.randomElement() { // nap on an empty chair
            let (x, y) = deskOrigin(d)
            (cat.tx, cat.ty, cat.mode, cat.place) = (Double(x + 9), Double(y - 5), "sleep", "\(desks[d])'s chair")
            cat.until = Date().addingTimeInterval(.random(in: 20...40))
        } else if roll < 0.6, let d = free.max(by: { (recentRank[desks[$0]] ?? 99) < (recentRank[desks[$1]] ?? 99) }) {
            // sit on the keyboard of the desk you've ignored the longest
            let (x, y) = deskOrigin(d)
            (cat.tx, cat.ty, cat.mode, cat.place) = (Double(x + 9), Double(y + 2), "sit", "\(desks[d])'s keyboard")
            cat.until = Date().addingTimeInterval(.random(in: 15...30))
        } else {
            (cat.tx, cat.ty, cat.mode, cat.place) = (.random(in: 4...140), .random(in: 2...40), "sit", "the floor")
            cat.until = Date().addingTimeInterval(.random(in: 5...12))
        }
    }

    func throwParty(_ project: String, _ kind: String) {
        party = (project, kind, Date().addingTimeInterval(7))
        confetti = (0..<80).map { _ in
            Particle(x: .random(in: 0...216), y: .random(in: 72...90), vx: .random(in: -0.4...0.4), vy: .random(in: -1.0 ... -0.2),
                     color: [0xffe066, 0xe05d5d, 0x5d9be0, 0x7fd36b, 0xc46be0, 0xffffff].randomElement()!)
        }
    }

    // MARK: drawing

    override func draw(_ dirty: NSRect) {
        let b = bounds, r: CGFloat = expanded ? 16 : 8
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: 0, y: b.maxY))
        shape.line(to: NSPoint(x: b.maxX, y: b.maxY))
        shape.appendArc(withCenter: NSPoint(x: b.maxX - r, y: r), radius: r, startAngle: 0, endAngle: -90, clockwise: true)
        shape.appendArc(withCenter: NSPoint(x: r, y: r), radius: r, startAngle: 270, endAngle: 180, clockwise: true)
        shape.close()
        NSColor.black.setFill()
        shape.fill()
        expanded ? drawRoom() : drawEars()
    }

    var notchWidth: CGFloat = 180

    /// One line for the collapsed notch: who needs you, else what the newest work is, else the music, else today's time.
    func status() -> (text: String, color: UInt32)? {
        if let a = agents.first(where: { $0.state == "waiting" }) { return ("\(a.project) needs you", 0xffb347) }
        let busy = agents.filter { $0.state == "working" }
        if let a = busy.max(by: { $0.seen < $1.seen }) {
            return ((busy.count > 1 ? "\(busy.count) working · " : "") + "\(a.project): \(a.doing ?? "working")", 0x5fd38d)
        }
        if let s = song, s.playing { return ("♫ \(s.title)", 0xe8e3f5) }
        return today.active >= 60 ? ("\(hm(today.active)) today", 0x8a80a8) : nil
    }

    func statusLabel() -> NSImage? { status().map { text($0.text.count > 24 ? $0.text.prefix(23) + "…" : $0.text, 10, $0.color) } }

    /// Width of each side of the collapsed notch (heads left, status right), in steps of 24 so it doesn't jitter.
    func earWidth() -> CGFloat {
        let heads = agents.isEmpty ? 0 : CGFloat(min(agents.count, Room.maxHeads) * 11 + (agents.count > Room.maxHeads ? 24 : 0) + 16)
        let label = statusLabel().map { $0.size.width + 30 } ?? 0
        let w = min(max(heads, label), 170) // never wider than this, whatever is going on
        return w == 0 ? 0 : (w / 24).rounded(.up) * 24
    }

    /// Whether moving the mouse changes the picture: something else hovered, or inside a card (its rows light up).
    func mouseMatters(_ old: NSPoint?, _ new: NSPoint?) -> Bool {
        guard let old, let new else { return (old == nil) != (new == nil) }
        if let p = pinned, [old, new].contains(where: { p.card.insetBy(dx: -10, dy: -10).contains($0) }) { return true }
        return hit(old) != hit(new)
    }

    func drawEars() {
        if let label = statusLabel(), let st = status() {
            let x = (bounds.width + notchWidth) / 2 + 10, y = (bounds.height - label.size.height) / 2
            if st.color != 0xffb347 || tick / 4 % 2 == 0 { hex(st.color).setFill(); NSRect(x: x, y: bounds.height / 2 - 3, width: 6, height: 6).fill() }
            label.put(at: NSPoint(x: x + 12, y: y))
        }
        scale = 2; oy = ((bounds.height - 8) / 2).rounded()
        // the first few heads, waiting ones first, then "+3" for the rest
        let shown = (agents.filter { $0.state == "waiting" } + agents.filter { $0.state != "waiting" }).prefix(Room.maxHeads)
        for (i, a) in shown.enumerated() {
            ox = CGFloat(10 + i * 11)
            sprite([".hhh", "hhff", ".fff"], 0, 1, a)
            if a.state != "waiting" || tick / 4 % 2 == 0 { px(0, -1, 4, 1, stateColor[a.state] ?? 0x6a6a7a) }
        }
        if agents.count > Room.maxHeads {
            let more = text("+\(agents.count - Room.maxHeads)", 10, 0x8a80a8)
            more.put(at: NSPoint(x: CGFloat(10 + Room.maxHeads * 11 + 2), y: (bounds.height - more.size.height) / 2))
        }
    }

    func plant(_ x: Int, _ y: Int) {
        px(x, y, 6, 6, 0x8b4a2b); px(x + 1, y + 1, 4, 4, 0x5a3020)
        px(x - 1, y + 2, 8, 5, 0x3f8f4f); px(x + 1, y, 4, 9, 0x3f8f4f); px(x + 2, y + 4, 2, 2, 0x5fb86f)
    }

    var cachedBackdrop: NSImage?
    override func viewDidChangeBackingProperties() { cachedBackdrop = nil }

    /// The parts of the room that never change, painted once into an image: hundreds of fills that would
    /// otherwise repeat every frame.
    func backdrop() -> NSImage {
        if let b = cachedBackdrop { return b }
        let size = NSSize(width: CGFloat(Room.cols) * scale, height: CGFloat(Room.rows) * scale)
        let (sx, sy) = (ox, oy)
        (ox, oy) = (0, 0)
        let img = bitmap(size) {
        // floor planks, staggered seams
        px(0, 0, 216, 60, 0x6b4a33)
        for row in 0..<12 {
            px(0, row * 5, 216, 1, 0x5a3d2b)
            for x in stride(from: (row * 9) % 17, to: 216, by: 17) { px(x, row * 5 + 1, 1, 4, 0x5a3d2b) }
        }

        // back wall, a framed landscape, bookshelf, side walls and the door
        px(0, 60, 216, 12, 0x3b2f5a); px(0, 70, 216, 2, 0x2a2142); px(0, 60, 216, 1, 0x1d1630)
        px(117, 61, 26, 9, 0x6a4430); px(118, 62, 24, 7, 0xf2c49b); px(136, 66, 2, 2, 0xfff1c1)
        px(119, 63, 9, 2, 0x6b5b8a); px(121, 65, 5, 1, 0x6b5b8a); px(123, 66, 2, 1, 0x6b5b8a)
        px(127, 63, 11, 2, 0x57497a); px(129, 65, 6, 1, 0x57497a); px(131, 66, 2, 1, 0x57497a); px(118, 62, 24, 1, 0x3f6f5a)
        px(184, 61, 22, 8, 0x5a3d2b)
        for (i, c) in [0xd05050, 0x5070d0, 0xd0b050, 0x50a070, 0xc46be0, 0xe0905d, 0x5de0c8, 0xd05050].enumerated() {
            px(185 + i * 2 + i / 4, 62, 2, 5 + i % 2, UInt32(c))
        }
        px(0, 0, 2, 72, 0x2a2142); px(214, 0, 2, 72, 0x2a2142)
        px(0, 27, 2, 11, 0x8a5a3b); px(0, 28, 2, 9, 0x4a3022) // the door everyone comes in by

        // lounge: rug, couch against the wall, coffee table, plants, the record player's cabinet
        px(156, 8, 50, 30, 0x7a3b4f); px(158, 10, 46, 26, 0x8f4a5f)
        for x in stride(from: 162, to: 202, by: 6) { px(x, 10, 2, 26, 0x9c5568) }
        px(154, 52, 56, 6, 0x24585c); px(156, 43, 52, 9, 0x2f6f73); px(156, 43, 52, 1, 0x24585c)
        px(173, 44, 1, 8, 0x24585c); px(190, 44, 1, 8, 0x24585c)
        px(152, 43, 4, 15, 0x24585c); px(208, 43, 4, 15, 0x24585c)
        px(168, 22, 26, 10, 0x6a4430); px(168, 23, 26, 9, 0x8a5a3b); px(173, 27, 2, 2, 0xf4efe6); px(184, 26, 5, 3, 0x5070d0)
        plant(140, 52); plant(204, 3); plant(146, 3)
        px(128, 25, 20, 11, 0x6a4430); px(128, 26, 20, 10, 0x8a5a3b)
        px(130, 28, 10, 7, 0x2a2a2a); px(131, 29, 7, 5, 0x111111); px(134, 31, 2, 2, 0xe05d5d)
        px(139, 29, 1, 5, 0xbbbbbb); px(138, 33, 1, 1, 0xbbbbbb)
        }
        (ox, oy) = (sx, sy)
        cachedBackdrop = img
        return img
    }

    func drawRoom() {
        scale = Room.p
        ox = ((bounds.width - CGFloat(Room.cols) * scale) / 2).rounded(); oy = 10
        let roomRect = box(0, 0, Room.cols, Room.rows)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: roomRect, xRadius: 6, yRadius: 6).addClip()
        targets = []; clicks = []
        let light = min(max((sun + 6) / 12, 0), 1) // 0 night ... 1 day, civil twilight in between
        let music = song?.playing == true
        let bob = music && tick / 3 % 2 == 0 ? 1 : 0

        backdrop().draw(in: roomRect)

        // back wall: windows onto the real sky, a clock with the real time
        let dayBlue: UInt32 = weather.rain || weather.snow ? 0x8a96a3 : weather.cloudy ? 0xb2c0cc : 0x8fc8f0
        let sky = light < 0.5 ? mix(0x16244a, 0xf0a070, light * 2) : mix(0xf0a070, dayBlue, (light - 0.5) * 2)
        let sunny = light > 0.6 && !weather.cloudy && !weather.rain && !weather.snow
        for wx in [60, 156] {
            if sunny { // sunlight on the floor, warmer while the sun is low
                let k = (light - 0.6) / 0.4
                NSColor(srgbRed: 1, green: sun < 15 ? 0.7 : 0.85, blue: 0.5, alpha: 0.18 * k).setFill(); box(wx - 2, 46, 22, 14).fill()
            }
            px(wx - 1, 61, 20, 9, 0x1a1426); px(wx, 62, 18, 7, sky)
            if light < 0.3 && !weather.cloudy { px(wx + 3, 67, 1, 1, 0xffffff); px(wx + 14, 63, 1, 1, 0xffffff) }
            if light < 0.3 && wx == 156 { px(wx + 12, 65, 2, 2, 0xf2e6b8) }
            if weather.rain { for k in 0..<6 { px(wx + (k * 5 + tick / 2) % 18, 62 + (k * 3 + 100 - tick) % 6, 1, 2, 0xc8d8f0) } }
            if weather.snow { for k in 0..<5 { px(wx + (k * 7 + tick / 6) % 18, 62 + (k * 5 + 300 - tick / 2) % 7, 1, 1, 0xffffff) } }
            px(wx + 8, 62, 1, 7, 0x1a1426); px(wx, 65, 18, 1, 0x1a1426)
        }
        let cal = Calendar.current, now = Date(), r = Double.pi / 180
        let hour = Double(cal.component(.hour, from: now) % 12) + Double(cal.component(.minute, from: now)) / 60
        px(103, 62, 7, 7, 0xe8e3f5); px(106, 65, 1, 1, 0x1d1630)
        px(106 + Int((sin(hour * 30 * r) * 1.6).rounded()), 65 + Int((cos(hour * 30 * r) * 1.6).rounded()), 1, 1, 0x1d1630)
        let minute = Double(cal.component(.minute, from: now))
        px(106 + Int((sin(minute * 6 * r) * 2.6).rounded()), 65 + Int((cos(minute * 6 * r) * 2.6).rounded()), 1, 1, 0xe05d5d)
        targets.append((box(102, 61, 9, 9), .clock)) // its card has today's numbers

        // the record player: spinning disc, tone arm, sleeve, notes
        if music { let spin = [(131, 29), (137, 29), (137, 33), (131, 33)][tick / 2 % 4]; px(spin.0, spin.1, 1, 1, 0x666666) }
        if let cover {
            NSGraphicsContext.current?.imageInterpolation = .none
            cover.draw(in: box(141, 28, 6, 6))
        } else { px(141, 28, 6, 6, 0x555566) }
        if music { for k in 0..<2 { let rise = (tick / 2 + k * 9) % 18; sprite(note, 132 + k * 4 + rise / 6, 36 + rise, nil, glyph: 0xf4efe6) } }
        targets.append((box(128, 25, 20, 11), .player))

        // workstations: three across, two deep; monitor faces the chair, nameplate on the floor below
        var anchors: [String: NSPoint] = [:]
        let hoverDesk = mouse.flatMap { m in desks.indices.first { cell($0).contains(m) } }
        for (d, proj) in desks.enumerated() {
            let (dx, dy) = deskOrigin(d)
            if d == hoverDesk {
                NSColor(white: 1, alpha: 0.08).setFill(); cell(d).insetBy(dx: 3, dy: 3).fill()
                hex(0xffe066).withAlphaComponent(0.6).setFill(); cell(d).insetBy(dx: 3, dy: 3).frame(withWidth: 2)
            }
            let here = agents.filter { $0.project == proj }
            let busy = here.contains { $0.state == "working" && walkers[$0.id]?.arrived == true }
            let g = growth[proj] ?? (0, false)
            px(dx, dy, 24, 9, 0x8a5a3b); px(dx, dy, 24, 1, 0x6a4430); px(dx, dy + 8, 24, 1, 0x9c6a48)
            px(dx + 6, dy + 5, 12, 7, 0x222222); px(dx + 11, dy + 4, 2, 1, 0x222222)
            px(dx + 7, dy + 6, 10, 5, busy ? 0x1e3a5f : 0x333340)
            if busy { for k in 0..<4 where (tick / 3 + k * 7 + d) % 5 != 0 { px(dx + 8, dy + 7 + k, 1 + (tick / 3 + k * 3) % 6, 1, 0x7fe0a0) } }
            px(dx + 8, dy + 2, 8, 2, 0xbbbbbb)
            // decor that comes with growth: cactus at 25 commits, a second screen at 75, books at 150, a trophy at v1
            if g.commits >= 25 { px(dx + 20, dy + 5, 3, 3, 0x8b4a2b); px(dx + 21, dy + 7, 1, 3, 0x3f8f4f); px(dx + 20, dy + 8, 1, 1, 0x3f8f4f) }
            else { px(dx + 20, dy + 5, 2, 2, 0xf4efe6) }
            if g.commits >= 75 { px(dx + 1, dy + 4, 5, 6, 0x222222); px(dx + 2, dy + 5, 3, 4, busy ? 0x1e3a5f : 0x333340) }
            if g.commits >= 150 { px(dx + 1, dy + 1, 4, 1, 0xd05050); px(dx + 1, dy + 2, 4, 1, 0x5070d0); px(dx + 2, dy + 3, 3, 1, 0xd0b050) }
            if g.released || g.commits >= 300 { px(dx + 19, dy + 1, 3, 1, 0xb8860b); px(dx + 20, dy + 2, 1, 1, 0xd4a017); px(dx + 19, dy + 3, 3, 1, 0xffd700) }
            if !(ideas[proj] ?? []).isEmpty { px(dx + 16, dy + 10, 2, 2, 0xffe066) } // sticky note on the monitor: this desk has ideas
            px(dx + 7, dy - 6, 10, 6, 0x555566); px(dx + 7, dy - 7, 10, 2, 0x3a3a4a)
            anchors[proj] = pt(dx + 12, dy + 12)

            let plate = text(String(proj.prefix(12)), 9, here.isEmpty ? 0xc9b8a6 : 0xffffff)
            let s = plate.size, at = NSPoint(x: pt(dx + 12, 0).x - s.width / 2, y: pt(0, dy - 11).y)
            NSColor(white: 0, alpha: 0.35).setFill(); NSRect(origin: at, size: s).insetBy(dx: -3, dy: -1).fill()
            plate.put(at: at)
            targets.append((cell(d), .desk(proj)))
        }

        // the cat, under everyone's feet
        let catFlip = cat.tx < cat.x - 0.5
        let walking = abs(cat.tx - cat.x) + abs(cat.ty - cat.y) > 1
        let (cx, cy) = (Int(cat.x.rounded()), Int(cat.y.rounded()))
        if walking { sprite(catWalk[tick / 2 % 2], cx, cy, nil, flip: catFlip) }
        else if cat.mode == "sleep" { sprite(catSleep, cx, cy, nil); sprite(["zz", ".z", "zz"], cx + 5, cy + 4 + tick / 8 % 2, nil, glyph: 0x9fb4ff) }
        else { sprite(catSit, cx, cy, nil) }
        targets.append((box(cx - 1, cy - 1, 10, 8), .cat))

        // everyone, back to front
        let partyNow = party.flatMap { $0.until > Date() ? $0 : nil }
        for w in walkers.values.sorted(by: { $0.y > $1.y }) {
            let a = w.agent, x = Int(w.x.rounded()), y = Int(w.y.rounded())
            if partyNow?.project == a.project && !w.leaving { // everyone on that project dances
                sprite(wave[tick % 2], x, y + tick / 2 % 2, a)
                anchors[a.project] = pt(x + 5, y + 13)
                targets.append((box(x, y, 10, 12), .agent(a.id)))
                continue
            }
            if !w.arrived {
                let up = (w.path.first?.1 ?? w.y) > w.y + 0.1
                sprite((up ? walkUp : walkDown)[tick / 2 % 2], x, y, a)
                targets.append((box(x, y, 9, 12), .agent(a.id)))
            } else if a.state == "working" {
                sprite(typing[(tick / 2 + a.seed) % 2], x, y + bob, a)
                px(x, y - 3, 10, 2, 0x3a3a4a) // the chair back in front of them
                anchors[a.project] = pt(x + 5, y + 8)
                targets.append((box(x, y - 3, 10, 11), .agent(a.id)))
            } else if a.state == "waiting" {
                sprite(wave[tick / 3 % 2], x, y + bob, a)
                if tick / 4 % 2 == 0 { px(x + 3, y + 13, 3, 7, 0xffffff); sprite(bang, x + 4, y + 14, nil, glyph: 0xff8c1a) }
                anchors[a.project] = nil // the "!" is the bubble
                targets.append((box(x, y, 10, 20), .agent(a.id)))
            } else {
                sprite(lie, x, y, a)
                let rise = (tick / 3 + a.seed) % 8
                sprite(zGlyph, x + 1 + rise / 3, y + 6 + rise, nil, glyph: 0x9fb4ff)
                if anchors[a.project] != nil, !agents.contains(where: { $0.project == a.project && $0.state != "idle" }) { anchors[a.project] = pt(x + 3, y + 5) }
                targets.append((box(x - 1, y - 2, 17, 9), .agent(a.id)))
            }
        }
        for p in confetti { px(Int(p.x), Int(p.y), 1, 1 + Int(p.x) % 2, p.color) }

        // night falls on the room; the lamp and busy screens keep glowing
        if light < 1 {
            NSColor(srgbRed: 0.04, green: 0.03, blue: 0.12, alpha: (1 - light) * 0.5).setFill(); roomRect.fill()
            if light < 0.6 {
                for k in 1...4 { NSColor(srgbRed: 1, green: 0.85, blue: 0.5, alpha: 0.05).setFill(); NSBezierPath(ovalIn: box(148 - k * 4, 46 - k * 4, 5 + k * 8, 5 + k * 8)).fill() }
                px(148, 46, 5, 5, 0xffd27a)
                for (d, proj) in desks.enumerated() where agents.contains(where: { $0.project == proj && $0.state == "working" }) {
                    let (dx, dy) = deskOrigin(d)
                    NSColor(srgbRed: 0.4, green: 0.7, blue: 1, alpha: 0.12).setFill(); box(dx + 3, dy + 3, 18, 12).fill()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        // the strip behind the notch: click it to keep the room open while you work
        let band = NSRect(x: 0, y: pt(0, Room.rows).y, width: bounds.width, height: bounds.height - pt(0, Room.rows).y)
        let overBand = mouse.map { band.contains($0) } == true
        let label = text(keptOpen ? "pinned · click here to close" : "click here to keep it open", 9,
                         keptOpen ? 0xffe066 : overBand ? 0xe8e3f5 : 0x6a6080)
        label.put(at: NSPoint(x: ox + 10, y: band.midY - label.size.height / 2))
        targets.insert((band, .pin), at: 0)

        // party banner, else a hover card, else an idea bubble
        if let p = partyNow, let a = anchors[p.project] {
            drawBubble(p.kind, at: a, icon: star)
        }
        let hovered: Target? = {
            if let p = pinned, let m = mouse, p.card.insetBy(dx: -10, dy: -10).contains(m) { return p.target } // keep it while you reach for its buttons
            if let m = mouse, let t = hit(m) { return t }
            return autoCard
        }()
        if let t = hovered, let anchor = targets.last(where: { $0.target == t })?.rect, let card = card(for: t) {
            pinned = (t, drawCard(card, beside: anchor))
        } else {
            pinned = nil
            if partyNow == nil, let b = bubble, let a = anchors[b.project], tick % 80 < 60 { drawBubble(b.text, at: a, icon: bulb) }
            if Date() < cat.meow { drawBubble("meow", at: pt(cx + 4, cy + 6), icon: nil) }
        }
    }

    /// What is under a point: anything in the room before the desk cell it stands in.
    func hit(_ m: NSPoint) -> Target? {
        let here = targets.filter { $0.rect.contains(m) }
        return (here.last { if case .desk = $0.target { false } else { true } } ?? here.last)?.target
    }

    // MARK: clicks

    override func mouseDown(with e: NSEvent) {
        let m = convert(e.locationInWindow, from: nil)
        if let c = clicks.last(where: { $0.rect.contains(m) }) { c.action(); needsDisplay = true; return }
        switch hit(m) {
        case .pin: keptOpen.toggle(); needsDisplay = true
        case .agent(let id): if let pid = agents.first(where: { $0.id == id })?.pid { focusTerminal(pid) }
        case .desk(let p): if let pid = agents.first(where: { $0.project == p })?.pid { focusTerminal(pid) }
        case .cat: cat.meow = Date().addingTimeInterval(2)
        default: break
        }
    }
}
