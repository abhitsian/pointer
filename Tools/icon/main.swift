import AppKit

// Pointer app icon: the white mark (selection corners, speech tail, dot) on a warm squircle.
// Usage: make-icon <output.iconset>

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

    let inset = s * 0.05
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = CGPath(roundedRect: tile, cornerWidth: s * 0.22, cornerHeight: s * 0.22, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let warm = CGGradient(colorsSpace: space, colors: [rgb(0.93, 0.72, 0.48), rgb(0.80, 0.45, 0.24)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(warm, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.22), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s * 0.5), options: [])

    let box = CGRect(x: s * 0.2, y: s * 0.2, width: s * 0.6, height: s * 0.6)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: rgb(0.3, 0.12, 0.02, 0.35))
    ctx.setFillColor(rgb(1, 0.99, 0.97))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil) // one shadow for the whole mark
    for part in Mark.parts(in: box) {
        ctx.addPath(part)
        ctx.fillPath()
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
}

for (px, name) in sizes {
    if let data = render(px) {
        try? data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
    }
}
