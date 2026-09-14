import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 210, yRadius: 210).fill()
        let arc = NSBezierPath(); arc.appendArc(withCenter: NSPoint(x: 512, y: 440), radius: 290, startAngle: 155, endAngle: 25, clockwise: true)
        arc.lineWidth = 70; arc.lineCapStyle = .round
        NSColor(calibratedRed: 0.32, green: 0.75, blue: 0.93, alpha: 1).setStroke(); arc.stroke()
        let needle = NSBezierPath(); needle.move(to: NSPoint(x: 512, y: 440)); needle.line(to: NSPoint(x: 680, y: 640)); needle.lineWidth = 40; needle.lineCapStyle = .round
        NSColor.white.setStroke(); needle.stroke(); NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 462, y: 390, width: 100, height: 100)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
