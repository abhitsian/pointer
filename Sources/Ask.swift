import Foundation

/// Transcript lines short enough to jump to. Recognition groups words into one line until the speaker pauses,
/// so a talk with no pauses becomes a single line many minutes long. Long lines are cut at sentence ends, and
/// each sentence's start is placed by its position in the line's text.
enum Cues {
    /// Lines longer than this are split.
    static let longest: Double = 15

    static func fine(_ cues: [SessionPage.Cue]) -> [SessionPage.Cue] {
        cues.flatMap { cue -> [SessionPage.Cue] in
            let span = cue.end - cue.start
            guard span > longest else { return [cue] }
            let text = cue.text
            let total = Double(max(1, text.count))
            // Sentences with their character offsets, merged until each holds at least 4 s or 60 characters.
            var pieces: [(offset: Int, text: String)] = []
            var start = text.startIndex, offset = 0
            for match in text.matches(of: #/[.?!]+["')\]]*\s+/#) {
                let piece = String(text[start..<match.range.upperBound])
                pieces.append((offset, piece))
                offset += piece.count
                start = match.range.upperBound
            }
            if start < text.endIndex { pieces.append((offset, String(text[start...]))) }
            var merged: [(offset: Int, text: String)] = []
            for piece in pieces {
                if var last = merged.last,
                   last.text.count < 60 || Double(piece.offset - last.offset) / total * span < 4 {
                    last.text += piece.text
                    merged[merged.count - 1] = last
                } else {
                    merged.append(piece)
                }
            }
            guard merged.count > 1 else { return [cue] }
            return merged.enumerated().map { i, piece in
                let from = cue.start + Double(piece.offset) / total * span
                let to = i + 1 < merged.count ? cue.start + Double(merged[i + 1].offset) / total * span : cue.end
                return SessionPage.Cue(start: from, end: to, text: piece.text.trimmingCharacters(in: .whitespaces),
                                       speaker: cue.speaker)
            }
        }
    }
}

/// Answers a question about one session from its page, using the session's notes, transcript and screen text.
enum Ask {
    struct Turn: Codable {
        var question: String
        var answer: String
    }

    /// Runs the question through `claude` and saves it with the session. Slow (tens of seconds): call off the main thread.
    static func answer(_ question: String, history: [Turn], folder: URL) -> String? {
        let json = folder.appendingPathComponent("session.json")
        guard var page = Viewer.load(json) else { return nil }
        let clock = WatchSession.clock
        let created = page.created.formatted(date: .abbreviated, time: .shortened)
        let length = page.seconds.map { " (\(clock($0)) long)" } ?? ""

        let said = Cues.fine(page.cues)
            .map { "[\(clock($0.start))] \($0.speaker.map { "\($0): " } ?? "")\($0.text)" }
            .joined(separator: "\n")
        let screen = page.frames
            .filter { $0.context != nil || !$0.appeared.isEmpty }
            .map { "[\(clock($0.time))] \($0.context ?? "")\($0.appeared.isEmpty ? "" : "\n    " + $0.appeared.prefix(12).joined(separator: "\n    "))" }
            .joined(separator: "\n")
        let earlier = history.suffix(6).map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n")

        let prompt = """
        Answer a question about one recorded session: a Pointer \(page.kind) session titled "\(page.title ?? "untitled")", \
        recorded \(created)\(length).

        Use only the material below. Lead with the answer. After each claim, cite the moment it comes from as a \
        timestamp in square brackets exactly as the transcript writes it, for example [12:34] or [1:02:05], so the \
        reader can jump the video there. When the question asks where or when something was said, give the \
        timestamps of every place it comes up. Quote short phrases from the transcript where the wording matters. \
        If the material does not hold the answer, say so in one line. The transcript is on-device speech \
        recognition, so treat odd words as misheard. "You" is the person who recorded the session; "Others" is \
        everyone else. Plain factual sentences, short paragraphs or a short list, no em dashes, no preamble.

        \(earlier.isEmpty ? "" : "## Earlier in this conversation\n\(earlier)\n")
        ## Notes written after the session
        \(page.digest ?? page.summary ?? "(none)")

        ## Transcript
        \(said.isEmpty ? page.narration : said)

        ## On screen at key frames
        \(cap(screen, 60_000))

        ## Question
        \(question)
        """
        guard let reply = Digest.run(prompt), !reply.isEmpty else { return nil }
        page.asks = (page.asks ?? []) + [SessionPage.Ask(at: Date(), question: question, answer: reply)]
        Viewer.write(page, folder: folder)
        Log.write("ask: \(folder.lastPathComponent) \(question.count) chars in, \(reply.count) out")
        return reply
    }

    private static func cap(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "\n… (trimmed)"
    }
}
