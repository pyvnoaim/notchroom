// The notch panel: where it sits, when it opens, and what it reloads how often.
import AppKit

func notchRect() -> NSRect {
    if let s = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
       let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
        let h = s.safeAreaInsets.top
        return NSRect(x: s.frame.minX + l.width, y: s.frame.maxY - h, width: s.frame.width - l.width - r.width, height: h)
    }
    let s = NSScreen.screens[0], bar = s.frame.maxY - s.visibleFrame.maxY
    let h = bar > 0 ? bar : 24
    return NSRect(x: s.frame.midX - 90, y: s.frame.maxY - h, width: 180, height: h)
}

func runApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    let room = Room()
    panel.contentView = room
    panel.orderFrontRegardless()

    let started = Date().timeIntervalSince1970, coords = homeCoords()
    var notch = notchRect(), peekUntil = Date.distantPast, asked = Set<String>(), turn = 0, lastTarget = NSRect.zero
    var lastParty = started, coverURL: String?

    func layout(tick: Bool = false) {
        room.notchWidth = notch.width
        let ear = room.earWidth()
        let small = NSRect(x: notch.minX - ear, y: notch.minY, width: notch.width + 2 * ear, height: notch.height)
        let w = max(CGFloat(Room.cols) * Room.p + 28, small.width), h = notch.height + CGFloat(Room.rows) * Room.p + 16
        let big = NSRect(x: notch.midX - w / 2, y: notch.maxY - h, width: w, height: h)

        let m = NSEvent.mouseLocation
        // grown by a point so a cursor pinned to the top screen edge still counts as inside (contains() excludes maxY)
        let hovering = (room.expanded ? big : small).insetBy(dx: -1, dy: -1).contains(m)
        let was = room.expanded
        room.expanded = hovering || Date() < peekUntil
        if hovering || !room.expanded { room.autoCard = nil }
        panel.ignoresMouseEvents = !room.expanded // closed, clicks fall through to the menu bar
        let target = room.expanded ? big : small
        if target != lastTarget {
            // animator() resizes without blocking the run loop like setFrame(_:display:animate:) does
            if lastTarget == .zero { panel.setFrame(target, display: true) }
            else { NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().setFrame(target, display: true) } }
            lastTarget = target
        }
        let mouse = hovering ? NSPoint(x: m.x - panel.frame.minX, y: m.y - panel.frame.minY) : nil
        // a frame costs a few ms: the timer animates at 10 fps, a mouse move redraws only when it changes something
        if tick || was != room.expanded || room.mouseMatters(room.mouse, mouse) { room.needsDisplay = true }
        room.mouse = mouse
    }
    // hover follows the mouse directly; mouse-moved global monitors need no accessibility permission
    NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in layout() }
    NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { e in layout(); return e }

    func everyMinute() {
        let recent = recentProjects()
        room.recentRank = Dictionary(uniqueKeysWithValues: recent.enumerated().map { ($1, $0) })
        room.sun = coords.map { sunElevation(lat: $0.lat, lon: $0.lon, at: Date()) }
            ?? ((7..<20).contains(Calendar.current.component(.hour, from: Date())) ? 30 : -20)
        room.today = stats((try? String(contentsOf: dayFile(Date()), encoding: .utf8)) ?? "")
        // logs older than a week go
        for f in (try? FileManager.default.contentsOfDirectory(at: logDir, includingPropertiesForKeys: nil)) ?? []
        where Date().timeIntervalSince(mtime(f.path) ?? Date()) > 7 * 86400 { try? FileManager.default.removeItem(at: f) }
    }
    var counting = false
    func countCommits() {
        guard !counting else { return }
        counting = true
        let desks = room.desks
        DispatchQueue.global(qos: .utility).async {
            let g = Dictionary(uniqueKeysWithValues: desks.map { ($0, growth($0)) })
            DispatchQueue.main.async { room.growth.merge(g) { $1 }; counting = false }
        }
    }
    func everyTenMinutes() {
        countCommits()
        if let coords { fetchWeather(coords) { room.weather = $0 } }
    }

    everyMinute()
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
        room.step()
        if room.tick % 10 == 1 {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: aliveFile.path, contents: nil) // heartbeat: hooks only wait on a running room
            notch = notchRect()
            room.agents = loadAgents()
            room.desks = deskProjects(room.agents, room.recentRank.sorted { $0.value < $1.value }.map(\.key))
            room.ideas = Dictionary(uniqueKeysWithValues: room.desks.map { ($0, ideas($0)) })
            if room.desks.contains(where: { room.growth[$0] == nil }) { countCommits() } // a desk that just appeared
            refreshIdeas(room.desks)

            // a new permission question peeks the room open with its card
            let asking = room.agents.filter { $0.state == "waiting" && $0.ask != nil }
            if let a = asking.first(where: { !asked.contains($0.id + ($0.ask ?? "")) }) {
                peekUntil = Date().addingTimeInterval(8); room.autoCard = .agent(a.id)
            } else if room.agents.contains(where: { $0.state == "waiting" && $0.ask == nil && !asked.contains($0.id) }) {
                peekUntil = Date().addingTimeInterval(4)
            }
            asked = Set(room.agents.filter { $0.state == "waiting" }.flatMap { [$0.id, $0.id + ($0.ask ?? "")] })

            if let line = try? String(contentsOf: partyFile, encoding: .utf8) {
                let f = line.split(separator: "\t").map(String.init)
                if f.count == 3, let t = Double(f[0]), t > lastParty {
                    lastParty = t
                    room.throwParty(f[1], f[2])
                    peekUntil = Date().addingTimeInterval(6)
                }
            }

            room.song = nowPlaying()
            if room.song?.cover != coverURL {
                coverURL = room.song?.cover
                room.cover = nil
                if let s = coverURL, let url = URL(string: s) {
                    URLSession.shared.dataTask(with: url) { data, _, _ in
                        let img = data.flatMap(NSImage.init(data:)).flatMap { pixelated($0, 16) }
                        DispatchQueue.main.async { if coverURL == s { room.cover = img } }
                    }.resume()
                }
            }
        }
        if room.tick % 600 == 2 { everyMinute() }
        if room.tick % 6000 == 3 { everyTenMinutes() }
        if room.tick % 80 == 0 { // next desk with ideas takes the speech bubble
            let talkers = room.desks.filter { !(room.ideas[$0] ?? []).isEmpty }
            turn += 1
            let p = talkers.isEmpty ? nil : talkers[turn % talkers.count]
            room.bubble = p.map { ($0, room.ideas[$0]!.randomElement()!) }
        }
        layout(tick: true)
    }
    app.run()
}
