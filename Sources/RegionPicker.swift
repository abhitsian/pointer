import AppKit

/// Dims every screen and lets the user drag a rectangle. A click without dragging picks the whole screen.
/// Returns the rectangle in global Cocoa coordinates (origin bottom-left of the main screen), or nil on Esc.
final class RegionPicker {
    private var panels: [NSPanel] = []
    private var escape: HotKey?
    private var completion: ((CGRect?) -> Void)?

    func pick(prompt: String, _ completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.acceptsMouseMovedEvents = true
            panel.isReleasedWhenClosed = false
            panel.sharingType = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = PickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.prompt = prompt
            view.onPick = { [weak self] local in
                self?.finish(local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
            }
            panel.contentView = view
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }
        escape = HotKey(keyCode: HotKey.keyEscape, modifiers: 0) { [weak self] in self?.finish(nil) }
    }

    func cancel() { finish(nil) }

    private func finish(_ rect: CGRect?) {
        guard let completion else { return }
        self.completion = nil
        escape?.unregister()
        escape = nil
        panels.forEach { $0.orderOut(nil) }
        panels = []
        completion(rect)
    }
}

private final class PickerView: NSView {
    var prompt = ""
    var onPick: ((CGRect) -> Void)?
    private var anchor: NSPoint?
    private var point: NSPoint?

    private var selection: NSRect? {
        guard let anchor, let point else { return nil }
        return NSRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                      width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .cursorUpdate, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        point = anchor
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        point = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let rect = selection else { return }
        onPick?(rect.width < 8 || rect.height < 8 ? bounds : rect.integral)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.3).setFill()
        bounds.fill()
        let tan = NSColor(red: 0.86, green: 0.66, blue: 0.44, alpha: 1)

        guard let rect = selection, rect.width >= 8, rect.height >= 8 else {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let text = NSAttributedString(string: prompt, attributes: attributes)
            let size = text.size()
            let pill = NSRect(x: bounds.midX - size.width / 2 - 18, y: bounds.maxY - 120, width: size.width + 36, height: size.height + 18)
            NSColor(white: 0.08, alpha: 0.9).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            text.draw(at: NSPoint(x: pill.minX + 18, y: pill.minY + 9))
            return
        }

        NSColor.clear.setFill()
        rect.fill(using: .copy)
        tan.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
        border.lineWidth = 2
        border.stroke()

        let label = NSAttributedString(string: "\(Int(rect.width)) × \(Int(rect.height))", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.08, alpha: 1),
        ])
        let size = label.size()
        let tag = NSRect(x: rect.minX, y: rect.maxY + 6, width: size.width + 12, height: size.height + 6)
        tan.setFill()
        NSBezierPath(roundedRect: tag, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: tag.minX + 6, y: tag.minY + 3))
    }
}
