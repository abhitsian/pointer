import AppKit

/// Watch mode: a silent partner. Records the screen at one frame a second with your microphone and the Mac's
/// own audio, keeps what was on screen and what was said, and writes it up afterwards. Nothing is pasted anywhere.
final class WatchSession: ActiveCapture {
    private enum Phase { case starting, watching, processing, over }

    /// Record the Mac's audio (the other side of a meeting) as well as the microphone.
    static var recordMeetingAudio: Bool {
        get { UserDefaults.standard.object(forKey: "watchMeetingAudio") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "watchMeetingAudio") }
    }

    private let hud: HUDController
    private let stopLabel: String
    private let folder: URL
    private let onEnd: (URL?) -> Void
    /// Reports the elapsed time so the menu bar can show it.
    var onTick: ((String?) -> Void)?

    private let recorder = ScreenRecorder()
    /// One recognizer per side, so every word knows who said it.
    private let you = SpeechStream(speaker: "You")
    private let others = SpeechStream(speaker: "Others")
    private let mixer: AudioMixer
    private var phase = Phase.starting
    private var started = Date()
    private var clock: Timer?
    private var context: [(at: Date, app: String, window: String)] = []
    private var meetingAudio = false

    /// Longest watch, in seconds.
    private let limit: TimeInterval = 4 * 3600

    private var videoURL: URL { folder.appendingPathComponent("recording.mov") }

    init(hud: HUDController, stopLabel: String, capturesFolder: URL, onEnd: @escaping (URL?) -> Void) {
        self.hud = hud
        self.stopLabel = stopLabel
        self.onEnd = onEnd
        meetingAudio = WatchSession.recordMeetingAudio
        mixer = AudioMixer(mic: true, system: meetingAudio)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        folder = capturesFolder.appendingPathComponent("\(stamp.string(from: Date()))-watch", isDirectory: true)
    }

    func start() {
        Log.write("watch: start meetingAudio=\(meetingAudio)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let you = self.you, others = self.others
        mixer.onSource = { frame, at, mic in (mic ? you : others).append(frame, at: at) }
        let meetingAudio = self.meetingAudio
        Task {
            async let mine: Void = you.start()
            if meetingAudio { await others.start() }
            await mine
            await MainActor.run { self.startRecording() }
        }
    }

    private func startRecording() {
        guard phase == .starting else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            phase = .over
            onEnd(nil)
            return
        }
        var options = ScreenRecorder.Options(voice: true, systemAudio: meetingAudio, framesPerSecond: 1, scale: 1)
        options.onAudio = { [weak self] sample, isMic in self?.mixer.add(sample, mic: isMic) }
        recorder.start(rect: screen.frame, to: videoURL, options: options) { [weak self] error in
            guard let self, self.phase == .starting else { return }
            if let error {
                Log.write("watch: recorder failed \(error)")
                self.phase = .over
                self.hud.flash("Couldn't start watching")
                self.onEnd(nil)
                return
            }
            self.phase = .watching
            self.started = Date()
            self.hud.flash("Watching this screen", hint: "\(self.stopLabel) stops · nothing is sent anywhere",
                           tone: .live, for: 3)
            self.noteContext()
            self.clock = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    /// The watch shortcut again: stop and write it up.
    func shortcutPressed() {
        if phase == .watching { stop() }
    }

    /// Stops and throws the session away.
    func cancel() {
        guard phase == .starting || phase == .watching else { return }
        phase = .over
        clock?.invalidate()
        onTick?(nil)
        recorder.stop { [folder] _ in try? FileManager.default.removeItem(at: folder) }
        you.finish(wait: 0.2) { _ in }
        others.finish(wait: 0.2) { _ in }
        hud.flash("Watch session discarded", tone: .live, for: 2)
        onEnd(nil)
    }

    private func tick() {
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= limit { return stop() }
        let seconds = Int(elapsed)
        onTick?("\(seconds / 60):" + String(format: "%02d", seconds % 60))
        noteContext()
    }

    /// The app and window in front, recorded when it changes.
    private func noteContext() {
        guard let app = NSWorkspace.shared.frontmostApplication?.localizedName else { return }
        var window = ""
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            window = list.first {
                $0[kCGWindowOwnerName as String] as? String == app && ($0[kCGWindowLayer as String] as? Int) == 0
            }?[kCGWindowName as String] as? String ?? ""
        }
        if context.last?.app != app || context.last?.window != window {
            context.append((Date(), app, window))
        }
    }

    /// Serial, so the "Processing…" placeholder is always written before the finished page.
    private let writeQueue = DispatchQueue(label: "pointer.watch.write", qos: .utility)

    private func stop() {
        guard phase == .watching else { return }
        Log.write("watch: stopping")
        phase = .processing
        clock?.invalidate()
        onTick?(nil)
        let started = self.started
        let seconds = Date().timeIntervalSince(started)
        // Stays up until the write-up is saved, so a long session never looks lost.
        hud.flash("Processing the session…", hint: "\(Int(seconds / 60)) min watched · it will appear in the library", tone: .live,
                  for: 600)
        var placeholder = SessionPage(kind: "watch", created: started, seconds: seconds, narration: "")
        placeholder.title = "Processing…"
        placeholder.processing = true
        let folder = self.folder
        writeQueue.async {
            Viewer.write(placeholder, folder: folder)
            Viewer.rebuildLibrary()
        }

        var saved = false
        var transcript: [SpeechStream.Word]?
        let proceed = { [weak self] in
            guard let self, saved, let transcript else { return }
            self.writeQueue.async {
                self.process(words: transcript, started: started, seconds: seconds)
            }
        }
        recorder.stop { _ in saved = true; proceed() }
        var heard: [[SpeechStream.Word]] = []
        let streams = meetingAudio ? [you, others] : [you]
        for stream in streams {
            stream.finish { words in
                heard.append(words)
                if heard.count == streams.count { transcript = heard.flatMap { $0 }; proceed() }
            }
        }
    }

    // MARK: Writing it up

    private func process(words: [SpeechStream.Word], started: Date, seconds: Double) {
        let frames = KeyFrames.extract(from: videoURL, into: folder, maxFrames: WatchSession.frameLimit(seconds),
                                       sampleEvery: 2)
        var screenText = [[ScreenText.Line]](repeating: [], count: frames.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: frames.count) { i in
            let lines = ScreenText.lines(at: frames[i].url)
            lock.lock(); screenText[i] = lines; lock.unlock()
        }

        Log.write("watch: audio \(mixer.summary) speech \(you.stats) · \(others.stats) words=\(words.count)")
        let cues = utterances(from: words, started: started)
        let transcript = cues.map { "[\(WatchSession.clock($0.start))] \($0.speaker ?? "You"): \($0.text)" }.joined(separator: "\n")
        if !transcript.isEmpty {
            try? transcript.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        }

        var notes: [SessionPage.Frame] = []
        for (i, frame) in frames.enumerated() {
            var note = SessionPage.Frame(file: frame.url.lastPathComponent, time: frame.time)
            if i > 0 {
                let images = ScreenText.image(at: frames[i - 1].url).flatMap { a in ScreenText.image(at: frame.url).map { (a, $0) } }
                let change = ScreenText.changes(from: screenText[i - 1], to: screenText[i], images: images)
                note.appeared = change.appeared
                note.gone = change.gone
            }
            note.context = where_(at: started.addingTimeInterval(frame.time))
            notes.append(note)
        }

        ScreenTranscript.write(notes.indices.map {
            ScreenTranscript.Entry(file: notes[$0].file, time: notes[$0].time, context: notes[$0].context, lines: ScreenTranscript.content(screenText[$0]))
        }, folder: folder)

        var page = SessionPage(kind: "watch", created: started, seconds: seconds, narration: cues.map(\.text).joined(separator: " "),
                               frames: notes)
        page.video = "recording.mov"
        page.voice = true
        page.cues = cues
        page.summary = nil
        let written = Digest.write(transcript: transcript, screen: screenText, frames: notes,
                                   context: contextTimeline(started: started), minutes: Int(seconds / 60), into: folder)
        page.digest = written?.body
        page.title = written?.title ?? notes.compactMap(\.context).mostCommon()
        Viewer.write(page, folder: folder)
        Viewer.rebuildLibrary()
        Log.write("watch: \(notes.count) frames, \(cues.count) lines, digest=\(page.digest != nil)")

        DispatchQueue.main.async {
            self.hud.flash("Session saved", hint: page.title ?? "", tone: .done, for: 3)
            self.phase = .over
            self.notify(digest: page.digest, title: page.title, minutes: Int(seconds / 60), frames: notes.count,
                        first: notes.first?.file)
            self.onEnd(self.folder.appendingPathComponent("index.html"))
        }
    }

    /// Words grouped into lines: same speaker, less than 1.5 s apart.
    private func utterances(from words: [SpeechStream.Word], started: Date) -> [SessionPage.Cue] {
        var cues: [SessionPage.Cue] = []
        var current: (speaker: String, start: Double, end: Double, words: [String])?
        for word in words.sorted(by: { $0.start < $1.start }) {
            let at = word.start
            let speaker = word.speaker
            if var open = current, open.speaker == speaker, at - open.end < 1.5 {
                open.end = at + word.duration
                open.words.append(word.text)
                current = open
            } else {
                if let open = current, !open.words.joined().trimmingCharacters(in: .whitespaces).isEmpty {
                    cues.append(SessionPage.Cue(start: open.start, end: open.end, text: open.words.joined(separator: " "), speaker: open.speaker))
                }
                current = (speaker, at, at + word.duration, [word.text])
            }
        }
        if let open = current, !open.words.joined().trimmingCharacters(in: .whitespaces).isEmpty {
            cues.append(SessionPage.Cue(start: open.start, end: open.end, text: open.words.joined(separator: " "), speaker: open.speaker))
        }
        return cues
    }

    private func where_(at moment: Date) -> String? {
        guard let entry = context.last(where: { $0.at <= moment.addingTimeInterval(1) }) ?? context.first else { return nil }
        return entry.window.isEmpty ? entry.app : "\(entry.app) · \(entry.window)"
    }

    private func contextTimeline(started: Date) -> String {
        context.map { "[\(WatchSession.clock($0.at.timeIntervalSince(started)))] \($0.app)\($0.window.isEmpty ? "" : " · \($0.window)")" }
            .joined(separator: "\n")
    }

    /// The headline comes from the write-up: what you may have missed, or else what the session was about.
    private func notify(digest: String?, title: String?, minutes: Int, frames: Int, first: String?) {
        let missed = WatchSession.section("What you may have missed", in: digest)
        let bullets = missed.filter { $0.hasPrefix("-") || $0.hasPrefix("*") }
        let nothing = missed.contains { $0.lowercased().hasPrefix("nothing stood out") }
        let headline: String
        if !bullets.isEmpty, !nothing {
            headline = bullets.count == 1 ? "1 thing you may have missed" : "\(bullets.count) things you may have missed"
        } else {
            headline = title ?? "Watch session ready"
        }
        let lead = bullets.first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-* ")) }
            ?? WatchSession.section("What happened", in: digest).first
            ?? "\(frames) frames from \(minutes) min of watching."
        Notifier.shared.post(title: headline, body: String(lead.prefix(220)),
                             page: folder.appendingPathComponent("index.html"),
                             image: first.map { folder.appendingPathComponent($0) }, hud: hud)
    }

    /// The lines under one `## Heading` of a Markdown write-up.
    static func section(_ heading: String, in markdown: String?) -> [String] {
        guard let markdown else { return [] }
        var inside = false
        var lines: [String] = []
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inside = line.lowercased().contains(heading.lowercased())
                continue
            }
            if inside, !line.isEmpty { lines.append(line) }
        }
        return lines
    }

    /// One frame per 30 s of watching, between 12 and 90.
    static func frameLimit(_ seconds: Double) -> Int {
        min(90, max(12, Int(seconds / 30)))
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600
            ? "\(total / 3600):" + String(format: "%02d:%02d", total % 3600 / 60, total % 60)
            : "\(total / 60):" + String(format: "%02d", total % 60)
    }
}
