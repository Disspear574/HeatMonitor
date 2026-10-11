import AppKit

// Draws the DMG window background (640x420 pt) at the given scale: logo, title, arrow to Applications.
let out = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let iconPath = CommandLine.arguments[3]
let size = NSSize(width: 640, height: 420)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let full = NSRect(origin: .zero, size: size)
NSGradient(colors: [NSColor(red: 1.0, green: 0.97, blue: 0.94, alpha: 1), NSColor(red: 1.0, green: 0.91, blue: 0.85, alpha: 1)])!
    .draw(in: full, angle: -90)

// Logo and title; y grows upwards in AppKit.
if let icon = NSImage(contentsOfFile: iconPath) {
    icon.draw(in: NSRect(x: 320 - 36, y: 420 - 28 - 72, width: 72, height: 72))
}
func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
    NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 0, y: y, width: 640, height: size * 1.4))
}
text("Heat Monitor", size: 24, weight: .bold, color: NSColor(white: 0.12, alpha: 1), y: 420 - 136)
text("Temperature, heat and power of your Mac", size: 13, weight: .regular, color: NSColor(white: 0.4, alpha: 1), y: 420 - 160)

// Arrow between the app (x 170) and Applications (x 470) icons, centred at y 260 from the top.
let y = 420 - 255.0
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 248, y: y))
arrow.line(to: NSPoint(x: 384, y: y))
arrow.lineWidth = 4
arrow.lineCapStyle = .round
let accent = NSColor(red: 0.95, green: 0.42, blue: 0.16, alpha: 1)
accent.setStroke()
arrow.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 376, y: y + 12))
head.line(to: NSPoint(x: 394, y: y))
head.line(to: NSPoint(x: 376, y: y - 12))
head.lineWidth = 4
head.lineCapStyle = .round
head.lineJoinStyle = .round
head.stroke()

text("Drag to Applications  ·  Перетащите в «Программы»", size: 12, weight: .medium, color: NSColor(white: 0.45, alpha: 1), y: 420 - 380)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
