import AppKit
import AVFoundation

/// Picks the frames of a screen recording worth showing Claude.
enum KeyFrames {
    struct Frame {
        let time: Double
        let url: URL
    }

    /// Frames are compared on a 96×96 grayscale thumbnail split into a 12×12 grid of 8×8-pixel cells.
    private static let side = 96
    private static let cell = 8
    /// Mean change (0…255) inside one cell below which the cell counts as unchanged. Keeps the cursor
    /// and small click rings from registering while a toast covering one cell still does.
    private static let cellNoise = 10.0
    /// Total change above noise, summed over cells, that makes a new frame.
    private static let frameThreshold = 12.0
    /// Longest edge of a saved frame. Claude reads up to 2576 px, but once a request holds more than
    /// 20 images every image must be 2000 px or less.
    private static let maxEdge: CGFloat = 2000

    /// 6 frames for recordings up to about 50 s, then one more per 8 s, up to 12.
    static func limit(forSeconds seconds: Double) -> Int {
        min(12, max(6, Int(seconds / 8)))
    }

    // MARK: Video frames

    static func extract(from video: URL, into folder: URL, maxFrames: Int, sampleEvery: Double? = nil) -> [Frame] {
        let asset = AVURLAsset(url: video)
        let end = CMTimeGetSeconds(asset.duration)
        guard end.isFinite else { return [] }
        let scanner = generator(for: asset, maxSize: 320)
        func thumb(at seconds: Double) -> [UInt8]? {
            image(from: scanner, at: seconds).map(thumbnail)
        }

        // At most ~240 samples, never closer than a quarter second.
        var picks: [(time: Double, score: Double)] = []
        var last: [UInt8]?
        var lastChangeAt = -1.0
        var chainStart = 0.0
        let step = sampleEvery ?? max(0.25, end / 240)
        var t = 0.0
        while t <= end {
            if let current = thumb(at: t) {
                let score = last.map { change($0, current) } ?? .infinity
                if score > frameThreshold {
                    // A change right after another is the same transition still settling (an animation, a
                    // redraw): keep its final state, unless the screen has been changing for over a second.
                    let settling = picks.count > 1 && abs(t - step - lastChangeAt) < 0.001 && t - chainStart < 1
                    if settling {
                        picks[picks.count - 1] = (t, max(score, picks[picks.count - 1].score))
                    } else {
                        picks.append((t, score))
                        chainStart = t
                    }
                    last = current
                    lastChangeAt = t
                }
            }
            t += step
        }
        // Always finish on the final state of the screen.
        if let lastThumb = last, let final = thumb(at: end - 0.05), change(lastThumb, final) > frameThreshold / 2 {
            picks.append((end - 0.05, frameThreshold))
        }

        if picks.count > maxFrames, let first = picks.first, let final = picks.last {
            let middle = picks.dropFirst().dropLast().sorted { $0.score > $1.score }.prefix(maxFrames - 2)
            picks = ([first] + middle + [final]).sorted { $0.time < $1.time }
        }
        return save(picks.map(\.time), from: asset, into: folder, prefix: "frame")
    }

    // MARK: Document pages

    /// For a recording of someone scrolling through a document: keeps a frame each time most of the visible
    /// text is new, and returns the document's text in reading order with repeated lines removed.
    static func pages(from video: URL, into folder: URL, maxImages: Int = 12) -> (pages: [Frame], text: [String]) {
        let asset = AVURLAsset(url: video)
        let end = CMTimeGetSeconds(asset.duration)
        guard end.isFinite else { return ([], []) }
        let reader = generator(for: asset, maxSize: 1600)

        var picks: [Double] = []
        var seen = Set<String>()
        let step = max(0.3, end / 200)
        var t = 0.0
        while t <= end + 0.001 {
            let at = min(t, max(0, end - 0.05))
            if let frame = image(from: reader, at: at) {
                let keys = ScreenText.lines(in: frame, fast: true).map(\.key)
                let fresh = keys.filter { !seen.contains($0) }.count
                let isLast = t + step > end
                // A new page once most of the visible text is new; the final screen counts if anything is new,
                // so the end of the document is never dropped.
                let enough = picks.isEmpty || isLast || Double(fresh) >= Double(keys.count) * 0.6
                if fresh >= 1, enough {
                    picks.append(at)
                    seen.formUnion(keys)
                }
            }
            t += step
        }

        let pages = save(picks, from: asset, into: folder, prefix: "page")
        // Accurate reading of every page, in parallel, then stitched with repeats dropped.
        var perPage = [[ScreenText.Line]](repeating: [], count: pages.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: pages.count) { i in
            let lines = ScreenText.lines(at: pages[i].url)
            lock.lock(); perPage[i] = lines; lock.unlock()
        }
        let text = stitch(perPage)

        // Attach at most maxImages pages, spread evenly; the text still covers every page.
        guard pages.count > maxImages else { return (pages, text) }
        let spread = (0..<maxImages).map { Int((Double($0) * Double(pages.count - 1) / Double(maxImages - 1)).rounded()) }
        return (Array(Set(spread)).sorted().map { pages[$0] }, text)
    }

    /// Joins the text of consecutive pages without repeating the overlap. Lines found on both pages give the
    /// scroll distance; a line that would already have been visible on the previous page is skipped, even if
    /// it was read differently there. Text that did not move (toolbars, headers) is kept once.
    static func stitch(_ pages: [[ScreenText.Line]]) -> [String] {
        var text: [String] = []
        var emitted = Set<String>()
        func emit(_ line: ScreenText.Line) {
            text.append(line.text)
            emitted.insert(line.key)
        }
        for (k, lines) in pages.enumerated() {
            guard k > 0 else { lines.forEach(emit); continue }
            let previous = pages[k - 1]
            let before = Dictionary(grouping: previous, by: \.key).compactMapValues { $0.count == 1 ? $0[0] : nil }
            let counts = Dictionary(grouping: lines, by: \.key).mapValues(\.count)
            var shifts: [CGFloat] = []
            var fixed = Set<String>()
            for line in lines where counts[line.key] == 1 {
                guard let old = before[line.key] else { continue }
                let shift = line.box.midY - old.box.midY // content moves up as the reader scrolls down
                if abs(shift) < 0.01 { fixed.insert(line.key) } else if shift > 0 { shifts.append(shift) }
            }
            let fresh = lines.filter { !fixed.contains($0.key) }
            guard !shifts.isEmpty else {
                // Nothing scrolled into view from the previous page: a jump ahead, or a return to text already read.
                if Double(fresh.filter { emitted.contains($0.key) }.count) < Double(max(fresh.count, 1)) * 0.5 {
                    fresh.forEach(emit)
                }
                continue
            }
            let shift = shifts.sorted()[shifts.count / 2]
            let lowestBefore = previous.map(\.box.midY).min() ?? 0
            for line in fresh where line.box.midY - shift < lowestBefore - 0.005 {
                // A line cut off at the edge of the previous page can land just past the boundary: skip exact repeats
                // of the last few lines.
                if !text.suffix(3).map(ScreenText.normalize).contains(line.key) { emit(line) }
            }
        }
        return text
    }

    // MARK: Helpers

    private static func generator(for asset: AVAsset, maxSize: CGFloat?) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: asset)
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        g.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        if let maxSize { g.maximumSize = CGSize(width: maxSize, height: maxSize) }
        return g
    }

    private static func image(from generator: AVAssetImageGenerator, at seconds: Double) -> CGImage? {
        try? generator.copyCGImage(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600), actualTime: nil)
    }

    /// Full-resolution images for the chosen moments, saved as prefix-1.png, prefix-2.png…
    private static func save(_ times: [Double], from asset: AVAsset, into folder: URL, prefix: String) -> [Frame] {
        let full = generator(for: asset, maxSize: nil)
        return times.enumerated().compactMap { index, time in
            let url = folder.appendingPathComponent("\(prefix)-\(index + 1).png")
            guard let image = image(from: full, at: time), write(image, to: url) else { return nil }
            return Frame(time: time, url: url)
        }
    }

    private static func thumbnail(_ image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return pixels
    }

    /// Sum, over grid cells, of each cell's mean change above the noise floor.
    private static func change(_ a: [UInt8], _ b: [UInt8]) -> Double {
        let cells = side / cell
        var total = 0.0
        for cy in 0..<cells {
            for cx in 0..<cells {
                var sum = 0
                for y in (cy * cell)..<(cy * cell + cell) {
                    let row = y * side
                    for x in (cx * cell)..<(cx * cell + cell) {
                        sum += abs(Int(a[row + x]) - Int(b[row + x]))
                    }
                }
                total += max(0, Double(sum) / Double(cell * cell) - cellNoise)
            }
        }
        return total
    }

    /// Writes a PNG no larger than `maxEdge` on its long side.
    private static func write(_ image: CGImage, to url: URL) -> Bool {
        let scale = min(1, maxEdge / CGFloat(max(image.width, image.height)))
        var output = image
        if scale < 1 {
            let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
            if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                if let scaled = ctx.makeImage() { output = scaled }
            }
        }
        guard let png = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}
