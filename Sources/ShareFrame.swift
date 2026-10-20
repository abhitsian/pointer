import AppKit
import QuartzCore

/// The edge frame shown while a watch session records: a pulsing amber border around the watched screen, or
/// around the watched window wherever it moves. Clicks pass through it, and recordings leave it out (screen
/// recordings exclude Pointer's windows; window recordings only see that window). Main thread only.
final class ShareFrame {
    private var panel: NSPanel?
    private var tracker: Timer?

    /// Frames a whole screen (Cocoa coordinates).
    func show(screen frame: CGRect) {
        stopTracking()
        place(frame, inset: true)
    }

    /// Frames one window and follows it as it moves or resizes; hides while it is minimized or off screen.
    func show(window id: CGWindowID) {
        stopTracking()
        let follow = { [weak self] in
            guard let self else { return }
            if let frame = ShareFrame.frame(of: id) {
                self.place(frame.insetBy(dx: -4, dy: -4), inset: false)
            } else {
                self.panel?.orderOut(nil)
            }
        }
        follow()
        tracker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in follow() }
    }

    func hide() {
        stopTracking()
        panel?.orderOut(nil)
        panel = nil
    }

    private func stopTracking() {
        tracker?.invalidate()
        tracker = nil
    }

    private func place(_ frame: CGRect, inset: Bool) {
        let panel = self.panel ?? makePanel()
        // A screen's frame sits on its edges; a window's frame sits just outside it, above other windows.
        panel.level = inset ? .screenSaver : .floating
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let view = NSView()
        view.wantsLayer = true
        view.autoresizingMask = [.width, .height]
        let border = CALayer()
        border.frame = view.bounds
        border.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        border.borderWidth = 4
        border.cornerRadius = 10
        border.borderColor = NSColor(red: 0.96, green: 0.58, blue: 0.16, alpha: 1).cgColor
        // A soft glow inside the edge, so it reads on light and dark screens alike.
        border.shadowColor = border.borderColor
        border.shadowOpacity = 0.9
        border.shadowRadius = 8
        border.shadowOffset = .zero
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.45
        pulse.duration = 1.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        border.add(pulse, forKey: "pulse")
        view.layer?.addSublayer(border)
        panel.contentView = view
        self.panel = panel
        return panel
    }

    /// A window's frame in Cocoa coordinates, or nil when it is not on screen.
    private static func frame(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds) else { return nil }
        // CGWindow bounds have a top-left origin on the main screen; Cocoa's origin is bottom-left.
        let height = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
