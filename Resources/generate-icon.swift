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
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.28, blue: 0.46, alpha: 1),
               ending: NSColor(calibratedRed: 0.055, green: 0.085, blue: 0.16, alpha: 1))!
        .draw(in: background, angle: -90)
    let rim = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888), xRadius: 200, yRadius: 200)
    NSColor.white.withAlphaComponent(0.15).setStroke()
    rim.lineWidth = 4
    rim.stroke()

    let mouse = NSBezierPath(roundedRect: NSRect(x: 332, y: 235, width: 360, height: 554), xRadius: 180, yRadius: 180)
    NSColor(calibratedRed: 0.32, green: 0.75, blue: 1, alpha: 1).setStroke()
    mouse.lineWidth = 42
    mouse.stroke()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 492, y: 575, width: 40, height: 104), xRadius: 20, yRadius: 20).fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name + ".png"))
}
