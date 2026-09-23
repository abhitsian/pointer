import Foundation

/// Writes screen.txt: every line of text read off each key frame, in order, so what was on screen can be
/// searched alongside what was said (the /pointer skill and the pointer MCP read it).
enum ScreenTranscript {
    struct Entry {
        let file: String
        let time: Double
        let context: String?
        let lines: [String]
    }

    /// Full-screen frames: the text of each line, minus the macOS menu bar strip at the top (app menus, clock,
    /// status items), which repeats on every frame and buries what was actually on screen.
    static func content(_ lines: [ScreenText.Line]) -> [String] {
        lines.filter { $0.box.minY < 0.966 }.map(\.text)
    }

    static func write(_ entries: [Entry], folder: URL) {
        let text = entries.map { entry in
            let head = "## [\(WatchSession.clock(entry.time))] \(entry.file)" + (entry.context.map { " · \($0)" } ?? "")
            return ([head] + entry.lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        try? (text + "\n").write(to: folder.appendingPathComponent("screen.txt"), atomically: true, encoding: .utf8)
    }

    /// A screenshot's text, next to it as <stamp>.screen.txt.
    static func write(screenshot image: URL) {
        let lines = ScreenText.lines(at: image).map(\.text)
        let text = (["## [0:00] \(image.lastPathComponent)"] + lines).joined(separator: "\n") + "\n"
        try? text.write(to: image.deletingPathExtension().appendingPathExtension("screen.txt"), atomically: true, encoding: .utf8)
    }

    /// Reads the frames of every capture folder that has none yet. Returns how many folders it wrote.
    @discardableResult
    static func backfill(root: URL = Viewer.root) -> Int {
        struct Page: Decodable {
            struct Frame: Decodable { let file: String; let time: Double; let context: String? }
            let frames: [Frame]
        }
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var written = 0
        for image in folders where image.pathExtension == "png"
            && !FileManager.default.fileExists(atPath: image.deletingPathExtension().appendingPathExtension("screen.txt").path) {
            write(screenshot: image)
            written += 1
        }
        for folder in folders where !FileManager.default.fileExists(atPath: folder.appendingPathComponent("screen.txt").path) {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("session.json")),
                  let page = try? JSONDecoder().decode(Page.self, from: data), !page.frames.isEmpty else { continue }
            var entries = [Entry?](repeating: nil, count: page.frames.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: page.frames.count) { i in
                let frame = page.frames[i]
                let lines = content(ScreenText.lines(at: folder.appendingPathComponent(frame.file)))
                lock.lock(); entries[i] = Entry(file: frame.file, time: frame.time, context: frame.context, lines: lines); lock.unlock()
            }
            write(entries.compactMap { $0 }, folder: folder)
            written += 1
        }
        return written
    }
}
