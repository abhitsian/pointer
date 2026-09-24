import AVFoundation
import Foundation

/// The data behind a capture's HTML page. Saved as JSON next to the capture and written into the page.
struct SessionPage: Codable {
    struct Frame: Codable {
        var file: String
        var time: Double
        var clicks: [String] = []
        var appeared: [String] = []
        var gone: [String] = []
        var said: String = ""
        /// Watch sessions: the app and window in front at that moment.
        var context: String?
    }
    struct Cue: Codable {
        var start: Double
        var end: Double
        var text: String
        /// Watch sessions: "You" or "Others".
        var speaker: String?
    }
    struct Click: Codable {
        var time: Double
        var target: String
        var app: String
    }

    var kind: String // "video", "document", "screenshot", "watch" or "listen"
    /// A short label for the library, written by the session or taken from what was captured.
    var title: String?
    var created: Date
    var seconds: Double?
    var target: String?
    var video: String?
    var voice = false
    var narration = ""
    var frames: [Frame] = []
    var cues: [Cue] = []
    var clicks: [Click] = []
    var documentSource: String?
    var documentLines: [String]?
    var summary: String?
    /// Watch sessions: the write-up in Markdown.
    var digest: String?
    /// Listen-and-ask sessions: the questions suggested live, at their time in the session.
    struct Question: Codable {
        var time: Double
        var text: String
    }
    var questions: [Question]?
    /// True while the capture is still being written up, so the library can show it straight away.
    var processing: Bool?
}

/// Writes the HTML pages: one per capture, and the library at ~/Pictures/Pointer/index.html.
enum Viewer {
    static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Pointer", isDirectory: true)

    /// Saves `page` as session.json and index.html inside a capture folder.
    static func write(_ page: SessionPage, folder: URL) {
        save(page, json: folder.appendingPathComponent("session.json"), html: folder.appendingPathComponent("index.html"))
    }

    /// Saves a screenshot's page next to its PNG: <stamp>.json and <stamp>.html.
    static func write(_ page: SessionPage, screenshot: URL) {
        let base = screenshot.deletingPathExtension()
        save(page, json: base.appendingPathExtension("json"), html: base.appendingPathExtension("html"))
    }

    /// Rebuilds the library page from every capture, creating pages for captures made before pages existed.
    @discardableResult
    static func rebuildLibrary() -> URL {
        struct Entry: Encodable {
            let href: String, kind: String, created: Date, seconds: Double?, thumb: String?
            let title: String?, said: String, frames: Int, clicks: Int, target: String?
            var processing = false
        }
        var entries: [Entry] = []
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isFolder, let page = load(item.appendingPathComponent("session.json")) ?? backfillFolder(item) {
                // A capture that produced nothing (a failed or abandoned run) stays out of the library.
                let processing = page.processing == true
                guard processing || !page.frames.isEmpty || !page.narration.isEmpty || page.digest != nil else { continue }
                render(page, to: item.appendingPathComponent("index.html"))
                let name = item.lastPathComponent
                entries.append(Entry(href: "\(name)/index.html", kind: page.kind, created: page.created, seconds: page.seconds,
                                     thumb: page.frames.first.map { "\(name)/\($0.file)" }, title: page.title ?? label(for: page),
                                     said: page.narration, frames: page.frames.count, clicks: page.clicks.count, target: page.target,
                                     processing: processing))
            } else if item.pathExtension == "png",
                      let page = load(item.deletingPathExtension().appendingPathExtension("json")) ?? backfillScreenshot(item) {
                render(page, to: item.deletingPathExtension().appendingPathExtension("html"))
                let base = item.deletingPathExtension().lastPathComponent
                entries.append(Entry(href: "\(base).html", kind: "screenshot", created: page.created, seconds: nil,
                                     thumb: item.lastPathComponent, title: page.title ?? label(for: page), said: page.narration,
                                     frames: 1, clicks: 0, target: page.target))
            }
        }
        let url = root.appendingPathComponent("index.html")
        if let json = try? encoder.encode(entries), let html = fill("library", with: json) {
            try? html.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    /// A label for a session that never got one: what was said, the document it came from, or where it was taken.
    static func label(for page: SessionPage) -> String? {
        if let source = page.documentSource, !source.isEmpty { return source }
        let said = page.narration.split(whereSeparator: \.isWhitespace).prefix(9).joined(separator: " ")
        if said.count > 12 { return said + (page.narration.count > said.count ? "…" : "") }
        if let context = page.frames.compactMap(\.context).mostCommon() { return context }
        return page.frames.first.flatMap { _ in page.target.map { "Sent to \($0)" } }
    }

    // MARK: Pages for older captures

    /// Rebuilds a page from a capture folder's files: frame or page images, summary.txt, transcript.txt, the video.
    private static func backfillFolder(_ folder: URL) -> SessionPage? {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let isDocument = folder.lastPathComponent.hasSuffix("-document")
        let prefix = isDocument ? "page-" : "frame-"
        let images = files.filter { $0.hasPrefix(prefix) && $0.hasSuffix(".png") }
            .sorted { number(in: $0) < number(in: $1) }
        let hasVideo = files.contains("recording.mov")
        guard !images.isEmpty || hasVideo else { return nil }

        let summary = try? String(contentsOf: folder.appendingPathComponent("summary.txt"), encoding: .utf8)
        let narration = (try? String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? ""
        var seconds: Double?
        if hasVideo {
            let duration = CMTimeGetSeconds(AVURLAsset(url: folder.appendingPathComponent("recording.mov")).duration)
            if duration.isFinite, duration > 0 { seconds = duration }
        }
        // Frame times and what was said, from summary lines like `Frame 2 at 0:03 … Said: "…"`.
        var notes: [Int: SessionPage.Frame] = [:]
        func quotedItems(_ text: Substring) -> [String] { text.matches(of: #/"([^"]*)"/#).map { String($0.1) } }
        for line in (summary ?? "").components(separatedBy: "\n") {
            guard let match = line.firstMatch(of: #/Frame (\d+) at (\d+):(\d\d)/#), let n = Int(match.1),
                  let m = Double(match.2), let s = Double(match.3) else { continue }
            var note = SessionPage.Frame(file: "", time: m * 60 + s)
            if let quote = line.firstMatch(of: #/Said: "(.*)"/#) { note.said = String(quote.1) }
            if let click = line.firstMatch(of: #/after clicking (.+?)\.(?= New on screen| Gone| Said|$)/#) {
                note.clicks = click.1.components(separatedBy: ", then ")
            }
            if let new = line.firstMatch(of: #/New on screen: (.+?)\.(?= Gone| Said|$)/#) { note.appeared = quotedItems(new.1) }
            if let gone = line.firstMatch(of: #/Gone: (.+?)\.(?= Said|$)/#) { note.gone = quotedItems(gone.1) }
            notes[n] = note
        }
        var frames = images.enumerated().map { i, file -> SessionPage.Frame in
            var frame = notes[i + 1] ?? SessionPage.Frame(file: file, time: Double(i))
            frame.file = file
            return frame
        }
        // Re-read the frames rather than trusting older summaries, which predate the text-change filter.
        if !isDocument {
            let urls = images.map { folder.appendingPathComponent($0) }
            let text = urls.map { ScreenText.lines(at: $0) }
            let pictures = urls.map(ScreenText.image(at:))
            for i in frames.indices.dropFirst() {
                let pair = pictures[i - 1].flatMap { a in pictures[i].map { (a, $0) } }
                let change = ScreenText.changes(from: text[i - 1], to: text[i], images: pair)
                frames[i].appeared = change.appeared
                frames[i].gone = change.gone
            }
        }
        var page = SessionPage(kind: isDocument ? "document" : "video", created: date(from: folder.lastPathComponent),
                               seconds: seconds, video: hasVideo ? "recording.mov" : nil, narration: narration,
                               frames: frames, summary: summary)
        if frames.count == 1, frames[0].said.isEmpty { page.frames[0].said = narration }
        page.clicks = frames.flatMap { frame in frame.clicks.map { SessionPage.Click(time: frame.time, target: $0, app: "") } }
        write(page, folder: folder)
        return page
    }

    private static func backfillScreenshot(_ png: URL) -> SessionPage? {
        let base = png.deletingPathExtension()
        guard base.lastPathComponent.firstMatch(of: #/^\d{4}-\d\d-\d\d_\d\d-\d\d-\d\d$/#) != nil else { return nil }
        let narration = (try? String(contentsOf: base.appendingPathExtension("txt"), encoding: .utf8)) ?? ""
        let page = SessionPage(kind: "screenshot", created: date(from: base.lastPathComponent), narration: narration,
                               frames: [SessionPage.Frame(file: png.lastPathComponent, time: 0)])
        write(page, screenshot: png)
        return page
    }

    // MARK: Helpers

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func save(_ page: SessionPage, json: URL, html: URL) {
        guard let data = try? encoder.encode(page) else { return }
        try? data.write(to: json)
        render(page, to: html)
    }

    /// Writes the page from the current template, so pages pick up template changes on every library rebuild.
    private static func render(_ page: SessionPage, to html: URL) {
        guard let data = try? encoder.encode(page), let text = fill("session", with: data) else { return }
        try? text.write(to: html, atomically: true, encoding: .utf8)
    }

    private static func load(_ url: URL) -> SessionPage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(SessionPage.self, from: data)
    }

    /// The bundled template with its JSON placeholder replaced. `</` is escaped so the data can't close the script tag.
    private static func fill(_ template: String, with json: Data) -> String? {
        guard let url = Bundle.main.url(forResource: template, withExtension: "html"),
              let html = try? String(contentsOf: url, encoding: .utf8),
              let text = String(data: json, encoding: .utf8) else { return nil }
        let placeholder = template == "library" ? "__LIBRARY_JSON__" : "__SESSION_JSON__"
        return html.replacingOccurrences(of: placeholder, with: text.replacingOccurrences(of: "</", with: "<\\/"))
    }

    private static func number(in file: String) -> Int {
        Int(file.filter(\.isNumber)) ?? 0
    }

    /// Capture names start with yyyy-MM-dd_HH-mm-ss.
    private static func date(from name: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.date(from: String(name.prefix(19))) ?? Date()
    }
}
