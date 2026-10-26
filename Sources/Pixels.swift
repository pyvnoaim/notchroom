// Pixel art: colors, cached bitmaps and text, the sprites, and the pixel font.
import AppKit

var colors: [UInt32: NSColor] = [:]
func hex(_ v: UInt32) -> NSColor {
    if let c = colors[v] { return c }
    let c = NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    colors[v] = c
    return c
}

/// Paints into a bitmap at retina scale and returns it as an image, tagged sRGB so it matches what is drawn live.
func bitmap(_ size: NSSize, _ paint: () -> Void) -> NSImage {
    let k: CGFloat = 2
    guard size.width > 0, size.height > 0,
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * k)), pixelsHigh: Int(ceil(size.height * k)),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)?.retagging(with: .sRGB) else { return NSImage(size: size) }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    paint()
    NSGraphicsContext.restoreGraphicsState()
    let img = NSImage(size: size)
    img.addRepresentation(rep)
    return img
}

var texts: [String: NSImage] = [:]
/// Text laid out once and kept as an image: the variable pixel font rebuilds its glyph outlines on every draw,
/// which was most of a frame. `width` wraps long lines.
func text(_ s: String, _ size: CGFloat, _ color: UInt32, width: CGFloat = 10_000) -> NSImage {
    let key = "\(size) \(color) \(width) \(s)"
    if let img = texts[key] { return img }
    if texts.count > 600 { texts.removeAll() } // ponytail: crude bound; ideas, statuses and cards come and go
    let attr = NSAttributedString(string: s, attributes: [.font: pixelFont(size), .foregroundColor: hex(color)])
    let r = attr.boundingRect(with: NSSize(width: width, height: 1000), options: .usesLineFragmentOrigin)
    let sz = NSSize(width: ceil(r.width), height: ceil(r.height))
    let img = bitmap(sz) { attr.draw(with: NSRect(origin: .zero, size: sz), options: .usesLineFragmentOrigin) }
    texts[key] = img
    return img
}

extension NSImage {
    func put(at p: NSPoint) { draw(at: p, from: .zero, operation: .sourceOver, fraction: 1) }
}

/// a -> b by t (0...1), per channel.
func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
    let t = min(max(t, 0), 1)
    return [16, 8, 0].reduce(0) { acc, sh in
        let x = Double(a >> UInt32(sh) & 255), y = Double(b >> UInt32(sh) & 255)
        return acc | UInt32((x + (y - x) * t).rounded()) << UInt32(sh)
    }
}

let shirts: [UInt32] = [0xe05d5d, 0x5d9be0, 0xe0c35d, 0x7fd36b, 0xc46be0, 0xe0905d, 0x5de0c8]
let hairs: [UInt32] = [0x2b1d14, 0x6b3e1f, 0xd9b25f, 0x1a1a1a, 0xa33a2a, 0x8a8a8a]
let skins: [UInt32] = [0xf1c7a0, 0xd9a066, 0x8d5a3b]
let stateColor: [String: UInt32] = ["working": 0x5fd38d, "waiting": 0xffb347, "idle": 0x9fb4ff]

// Sprites for a 3/4 top-down view, rows top first:
// h hair, f skin, e eyes, s shirt (also the blanket), l pants, k shoes, o/d cat fur and stripes, y/g bulb, z/! glyph color
let typing = [["f..hhhh...", "s.hhhhhh.f", "s.hhhhhh.s", "s..hhhh..s", "ssssssssss", "ssssssssss", ".ssssssss.", ".ssssssss."], // from behind, at the keyboard
              ["...hhhh..f", "f.hhhhhh.s", "s.hhhhhh.s", "s..hhhh..s", "ssssssssss", "ssssssssss", ".ssssssss.", ".ssssssss."]]
let wave = [["..hhhhh..f", ".hhhhhhh.s", ".hfffffh.s", ".fefffef.s", "..fffff..s", ".ssssssss.", "fsssssss..", "f.sssss...", "..sssss...", "..ll.ll...", "..ll.ll...", "..kk.kk..."], // facing you
            ["..hhhhh...", ".hhhhhhh..", ".hfffffh..", ".fefffef..", "..fffff...", ".ssssssssf", "fsssssss..", "f.sssss...", "..sssss...", "..ll.ll...", "..ll.ll...", "..kk.kk..."]]
let walkDown = [["..hhhhh..", ".hhhhhhh.", ".hfffffh.", ".fefffef.", "..fffff..", ".sssssss.", "fsssssss.", "..sssssf.", "..sssss..", "..ll.ll..", "..ll..l..", "..kk..kk."],
                ["..hhhhh..", ".hhhhhhh.", ".hfffffh.", ".fefffef.", "..fffff..", ".sssssss.", ".sssssssf", ".fsssss..", "..sssss..", "..ll.ll..", "..l..ll..", ".kk..kk.."]]
let walkUp = [["..hhhhh..", ".hhhhhhh.", ".hhhhhhh.", ".hhhhhhh.", "..hhhhh..", ".sssssss.", "fsssssss.", "..sssssf.", "..sssss..", "..ll.ll..", "..ll..l..", "..kk..kk."],
              ["..hhhhh..", ".hhhhhhh.", ".hhhhhhh.", ".hhhhhhh.", "..hhhhh..", ".sssssss.", ".sssssssf", ".fsssss..", "..sssss..", "..ll.ll..", "..l..ll..", ".kk..kk.."]]
let lie = ["..hhh..........", ".hhhhfsssssssss", "hhhhffssssssssk", ".hhhhfsssssssss", "..hhh.........."] // on the couch, blanket up to the chin
let catWalk = [["o.....oo", "o....ooo", ".oooooeo", ".ododdo.", ".o..o..."],
               ["o.....oo", "o....ooo", ".oooooeo", ".ododdo.", "..o..o.."]]
let catSit = ["....oo", "....eo", "o..oo.", "o.ooo.", ".oodo.", ".oooo."]
let catSleep = ["..ooo..", ".odoooo", "ooooooo"]
let zGlyph = ["zzzz", "..z.", ".z..", "zzzz"]
let bang = ["!", "!", "!", ".", "!"]
let note = ["..zz", "..z.", "..z.", "zzz.", "zz.."]
let bulb = [".yy.", "yyyy", "yyyy", ".yy.", ".gg."]
let star = ["..y..", ".yyy.", "yyyyy", ".yyy.", ".y.y."]
let pixelFont = { (size: CGFloat) in NSFont(name: "GeistPixelRegular-Square", size: size) ?? .monospacedSystemFont(ofSize: size - 1, weight: .medium) }

/// An image squashed to n×n pixels, to be drawn big without smoothing: album art as pixel art.
func pixelated(_ img: NSImage, _ n: Int) -> NSImage? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
    NSGraphicsContext.restoreGraphicsState()
    let out = NSImage(size: NSSize(width: n, height: n))
    out.addRepresentation(rep)
    return out
}
