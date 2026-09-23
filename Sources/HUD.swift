import AppKit
import SwiftUI

final class HUDModel: ObservableObject {
    enum Tone { case live, done, error }

    @Published var status = ""
    @Published var hint = ""
    @Published var transcript = ""
    @Published var placeholder = HUDModel.defaultPlaceholder
    @Published var level: Float = 0
    @Published var listening = false
    @Published var tone: Tone = .live
    /// 0…1 while Pointer waits out a pause before sending. Nil hides the bar.
    @Published var countdown: Double?
    /// Shows a Stop button while a recording runs.
    @Published var showsStop = false
    var stop: (() -> Void)?

    static let defaultPlaceholder = "Say what's wrong while you drag over it"

    func reset() {
        status = ""; hint = ""; transcript = ""; level = 0
        listening = false; tone = .live; countdown = nil; showsStop = false
        placeholder = HUDModel.defaultPlaceholder
    }
}

private enum Palette {
    static let tan = Color(red: 0.86, green: 0.66, blue: 0.44)
    static let ink = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let done = Color(red: 0.55, green: 0.82, blue: 0.60)
    static let error = Color(red: 0.96, green: 0.52, blue: 0.47)
}

/// The pill sits at the bottom of a fixed, transparent panel and grows upward when the transcript wraps.
struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HUDPill(model: model)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(width: 588, height: 150, alignment: .bottom)
    }
}

struct HUDPill: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MarkGlyph(tint: glyphTint)
                .frame(width: 32, height: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(model.status.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(model.hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
                if !(model.transcript.isEmpty && model.placeholder.isEmpty) {
                    Text(model.transcript.isEmpty ? model.placeholder : model.transcript)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(model.transcript.isEmpty ? 0.34 : 0.94))
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LevelMeter(level: model.level)
                .opacity(model.listening ? 1 : 0)

            if model.showsStop {
                Button(action: { model.stop?() }) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).frame(width: 9, height: 9)
                        Text("Stop").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Palette.tan))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(width: 540)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.ink.opacity(0.94))
        )
        .overlay(alignment: .bottomLeading) {
            if let countdown = model.countdown {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Palette.tan.opacity(0.85))
                        .frame(width: geo.size.width * countdown, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.09))
        )
    }

    private var statusColor: Color {
        switch model.tone {
        case .live: return Palette.tan
        case .done: return Palette.done
        case .error: return Palette.error
        }
    }

    private var glyphTint: Color {
        model.tone == .error ? Palette.error : Palette.tan
    }
}

private struct MarkGlyph: View {
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            // Canvas is y-down; the mark is drawn y-up.
            let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
            for part in Mark.parts(in: CGRect(origin: .zero, size: size)) {
                ctx.fill(Path(part).applying(flip), with: .color(tint))
            }
        }
    }
}

private struct LevelMeter: View {
    let level: Float
    private let weights: [CGFloat] = [0.45, 0.8, 1.0, 0.7, 0.4]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(Palette.tan)
                    .frame(width: 3, height: 4 + 18 * CGFloat(level) * weights[i])
            }
        }
        .frame(width: 27, height: 24)
        .animation(.easeOut(duration: 0.12), value: level)
    }
}

/// Takes the first click even though Pointer is never the active app.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A floating panel near the bottom of the screen the pointer is on. Click-through unless it shows a Stop button.
final class HUDController {
    let model = HUDModel()

    /// Set while a recording runs: shows the Stop button and lets the panel take clicks.
    var onStop: (() -> Void)? {
        didSet {
            model.stop = onStop
            model.showsStop = onStop != nil
            panel.ignoresMouseEvents = onStop == nil
        }
    }
    private lazy var panel: NSPanel = makePanel()
    private var hideWork: DispatchWorkItem?

    func show() {
        hideWork?.cancel()
        position()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let panel = self?.panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Shows a one-line message on its own, e.g. when a capture can't start.
    func flash(_ status: String, hint: String = "", tone: HUDModel.Tone = .error, for seconds: TimeInterval = 3) {
        model.reset()
        model.status = status
        model.hint = hint
        model.tone = tone
        model.placeholder = ""
        show()
        hide(after: seconds)
    }

    private func makePanel() -> NSPanel {
        let host = ClickThroughHostingView(rootView: HUDView(model: model))
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the pill draws its own shadow
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1) // above the region picker
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none // keep the HUD out of the screenshot
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        return panel
    }

    /// Moves the HUD off an area being recorded: bottom of the screen, then the top, then another screen.
    func keepClear(of rect: CGRect) {
        let size = panel.frame.size
        let screens = NSScreen.screens.sorted { a, _ in a.frame.intersects(rect) }
        let spots = screens.flatMap { screen -> [NSPoint] in
            let area = screen.visibleFrame
            return [NSPoint(x: area.midX - size.width / 2, y: area.minY + 16),
                    NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height)]
        }
        // The pill fills the bottom ~80 pt of the transparent panel.
        if let spot = spots.first(where: { !NSRect(x: $0.x, y: $0.y, width: size.width, height: 90).intersects(rect) }) {
            panel.setFrameOrigin(spot)
        }
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let size = panel.frame.size
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.minY + 16))
    }
}

/// Renders the HUD to a PNG for design checks: `Pointer --render-hud out.png`.
enum HUDPreview {
    @MainActor static func render(to path: String) {
        let states: [(String, String, String, Float, Double?, HUDModel.Tone)] = [
            ("Listening · drag over the problem", "esc cancels", "", 0.2, nil, .live),
            ("Got the shot · keep talking", "⏎ send   esc cancel",
             "The save button sits under the footer on narrow windows, and the toast covers the error text", 0.7, 0.55, .live),
            ("● Recording 0:07", "⌃⌥V stops", "When I pick Canada the page jumps back to the top", 0.6, nil, .live),
            ("Sent to Terminal", "", "The save button sits under the footer on narrow windows.", 0, nil, .done),
            ("No assistant open", "open Terminal or Claude first", "", 0, nil, .error),
        ]
        let stack = VStack(spacing: 18) {
            ForEach(states.indices, id: \.self) { i in
                let s = states[i]
                let model = HUDModel()
                HUDPill(model: {
                    model.status = s.0; model.hint = s.1; model.transcript = s.2
                    model.level = s.3; model.countdown = s.4; model.tone = s.5
                    model.listening = s.5 == .live
                    if s.5 == .error { model.placeholder = "" }
                    model.showsStop = s.0.hasPrefix("●")
                    return model
                }())
            }
        }
        .frame(width: 540)
        .padding(20)
        .background(Color(red: 0.93, green: 0.92, blue: 0.89))

        let renderer = ImageRenderer(content: stack)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
