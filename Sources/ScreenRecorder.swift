import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records part of a display, or one window, to a .mov with ScreenCaptureKit. Pointer's own windows are
/// left out, and the microphone can be recorded into the file.
final class ScreenRecorder: NSObject, SCRecordingOutputDelegate, SCStreamOutput, SCStreamDelegate {
    enum RecorderError: Error {
        case noDisplay
        case noWindow
    }

    struct Options {
        /// Record the microphone into the file.
        var voice = false
        /// Record the Mac's own audio (a meeting, a video) into the file.
        var systemAudio = false
        /// Include Pointer's own audio in that capture. Only used by the self-test.
        var ownAudio = false
        var framesPerSecond = 30
        /// Pixels per point. Nil records at the screen's full resolution; 1 halves a Retina screen.
        var scale: CGFloat? = nil
        /// Receives audio buffers as they arrive; `true` for the microphone, `false` for the Mac's audio.
        var onAudio: ((CMSampleBuffer, Bool) -> Void)? = nil
    }

    private var onAudio: ((CMSampleBuffer, Bool) -> Void)?
    private let audioQueue = DispatchQueue(label: "pointer.recorder.audio")

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var onFinish: ((Error?) -> Void)?
    private var url: URL?
    /// macOS ended the capture while it was meant to be running (display change, lock, another capture app).
    /// Called on the main queue; the owner decides whether to start again.
    var onInterrupted: ((Error) -> Void)?
    private var stopping = false

    /// Records `rect` (global Cocoa coordinates, on one screen). `started` runs on the main queue.
    func start(rect: CGRect, to url: URL, voice: Bool, started: @escaping (Error?) -> Void) {
        start(rect: rect, to: url, options: Options(voice: voice), started: started)
    }

    func start(rect: CGRect, to url: URL, options: Options, started: @escaping (Error?) -> Void) {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            started(RecorderError.noDisplay)
            return
        }
        let frame = screen.frame
        let scale = options.scale ?? screen.backingScaleFactor
        begin(url: url, options: options, started: started) { content in
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw RecorderError.noDisplay }
            let own = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
            let config = SCStreamConfiguration()
            // sourceRect is in the display's points, origin top-left.
            let local = CGRect(x: rect.minX - frame.minX, y: frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            config.sourceRect = local
            config.width = Int(local.width * scale) / 2 * 2
            config.height = Int(local.height * scale) / 2 * 2
            return (filter, config)
        }
    }

    /// Records one window, even where other windows cover it.
    func start(window windowID: CGWindowID, to url: URL, voice: Bool, started: @escaping (Error?) -> Void) {
        begin(url: url, options: Options(voice: voice), started: started) { content in
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw RecorderError.noWindow }
            let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 2
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale) / 2 * 2
            config.height = Int(window.frame.height * scale) / 2 * 2
            return (SCContentFilter(desktopIndependentWindow: window), config)
        }
    }

    private func begin(url: URL, options: Options, started: @escaping (Error?) -> Void,
                       setup: @escaping (SCShareableContent) throws -> (SCContentFilter, SCStreamConfiguration)) {
        self.url = url
        onAudio = options.onAudio
        let mic = Transcriber.microphone()?.uniqueID
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let (filter, config) = try setup(content)
                config.showsCursor = true
                config.showMouseClicks = true
                config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
                if options.voice {
                    // Same mic the transcript uses, so Bluetooth headphones stay out of headset mode.
                    config.captureMicrophone = true
                    config.microphoneCaptureDeviceID = mic
                }
                if options.systemAudio {
                    config.capturesAudio = true
                    config.excludesCurrentProcessAudio = !options.ownAudio
                }

                let recording = SCRecordingOutputConfiguration()
                recording.outputURL = url
                recording.outputFileType = .mov
                recording.videoCodecType = .h264

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                let output = SCRecordingOutput(configuration: recording, delegate: self)
                try stream.addRecordingOutput(output)
                if options.onAudio != nil {
                    if options.systemAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue) }
                    if options.voice { try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: self.audioQueue) }
                }
                try await stream.startCapture()
                await MainActor.run {
                    self.stream = stream
                    self.output = output
                    started(nil)
                }
            } catch {
                await MainActor.run { started(error) }
            }
        }
    }

    /// Stops and waits for the file to be written. `finished` runs on the main queue.
    func stop(_ finished: @escaping (Error?) -> Void) {
        stopping = true
        guard let stream else { finished(nil); return }
        self.stream = nil
        onFinish = finished
        let url = self.url
        Task {
            try? await stream.stopCapture()
            // The delegate usually reports the finished file, but not always (it stays silent when the mic is
            // recorded), so also finish as soon as the file opens as a playable movie. A long recording can take
            // well over 5 s to finalize, so wait up to 2 min.
            for _ in 0..<600 {
                if let url, ScreenRecorder.playable(url) { break }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await MainActor.run { self.finish(nil) }
        }
    }

    private static func playable(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        return !asset.tracks(withMediaType: .video).isEmpty && CMTimeGetSeconds(asset.duration) > 0
    }

    /// The front window of the frontmost app, for recording a document.
    static func frontWindow() -> (id: CGWindowID, app: String, title: String)? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in list {
            guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 200, (bounds["Height"] ?? 0) > 150 else { continue }
            return (id, app.localizedName ?? "the app", info[kCGWindowName as String] as? String ?? "")
        }
        return nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio: onAudio?(sampleBuffer, false)
        case .microphone: onAudio?(sampleBuffer, true)
        default: break
        }
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        DispatchQueue.main.async { self.finish(nil) }
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Log.write("recorder: failed \(error)")
        DispatchQueue.main.async { self.interrupted(error) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("recorder: stream stopped \(error)")
        DispatchQueue.main.async { self.interrupted(error) }
    }

    private func interrupted(_ error: Error) {
        if !stopping, let onInterrupted {
            self.stream = nil
            onInterrupted(error)
        }
        finish(error)
    }

    private func finish(_ error: Error?) {
        let callback = onFinish
        onFinish = nil
        callback?(error)
    }
}
