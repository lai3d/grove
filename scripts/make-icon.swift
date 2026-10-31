// Renders Resources/AppIcon.icns: a green "grove" of branch lines and commit dots.
// Usage: swift scripts/make-icon.swift   (needs iconutil, part of macOS)
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle-ish rounded square with the standard macOS icon margin.
    let inset = s * 0.1
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSColor(calibratedRed: 0.13, green: 0.45, blue: 0.27, alpha: 1).setFill()
    shape.fill()
    ctx.restoreGState()
    shape.addClip()
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.80, blue: 0.47, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.46, blue: 0.31, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: -90)

    // Branch lines: a trunk with two branches forking and one merging back.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
    let line = NSBezierPath()
    line.lineWidth = rect.width * 0.055
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    line.move(to: p(0.5, 0.14)); line.line(to: p(0.5, 0.86))                                   // trunk
    line.move(to: p(0.5, 0.30)); line.curve(to: p(0.27, 0.56), controlPoint1: p(0.5, 0.42), controlPoint2: p(0.27, 0.42))
    line.line(to: p(0.27, 0.72))                                                                 // left branch
    line.move(to: p(0.5, 0.40)); line.curve(to: p(0.73, 0.60), controlPoint1: p(0.5, 0.50), controlPoint2: p(0.73, 0.48))
    line.curve(to: p(0.5, 0.80), controlPoint1: p(0.73, 0.72), controlPoint2: p(0.5, 0.70))      // right branch, merges back
    NSColor.white.withAlphaComponent(0.95).setStroke()
    line.stroke()

    // Commit dots ("leaves").
    for (x, y, r) in [(0.5, 0.14, 0.075), (0.27, 0.72, 0.07), (0.73, 0.60, 0.07), (0.5, 0.86, 0.085), (0.5, 0.52, 0.06)] {
        let c = p(CGFloat(x), CGFloat(y)), rr = CGFloat(r) * rect.width
        let dot = NSBezierPath(ovalIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr))
        NSColor.white.setFill(); dot.fill()
        let inner = NSBezierPath(ovalIn: CGRect(x: c.x - rr * 0.5, y: c.y - rr * 0.5, width: rr, height: rr))
        NSColor(calibratedRed: 0.16, green: 0.58, blue: 0.36, alpha: 1).setFill(); inner.fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
try render(1024).write(to: out.deletingLastPathComponent().appendingPathComponent("AppIcon-1024.png"))
print("wrote \(out.path)")
