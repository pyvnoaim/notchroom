// Hover cards and speech bubbles: what you see when you point at something in the room.
import AppKit

extension Room {
    func card(for t: Target) -> Card? {
        switch t {
        case .pin, .bubble: return nil
        case .agent(let id): return agents.first { $0.id == id }.map { projectCard($0.project, focus: id) }
        case .desk(let p): return projectCard(p)
        case .cat: return Card(title: "Byte", chip: (cat.mode == "sleep" ? "napping" : "on patrol", 0xe0905d),
                               lines: [("on \(cat.place)", 0xe8e3f5, nil, nil), ("click to say hi", 0x8a80a8, nil, nil)])
        case .clock:
            var c = Card(title: "Today", chip: ("\(today.sessions) sessions", 0x9fb4ff))
            c.lines = [("\(hm(today.active)) active", 0xe8e3f5, 0x5fd38d, nil), ("\(today.tools) tool calls", 0xe8e3f5, 0x5fd38d, nil)]
            for (p, n) in today.perProject.sorted(by: { $0.value > $1.value }).prefix(5) { c.lines.append(("\(p)  \(n)", 0xc9b8a6, 0xffe066, nil)) }
            return c
        case .player:
            guard let s = song else { return Card(title: "Record player", chip: ("silent", 0x8a80a8), lines: [("play something in resona", 0x8a80a8, nil, nil)]) }
            return Card(title: "Now playing", chip: (s.playing ? "playing" : "paused", s.playing ? 0x5fd38d : 0x8a80a8), image: cover,
                        lines: [(s.title, 0xffffff, nil, nil), (s.artist, 0xc9b8a6, nil, nil)])
        }
    }

    /// A project's card: who is on it and doing what, a permission question with its buttons, and the ideas.
    /// At most one question gets buttons (the clicked session's, else the first), built from that request alone.
    func projectCard(_ proj: String, focus: String? = nil) -> Card {
        let here = agents.filter { $0.project == proj }
        let chip: (String, UInt32) =
            here.contains { $0.state == "waiting" } ? ("needs you", 0xffb347)
            : here.contains { $0.state == "working" } ? (here.count > 1 ? "\(here.count) working" : "working", 0x5fd38d)
            : here.isEmpty ? ("no agent", 0x8a80a8) : ("idle", 0x9fb4ff)
        var c = Card(title: proj, chip: chip)
        if let g = growth[proj], g.commits > 0 { c.lines.append(("\(g.commits) commits" + (g.released ? " · v1 shipped" : ""), 0x8a80a8, nil, nil)) }
        // who gets the buttons is decided from the open requests themselves, never from the session files
        let asking = here.filter { answers.question(for: $0.id) != nil }
        let asker = asking.first { $0.id == focus } ?? asking.first
        for a in here {
            if answers.question(for: a.id) != nil, a.id != asker?.id {
                c.lines.append(("another session here is asking too: hover it", 0xffb347, 0xffb347, nil))
            } else if a.id == asker?.id, let q = answers.question(for: a.id) {
                // the question and its buttons as the waiting hook itself sent them, nothing from the session's file
                let left = max(0, Int(q.since.timeIntervalSinceNow + approveWait))
                c.lines.append((q.text, 0xffb347, 0xffb347, nil))
                c.lines.append((q.approvable ? "answer here within \(left)s, or in the terminal"
                                             : "too much to show here: allow it in the terminal", 0x8a80a8, nil, nil))
                c.buttons = (q.approvable ? [("Allow", 0x5fd38d, { answers.answer(q.request, "allow") })] : [])
                    + [("Deny", 0xe05d5d, { answers.answer(q.request, "deny") }),
                       ("Terminal", 0x8a80a8, { answers.answer(q.request, "terminal"); if let pid = a.pid { focusTerminal(pid) } })]
            } else if a.ask != nil, a.state == "waiting" {
                c.lines.append(("waiting for permission: answer it in the terminal", 0xffb347, 0xffb347, nil))
                if let pid = a.pid {
                    c.buttons = [(openLabel(pid), 0x8a80a8, { focusTerminal(pid) })]
                }
            } else if let what = a.doing, a.state == "working" {
                c.lines.append((what, 0xe8e3f5, 0x5fd38d, nil))
            }
        }
        if asker != nil { return c } // a permission question: keep the card short, the buttons in reach
        if c.buttons.isEmpty {
            c.buttons = (here.first?.pid.map { pid in [(openLabel(pid), UInt32(0x8a80a8), { focusTerminal(pid) })] } ?? [])
                + [("New session", 0x5fd38d, { newSession(proj, in: here.first?.pid.flatMap(hostApp)) })]
                // a session already in VS Code has its own Open button above
                + (here.first?.pid.flatMap(hostApp)?.bundleIdentifier == "com.microsoft.VSCode" ? []
                   : vscode.map { app in [("VS Code", UInt32(0x8a80a8), { openIn(proj, app) })] } ?? [])
        }
        let list = ideas[proj] ?? []
        if let pick = picking[proj] {
            // asked once per repo, then remembered; the idea that asked is filed as soon as there's an answer
            c.lines.append(("where in stash do \(proj)'s ideas go?", 0x8a80a8, nil, nil))
            let repo = repoProject(proj)
            let places = pick.names.prefix(12).map { ($0, $0) } // ponytail: first 12 projects, scroll if stashes grow past that
                + (repo.map { r in pick.names.contains(r) ? [] : [("new project \"\(r)\"", r)] } ?? []) + [("Inbox", "")]
            for (label, place) in places {
                c.lines.append((label, 0xe8e3f5, 0x9fb4ff, { [weak self] in
                    self?.picking[proj] = nil
                    self?.file(pick.idea, proj, pick: (place, pick.names))
                }))
            }
            c.lines.append(("not now", 0x8a80a8, nil, { [weak self] in self?.picking[proj] = nil; self?.filing[pick.idea] = nil }))
        } else if list.isEmpty {
            let git = FileManager.default.fileExists(atPath: "\(devDir.path)/\(proj)/.git")
            c.lines.append((git ? "no ideas yet, Haiku is on it" : "not a git repo, no ideas", 0x8a80a8, nil, nil))
        } else {
            c.lines.append((stashReady ? "ideas · click one to file it in stash" : "ideas · click one to copy it", 0x8a80a8, nil, nil))
            if stashReady, let place = stashPlaces[proj] {
                c.lines.append(("going to \(place.isEmpty ? "Inbox" : place) · click to change", 0x8a80a8, nil,
                                { [weak self] in rememberPlace(proj, nil); self?.needsDisplay = true }))
            }
            for idea in list {
                let status = filing[idea]
                c.lines.append((status.map { "\(idea)  (\($0))" } ?? idea, status == nil ? 0xe8e3f5 : 0x8a80a8, 0xffe066,
                                status != nil ? nil : { [weak self] in self?.file(idea, proj) }))
            }
        }
        return c
    }

    /// Files an idea in stash, showing how that went next to it for a few seconds. With no stash, or when filing
    /// fails, it is copied instead and stays.
    func file(_ idea: String, _ proj: String, pick: (place: String, names: [String])? = nil) {
        func copy() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(idea, forType: .string)
        }
        guard stashReady else {
            copy()
            filing[idea] = "copied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.filing[idea] = nil }
            return
        }
        filing[idea] = "filing…"
        fileIdea(proj, idea, pick: pick) { [weak self] result in
            guard let self else { return }
            if case .ask(let names) = result {
                if let waiting = picking[proj]?.idea, waiting != idea { filing[waiting] = nil } // one question per desk: the newest
                picking[proj] = (idea, names)
                filing[idea] = "pick where in the desk's card"
                return
            }
            let ok = switch result { case .yes, .misfiled: true; default: false }
            if !ok { copy() }
            filing[idea] = switch result { case .yes: "filed"; case .misfiled: "filed, check stash"; default: "couldn't file, copied" }
            if ok, bubble?.text == idea { bubbleUntil = min(bubbleUntil, Date().addingTimeInterval(4)) } // shows "filed", then goes
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.filing[idea] = nil
                if ok { self?.ideas[proj]?.removeAll { $0 == idea } } // gone from the desk, never filed twice
            }
        }
    }

    /// Drops an idea for good, without filing it.
    func skip(_ idea: String, _ proj: String) {
        dropIdea(proj, idea)
        ideas[proj]?.removeAll { $0 == idea }
        bubble = nil
    }

    /// A box with 2pt pixel corners, an outline and a hard drop shadow.
    func pixelBox(_ r: NSRect, fill: UInt32, edge: UInt32) {
        func cut(_ r: NSRect) { NSRect(x: r.minX + 2, y: r.minY, width: r.width - 4, height: r.height).fill(); NSRect(x: r.minX, y: r.minY + 2, width: r.width, height: r.height - 4).fill() }
        NSColor(white: 0, alpha: 0.45).setFill(); cut(r.insetBy(dx: -2, dy: -2).offsetBy(dx: 3, dy: -3))
        hex(edge).setFill(); cut(r.insetBy(dx: -2, dy: -2))
        hex(fill).setFill(); cut(r)
    }

    /// A speech bubble above what is speaking (below it when there is no room), with an icon, a stepped tail and an
    /// optional grey hint under the words. Near the left wall it opens rightward; past the middle, where the lounge
    /// starts, leftward, so it stays off the lounge; in between, centered. Returns where it went.
    @discardableResult
    func drawBubble(_ words: String, at a: NSPoint, icon: [String]?, hint: String? = nil) -> NSRect {
        let label = text(words, 11, 0x1d1630, width: 230), size = label.size
        let note = hint.map { text($0, 9, 0x6a6080) }, noteH = note.map { ceil($0.size.height) + 2 } ?? 0
        let inset: CGFloat = icon == nil ? 8 : 22
        let w = max(ceil(size.width), note.map { ceil($0.size.width) } ?? 0) + inset + 8, h = max(ceil(size.height), 12) + noteH + 12
        var y = a.y + 14
        if y + h > bounds.maxY - 6 { y = a.y - h - 14 }
        let x = a.x < bounds.width / 3 ? a.x - 20 : a.x > bounds.width / 2 ? a.x + 20 - w : a.x - w / 2
        let box = NSRect(x: min(max(x, 8), bounds.width - w - 8), y: max(y, 8), width: w, height: h)
        let up = box.minY > a.y
        for (i, s) in [CGFloat(6), 4].enumerated() { // tail steps toward the speaker
            let ty = up ? box.minY - CGFloat(i + 1) * 5 : box.maxY + CGFloat(i) * 5 + 1
            let t = NSRect(x: a.x - s / 2, y: ty, width: s, height: s)
            hex(0x1d1630).setFill(); t.insetBy(dx: -2, dy: -2).fill(); hex(0xf4efe6).setFill(); t.fill()
        }
        pixelBox(box, fill: 0xf4efe6, edge: 0x1d1630)
        if let icon {
            let (sx, sy, ss) = (ox, oy, scale)
            scale = 2; ox = box.minX + 7; oy = box.midY - 5
            sprite(icon, 0, 0, nil)
            (ox, oy, scale) = (sx, sy, ss)
        }
        label.put(at: NSPoint(x: box.minX + inset, y: box.minY + 6 + noteH))
        note?.put(at: NSPoint(x: box.minX + inset, y: box.minY + 6))
        return box
    }

    /// Draws a card beside what it is about (right, else left), never on top of it; returns where it went.
    func drawCard(_ c: Card, beside r: NSRect) -> NSRect {
        var c = c
        let fit = bounds.height - 14 - (c.buttons.isEmpty ? 0 : 30) - 42 // room for lines under title and above buttons
        // ponytail: drop trailing lines (the ideas) until it fits, so the buttons never fall off the bottom
        var heights = c.lines.map { ceil(text($0.text, 11, $0.color, width: 250).size.height) + 4 }
        while heights.count > 1, heights.reduce(0, +) > fit { heights.removeLast(); c.lines.removeLast() }
        let title = text(c.title, 13, 0xffffff), chip = text(c.chip.0, 10, c.chip.1)
        let pic: CGFloat = c.image == nil ? 0 : 72, textW: CGFloat = 250
        let lines = c.lines.map { text($0.text, 11, $0.color, width: textW) }, sizes = lines.map(\.size)
        let labels = c.buttons.map { text($0.label, 11, 0x1d1630) }
        let buttonsW = labels.reduce(0) { $0 + $1.size.width + 26 }
        let linesH = max(sizes.reduce(0) { $0 + ceil($1.height) + 4 }, pic > 0 ? pic : 0)
        let w = ceil(max(title.size.width + chip.size.width + 18, (sizes.map(\.width).max() ?? 0) + 14 + pic, buttonsW) + 20)
        let h = ceil(title.size.height + 10 + linesH + (c.buttons.isEmpty ? 0 : 30) + 16)
        let box = NSRect(x: r.maxX + 10 + w <= bounds.width - 8 ? r.maxX + 10 : max(r.minX - 10 - w, 8),
                         y: min(max(r.midY - h / 2, 8), bounds.maxY - h - 6), width: w, height: h)
        pixelBox(box, fill: 0x1d1630, edge: 0x8a80a8)

        var y = box.maxY - 8 - title.size.height
        title.put(at: NSPoint(x: box.minX + 10, y: y))
        hex(c.chip.1).setFill(); NSRect(x: box.maxX - 10 - chip.size.width - 10, y: y + 4, width: 6, height: 6).fill()
        chip.put(at: NSPoint(x: box.maxX - 10 - chip.size.width, y: y + 1))
        y -= 6
        hex(0x3b2f5a).setFill(); NSRect(x: box.minX + 10, y: y, width: box.width - 20, height: 2).fill()
        y -= 4
        if let img = c.image {
            NSGraphicsContext.current?.imageInterpolation = .none
            img.draw(in: NSRect(x: box.minX + 10, y: y - pic + 4, width: pic - 8, height: pic - 8))
        }
        let left = box.minX + 10 + pic
        for (i, (line, size)) in zip(lines, sizes).enumerated() {
            let lh = ceil(size.height)
            y -= lh
            let row = NSRect(x: box.minX + 6, y: y - 2, width: box.width - 12, height: lh + 4)
            if let act = c.lines[i].action {
                if let m = mouse, row.contains(m) { NSColor(white: 1, alpha: 0.08).setFill(); row.fill() }
                clicks.append((row, act))
            }
            if let b = c.lines[i].bullet { hex(b).setFill(); NSRect(x: left, y: y + lh - 9, width: 4, height: 4).fill() }
            line.put(at: NSPoint(x: left + (c.lines[i].bullet == nil ? 0 : 14), y: y))
            y -= 4
        }
        var bx = box.minX + 10
        for (b, label) in zip(c.buttons, labels) {
            let br = NSRect(x: bx, y: box.minY + 10, width: label.size.width + 16, height: 20)
            pixelBox(br, fill: mouse.map { br.contains($0) } == true ? mix(b.color, 0xffffff, 0.3) : b.color, edge: 0x0d0a18)
            label.put(at: NSPoint(x: br.minX + 8, y: br.minY + (20 - label.size.height) / 2))
            clicks.append((br, b.action))
            bx += br.width + 10
        }
        return box
    }
}
