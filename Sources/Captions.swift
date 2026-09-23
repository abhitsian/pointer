import Foundation

/// Caption files for a recording, timed from when each word first showed up in the live transcript.
enum Captions {
    struct Cue {
        let start: Double
        let end: Double
        let text: String
    }

    /// A spoken word and when it started, in seconds from the start of the recording.
    typealias Spoken = (text: String, start: Double)

    /// Words timed by when they first showed up in the live transcript, less the recognizer's usual delay.
    /// Used only when the recognizer gives no word timestamps.
    static func estimated(narration: String, history: [(time: Date, words: Int)], started: Date,
                          duration: Double, lag: Double) -> [Spoken] {
        let words = narration.split(separator: " ").map(String.init)
        var heard = [Double](repeating: duration, count: words.count)
        var next = 0
        for entry in history where next < words.count {
            let at = entry.time.timeIntervalSince(started) - lag
            while next < min(entry.words, words.count) {
                heard[next] = at
                next += 1
            }
        }
        return zip(words, heard).map { ($0, $1) }
    }

    /// Groups words into cues of at most 8 words or 3.5 seconds. Each cue runs until the next starts
    /// (at least 1 s, at most 4 s).
    static func cues(_ spoken: [Spoken], duration: Double) -> [Cue] {
        var groups: [(from: Double, text: String)] = []
        var start = 0
        while start < spoken.count {
            var end = start + 1
            while end < spoken.count, end - start < 8, spoken[end].start - spoken[start].start < 3.5 { end += 1 }
            groups.append((min(max(0, spoken[start].start), duration), spoken[start..<end].map(\.text).joined(separator: " ")))
            start = end
        }
        return groups.enumerated().map { i, group in
            let natural = group.from + min(4, max(1, (i + 1 < groups.count ? groups[i + 1].from : group.from + 2.5) - group.from))
            let end = i + 1 < groups.count ? max(group.from + 0.3, min(natural, groups[i + 1].from))
                                           : min(natural, max(duration, group.from + 1))
            return Cue(start: group.from, end: end, text: group.text)
        }
    }

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, cue in
            "\(i + 1)\n\(stamp(cue.start, comma: true)) --> \(stamp(cue.end, comma: true))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { "\(stamp($0.start, comma: false)) --> \(stamp($0.end, comma: false))\n\($0.text)\n" }
            .joined(separator: "\n")
    }

    private static func stamp(_ seconds: Double, comma: Bool) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, comma ? "," : ".", ms % 1000)
    }
}
