import AppKit
import ScreenCaptureKit
import SwiftUI

/// What a recording or watch session captures: one whole screen, or one window wherever it sits.
enum ShareTarget {
    case screen(CGRect)
    case window(CGWindowID)
    /// Drag out an area instead (video only).
    case area
}

/// The "choose what to share" sheet, like Zoom's Share Screen: a thumbnail for every screen and every open window.
/// The screen under the pointer is picked to start with, so Return shares it straight away.
@MainActor
final class SharePicker {
    static let shared = SharePicker()

    private var panel: NSPanel?
    private var done: ((ShareTarget?) -> Void)?
    /// The app that was in front before the picker took focus; it comes back when the picker closes.
    private var previous: NSRunningApplication?

    /// Shows the picker. `allowArea` adds the drag-an-area tile. `pick` gets nil if the user cancels.
    func choose(title: String, allowArea: Bool, pick: @escaping (ShareTarget?) -> Void) {
        close(with: nil)
        done = pick
        let front = NSWorkspace.shared.frontmostApplication
        previous = front?.processIdentifier == getpid() ? nil : front

        let model = ShareModel(allowArea: allowArea)
        let view = ShareView(title: title, model: model, share: { [weak self] in self?.close(with: $0) },
                             cancel: { [weak self] in self?.close(with: nil) })
        let host = NSHostingView(rootView: view)
        let panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        panel.onCancel = { [weak self] in self?.close(with: nil) }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - 430, y: visible.midY - 300))
        }
        self.panel = panel
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        Task { await model.load() }
    }

    private func close(with target: ShareTarget?) {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
        let done = self.done
        self.done = nil
        // Hand focus back, so the capture (and anything it pastes) lands on the app you were in.
        if let previous { previous.activate() } else if target != nil { NSApp.hide(nil) }
        previous = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { done?(target) }
    }
}

/// A panel that takes keyboard focus and closes on Esc.
private final class KeyPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// One tile in the picker.
struct ShareSource: Identifiable {
    enum Kind { case screen, window, area }
    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: NSImage?
    let target: ShareTarget
    var thumbnail: CGImage?
}

@MainActor
final class ShareModel: ObservableObject {
    @Published var screens: [ShareSource] = []
    @Published var windows: [ShareSource] = []
    @Published var selected: String?
    @Published var failed: String?
    let allowArea: Bool

    init(allowArea: Bool) { self.allowArea = allowArea }

    var all: [ShareSource] { screens + windows }

    func load() async {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            failed = "Pointer needs Screen Recording to list screens and windows."
            return
        }
        let mouse = NSEvent.mouseLocation
        var screens: [ShareSource] = []
        for display in content.displays {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) else { continue }
            let id = "screen-\(display.displayID)"
            if NSMouseInRect(mouse, screen.frame, false) { selected = id }
            screens.append(ShareSource(id: id, kind: .screen, title: screen.localizedName,
                                       subtitle: "\(Int(screen.frame.width)) × \(Int(screen.frame.height))", icon: nil,
                                       target: .screen(screen.frame)))
        }
        if allowArea {
            screens.append(ShareSource(id: "area", kind: .area, title: "Part of the screen", subtitle: "Drag out an area",
                                       icon: nil, target: .area))
        }
        // Real app windows only: normal level, a usable size, and not Pointer, the Dock or the menu bar.
        let skip: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
                                 "com.apple.notificationcenterui", "com.apple.Spotlight"]
        let windows = content.windows.filter { window in
            guard let app = window.owningApplication, app.processID != getpid(), !skip.contains(app.bundleIdentifier),
                  window.windowLayer == 0, window.isOnScreen, window.frame.width >= 160, window.frame.height >= 100 else { return false }
            return true
        }
        self.windows = windows.map { window in
            let app = window.owningApplication
            let running = app.flatMap { NSRunningApplication(processIdentifier: $0.processID) }
            let name = app?.applicationName ?? "Window"
            let title = (window.title ?? "").isEmpty ? name : window.title!
            return ShareSource(id: "window-\(window.windowID)", kind: .window, title: title,
                               subtitle: title == name ? "" : name, icon: running?.icon, target: .window(window.windowID))
        }
        if selected == nil { selected = screens.first?.id }
        self.screens = screens

        // Thumbnails arrive one by one, so the picker is usable straight away.
        for display in content.displays {
            let image = await thumbnail(SCContentFilter(display: display, excludingWindows: []), size: display.frame.size)
            if let index = self.screens.firstIndex(where: { $0.id == "screen-\(display.displayID)" }) { self.screens[index].thumbnail = image }
        }
        for window in windows {
            let image = await thumbnail(SCContentFilter(desktopIndependentWindow: window), size: window.frame.size)
            if let index = self.windows.firstIndex(where: { $0.id == "window-\(window.windowID)" }) { self.windows[index].thumbnail = image }
        }
    }

    private func thumbnail(_ filter: SCContentFilter, size: CGSize) async -> CGImage? {
        guard size.width > 0, size.height > 0 else { return nil }
        let config = SCStreamConfiguration()
        let scale = min(1, 560 / size.width)
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

private struct ShareView: View {
    let title: String
    @ObservedObject var model: ShareModel
    let share: (ShareTarget) -> Void
    let cancel: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 14)
                .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let failed = model.failed {
                        Text(failed).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                    section("Screens", model.screens)
                    if !model.windows.isEmpty { section("Windows", model.windows) }
                }
                .padding(20)
            }
            Divider()
            HStack {
                Text("Double-click to share. Return shares the highlighted one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Button("Share") { selectedTarget.map(share) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedTarget == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 860, minHeight: 600)
    }

    private var selectedTarget: ShareTarget? {
        model.all.first { $0.id == model.selected }?.target
    }

    private func section(_ heading: String, _ sources: [ShareSource]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                ForEach(sources) { source in
                    tile(source)
                        .onTapGesture(count: 2) { share(source.target) }
                        .onTapGesture { model.selected = source.id }
                }
            }
        }
    }

    private func tile(_ source: ShareSource) -> some View {
        let picked = model.selected == source.id
        return VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
                if let image = source.thumbnail {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(4)
                } else if source.kind == .area {
                    Image(systemName: "rectangle.dashed").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 118)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(picked ? Color.accentColor : .clear, lineWidth: 3))
            HStack(spacing: 6) {
                if let icon = source.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: source.kind == .area ? "crop" : "display").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if !source.subtitle.isEmpty {
                        Text(source.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }
}
