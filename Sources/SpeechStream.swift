import AVFoundation
import Speech

/// Live transcription of one audio feed that can run for hours: frames in, timed words out. One per source
/// (your microphone, the Mac's audio), so each word is attributed by where it came from, not by loudness.
final class SpeechStream {
    let speaker: String
    private let analyzer = Analyzer()
    private let queue: DispatchQueue
    private var ready = false
    private var startedAt = Date()
    /// A word and where it was said, in seconds from the start of the session.
    struct Word {
        let text: String
        let start: Double
        let duration: Double
        var speaker = ""
    }
    /// Buffers received and the recognizer's progress, for diagnosing a silent transcript.
    private(set) var received = 0
    private(set) var peakIn: Float = 0
    var stats: String {
        "\(speaker): received=\(received) dropped=\(analyzer.dropped) results=\(analyzer.results) peak=\(String(format: "%.2f", peakIn))"
            + (analyzer.lastError.isEmpty ? "" : " error=\(analyzer.lastError)")
    }

    init(speaker: String) {
        self.speaker = speaker
        queue = DispatchQueue(label: "pointer.speech.\(speaker)")
    }

    /// Starts recognition. Audio fed before it is ready is dropped.
    func start() async {
        do {
            try await analyzer.start()
            queue.sync { ready = true }
        } catch {
            Log.write("speech \(speaker): start failed \(error)")
        }
    }

    var words: [Word] {
        analyzer.words.map { Word(text: $0.text, start: $0.start, duration: $0.duration, speaker: speaker) }
    }

    /// Feed one frame with its position in the session's audio. The buffer is converted before this returns.
    func append(_ frame: AVAudioPCMBuffer, at seconds: Double) {
        received += 1
        peakIn = max(peakIn, SpeechStream.peak(frame))
        analyzer.append(frame, at: seconds)
    }

    /// Ends recognition and waits (up to `wait` seconds) for the final words, then calls back on the main queue.
    func finish(wait: TimeInterval = 4, _ done: @escaping ([Word]) -> Void) {
        Task {
            await analyzer.finish(timeout: wait)
            let words = self.words
            await MainActor.run { done(words) }
        }
    }

    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return -1 }
        var top: Float = 0
        for c in 0..<Int(buffer.format.channelCount) {
            for i in 0..<Int(buffer.frameLength) { top = max(top, abs(channels[c][i])) }
        }
        return top
    }

    static func pcm(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var basic = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &basic) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
