import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32),
                       ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256),
                       ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512),
                       ("icon_512x512@2x", 1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let transform = AffineTransform(scale: CGFloat(pixels) / 1024); (transform as NSAffineTransform).concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(calibratedRed: 0.03, green: 0.30, blue: 0.37, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.73, blue: 0.70, alpha: 1))!.draw(in: background, angle: 55)
    let mouse = NSBezierPath(roundedRect: NSRect(x: 347, y: 250, width: 330, height: 540), xRadius: 155, yRadius: 155)
    NSColor.white.setStroke(); mouse.lineWidth = 32; mouse.stroke()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 494, y: 624, width: 36, height: 86), xRadius: 18, yRadius: 18).fill()
    for y in [400.0, 520.0, 640.0] {
        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: 185, y: y - 25))
        wave.curve(to: NSPoint(x: 275, y: y + 25), controlPoint1: NSPoint(x: 230, y: y - 25),
                   controlPoint2: NSPoint(x: 230, y: y + 25))
        wave.lineWidth = 24; wave.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.65).setStroke(); wave.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
}
