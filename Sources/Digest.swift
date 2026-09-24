import Foundation

/// Turns a watch session into a short write-up by running the `claude` command line on what was captured.
enum Digest {
    static func write(transcript: String, screen: [[ScreenText.Line]], frames: [SessionPage.Frame],
                      context: String, minutes: Int, questions: [SessionPage.Question]? = nil,
                      into folder: URL) -> (title: String, body: String)? {
        let onScreen = frames.enumerated().compactMap { i, frame -> String? in
            let new = frame.appeared.prefix(10).joined(separator: " | ")
            guard !new.isEmpty || frame.context != nil else { return nil }
            return "[\(WatchSession.clock(frame.time))] \(frame.context ?? "")\(new.isEmpty ? "" : " — new on screen: \(new)")"
        }.joined(separator: "\n")

        let prompt = """
        You are reviewing \(minutes) minutes of someone's workday that their Mac recorded, so they can catch what they \
        missed. Three sources follow. "You" in the transcript is the person; "Others" is audio playing on their Mac, \
        usually a meeting or a video.

        <transcript>
        \(cap(transcript, 60_000))
        </transcript>

        <apps>
        \(cap(context, 6_000))
        </apps>

        <on-screen>
        \(cap(onScreen, 24_000))
        </on-screen>

        Write Markdown. Start with a single line: "# " followed by a four to eight word title naming what this \
        session was about (the document, the meeting, the task). Then exactly these sections, in this order:

        ## What happened
        Two to four sentences.

        ## What you may have missed
        Asks aimed at the person, decisions, dates, numbers, names, commitments. Each bullet starts with a [m:ss] \
        timestamp. Write "Nothing stood out." if there is nothing.

        ## Follow-ups
        Things the person said they would do or check, each with a [m:ss] timestamp. Leave the section out if there are none.

        ## Key moments
        Up to eight bullets, each starting with a [m:ss] timestamp.
        \(questions.map { asked in """

        ## Questions that came up
        The person was listening to learn and wants questions to take away. Up to ten bullets, each starting with \
        a [m:ss] timestamp: questions to ask the presenter or their team afterwards, things that were skipped or \
        left unclear, and claims to check. Keep the useful ones from this list, suggested live while they \
        listened, and add any the material raises that it missed:
        \(asked.map { "[\(WatchSession.clock($0.time))] \($0.text)" }.joined(separator: "\n"))

        ## To look up
        Terms, products or references that went unexplained, one line each. Leave the section out if there are none.
        """ } ?? "")

        Rules: only state what is in the material, quoting short exact phrases where it helps. Speech recognition \
        makes mistakes, so treat odd words as misheard rather than inventing meaning. Plain factual sentences, no em \
        dashes, no filler, no praise, no advice.
        """

        guard let text = run(prompt), text.count > 40 else { return nil }
        try? text.write(to: folder.appendingPathComponent("digest.md"), atomically: true, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        var title = ""
        if let first = lines.first, first.hasPrefix("# ") {
            title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }
        return (title, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Runs a prompt through the `claude` command line (the user's own login) and returns the reply.
    static func run(_ prompt: String, model: String = "sonnet") -> String? {
        guard let claude = path() else {
            Log.write("digest: claude command not found")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = ["-p", "--model", model]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = environment

        do {
            try process.run()
            input.fileHandleForWriting.write(Data(prompt.utf8))
            input.fileHandleForWriting.closeFile()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus == 0 else {
                Log.write("digest: claude exited \(process.terminationStatus), \(text.count) chars")
                return nil
            }
            return text
        } catch {
            Log.write("digest: \(error)")
            return nil
        }
    }

    private static func path() -> String? {
        let candidates = ["\(NSHomeDirectory())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func cap(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "\n… (trimmed)"
    }
}
