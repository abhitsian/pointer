import AppKit

/// Pointer's mark: an arrow cursor with a speech bubble coming off it (point and tell), the bubble's three dots
/// cut out. Drawn in a 24×18 unit box with y pointing up. Fill each part on its own so overlaps stay solid.
enum Mark {
    static func parts(in rect: CGRect) -> [CGPath] {
        let t = transform(for: rect)
        let u: CGFloat = 0.74
        let tip = CGPoint(x: 1.2, y: 16.2)
        let arrow = CGMutablePath()
        arrow.addLines(between: [(0, 0), (0, 16.5), (4, 12.8), (6.8, 19.3), (9.6, 18.1), (6.9, 11.8), (12.2, 11.8)]
            .map { CGPoint(x: tip.x + $0.0 * u, y: tip.y - $0.1 * u) }, transform: t)
        arrow.closeSubpath()

        let body = CGRect(x: 11.2, y: 8.6, width: 12.3, height: 8.4)
        let bubble = CGMutablePath()
        bubble.addRoundedRect(in: body, cornerWidth: 3.2, cornerHeight: 3.2, transform: t)
        bubble.addLines(between: [CGPoint(x: 12.6, y: 9.4), CGPoint(x: 10.2, y: 6.4), CGPoint(x: 16.2, y: 9.4)], transform: t)
        bubble.closeSubpath()
        let dots = CGMutablePath()
        for i in 0..<3 {
            dots.addEllipse(in: CGRect(x: body.midX - 1 + CGFloat(i - 1) * 3, y: body.midY - 1, width: 2, height: 2), transform: t)
        }
        return [arrow, bubble.subtracting(dots)]
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
