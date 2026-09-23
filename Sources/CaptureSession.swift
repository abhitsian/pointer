import AppKit
import Carbon

struct CaptureRecord {
    let parts: [Part]
    /// The .mov for video and document captures.
    var video: URL? = nil
}

/// A capture in progress. The shortcut sends it early (screenshot) or stops it (video).
protocol ActiveCapture: AnyObject {
    func shortcutPressed()
    func cancel()
}

/// One press of the shortcut: listen, let the user drag a region, wait out the pause, paste.
final class CaptureSession: ActiveCapture {
    private enum Phase { case selecting, selected, sending, over }

    private let target: Target
    private let hud: HUDController
    private let autoSend: Bool
    private let imageURL: URL
    private let onEnd: (CaptureRecord?) -> Void

    private let transcriber = Transcriber()
    private var phase = Phase.selecting
    private var micOn = false
    private var selectedAt = Date()
    private var screencapture: Process?
    private var ticker: Timer?
    private var keys: [HotKey] = []

    /// Pause length that ends a capture once the region is chosen.
    private let pauseAfterSpeech: TimeInterval = 1.8
    private let pauseBeforeSpeech: TimeInterval = 3.0

    init(target: Target, hud: HUDController, autoSend: Bool, folder: URL, onEnd: @escaping (CaptureRecord?) -> Void) {
        self.target = target
        self.hud = hud
        self.autoSend = autoSend
        self.onEnd = onEnd
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        imageURL = folder.appendingPathComponent("\(stamp.string(from: Date())).png")
    }

    func start() {
        Log.write("capture: start target=\(target.app.bundleIdentifier ?? "?") style=\(target.style)")
        hud.model.reset()
        hud.model.hint = "esc cancels"
        transcriber.onText = { [weak self] in self?.hud.model.transcript = $0 }
        transcriber.onLevel = { [weak self] in self?.hud.model.level = $0 }
        transcriber.start { [weak self] error in self?.micReady(error) }
        micOn = true
        hud.model.status = "Opening mic · drag over the problem"
        hud.show()
        selectRegion()
    }

    private func micReady(_ error: Error?) {
        guard phase == .selecting || phase == .selected else { return }
        if let error {
            Log.write("capture: mic failed \(error)")
            micOn = false
            hud.model.status = "\((error as? PointerError)?.message ?? "Mic unavailable") · screenshot only"
            hud.model.placeholder = "Drag over the problem"
            if phase == .selected { finish() }
            return
        }
        hud.model.listening = true
        if phase == .selecting { hud.model.status = "Listening · drag over the problem" }
    }

    /// The shortcut again, or Return: send now.
    func shortcutPressed() {
        if phase == .selected { finish() }
    }

    func cancel() {
        guard phase == .selecting || phase == .selected else { return }
        phase = .over
        if let screencapture, screencapture.isRunning { screencapture.terminate() }
        stopWaiting()
        transcriber.cancel()
        try? FileManager.default.removeItem(at: imageURL)
        hud.model.listening = false
        hud.model.status = "Cancelled"
        hud.model.hint = ""
        hud.hide(after: 0.5)
        onEnd(nil)
    }

    private func selectRegion() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: drag a region (Space switches to picking a window), -x: no shutter sound.
        process.arguments = ["-i", "-x", imageURL.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.regionChosen() }
        }
        do {
            try process.run()
            screencapture = process
        } catch {
            transcriber.cancel()
            phase = .over
            hud.flash("Couldn't start screen selection")
            onEnd(nil)
        }
    }

    private func regionChosen() {
        guard phase == .selecting else { return }
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            Log.write("capture: selection cancelled")
            cancel()
            return
        }
        Log.write("capture: region chosen")
        phase = .selected
        selectedAt = Date()
        guard micOn else { finish(); return }

        hud.model.status = "Got the shot · keep talking"
        hud.model.hint = "⏎ send   esc cancel"
        keys = [
            HotKey(keyCode: HotKey.keyReturn, modifiers: 0) { [weak self] in self?.finish() },
            HotKey(keyCode: HotKey.keyEscape, modifiers: 0) { [weak self] in self?.cancel() },
        ]
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.watchForPause() }
    }

    /// Sends once the user stops talking. Waits longer if nothing has been said yet.
    private func watchForPause() {
        let spoke = !transcriber.text.isEmpty
        let window = spoke ? pauseAfterSpeech : pauseBeforeSpeech
        let quiet = Date().timeIntervalSince(max(transcriber.lastHeard, selectedAt))
        hud.model.countdown = quiet < 0.4 ? nil : min(1, quiet / window)
        if quiet >= window { finish() }
    }

    private func finish() {
        guard phase == .selected else { return }
        phase = .sending
        stopWaiting()
        hud.model.listening = false
        hud.model.countdown = nil
        hud.model.hint = ""
        hud.model.status = "Sending to \(target.name)"
        transcriber.finish { [weak self] raw in self?.deliver(CaptureSession.tidy(raw)) }
    }

    private func deliver(_ text: String) {
        Log.write("capture: delivering \(text.count) chars to \(target.name)")
        hud.model.transcript = text
        if text.isEmpty { hud.model.placeholder = "Screenshot only" }
        if !text.isEmpty {
            try? text.write(to: imageURL.deletingPathExtension().appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        }
        // Text first: an app that is still attaching the image can't drop text pasted after it.
        let parts: [Part] = text.isEmpty ? [.image(imageURL)] : [.text(text + " "), .image(imageURL)]
        let record = CaptureRecord(parts: parts)
        var page = SessionPage(kind: "screenshot", created: selectedAt, target: target.name, narration: text,
                               frames: [SessionPage.Frame(file: imageURL.lastPathComponent, time: 0)])
        page.title = Viewer.label(for: page)
        let image = imageURL
        DispatchQueue.global(qos: .utility).async {
            Viewer.write(page, screenshot: image)
            ScreenTranscript.write(screenshot: image)
            Viewer.rebuildLibrary()
        }
        Deliverer.deliver(parts, to: target, autoSend: autoSend) { [weak self] result in
            guard let self else { return }
            self.phase = .over
            switch result {
            case .success:
                self.hud.model.tone = .done
                self.hud.model.status = self.autoSend ? "Sent to \(self.target.name)" : "Pasted into \(self.target.name)"
                self.hud.hide(after: 1.4)
            case .failure(let error):
                Log.write("capture: delivery failed \(error.message)")
                self.hud.model.tone = .error
                self.hud.model.status = error.message
                self.hud.hide(after: 4)
            }
            self.onEnd(record)
        }
    }

    private func stopWaiting() {
        ticker?.invalidate()
        ticker = nil
        keys.forEach { $0.unregister() }
        keys = []
    }

    private static func tidy(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return "" }
        return first.uppercased() + text.dropFirst()
    }
}
