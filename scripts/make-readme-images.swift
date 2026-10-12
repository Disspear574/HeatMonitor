import AppKit

// README images on the icon's orange-to-red gradient.
let args = CommandLine.arguments
let warm = NSColor(red: 1.0, green: 0.62, blue: 0.1, alpha: 1)
let hot = NSColor(red: 0.93, green: 0.18, blue: 0.22, alpha: 1)

func canvas(_ w: Int, _ h: Int, _ draw: (NSSize) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw(NSSize(width: w, height: h))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func image(_ path: String) -> NSImage {
    guard let i = NSImage(contentsOfFile: path) else { fatalError("cannot read \(path)") }
    return i
}

// The window capture has transparent rounded corners, so the shadow follows its shape.
func window(_ img: NSImage, in r: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = r.width * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -r.width * 0.012)
    shadow.set()
    img.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, in r: NSRect) {
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                            .foregroundColor: NSColor.white.withAlphaComponent(alpha)]
    NSAttributedString(string: s, attributes: a).draw(with: r, options: [.usesLineFragmentOrigin])
}

switch args.count > 1 ? args[1] : "" {
case "hero" where args.count == 5:
    let back = image(args[3]), front = image(args[4])
    let data = canvas(2400, 1400) { s in
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: s), xRadius: 64, yRadius: 64).addClip()
        NSGradient(colors: [warm, hot])!.draw(in: NSRect(origin: .zero, size: s), angle: -60)
        let w: CGFloat = 1500
        let bh = w * back.size.height / back.size.width, fh = w * front.size.height / front.size.width
        window(back, in: NSRect(x: 130, y: s.height - 110 - bh, width: w, height: bh))
        window(front, in: NSRect(x: s.width - 130 - w, y: 110, width: w, height: fh))
    }
    try! data.write(to: URL(fileURLWithPath: args[2]))
case "social" where args.count == 6:
    let icon = image(args[3]), win = image(args[4])
    let data = canvas(1280, 640) { s in
        NSGradient(colors: [warm, hot])!.draw(in: NSRect(origin: .zero, size: s), angle: -60)
        icon.draw(in: NSRect(x: 64, y: 360, width: 176, height: 176))
        text("Heat Monitor", size: 76, weight: .bold, alpha: 1, in: NSRect(x: 80, y: 250, width: 560, height: 100))
        text(args[5], size: 32, weight: .medium, alpha: 0.9, in: NSRect(x: 80, y: 110, width: 540, height: 140))
        // The window runs off the right and bottom edges.
        let w: CGFloat = 820
        let h = w * win.size.height / win.size.width
        window(win, in: NSRect(x: 640, y: 560 - h, width: w, height: h))
    }
    try! data.write(to: URL(fileURLWithPath: args[2]))
default:
    FileHandle.standardError.write("usage: make-readme-images hero <out> <back> <front> | social <out> <icon> <window> <tagline>\n".data(using: .utf8)!)
    exit(2)
}
