// Renders Resources/AppIcon.icns: a rounded square with two arrows chasing each other around a "Z".
// Usage: swift Tools/make-icon.swift   (run from the repo root)
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // macOS icon grid: 824pt body centered in 1024 with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(shape); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.99, green: 0.45, blue: 0.20, alpha: 1).cgColor,
        NSColor(srgbRed: 0.86, green: 0.16, blue: 0.48, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    let hi = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

    // Two arc arrows around the centre.
    let center = CGPoint(x: 512, y: 512), radius: CGFloat = 285
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineWidth(58)
    ctx.setLineCap(.round)
    for start in [CGFloat(20), 200] {
        let a0 = start * .pi / 180, a1 = (start + 125) * .pi / 180
        ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.strokePath()
        // Arrowhead at the end of the arc, pointing along the direction of travel.
        let tip = a1 + 0.30
        let p = CGPoint(x: center.x + radius * cos(tip), y: center.y + radius * sin(tip))
        let b1 = CGPoint(x: center.x + (radius + 88) * cos(a1), y: center.y + (radius + 88) * sin(a1))
        let b2 = CGPoint(x: center.x + (radius - 88) * cos(a1), y: center.y + (radius - 88) * sin(a1))
        ctx.move(to: p); ctx.addLine(to: b1); ctx.addLine(to: b2); ctx.closePath(); ctx.fillPath()
    }

    // The Z.
    let z = CGMutablePath()
    let l: CGFloat = 392, r: CGFloat = 632, t: CGFloat = 652, b: CGFloat = 372, w: CGFloat = 62
    z.move(to: CGPoint(x: l, y: t)); z.addLine(to: CGPoint(x: r, y: t)); z.addLine(to: CGPoint(x: r, y: t - w))
    z.addLine(to: CGPoint(x: l + 92, y: b + w)); z.addLine(to: CGPoint(x: r, y: b + w)); z.addLine(to: CGPoint(x: r, y: b))
    z.addLine(to: CGPoint(x: l, y: b)); z.addLine(to: CGPoint(x: l, y: b + w))
    z.addLine(to: CGPoint(x: r - 92, y: t - w)); z.addLine(to: CGPoint(x: l, y: t - w)); z.closeSubpath()
    ctx.addPath(z); ctx.fillPath()

    ctx.restoreGState()
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
try render(1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
