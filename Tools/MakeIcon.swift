// Generates the Mousi app icon (an .iconset of PNGs) using CoreGraphics.
// Usage: swift MakeIcon.swift <output.iconset>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Mousi.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size s: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return img }

    // macOS-style rounded square with a transparent margin.
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    // Gradient background (indigo → blue, Apple-esque)
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(red: 0.42, green: 0.35, blue: 0.95, alpha: 1).cgColor,
                  NSColor(red: 0.05, green: 0.52, blue: 1.00, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    // subtle top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY), end: CGPoint(x: rect.midX, y: rect.midY), options: [])
    ctx.restoreGState()

    // Three "text lines"; middle one is highlighted (selection) — the Mousi idea.
    let lineH = rect.height * 0.075
    let lineX = rect.minX + rect.width * 0.20
    let lineW = rect.width * 0.60
    let ys: [CGFloat] = [0.66, 0.50, 0.34].map { rect.minY + rect.height * $0 }

    // selection highlight behind middle line
    let hl = CGRect(x: lineX - lineH * 0.9, y: ys[1] - lineH * 1.05, width: lineW * 0.82 + lineH * 1.8, height: lineH * 3.1)
    ctx.setFillColor(NSColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 0.95).cgColor)
    ctx.addPath(CGPath(roundedRect: hl, cornerWidth: lineH * 0.9, cornerHeight: lineH * 0.9, transform: nil)); ctx.fillPath()

    for (i, y) in ys.enumerated() {
        let w = i == 1 ? lineW * 0.82 : (i == 0 ? lineW : lineW * 0.7)
        let r = CGRect(x: lineX, y: y - lineH / 2, width: w, height: lineH)
        ctx.setFillColor(i == 1 ? NSColor(white: 0.12, alpha: 0.85).cgColor : NSColor.white.withAlphaComponent(0.92).cgColor)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: lineH / 2, cornerHeight: lineH / 2, transform: nil)); ctx.fillPath()
    }

    // Cursor arrow at the end of the highlighted line
    let ax = hl.maxX - lineH * 0.6, ay = ys[1] + lineH * 0.9
    let arrow = CGMutablePath()
    let sz = rect.width * 0.19
    arrow.move(to: CGPoint(x: ax, y: ay))
    arrow.addLine(to: CGPoint(x: ax, y: ay - sz))
    arrow.addLine(to: CGPoint(x: ax + sz * 0.27, y: ay - sz * 0.74))
    arrow.addLine(to: CGPoint(x: ax + sz * 0.46, y: ay - sz * 1.08))
    arrow.addLine(to: CGPoint(x: ax + sz * 0.62, y: ay - sz * 1.0))
    arrow.addLine(to: CGPoint(x: ax + sz * 0.44, y: ay - sz * 0.66))
    arrow.addLine(to: CGPoint(x: ax + sz * 0.74, y: ay - sz * 0.66))
    arrow.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.012, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(arrow); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(arrow); ctx.setStrokeColor(NSColor(white: 0.1, alpha: 0.7).cgColor); ctx.setLineWidth(max(1, s * 0.008)); ctx.setLineJoin(.round); ctx.strokePath()

    // Sparkle (AI) top-right
    func sparkle(cx: CGFloat, cy: CGFloat, r: CGFloat) {
        let p = CGMutablePath()
        let k = r * 0.28
        p.move(to: CGPoint(x: cx, y: cy + r))
        p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + k, y: cy + k))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx + k, y: cy - k))
        p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - k, y: cy - k))
        p.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx - k, y: cy + k))
        p.closeSubpath()
        ctx.addPath(p); ctx.setFillColor(NSColor.white.cgColor); ctx.fillPath()
    }
    sparkle(cx: rect.minX + rect.width * 0.80, cy: rect.minY + rect.height * 0.80, r: rect.width * 0.085)
    sparkle(cx: rect.minX + rect.width * 0.90, cy: rect.minY + rect.height * 0.69, r: rect.width * 0.04)

    img.unlockFocus()
    return img
}

func writePNG(_ img: NSImage, px: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

for base in [16, 32, 128, 256, 512] {
    writePNG(draw(size: CGFloat(base)), px: base, name: "icon_\(base)x\(base).png")
    writePNG(draw(size: CGFloat(base * 2)), px: base * 2, name: "icon_\(base)x\(base)@2x.png")
}
print("iconset written to \(outDir)")
