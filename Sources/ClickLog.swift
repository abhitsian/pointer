import AppKit
import ApplicationServices

/// Records each mouse click during a recording, with the name of the button, link or field under it,
/// read through the Accessibility API. Keystrokes are never recorded.
final class ClickLog {
    struct Click {
        let time: Date
        let app: String
        /// e.g. `button "Save"`, `link "Details"`, `text field "Email"`.
        let target: String
    }

    private(set) var clicks: [Click] = []
    private var monitor: Any?
    private let lookupQueue = DispatchQueue(label: "pointer.clicks")

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.record(at: NSEvent.mouseLocation, right: event.type == .rightMouseDown)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func record(at point: NSPoint, right: Bool) {
        let time = Date()
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "an app"
        // Accessibility uses points from the top-left of the main screen.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let axPoint = CGPoint(x: point.x, y: mainHeight - point.y)
        lookupQueue.async {
            var target = ClickLog.describe(at: axPoint) ?? "an unlabelled spot"
            if right { target = "right-click on " + target }
            DispatchQueue.main.async { self.clicks.append(Click(time: time, app: app, target: target)) }
        }
    }

    /// The nearest labelled element at a point: its own label, or a parent's within three levels.
    static func describe(at point: CGPoint) -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.4)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }

        for _ in 0..<4 {
            let role = string(element, kAXRoleDescriptionAttribute) ?? string(element, kAXRoleAttribute) ?? "element"
            if let label = label(of: element) { return "\(role) \"\(label)\"" }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let next = parent, CFGetTypeID(next) == AXUIElementGetTypeID() else { break }
            element = next as! AXUIElement
        }
        return nil
    }

    private static func label(of element: AXUIElement) -> String? {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
            if let text = string(element, attribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                return text.count > 60 ? String(text.prefix(57)) + "…" : text
            }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
