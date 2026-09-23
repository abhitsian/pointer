import AVFoundation

/// Lines the microphone and the Mac's own audio up on one 16 kHz timeline in 20 ms frames. Each side goes to its
/// own recognizer (onSource); the mixed frame (onFrame) and per-frame loudness are kept for diagnostics.
final class AudioMixer {
    /// Emitted frames, mixed and ready for recognition, with their position in the session's audio (seconds).
    var onFrame: ((AVAudioPCMBuffer, Double) -> Void)?
    /// Each side's frame on its own (mic true for yours), on the same timeline, for per-speaker recognition.
    var onSource: ((AVAudioPCMBuffer, Double, Bool) -> Void)?

    private let queue = DispatchQueue(label: "pointer.mixer")
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let frame = 320 // 20 ms at 16 kHz
    private let sources: (mic: Bool, system: Bool)

    private var pending: [[Float]] = [[], []]
    private var converters: [AVAudioConverter?] = [nil, nil]
    private var inputs: [AVAudioFormat?] = [nil, nil]
    private var levels: [(at: Double, you: Float, others: Float)] = []
    private var emitted = 0

    /// Frames emitted, and how loud each side ever got, for the log.
    var summary: String {
        queue.sync {
            let you = levels.map(\.you).max() ?? 0, others = levels.map(\.others).max() ?? 0
            return "frames=\(emitted) peakYou=\(String(format: "%.2f", you)) peakOthers=\(String(format: "%.2f", others))"
        }
    }

    init(mic: Bool, system: Bool) {
        sources = (mic, system)
    }

    /// Call from the recorder's audio queue.
    func add(_ sample: CMSampleBuffer, mic: Bool) {
        let slot = mic ? 0 : 1
        var samples: [Float] = []
        try? sample.withAudioBufferList { list, _ in
            guard let asbd = sample.formatDescription?.audioStreamBasicDescription,
                  let source = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: asbd.mChannelsPerFrame),
                  let buffer = AVAudioPCMBuffer(pcmFormat: source, bufferListNoCopy: list.unsafePointer),
                  let mono = convert(buffer, slot: slot), let channel = mono.floatChannelData?[0] else { return }
            samples = Array(UnsafeBufferPointer(start: channel, count: Int(mono.frameLength)))
        }
        guard !samples.isEmpty else { return }
        queue.async {
            self.pending[slot] += samples
            self.drain()
        }
    }

    /// Which side was talking around a moment in the session's audio: "You" or "Others".
    func speaker(at start: Double, duration: TimeInterval) -> String {
        queue.sync {
            let end = start + max(duration, 0.25)
            let window = levels.filter { $0.at >= start - 0.1 && $0.at <= end }
            let you = window.reduce(0) { $0 + $1.you }
            let others = window.reduce(0) { $0 + $1.others }
            return you >= others ? "You" : "Others"
        }
    }

    // Runs on `queue`.
    private func drain() {
        // One source running ahead is normal; only wait for the other while it is roughly in step. Waiting
        // longer than a second would mean dropping audio.
        let waitFor = { (slot: Int) -> Bool in
            let enabled = slot == 0 ? self.sources.mic : self.sources.system
            return enabled && self.pending[slot].count < self.frame && self.pending[1 - slot].count < 16_000
        }
        while !waitFor(0) && !waitFor(1), pending[0].count >= frame || pending[1].count >= frame {
            var mixed = [Float](repeating: 0, count: frame)
            var loudness: [Float] = [0, 0]
            let at = Double(emitted) * Double(frame) / format.sampleRate
            for slot in 0...1 where pending[slot].count >= frame {
                let chunk = Array(pending[slot].prefix(frame))
                pending[slot].removeFirst(frame)
                var peak: Float = 0
                for (i, sample) in chunk.enumerated() {
                    mixed[i] += sample
                    peak = max(peak, abs(sample))
                }
                loudness[slot] = peak
                if let onSource, let own = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame)),
                   let channel = own.floatChannelData?[0] {
                    own.frameLength = AVAudioFrameCount(frame)
                    for i in 0..<frame { channel[i] = chunk[i] }
                    onSource(own, at, slot == 0)
                }
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame)),
                  let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = AVAudioFrameCount(frame)
            for i in 0..<frame { channel[i] = max(-1, min(1, mixed[i])) }
            emitted += 1
            levels.append((at, loudness[0], loudness[1]))
            onFrame?(buffer, at)
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, slot: Int) -> AVAudioPCMBuffer? {
        if inputs[slot] != buffer.format {
            converters[slot] = AVAudioConverter(from: buffer.format, to: format)
            inputs[slot] = buffer.format
        }
        guard let converter = converters[slot] else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}
