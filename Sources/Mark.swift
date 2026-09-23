import AppKit

/// Pointer's mark: the four corners of a screen selection ("show") with a speech-bubble tail ("tell") and a dot
/// in the middle. Drawn in a 24×18 unit box with y pointing up. Fill each part on its own so overlaps stay solid.
enum Mark {
    static func parts(in rect: CGRect) -> [CGPath] {
        let t = transform(for: rect)
        let frame = CGRect(x: 2, y: 5, width: 20, height: 12)
        let arm: CGFloat = 5.5  // horizontal arms
        let rise: CGFloat = 3.8 // vertical arms, short enough that top and bottom corners never meet

        let corners = CGMutablePath()
        corners.addLines(between: [CGPoint(x: frame.minX, y: frame.maxY - rise), CGPoint(x: frame.minX, y: frame.maxY),
                                   CGPoint(x: frame.minX + arm, y: frame.maxY)])
        corners.addLines(between: [CGPoint(x: frame.maxX - arm, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY),
                                   CGPoint(x: frame.maxX, y: frame.maxY - rise)])
        corners.addLines(between: [CGPoint(x: frame.maxX, y: frame.minY + rise), CGPoint(x: frame.maxX, y: frame.minY),
                                   CGPoint(x: frame.maxX - arm, y: frame.minY)])
        corners.addLines(between: [CGPoint(x: frame.minX + arm, y: frame.minY), CGPoint(x: frame.minX, y: frame.minY),
                                   CGPoint(x: frame.minX, y: frame.minY + rise)])
        var stroked = corners.copy(strokingWithWidth: 2.4, lineCap: .round, lineJoin: .round, miterLimit: 10)
        stroked = stroked.copy(using: [t]) ?? stroked

        let tail = CGMutablePath()
        tail.addLines(between: [CGPoint(x: 3.2, y: 5), CGPoint(x: 1.4, y: 0.4), CGPoint(x: 8.2, y: 5)], transform: t)
        tail.closeSubpath()

        let dot = CGPath(ellipseIn: CGRect(x: 9.3, y: 8.3, width: 5.4, height: 5.4), transform: [t])
        return [stroked, tail, dot]
    }

    /// Menu bar glyph. Template image, so macOS tints it for light and dark menu bars.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 17), flipped: false) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            for part in parts(in: bounds.insetBy(dx: 0.5, dy: 0.5)) {
                ctx.addPath(part)
                ctx.fillPath()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func transform(for rect: CGRect) -> CGAffineTransform {
        let s = min(rect.width / 24, rect.height / 18)
        return CGAffineTransform(translationX: rect.midX - 12 * s, y: rect.midY - 9 * s).scaledBy(x: s, y: s)
    }
}
