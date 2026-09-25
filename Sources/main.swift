import AVFoundation
import AppKit

let arguments = CommandLine.arguments
if let flag = arguments.firstIndex(of: "--render-hud"), flag + 1 < arguments.count {
    MainActor.assumeIsolated { HUDPreview.render(to: arguments[flag + 1]) }
    exit(0)
}

if let flag = arguments.firstIndex(of: "--keyframes"), flag + 2 < arguments.count {
    let frames = KeyFrames.extract(from: URL(fileURLWithPath: arguments[flag + 1]),
                                   into: URL(fileURLWithPath: arguments[flag + 2]), maxFrames: 12)
    var previous: [ScreenText.Line] = []
    for frame in frames {
        let lines = ScreenText.lines(at: frame.url)
        let change = ScreenText.changes(from: previous, to: lines)
        print(String(format: "%.2f", frame.time), frame.url.lastPathComponent, "new text:", change.appeared.prefix(4))
        previous = lines
    }
    exit(0)
}
if let flag = arguments.firstIndex(of: "--document-pages"), flag + 2 < arguments.count {
    let document = KeyFrames.pages(from: URL(fileURLWithPath: arguments[flag + 1]), into: URL(fileURLWithPath: arguments[flag + 2]))
    document.pages.forEach { print(String(format: "%.2f", $0.time), $0.url.lastPathComponent) }
    print("lines: \(document.text.count)")
    print(document.text.joined(separator: "\n"))
    exit(0)
}
if let flag = arguments.firstIndex(of: "--transcribe"), flag + 1 < arguments.count {
    // Runs an audio file through the speech engine in 20 ms frames on its own timeline, and prints timed words.
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        let analyzer = Analyzer()
        await Analyzer.prepare()
        try await analyzer.start()
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: arguments[flag + 1]))
        let frame = AVAudioFrameCount(file.processingFormat.sampleRate / 50)
        var position = 0.0
        // --restart-at <sec> swaps in a fresh analyzer partway through, as the stall check would.
        let restartAt = arguments.firstIndex(of: "--restart-at").flatMap { Double(arguments[$0 + 1]) }
        var restarted = false
        while let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frame),
              (try? file.read(into: buffer, frameCount: frame)) != nil, buffer.frameLength > 0 {
            if let restartAt, !restarted, position >= restartAt {
                restarted = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await analyzer.restart()
                print("[restarted at \(position)s]")
            }
            analyzer.append(buffer, at: position)
            position += Double(buffer.frameLength) / file.processingFormat.sampleRate
        }
        await analyzer.finish(timeout: 10)
        print(analyzer.text)
        print(analyzer.words.map { "\($0.text)@\(String(format: "%.2f", $0.start))" }.joined(separator: " "))
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}
if arguments.contains("--screen-text-backfill") {
    print("wrote screen.txt for \(ScreenTranscript.backfill()) captures")
    exit(0)
}
if arguments.contains("--build-library") {
    print(Viewer.rebuildLibrary().path)
    exit(0)
}
if arguments.contains("--summary-demo") {
    // A made-up 3-frame recording, to show the text Pointer pastes ahead of the frames.
    let start = Date()
    func line(_ text: String, _ y: CGFloat) -> ScreenText.Line { ScreenText.Line(text: text, box: CGRect(x: 0.1, y: y, width: 0.3, height: 0.02)) }
    let frames = [0.0, 3.2, 7.5].enumerated().map { KeyFrames.Frame(time: $0.element, url: URL(fileURLWithPath: "/tmp/frame-\($0.offset + 1).png")) }
    let text = [[line("Country", 0.8), line("Select a country", 0.7)],
                [line("Country", 0.8), line("Canada", 0.7), line("Province", 0.6)],
                [line("Country", 0.8), line("Select a country", 0.7), line("Changes not saved", 0.1)]]
    let spoken: [Captions.Spoken] = [("The", -0.5), ("country", -0.3), ("picker", 0.1), ("opens", 0.4), ("fine.", 0.8),
                                     ("I", 3.5), ("pick", 3.7), ("Canada", 4.0), ("and", 5.0), ("save.", 5.3),
                                     ("Now", 7.8), ("it", 8.0), ("reset.", 8.2)]
    let clicks = [ClickLog.Click(time: start.addingTimeInterval(2.9), app: "Google Chrome", target: "pop-up button \"Country\""),
                  ClickLog.Click(time: start.addingTimeInterval(7.1), app: "Google Chrome", target: "button \"Save\"")]
    let notes = VideoSession.notes(frames: frames, screenText: text, spoken: spoken, clicks: clicks, started: start)
    print(VideoSession.summary(notes: notes, lateClicks: [], seconds: 9, video: URL(fileURLWithPath: "/tmp/recording.mov"),
                               captions: URL(fileURLWithPath: "/tmp/captions.srt"), voice: true))
    print(Captions.srt(Captions.cues(spoken, duration: 9)))
    exit(0)
}
if let flag = arguments.firstIndex(of: "--describe-point"), flag + 2 < arguments.count,
   let x = Double(arguments[flag + 1]), let y = Double(arguments[flag + 2]) {
    print(ClickLog.describe(at: CGPoint(x: x, y: y)) ?? "nothing labelled")
    exit(0)
}

let app = NSApplication.shared
let delegate: NSApplicationDelegate
if let flag = arguments.firstIndex(of: "--self-test"), flag + 1 < arguments.count {
    delegate = SelfTest(out: arguments[flag + 1])
} else {
    delegate = AppDelegate()
}
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
