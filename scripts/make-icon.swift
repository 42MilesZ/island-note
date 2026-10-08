import AppKit
import ImageIO
import UniformTypeIdentifiers

// Render the shared SVG at every resolution using macOS's vector decoder.
enum IconError: LocalizedError {
    case invalidArguments, invalidSource(URL), bitmap, png

    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "Usage: swift scripts/make-icon.swift <iconset-directory> [source.svg]"
        case .invalidSource(let url): return "Could not decode SVG icon: \(url.path)"
        case .bitmap: return "Could not allocate icon bitmap."
        case .png: return "Could not encode icon PNG."
        }
    }
}

do {
    guard (2...3).contains(CommandLine.arguments.count) else { throw IconError.invalidArguments }
    let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let source = CommandLine.arguments.count == 3
        ? URL(fileURLWithPath: CommandLine.arguments[2])
        : URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AppIcon.svg")
    guard let icon = NSImage(contentsOf: source), icon.isValid else { throw IconError.invalidSource(source) }
    icon.cacheMode = .never
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let canvas = CGContext(data: nil, width: pixels, height: pixels,
                    bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw IconError.bitmap }
            let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
            canvas.clear(bounds)
            let context = NSGraphicsContext(cgContext: canvas, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            context.cgContext.setShouldAntialias(true)
            icon.draw(in: bounds)
            NSGraphicsContext.restoreGraphicsState()

            guard let rendered = canvas.makeImage() else { throw IconError.bitmap }
            let data = NSMutableData()
            guard let encoder = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
            else { throw IconError.png }
            CGImageDestinationAddImage(encoder, rendered, nil)
            guard CGImageDestinationFinalize(encoder) else { throw IconError.png }
            let suffix = scale == 2 ? "@2x" : ""
            try (data as Data).write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"), options: .atomic)
        }
    }
    print("Rendered 10 icon sizes from \(source.lastPathComponent).")
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
