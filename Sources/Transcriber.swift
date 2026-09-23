import AVFoundation
import CoreAudio
import Speech

enum PointerError: Error {
    case noMicrophone
    case speechUnavailable

    var message: String {
        switch self {
        case .noMicrophone: return "No microphone found"
        case .speechUnavailable: return "Speech recognition is unavailable (the speech model may still be downloading)"
        }
    }
}

/// Streams a microphone into on-device speech recognition (SpeechAnalyzer, see Analyzer).
final class Transcriber: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    var onText: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private(set) var text = ""
    /// Last time the transcript changed or the mic heard something loud. Drives auto-send.
    private(set) var lastHeard = Date.distantPast
    /// Word count each time the transcript changed. A fallback for timing when `words` is empty.
    private(set) var history: [(time: Date, words: Int)] = []

    struct Word {
        let text: String
        /// When the word was spoken, from the recognizer's own audio timestamps.
        let at: Date
        let duration: TimeInterval
    }
    /// Every word with the moment it was spoken. Recognition reports words late, so these timestamps, not arrival
    /// times, are what line narration up with video frames and captions.
    var words: [Word] {
        guard let audioStart else { return [] }
        return analyzer.words.map { Word(text: $0.text, at: audioStart.addingTimeInterval($0.start), duration: $0.duration) }
    }
    /// When the first audio buffer reached the recognizer; its timestamps count from here.
    private var audioStart: Date?

    /// When on, Bluetooth headphones are skipped in favour of the Mac's own microphone. Opening a Bluetooth
    /// mic switches the headphones to headset mode, which takes seconds and swallows the first words.
    static var preferBuiltInMic: Bool {
        get { UserDefaults.standard.object(forKey: "preferBuiltInMic") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "preferBuiltInMic") }
    }

    private static let setupQueue = DispatchQueue(label: "pointer.setup")

    /// Loads the speech model and enumerates microphones ahead of the first capture. Both take over a second cold.
    static func warmUp() {
        Task { await Analyzer.prepare() }
        setupQueue.async { _ = microphone() }
    }

    private let audioQueue = DispatchQueue(label: "pointer.audio")
    private let analyzer = Analyzer()
    private var session: AVCaptureSession?
    private var feeding = false // audioQueue only
    private var fedAudio = false // audioQueue only
    private var started = false
    private var waiters: [(String) -> Void] = []
    private var cancelled = false
    private var buffers = 0
    private var peak: Float = 0
    private var micOpened: Date?
    private var firstWords = false

    /// Returns at once. The recognizer and microphone are set up in the background; `ready` runs on the main
    /// queue once audio is flowing, or with the error that stopped it.
    func start(ready: @escaping (Error?) -> Void) {
        let began = Date()
        analyzer.onText = { [weak self] in self?.handle($0) }
        Task {
            let result: Result<AVCaptureSession, Error>
            do {
                async let session = Transcriber.captureSession(delegate: self, queue: audioQueue)
                try await analyzer.start()
                result = .success(try await session)
            } catch {
                Log.write("speech: start failed \(error)")
                result = .failure(error is PointerError ? error : PointerError.speechUnavailable)
            }
            await MainActor.run {
                switch result {
                case .success(let session): self.run(session, began, ready)
                case .failure(let error): ready(error)
                }
            }
        }
    }

    private static func captureSession(delegate: AVCaptureAudioDataOutputSampleBufferDelegate, queue: DispatchQueue) async throws -> AVCaptureSession {
        try await withCheckedThrowingContinuation { done in
            setupQueue.async {
                guard let device = microphone() else { return done.resume(throwing: PointerError.noMicrophone) }
                Log.write("speech: start engine=SpeechAnalyzer mic=\(device.localizedName)")
                let session = AVCaptureSession()
                guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                    return done.resume(throwing: PointerError.noMicrophone)
                }
                session.addInput(input)
                let output = AVCaptureAudioDataOutput()
                // 16 kHz mono float: what speech recognition works in, whatever the mic delivers.
                output.audioSettings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                output.setSampleBufferDelegate(delegate, queue: queue)
                guard session.canAddOutput(output) else { return done.resume(throwing: PointerError.noMicrophone) }
                session.addOutput(output)
                done.resume(returning: session)
            }
        }
    }

    private func run(_ session: AVCaptureSession, _ began: Date, _ ready: @escaping (Error?) -> Void) {
        guard !cancelled else { analyzer.cancel(); return }
        started = true
        self.session = session
        audioQueue.async {
            self.feeding = true
            session.startRunning() // blocks until the device is open
            let ok = session.isRunning
            DispatchQueue.main.async {
                Log.write("speech: mic \(ok ? "open" : "failed") \(String(format: "%.2f", Date().timeIntervalSince(began)))s after the shortcut")
                self.micOpened = Date()
                ready(ok ? nil : PointerError.noMicrophone)
            }
        }
    }

    /// Stops listening and hands back the final transcript.
    func finish(_ done: @escaping (String) -> Void) {
        guard started else {
            cancelled = true // setup still in flight: make sure it never opens the mic
            done(text)
            return
        }
        waiters.append(done)
        stopAudio()
        Task {
            await analyzer.finish(timeout: 2)
            await MainActor.run {
                let final = self.analyzer.text
                if !final.isEmpty { self.text = final }
                self.deliver()
            }
        }
    }

    func cancel() {
        cancelled = true
        waiters.removeAll()
        stopAudio()
        analyzer.cancel()
    }

    // Runs on audioQueue.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard feeding else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let description = sampleBuffer.formatDescription,
                  let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
                                                bufferListNoCopy: list.unsafePointer) else { return }
            analyzer.append(buffer)
        }
        if !fedAudio {
            fedAudio = true
            let now = Date()
            DispatchQueue.main.async { [weak self] in self?.audioStart = now }
        }
        let db = connection.audioChannels.first?.averagePowerLevel ?? -160
        let level = max(0, min(1, (db + 50) / 40)) // -50…-10 dBFS onto 0…1
        DispatchQueue.main.async { [weak self] in self?.heard(level: level) }
    }

    private func handle(_ latest: String) {
        // An empty reading must not wipe what was heard.
        guard !latest.trimmingCharacters(in: .whitespaces).isEmpty, latest != text else { return }
        if !firstWords, let micOpened {
            firstWords = true
            Log.write("speech: first words \(String(format: "%.2f", Date().timeIntervalSince(micOpened)))s after the mic opened")
        }
        text = latest
        lastHeard = Date()
        history.append((Date(), text.split(separator: " ").count))
        onText?(text)
    }

    private func heard(level: Float) {
        buffers += 1
        peak = max(peak, level)
        onLevel?(level)
        if level > 0.5 { lastHeard = Date() }
    }

    private func deliver() {
        guard !waiters.isEmpty else { return }
        let pending = waiters
        waiters.removeAll()
        Log.write("speech: done buffers=\(buffers) peak=\(String(format: "%.2f", peak)) results=\(analyzer.results) dropped=\(analyzer.dropped) chars=\(text.count) timed words=\(words.count)")
        pending.forEach { $0(text) }
    }

    private func stopAudio() {
        let session = self.session
        self.session = nil
        audioQueue.async {
            self.feeding = false
            session?.stopRunning()
        }
        onLevel?(0)
    }

    /// The system default input, or the Mac's built-in mic when the default is Bluetooth and the preference is on.
    static func microphone() -> AVCaptureDevice? {
        let fallback = AVCaptureDevice.default(for: .audio)
        guard preferBuiltInMic, fallback?.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBluetooth) else {
            return fallback
        }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
        return devices.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) } ?? fallback
    }
}
