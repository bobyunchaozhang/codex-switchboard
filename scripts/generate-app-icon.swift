import AppKit

// Run from the project root. The original SVG attribution is in THIRD_PARTY_NOTICES.md.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = try String(contentsOf: root.appendingPathComponent("Assets/thumbs-up.svg"), encoding: .utf8)
    .replacingOccurrences(of: "width=\"1em\" height=\"1em\"", with: "width=\"24\" height=\"24\"")
guard let thumb = NSImage(data: Data(source.utf8)) else { fatalError("Could not load the icon SVG") }
thumb.isTemplate = false

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("switchboard-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }

func render(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 185, yRadius: 185)
    context.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.shadowOffset = NSSize(width: 0, height: -9)
    shadow.shadowBlurRadius = 22
    shadow.set()
    NSColor.white.setFill()
    tile.fill()
    context.restoreGState()
    NSGradient(starting: NSColor(calibratedRed: 1, green: 0.985, blue: 0.95, alpha: 1), ending: .white)!
        .draw(in: tile, angle: 90)
    NSColor(calibratedWhite: 0.82, alpha: 0.45).setStroke()
    tile.lineWidth = 1.5
    tile.stroke()
    thumb.draw(in: NSRect(x: 196, y: 196, width: 632, height: 632))
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

let output = root.appendingPathComponent("Assets/AppIcon.icns")
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { fatalError("Icon conversion failed") }
if CommandLine.arguments.count > 1 {
    try render(pixels: 512).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print("Generated Assets/AppIcon.icns")
