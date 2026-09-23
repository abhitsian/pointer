import AppKit
import AVFoundation
import Speech

/// `Pointer --self-test <out.txt>`: recognizes a synthesized file, then records a screen area with `screencapture`
/// while `say` speaks through the Mac's speakers, and builds the same text a video capture would paste.
final class SelfTest: NSObject, NSApplicationDelegate {
    private let out: URL
    private var lines: [String] = []
    private var recognizer: SFSpeechRecognizer?
    private var fileTask: SFSpeechRecognitionTask?
    private var transcriber: Transcriber?
    private let recorder = ScreenRecorder()
    private var videoStarted = false
    private var sayStarted = Date()

    init(out: String) { self.out = URL(fileURLWithPath: out) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("window") { return windowTest() }
        if CommandLine.arguments.contains("audio") { return audioTest() }
        note("speech auth=\(SFSpeechRecognizer.authorizationStatus().rawValue) mic auth=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 means allowed)")
        note("locale=\(Locale.current.identifier) default input=\(AVCaptureDevice.default(for: .audio)?.localizedName ?? "none")")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pointer-selftest.aiff")
        run("/usr/bin/say", ["-o", file.path, "The save button is hidden behind the footer [[slnc 1500]]"], wait: true)
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) else {
            note("file: no recognizer")
            videoTest()
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: file)
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        fileTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.note("file: error \(error.localizedDescription)")
                    self.videoTest()
                } else if let result, result.isFinal {
                    self.note("file: \"\(result.bestTranscription.formattedString)\"")
                    self.videoTest()
                }
            }
        }
    }

    private func videoTest() {
        guard !videoStarted else { return }
        videoStarted = true
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pointer-selftest-video", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("recording.mov")

        let transcriber = Transcriber()
        self.transcriber = transcriber
        let shortcut = Date()
        transcriber.start { [weak self] error in
            guard let self else { return }
            self.note("mic: \(Transcriber.microphone()?.localizedName ?? "none") \(error.map { "failed \($0)" } ?? "open") after \(String(format: "%.2f", Date().timeIntervalSince(shortcut)))s")
            // The top-left 800×500 of the main screen, in Cocoa coordinates.
            let main = NSScreen.screens[0].frame
            let rect = CGRect(x: main.minX, y: main.maxY - 500, width: 800, height: 500)
            let requested = Date()
            let voice = !CommandLine.arguments.contains("novoice")
            self.note("voice in video: \(voice)")
            self.recorder.start(rect: rect, to: video, voice: voice) { error in
                self.note("recorder: \(error.map { "failed \($0)" } ?? "started") after \(String(format: "%.2f", Date().timeIntervalSince(requested)))s")
                let started = Date()
                self.sayStarted = Date()
                var loudAt: Date?
                transcriber.onLevel = { level in
                    if loudAt == nil, level > 0.3 {
                        loudAt = Date()
                        self.note("mic first hears sound \(String(format: "%.2f", loudAt!.timeIntervalSince(self.sayStarted)))s after say started")
                    }
                }
                // Speak through the Mac's speakers so the built-in mic hears it even with headphones on.
                self.run("/usr/bin/say", ["-a", "MacBook Air Speakers", "The login page shows a blank screen after I sign in"], wait: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    let seconds = Date().timeIntervalSince(started)
                    let stopped = Date()
                    self.recorder.stop { error in
                        self.note("video: stop took \(String(format: "%.2f", Date().timeIntervalSince(stopped)))s error=\(String(describing: error)) file=\(FileManager.default.fileExists(atPath: video.path))")
                        transcriber.finish { text in
                            let timed = transcriber.words.prefix(12).map { "\($0.text)@\(String(format: "%.2f", $0.at.timeIntervalSince(self.sayStarted)))" }
                            self.note("word timings from say start: \(timed.joined(separator: " "))")
                            let frames = KeyFrames.extract(from: video, into: folder, maxFrames: 6)
                            self.note("frames: \(frames.count)")
                            self.note("audio tracks: \(AVURLAsset(url: video).tracks(withMediaType: .audio).count)")
                            let spoken: [Captions.Spoken] = transcriber.words.isEmpty
                                ? Captions.estimated(narration: text, history: transcriber.history, started: started, duration: seconds, lag: 0.8)
                                : transcriber.words.map { ($0.text, $0.at.timeIntervalSince(started)) }
                            let cues = Captions.cues(spoken, duration: seconds)
                            self.note("captions:\n" + Captions.srt(cues))
                            let screenText = frames.map { ScreenText.lines(at: $0.url) }
                            self.note("text read from frame 1: \(screenText.first?.count ?? 0) lines, e.g. \(screenText.first?.prefix(3).map(\.text) ?? [])")
                            let notes = VideoSession.notes(frames: frames, screenText: screenText, spoken: spoken, clicks: [], started: started)
                            self.note("paste:\n" + VideoSession.summary(notes: notes, lateClicks: [], seconds: seconds, video: video,
                                                                        captions: nil, voice: true))
                            self.finish()
                        }
                    }
                }
            }
        }
    }

    /// Records the front window for 4 s and reads it the way document mode does.
    private func windowTest() {
        guard let window = ScreenRecorder.frontWindow() else { note("window: none"); return finish() }
        note("window: \(window.app) \"\(window.title)\"")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pointer-selftest-window", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("recording.mov")
        recorder.start(window: window.id, to: video, voice: false) { error in
            self.note("recorder: \(error.map { "failed \($0)" } ?? "started")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                self.recorder.stop { _ in
                    let document = KeyFrames.pages(from: video, into: folder)
                    let size = document.pages.first.flatMap { NSImage(contentsOf: $0.url)?.representations.first }
                    self.note("pages: \(document.pages.count), first page \(size?.pixelsWide ?? 0)x\(size?.pixelsHigh ?? 0) px, lines read: \(document.text.count)")
                    self.note("first lines: \(document.text.prefix(4))")
                    self.finish()
                }
            }
        }
    }

    /// Records the main screen at 1 fps with the Mac's audio and the mic, transcribing both live while `say` speaks.
    private func audioTest() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pointer-selftest-audio", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let video = folder.appendingPathComponent("recording.mov")
        let speech = SpeechStream(speaker: "mixed")
        Task { await speech.start() }
        let mixer = AudioMixer(mic: true, system: true)
        mixer.onFrame = { frame, at in speech.append(frame, at: at) }
        var buffers = (mic: 0, system: 0)
        var options = ScreenRecorder.Options(voice: true, systemAudio: true, ownAudio: true, framesPerSecond: 1, scale: 1)
        var phasePeak: [String: Float] = [:]
        var phase = "quiet"
        options.onAudio = { sample, isMic in
            if isMic { buffers.mic += 1; mixer.add(sample, mic: true); return }
            buffers.system += 1
            mixer.add(sample, mic: false)
            var peak: Float = 0
            try? sample.withAudioBufferList { list, _ in
                guard let asbd = sample.formatDescription?.audioStreamBasicDescription,
                      let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
                peak = SpeechStream.peak(buffer)
            }
            phasePeak[phase] = max(phasePeak[phase] ?? 0, peak)
        }
        let started = Date()
        recorder.start(rect: NSScreen.screens[0].frame, to: video, options: options) { error in
            self.note("recorder: \(error.map { "failed \($0)" } ?? "started") after \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            let clip = FileManager.default.temporaryDirectory.appendingPathComponent("pointer-clip.aiff")
            self.run("/usr/bin/say", ["-o", clip.path, "Leo said the launch memo is due on Friday, and Maya owns the pricing deck."], wait: true)
            phase = "say"
            self.run("/usr/bin/say", ["Leo said the launch memo is due on Friday."], wait: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                phase = "nssound"
                NSSound(contentsOf: clip, byReference: false)?.play()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                phase = "afplay"
                self.run("/usr/bin/afplay", [clip.path], wait: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 16) {
                self.note("system audio peaks by source: \(phasePeak.mapValues { String(format: "%.3f", $0) })")
                self.recorder.stop { _ in
                    let asset = AVURLAsset(url: video)
                    self.note("buffers: mic \(buffers.mic), system \(buffers.system); file audio tracks \(asset.tracks(withMediaType: .audio).count), video \(asset.tracks(withMediaType: .video).first.map { "\(Int($0.naturalSize.width))x\(Int($0.naturalSize.height))" } ?? "none"), size \(((try? FileManager.default.attributesOfItem(atPath: video.path)[.size]) as? Int ?? 0) / 1024) KB")
                    self.note("speech stats: \(speech.stats)")
                    speech.finish { words in
                        self.note("transcript: " + words.map { "[\(mixer.speaker(at: $0.start, duration: $0.duration))] \($0.text)@\(String(format: "%.1f", $0.start))" }.joined(separator: " "))
                        self.finish()
                    }
                }
            }
        }
    }

    private func note(_ line: String) {
        lines.append(line)
    }

    private func finish() {
        try? (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }

    private func run(_ path: String, _ arguments: [String], wait: Bool) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
        if wait { process.waitUntilExit() }
    }
}
