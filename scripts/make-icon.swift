import AppKit
let out = CommandLine.arguments[1]
func render(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let s = CGFloat(px)
  let body = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
  let path = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
  NSGradient(colors: [NSColor(red: 1.0, green: 0.62, blue: 0.1, alpha: 1), NSColor(red: 0.93, green: 0.18, blue: 0.22, alpha: 1)])!.draw(in: path, angle: -90)
  let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .semibold).applying(.init(paletteColors: [.white]))
  if let sym = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let r = NSRect(x: (s - sym.size.width) / 2, y: (s - sym.size.height) / 2, width: sym.size.width, height: sym.size.height)
    sym.draw(in: r)
  }
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (name, px) in [("16x16",16),("16x16@2x",32),("32x32",32),("32x32@2x",64),("128x128",128),("128x128@2x",256),("256x256",256),("256x256@2x",512),("512x512",512),("512x512@2x",1024)] {
  try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
