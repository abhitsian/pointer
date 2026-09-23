import AVFoundation
import Speech

/// On-device speech recognition with SpeechAnalyzer (macOS 26), the engine Cuecard uses. Several run at once, so
/// the microphone and the Mac's audio each get their own and every word knows who said it. Audio goes in with
/// its position on the capture's timeline; timed words come out.
final class Analyzer {
    struct Word {
        let text: String
        /// Seconds from the start of the capture's audio.
        let start: Double
        let duration: Double
    }

    /// Finalized text plus the current guess, on the main queue whenever it changes.
    var onText: ((String) -> Void)?

    private let lock = NSLock()
    private var finalText = ""
    private var volatileText = ""
    private var finalWords: [Word] = []
    private var volatileWords: [Word] = []
    private(set) var results = 0
    private(set) var lastError = ""

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let feedLock = NSLock()
    private(set) var dropped = 0
    /// Where the next buffer may start on the analyzer's timeline, in samples.
    private var nextSample: Int64 = 0

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return Analyzer.join(finalText, volatileText)
    }

    var words: [Word] {
        lock.lock(); defer { lock.unlock() }
        return finalWords + volatileWords
    }

    // MARK: Setup

    private static var cachedLocale: Locale?

    static func locale() async -> Locale {
        if let cachedLocale { return cachedLocale }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
        cachedLocale = locale
        return locale
    }

    private static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
                          attributeOptions: [.audioTimeRange])
    }

    /// Resolves the language and downloads its speech model if the Mac doesn't have it yet. Call at launch so the
    /// first capture doesn't wait on it.
    @discardableResult
    static func prepare() async -> Bool {
        let locale = await locale()
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module(locale)]) {
                Log.write("speech: downloading the model for \(locale.identifier)")
                try await request.downloadAndInstall()
            }
            return true
        } catch {
            Log.write("speech assets: \(error)")
            return false
        }
    }

    /// Starts the analyzer. Audio appended before this finishes is dropped, so await it before opening a mic.
    func start() async throws {
        let locale = await Analyzer.locale()
        let transcriber = Analyzer.module(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results { self?.take(result) }
            } catch {
                self?.lock.withLock { self?.lastError = "\(error)" }
                Log.write("speech: results ended \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)
        feedLock.withLock {
            self.format = format
            self.continuation = continuation
        }
        self.analyzer = analyzer
    }

    // MARK: Audio

    /// Call from one audio thread. Converts synchronously, since the buffer may not outlive the call.
    /// `at` places the buffer on the capture's timeline; nil means it follows straight on from the last one.
    func append(_ buffer: AVAudioPCMBuffer, at seconds: Double? = nil) {
        feedLock.lock(); defer { feedLock.unlock() }
        guard let format, let continuation else { dropped += 1; return }
        if inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            inputFormat = buffer.format
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return }
        // Resampling in chunks can make a buffer run a few samples past where the next one starts, and the
        // analyzer rejects audio that overlaps what it already has: never start before the last buffer ended.
        let requested = seconds.map { Int64(($0 * format.sampleRate).rounded()) } ?? nextSample
        let start = max(requested, nextSample)
        nextSample = start + Int64(output.frameLength)
        continuation.yield(AnalyzerInput(buffer: output, bufferStartTime: CMTime(value: start, timescale: CMTimeScale(format.sampleRate))))
    }

    /// Ends the audio and waits for the last words (at most `timeout` seconds).
    func finish(timeout: TimeInterval = 3) async {
        let continuation = feedLock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.finish()
        guard let analyzer else { return }
        self.analyzer = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do { try await analyzer.finalizeAndFinishThroughEndOfInput() } catch { Log.write("speech finish: \(error)") }
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
        // Whatever was still a guess at the end is the best reading there is.
        lock.withLock {
            finalText = Analyzer.join(finalText, volatileText)
            finalWords += volatileWords
            volatileText = ""
            volatileWords = []
        }
    }

    func cancel() {
        feedLock.lock()
        continuation?.finish()
        continuation = nil
        feedLock.unlock()
        let analyzer = self.analyzer
        self.analyzer = nil
        resultsTask?.cancel()
        Task { await analyzer?.cancelAndFinishNow() }
    }

    // MARK: Results

    private func take(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        var words: [Word] = []
        for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let piece = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            words.append(Word(text: piece, start: range.start.seconds, duration: range.duration.seconds))
        }
        lock.lock()
        results += 1
        if result.isFinal {
            finalText = Analyzer.join(finalText, text)
            finalWords += words
            volatileText = ""
            volatileWords = []
        } else {
            volatileText = text
            volatileWords = words
        }
        let current = Analyzer.join(finalText, volatileText)
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onText?(current) }
    }

    static func join(_ a: String, _ b: String) -> String {
        [a, b].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
