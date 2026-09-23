import AppKit

// Pointer app icon: a cream arrow cursor with a dark speech bubble coming off it (point and tell), amber dots in
// the bubble, on a warm squircle. Usage: make-icon <output.iconset>

let output = CommandLine.arguments.dropFirst().first ?? "Pointer.iconset"
try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func render(_ px: Int) -> Data? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let s = CGFloat(px)

    let inset = s * 0.09
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset),
                       cornerWidth: s * 0.2, cornerHeight: s * 0.2, transform: nil))
    ctx.clip()
    let warm = CGGradient(colorsSpace: space, colors: [rgb(0.96, 0.62, 0.3), rgb(0.8, 0.36, 0.2)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    func shadowed(_ draw: () -> Void) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.035, color: rgb(0, 0, 0, 0.45))
        draw()
        ctx.restoreGState()
    }

    // The bubble, with its tail pointing back at the cursor.
    let bubble = CGRect(x: s * 0.44, y: s * 0.5, width: s * 0.36, height: s * 0.24)
    shadowed {
        ctx.setFillColor(rgb(0.16, 0.12, 0.1))
        ctx.addPath(CGPath(roundedRect: bubble, cornerWidth: s * 0.08, cornerHeight: s * 0.08, transform: nil))
        ctx.fillPath()
        ctx.move(to: CGPoint(x: bubble.minX + s * 0.05, y: bubble.minY + 1))
        ctx.addLine(to: CGPoint(x: bubble.minX - s * 0.04, y: bubble.minY - s * 0.06))
        ctx.addLine(to: CGPoint(x: bubble.minX + s * 0.14, y: bubble.minY + 1))
        ctx.fillPath()
    }
    ctx.setFillColor(rgb(0.97, 0.69, 0.25))
    for i in 0..<3 {
        let r = s * 0.027
        ctx.fillEllipse(in: CGRect(x: bubble.midX - r + CGFloat(i - 1) * s * 0.085, y: bubble.midY - r, width: 2 * r, height: 2 * r))
    }

    // The cursor: macOS arrow proportions, tip top-left.
    let tip = CGPoint(x: s * 0.22, y: s * 0.58), u = s * 0.4 / 20
    let arrow = CGMutablePath()
    arrow.addLines(between: [(0, 0), (0, 16.5), (4, 12.8), (6.8, 19.3), (9.6, 18.1), (6.9, 11.8), (12.2, 11.8)]
        .map { CGPoint(x: tip.x + $0.0 * u, y: tip.y - $0.1 * u) })
    arrow.closeSubpath()
    shadowed {
        ctx.setFillColor(rgb(0.98, 0.95, 0.88))
        ctx.addPath(arrow)
        ctx.fillPath()
    }
    ctx.setStrokeColor(rgb(0.3, 0.14, 0.08))
    ctx.setLineWidth(max(1, s * 0.012))
    ctx.setLineJoin(.round)
    ctx.addPath(arrow)
    ctx.strokePath()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for (px, name) in sizes {
    if let data = render(px) {
        try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
