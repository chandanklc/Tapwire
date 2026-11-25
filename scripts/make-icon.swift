// Draws Tapwire's app icon (an original design: a wire with a tap point) into the asset catalog.
// Usage: swift scripts/make-icon.swift Sources/Tapwire/Assets.xcassets/AppIcon.appiconset
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let inset = s * 0.09
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [NSColor(red: 0.05, green: 0.58, blue: 0.53, alpha: 1).cgColor,
                  NSColor(red: 0.16, green: 0.20, blue: 0.55, alpha: 1).cgColor] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // The wire: a smooth S-curve across the tile.
    let wire = CGMutablePath()
    wire.move(to: CGPoint(x: rect.minX - s * 0.05, y: rect.midY - rect.height * 0.18))
    wire.addCurve(to: CGPoint(x: rect.maxX + s * 0.05, y: rect.midY + rect.height * 0.18),
                  control1: CGPoint(x: rect.midX - rect.width * 0.05, y: rect.midY - rect.height * 0.55),
                  control2: CGPoint(x: rect.midX + rect.width * 0.05, y: rect.midY + rect.height * 0.55))
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
    ctx.setLineWidth(rect.width * 0.13)
    ctx.addPath(wire)
    ctx.strokePath()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(rect.width * 0.055)
    ctx.addPath(wire)
    ctx.strokePath()
    // The tap: a node clamped on the wire, with a short probe line.
    let c = CGPoint(x: rect.midX, y: rect.midY)
    ctx.setStrokeColor(NSColor(red: 1, green: 0.78, blue: 0.25, alpha: 1).cgColor)
    ctx.setLineWidth(rect.width * 0.05)
    ctx.move(to: c)
    ctx.addLine(to: CGPoint(x: c.x + rect.width * 0.2, y: c.y - rect.height * 0.3))
    ctx.strokePath()
    let r = rect.width * 0.12
    ctx.setFillColor(NSColor(red: 1, green: 0.78, blue: 0.25, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(NSColor(red: 0.16, green: 0.20, blue: 0.55, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.42, y: c.y - r * 0.42, width: r * 0.84, height: r * 0.84))
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! draw(size: px).write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    .write(to: outDir.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images")
