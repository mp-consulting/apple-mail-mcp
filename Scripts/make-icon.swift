// Renders the app icon: a glassy squircle (same family as Panes) holding a stack of mail with a
// spark for the AI link. Drawn shapes, not system artwork, so it never looks like Apple Mail.
// Usage: swift Scripts/make-icon.swift <output folder>   (writes AppIcon.icns)
import AppKit

let folder = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let output = URL(fileURLWithPath: folder).appending(path: "AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appending(path: "AppleMailMCP-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let indigo = NSColor(srgbRed: 0.36, green: 0.33, blue: 0.96, alpha: 1)
let violet = NSColor(srgbRed: 0.80, green: 0.36, blue: 0.86, alpha: 1)

/// A four-point star centred on `center`.
func spark(center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let inner = radius * 0.28
    for index in 0..<8 {
        let angle = CGFloat(index) * .pi / 4 + .pi / 2
        let r = index.isMultiple(of: 2) ? radius : inner
        let point = NSPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
        if index == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    // macOS icon grid: the shape sits inside a 824/1024 square.
    let body = NSRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(colors: [indigo, violet])!.draw(in: shape, angle: -60)
    // Glass sheen from the top.
    NSGradient(colors: [.white.withAlphaComponent(0.35), .white.withAlphaComponent(0)])!
        .draw(in: NSBezierPath(roundedRect: body.insetBy(dx: body.width * 0.02, dy: body.width * 0.02),
                               xRadius: body.width * 0.21, yRadius: body.width * 0.21), angle: -90)

    let w = body.width
    // The envelope, slightly below centre to leave room for the stack behind it.
    let front = NSRect(x: body.midX - w * 0.33, y: body.minY + w * 0.20, width: w * 0.66, height: w * 0.46)
    let corner = w * 0.06
    // Two translucent envelopes behind: a stack of mail.
    for (step, alpha) in [(2.0, 0.16), (1.0, 0.28)] {
        let offset = w * 0.055 * step
        let back = front.offsetBy(dx: 0, dy: offset).insetBy(dx: w * 0.035 * step, dy: 0)
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: back, xRadius: corner, yRadius: corner).fill()
    }
    NSColor.white.withAlphaComponent(0.95).setFill()
    NSBezierPath(roundedRect: front, xRadius: corner, yRadius: corner).fill()
    // The flap: a soft V in the gradient's colour.
    let flap = NSBezierPath()
    flap.move(to: NSPoint(x: front.minX + w * 0.05, y: front.maxY - w * 0.05))
    flap.line(to: NSPoint(x: front.midX, y: front.midY - w * 0.01))
    flap.line(to: NSPoint(x: front.maxX - w * 0.05, y: front.maxY - w * 0.05))
    flap.lineWidth = max(1, w * 0.035)
    flap.lineCapStyle = .round
    flap.lineJoinStyle = .round
    indigo.withAlphaComponent(0.55).setStroke()
    flap.stroke()

    // The spark, top right, with a soft glow.
    let center = NSPoint(x: front.maxX - w * 0.06, y: front.maxY + w * 0.10)
    NSGraphicsContext.current?.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = NSColor.white.withAlphaComponent(0.8)
    glow.shadowBlurRadius = w * 0.04
    glow.set()
    NSColor.white.setFill()
    spark(center: center, radius: w * 0.11).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSColor.white.withAlphaComponent(0.85).setFill()
    spark(center: NSPoint(x: center.x - w * 0.15, y: center.y + w * 0.07), radius: w * 0.045).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("wrote \(output.path)")
exit(iconutil.terminationStatus)
