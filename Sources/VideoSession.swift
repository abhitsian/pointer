import AppKit

/// Records the screen, a picked area, or one document window while the user talks, then pastes what Claude
/// can read: key frames (or document pages), the narration split per frame, clicks, and text read off the screen.
final class VideoSession: ActiveCapture {
    enum Mode { case screen, area, document }
    private enum Phase { case picking, starting, recording, processing, over }

    /// Records the microphone into the .mov so the video can be shared with people.
    static var includeVoice: Bool {
        get { UserDefaults.standard.object(forKey: "voiceInRecordings") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceInRecordings") }
    }

    private let mode: Mode
    private let target: Target
    private let hud: HUDController
    private let autoSend: Bool
    private let stopLabel: String
    private let folder: URL
    private let onEnd: (CaptureRecord?) -> Void

    private let transcriber = Transcriber()
    private let picker = RegionPicker()
    private let recorder = ScreenRecorder()
    private let clicks = ClickLog()
    private var phase = Phase.picking
    private var recordingStarted = Date()
    private var clock: Timer?
    private var voice = false
    private var documentSource = ""

    /// Longest recording, in seconds.
    private let limit = 120
    /// Speech recognition reports words about this long after they are spoken.
    private static let recognitionLag: TimeInterval = 0.8

    private var videoURL: URL { folder.appendingPathComponent("recording.mov") }

    init(mode: Mode, target: Target, hud: HUDController, autoSend: Bool, stopLabel: String,
         capturesFolder: URL, onEnd: @escaping (CaptureRecord?) -> Void) {
        self.mode = mode
        self.target = target
        self.hud = hud
        self.autoSend = autoSend
        self.stopLabel = stopLabel
        self.onEnd = onEnd
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        folder = capturesFolder.appendingPathComponent("\(stamp.string(from: Date()))-\(mode == .document ? "document" : "video")",
                                                      isDirectory: true)
    }

    func start() {
        Log.write("video: start mode=\(mode) target=\(target.app.bundleIdentifier ?? "?")")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        hud.model.reset()
        hud.model.placeholder = mode == .document ? "Say what you want from this document" : "Talk through what you're showing"
        transcriber.onText = { [weak self] in self?.hud.model.transcript = $0 }
        transcriber.onLevel = { [weak self] in self?.hud.model.level = $0 }
        transcriber.start { [weak self] error in
            guard let self, self.phase != .over, self.phase != .processing else { return }
            if let error {
                Log.write("video: mic failed \(error)")
                self.hud.model.placeholder = (error as? PointerError)?.message ?? "Mic unavailable"
            } else {
                self.hud.model.listening = true
            }
        }

        switch mode {
        case .screen:
            let mouse = NSEvent.mouseLocation
            hud.model.status = "Starting recording"
            hud.show()
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
                record(.rect(screen.frame))
            } else {
                cancel()
            }
        case .area:
            hud.model.status = "Video · pick the area to record"
            hud.model.hint = "esc cancels"
            hud.show()
            picker.pick(prompt: "Drag the area to record, or click to record the whole screen") { [weak self] rect in
                guard let self else { return }
                if let rect { self.record(.rect(rect)) } else { self.cancel() }
            }
        case .document:
            guard let window = ScreenRecorder.frontWindow() else {
                phase = .over
                transcriber.cancel()
                hud.flash("No window to read", hint: "click into the document first")
                onEnd(nil)
                return
            }
            documentSource = window.title.isEmpty ? window.app : "\(window.app), \"\(window.title)\""
            hud.model.status = "Starting"
            hud.show()
            record(.window(window.id))
        }
    }

    /// The shortcut again: stop and send.
    func shortcutPressed() {
        Log.write("video: shortcut in phase \(phase)")
        if phase == .recording { stop() }
    }

    func cancel() {
        Log.write("video: cancel in phase \(phase)")
        guard phase == .picking || phase == .starting || phase == .recording else { return }
        if phase == .picking { picker.cancel() }
        phase = .over
        clock?.invalidate()
        clicks.stop()
        hud.onStop = nil
        recorder.stop { [folder] _ in try? FileManager.default.removeItem(at: folder) }
        transcriber.cancel()
        hud.model.listening = false
        hud.model.status = "Cancelled"
        hud.model.hint = ""
        hud.hide(after: 0.5)
        onEnd(nil)
    }

    private enum Source {
        case rect(CGRect)
        case window(CGWindowID)
    }

    private func record(_ source: Source) {
        guard phase == .picking else { return }
        phase = .starting
        voice = VideoSession.includeVoice
        let begun: (Error?) -> Void = { [weak self] error in
            guard let self, self.phase == .starting else { return }
            if let error {
                Log.write("video: recorder failed \(error)")
                self.phase = .over
                self.transcriber.cancel()
                self.hud.flash("Couldn't start recording")
                self.onEnd(nil)
                return
            }
            self.phase = .recording
            self.recordingStarted = Date()
            if self.mode != .document { self.clicks.start() }
            Log.write("video: recording mode=\(self.mode) voice=\(self.voice)")
            self.hud.model.hint = "\(self.stopLabel) stops"
            self.hud.onStop = { [weak self] in self?.stop() }
            self.tick()
            self.clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        }
        switch source {
        case .rect(let rect):
            hud.keepClear(of: rect)
            recorder.start(rect: rect, to: videoURL, voice: voice, started: begun)
        case .window(let id):
            recorder.start(window: id, to: videoURL, voice: voice, started: begun)
        }
    }

    private func tick() {
        let elapsed = Int(Date().timeIntervalSince(recordingStarted))
        if elapsed >= limit { stop() }
        let time = "\(elapsed / 60):" + String(format: "%02d", elapsed % 60)
        hud.model.status = mode == .document ? "● Reading \(time) · scroll through it" : "● Recording \(time)"
    }

    private func stop() {
        guard phase == .recording else { return }
        Log.write("video: stopping")
        phase = .processing
        clock?.invalidate()
        clicks.stop()
        hud.onStop = nil
        hud.model.listening = false
        hud.model.hint = ""
        hud.model.status = mode == .document ? "Reading the pages" : "Picking key frames"
        let started = recordingStarted
        let seconds = Date().timeIntervalSince(started)
        var narration: String?
        var saved = false
        // Both the file and the transcript have to be finished before frames can be matched to words.
        let proceed = { [weak self] in
            guard let self, saved, let narration else { return }
            let spoken = self.spokenWords(narration: narration, started: started, seconds: seconds)
            self.writeCaptions(spoken, narration: narration, seconds: seconds)
            let video = self.videoURL
            let folder = self.folder
            if self.mode == .document {
                DispatchQueue.global(qos: .userInitiated).async {
                    let document = KeyFrames.pages(from: video, into: folder)
                    DispatchQueue.main.async {
                        self.deliverDocument(pages: document.pages, text: document.text, narration: narration, seconds: seconds)
                    }
                }
                return
            }
            let clicks = self.clicks.clicks
            DispatchQueue.global(qos: .userInitiated).async {
                let frames = KeyFrames.extract(from: video, into: folder, maxFrames: KeyFrames.limit(forSeconds: seconds))
                var text = [[ScreenText.Line]](repeating: [], count: frames.count)
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: frames.count) { i in
                    let lines = ScreenText.lines(at: frames[i].url)
                    lock.lock(); text[i] = lines; lock.unlock()
                }
                ScreenTranscript.write(frames.indices.map {
                    ScreenTranscript.Entry(file: frames[$0].url.lastPathComponent, time: frames[$0].time, context: nil,
                                           lines: ScreenTranscript.content(text[$0]))
                }, folder: folder)
                DispatchQueue.main.async {
                    self.deliverVideo(frames: frames, screenText: text, narration: narration, spoken: spoken,
                                      clicks: clicks, started: started, seconds: seconds)
                }
            }
        }
        recorder.stop { error in
            Log.write("video: file saved=\(FileManager.default.fileExists(atPath: self.videoURL.path)) error=\(String(describing: error))")
            saved = true
            proceed()
        }
        transcriber.finish { text in
            narration = text
            proceed()
        }
    }

    // MARK: Output

    private var captionsURL: URL { folder.appendingPathComponent("captions.srt") }

    /// Each word with when it was spoken: the recognizer's own timestamps, or an estimate when it gave none.
    private func spokenWords(narration: String, started: Date, seconds: Double) -> [Captions.Spoken] {
        let timed = transcriber.words
        if !timed.isEmpty { return timed.map { ($0.text, $0.at.timeIntervalSince(started)) } }
        return Captions.estimated(narration: narration, history: transcriber.history, started: started,
                                  duration: seconds, lag: VideoSession.recognitionLag)
    }

    private var cues: [Captions.Cue] = []

    private func writeCaptions(_ spoken: [Captions.Spoken], narration: String, seconds: Double) {
        guard !narration.isEmpty else { return }
        try? narration.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        cues = Captions.cues(spoken, duration: seconds)
        try? Captions.srt(cues).write(to: captionsURL, atomically: true, encoding: .utf8)
        try? Captions.vtt(cues).write(to: folder.appendingPathComponent("captions.vtt"), atomically: true, encoding: .utf8)
    }

    /// Per frame: the clicks just before it, the text that appeared and went, and the words said while it was on
    /// screen (from its time until the next frame's; anything said before the recording began goes with frame 1).
    static func notes(frames: [KeyFrames.Frame], screenText: [[ScreenText.Line]], spoken: [Captions.Spoken],
                      clicks: [ClickLog.Click], started: Date) -> [SessionPage.Frame] {
        let clickTimes = clicks.map { ($0, $0.time.timeIntervalSince(started)) }
        return frames.enumerated().map { i, frame in
            let from = i == 0 ? -Double.infinity : frame.time
            let to = i + 1 < frames.count ? frames[i + 1].time : .infinity
            var note = SessionPage.Frame(file: frame.url.lastPathComponent, time: frame.time)
            note.said = spoken.filter { $0.start >= from && $0.start < to }.map(\.text).joined(separator: " ")
            if i > 0 {
                note.clicks = clickTimes.filter { $0.1 > frames[i - 1].time && $0.1 <= frame.time }.map { "\($0.0.target) in \($0.0.app)" }
                if i < screenText.count {
                    let images = ScreenText.image(at: frames[i - 1].url).flatMap { a in ScreenText.image(at: frame.url).map { (a, $0) } }
                    let change = ScreenText.changes(from: screenText[i - 1], to: screenText[i], images: images)
                    note.appeared = change.appeared
                    note.gone = change.gone
                }
            }
            return note
        }
    }

    /// The text pasted ahead of the frames.
    static func summary(notes: [SessionPage.Frame], lateClicks: [String], seconds: Double, video: URL, captions: URL?,
                        voice: Bool) -> String {
        func quoted(_ items: [String], max: Int) -> String {
            items.prefix(max).map { "\"\($0.count > 70 ? String($0.prefix(67)) + "…" : $0)\"" }.joined(separator: "; ")
                + (items.count > max ? " (+\(items.count - max) more)" : "")
        }
        func listed(_ clicks: [String]) -> String {
            clicks.prefix(3).joined(separator: ", then ") + (clicks.count > 3 ? " (+\(clicks.count - 3) more clicks)" : "")
        }
        var lines = ["Screen recording, \(Int(seconds.rounded())) s, \(notes.count) key frames attached in order."]
        for (i, note) in notes.enumerated() {
            var line = "Frame \(i + 1) at \(clock(note.time))"
            if !note.clicks.isEmpty { line += ", after clicking \(listed(note.clicks))" }
            line += "."
            if !note.appeared.isEmpty { line += " New on screen: \(quoted(note.appeared, max: 6))." }
            if !note.gone.isEmpty { line += " Gone: \(quoted(note.gone, max: 3))." }
            if !note.said.isEmpty { line += " Said: \"\(note.said)\"" }
            lines.append(line)
        }
        if !lateClicks.isEmpty { lines.append("After the last frame: clicked \(listed(lateClicks)).") }
        lines.append("Video\(voice ? " with my voice" : ""): \(video.path)" + (captions.map { ", captions: \($0.path)" } ?? ""))
        return lines.joined(separator: "\n") + "\n"
    }

    private static func clock(_ seconds: Double) -> String {
        "\(Int(seconds) / 60):" + String(format: "%02d", Int(seconds) % 60)
    }

    private func deliverVideo(frames: [KeyFrames.Frame], screenText: [[ScreenText.Line]], narration: String,
                              spoken: [Captions.Spoken], clicks: [ClickLog.Click], started: Date, seconds: Double) {
        Log.write("video: \(frames.count) frames, \(narration.count) chars, \(clicks.count) clicks")
        guard !frames.isEmpty else { return failEmpty() }
        let captions = FileManager.default.fileExists(atPath: captionsURL.path) ? captionsURL : nil
        let notes = VideoSession.notes(frames: frames, screenText: screenText, spoken: spoken, clicks: clicks, started: started)
        let late = clicks.filter { $0.time.timeIntervalSince(started) > frames[frames.count - 1].time }.map { "\($0.target) in \($0.app)" }
        let summary = VideoSession.summary(notes: notes, lateClicks: late, seconds: seconds, video: videoURL,
                                           captions: captions, voice: voice)
        try? summary.write(to: folder.appendingPathComponent("summary.txt"), atomically: true, encoding: .utf8)
        writePage(kind: "video", seconds: seconds, narration: narration, frames: notes, summary: summary,
                  clicks: clicks.map { SessionPage.Click(time: $0.time.timeIntervalSince(started), target: $0.target, app: $0.app) })
        send([.text(summary)] + frames.map { .image($0.url) }, narration: narration, label: "\(frames.count) frames")
    }

    /// The capture's HTML page, and the library entry for it.
    private func writePage(kind: String, seconds: Double, narration: String, frames: [SessionPage.Frame], summary: String,
                           clicks: [SessionPage.Click] = [], lines: [String]? = nil) {
        var page = SessionPage(kind: kind, created: recordingStarted, seconds: seconds, target: target.name,
                               video: "recording.mov", voice: voice, narration: narration, frames: frames)
        page.title = Viewer.label(for: page)
        page.cues = cues.map { SessionPage.Cue(start: $0.start, end: $0.end, text: $0.text) }

        page.clicks = clicks
        page.summary = summary
        if kind == "document" {
            page.documentSource = documentSource
            page.documentLines = lines
        }
        let folder = self.folder
        DispatchQueue.global(qos: .utility).async {
            Viewer.write(page, folder: folder)
            Viewer.rebuildLibrary()
        }
    }

    private func deliverDocument(pages: [KeyFrames.Frame], text: [String], narration: String, seconds: Double) {
        Log.write("document: \(pages.count) pages, \(text.count) lines, \(narration.count) chars")
        guard !pages.isEmpty else { return failEmpty() }
        let file = folder.appendingPathComponent("document.md")
        try? ("# \(documentSource)\n\nRead from the screen by Pointer.\n\n" + text.joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)

        var intro = narration.isEmpty ? "" : narration + "\n"
        intro += "Document from \(documentSource), \(pages.count) pages attached in order. "
        switch target.style {
        case .path:
            intro += "Full text read from the screen (\(text.count) lines): \(file.path)\n"
        case .image:
            intro += "Full text read from the screen:\n\n" + text.joined(separator: "\n") + "\n"
        }
        writePage(kind: "document", seconds: seconds, narration: narration,
                  frames: pages.map { SessionPage.Frame(file: $0.url.lastPathComponent, time: $0.time) }, summary: intro, lines: text)
        send([.text(intro)] + pages.map { .image($0.url) }, narration: narration, label: "\(pages.count) pages")
    }

    private func failEmpty() {
        Log.write("video: nothing to send, file exists=\(FileManager.default.fileExists(atPath: videoURL.path))")
        phase = .over
        hud.model.tone = .error
        hud.model.status = "The recording came out empty"
        hud.hide(after: 3)
        onEnd(nil)
    }

    private func send(_ parts: [Part], narration: String, label: String) {
        hud.model.transcript = narration
        hud.model.status = "Sending to \(target.name)"
        let video = videoURL
        Deliverer.deliver(parts, to: target, autoSend: autoSend) { [weak self] result in
            guard let self else { return }
            self.phase = .over
            switch result {
            case .success:
                self.hud.model.tone = .done
                self.hud.model.status = "\(label) " + (self.autoSend ? "sent to" : "pasted into") + " \(self.target.name)"
                self.hud.hide(after: 1.6)
            case .failure(let error):
                Log.write("video: delivery failed \(error.message)")
                self.hud.model.tone = .error
                self.hud.model.status = error.message
                self.hud.hide(after: 4)
            }
            self.onEnd(CaptureRecord(parts: parts, video: video))
        }
    }
}
