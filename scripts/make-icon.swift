import AppKit

// Editable vector drawing; render each size directly for crisp small icons.
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 1024)
        transform.concat()
        NSColor(white: 0.09, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200).fill()
        NSColor(white: 0.93, alpha: 1).setFill()
        for (y, width) in [(620.0, 450.0), (458.0, 560.0), (296.0, 340.0)] {
            NSBezierPath(roundedRect: NSRect(x: 232, y: y, width: width, height: 46), xRadius: 23, yRadius: 23).fill()
        }
        NSColor(red: 0.55, green: 0.80, blue: 0.67, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 742, y: 742, width: 64, height: 64)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using: .png, properties: [:])!.write(
            to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
