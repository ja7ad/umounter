// Renders UMounter's app icon to App/Resources/AppIcon.icns.
//   swift scripts/make-icon.swift
// A white eject glyph on a blue squircle, drawn with AppKit at every iconset size.
import AppKit

let root = URL(filePath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)

    // macOS icon grid: the body is ~80% of the canvas, corner radius ~22.5% of it.
    let inset = size * 0.1
    let body = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = body.width * 0.225
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.01)
    shadow.shadowBlurRadius = size * 0.02
    shadow.set()
    NSColor(srgbRed: 0.10, green: 0.42, blue: 0.95, alpha: 1).setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(srgbRed: 0.33, green: 0.62, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.07, green: 0.30, blue: 0.85, alpha: 1),
    ])!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: body.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let glyph = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let g = glyph.size
        glyph.draw(in: NSRect(x: body.midX - g.width / 2, y: body.midY - g.height / 2, width: g.width, height: g.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let output = root.appending(path: "App/Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
