import AppKit
import Vision

/// Reads text off a frame with Apple's on-device text recognition.
enum ScreenText {
    struct Line {
        let text: String
        /// Normalized (0…1, origin bottom-left) box of the line in the image.
        let box: CGRect
        /// Lowercased, whitespace-collapsed text used to compare lines across frames.
        var key: String { ScreenText.normalize(text) }
    }

    /// Lines top to bottom. `fast` trades accuracy for roughly 10x speed.
    static func lines(in image: CGImage, fast: Bool = false) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = !fast
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            return text.count >= 2 ? Line(text: text, box: observation.boundingBox) : nil
        }
        // Reading order: top to bottom, then left to right within a row.
        return lines.sorted { a, b in
            abs(a.box.midY - b.box.midY) > 0.01 ? a.box.midY > b.box.midY : a.box.minX < b.box.minX
        }
    }

    static func lines(at url: URL, fast: Bool = false) -> [Line] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return lines(in: image, fast: fast)
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Text that is on screen in `after` but was not in `before`, and the reverse. Lines are compared on their
    /// letters and digits only, so a re-read that differs in spacing or punctuation ("2:13 PM" / "2:13PM") is not a
    /// change, and lines with fewer than three letters or digits (usually icons read as text) are left out.
    ///
    /// With the two frames' images, a line also counts only if the pixels inside its box changed: the same unchanged
    /// text read two ways (a site icon read as "6" one time and "G•" the next) is not a change.
    static func changes(from before: [Line], to after: [Line], images: (CGImage, CGImage)? = nil) -> (appeared: [String], gone: [String]) {
        func core(_ line: Line) -> String { String(line.text.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let meaningful = { (line: Line) in core(line).count >= 3 }
        let old = Set(before.filter(meaningful).map(core))
        let new = Set(after.filter(meaningful).map(core))
        let moved = { (line: Line) in images.map { pixelsChanged(in: line.box, $0.0, $0.1) } ?? true }
        return (after.filter { meaningful($0) && !old.contains(core($0)) && moved($0) }.map(\.text),
                before.filter { meaningful($0) && !new.contains(core($0)) && moved($0) }.map(\.text))
    }

    /// Whether a normalized box (origin bottom-left) looks different in two images of the same size.
    static func pixelsChanged(in box: CGRect, _ a: CGImage, _ b: CGImage) -> Bool {
        func sample(_ image: CGImage) -> [UInt8]? {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
                .insetBy(dx: -2, dy: -2).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !rect.isEmpty, let crop = image.cropping(to: rect) else { return nil }
            let sw = 64, sh = max(4, min(24, Int(64 * rect.height / max(rect.width, 1))))
            var pixels = [UInt8](repeating: 0, count: sw * sh)
            pixels.withUnsafeMutableBytes { buffer in
                guard let ctx = CGContext(data: buffer.baseAddress, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                ctx.interpolationQuality = .medium
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            }
            return pixels
        }
        guard a.width == b.width, a.height == b.height, let x = sample(a), let y = sample(b) else { return true }
        let diff = zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(diff) / Double(x.count) > 10
    }

    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
