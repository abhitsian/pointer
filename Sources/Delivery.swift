import AppKit
import ApplicationServices
import Carbon

/// Where a capture gets pasted.
struct Target {
    enum Style {
        /// Terminals and editors: paste the PNG path. Claude Code turns a pasted image path into an attachment.
        case path
        /// Chat apps: paste the image itself.
        case image
    }

    let app: NSRunningApplication
    let style: Style
    var name: String { app.localizedName ?? "assistant" }
}

/// Remembers the assistant app you used last, so a capture goes back to the conversation you were in.
final class TargetTracker {
    static let known: [(bundleID: String, style: Target.Style)] = [
        ("com.apple.Terminal", .path),
        ("com.googlecode.iterm2", .path),
        ("com.mitchellh.ghostty", .path),
        ("dev.warp.Warp-Stable", .path),
        ("com.github.wez.wezterm", .path),
        ("net.kovidgoyal.kitty", .path),
        ("org.alacritty", .path),
        ("co.zeit.hyper", .path),
        ("com.microsoft.VSCode", .path),
        ("com.todesktop.230313mzl4w4u92", .path), // Cursor
        ("com.exafunction.windsurf", .path),
        ("dev.zed.Zed", .path),
        ("com.anthropic.claudefordesktop", .image),
        ("com.openai.chat", .image),
    ]

    static func style(for bundleID: String?) -> Target.Style? {
        known.first { $0.bundleID == bundleID }?.style
    }

    private(set) var lastUsed: NSRunningApplication?

    /// A bundle ID chosen in the menu. Nil means "last used".
    var pinned: String? {
        get { UserDefaults.standard.string(forKey: "pinnedTarget") }
        set { UserDefaults.standard.set(newValue, forKey: "pinnedTarget") }
    }

    init() {
        if let front = NSWorkspace.shared.frontmostApplication, Self.style(for: front.bundleIdentifier) != nil {
            lastUsed = front
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.style(for: app.bundleIdentifier) != nil else { return }
            self?.lastUsed = app
        }
    }

    var runningAssistants: [NSRunningApplication] {
        Self.known.compactMap { running($0.bundleID) }
    }

    func current() -> Target? {
        if let id = pinned, let app = running(id) { return target(app) }
        if let app = lastUsed, !app.isTerminated { return target(app) }
        return runningAssistants.first.map(target)
    }

    private func target(_ app: NSRunningApplication) -> Target {
        Target(app: app, style: Self.style(for: app.bundleIdentifier) ?? .path)
    }

    private func running(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first { !$0.isTerminated }
    }
}

enum DeliveryError: Error {
    case notTrusted
    case couldNotFocus(String)

    var message: String {
        switch self {
        case .notTrusted: return "Copied. Press ⌘V to paste (allow Accessibility so Pointer can paste for you)"
        case .couldNotFocus(let name): return "Couldn't bring \(name) forward. Copied, press ⌘V"
        }
    }
}

/// One piece of a message, pasted in order.
enum Part {
    case text(String)
    case image(URL)
}

/// Brings the target forward and pastes the parts into it.
enum Deliverer {
    static func deliver(_ parts: [Part], to target: Target, autoSend: Bool,
                        completion: @escaping (Result<Void, DeliveryError>) -> Void) {
        let fallback = parts.map { part -> String in
            switch part {
            case .text(let text): return text
            case .image(let url): return url.path
            }
        }.joined(separator: " ")
        guard AXIsProcessTrusted() else {
            Clipboard.setText(fallback)
            completion(.failure(.notTrusted))
            return
        }

        let saved = ClipboardSnapshot.take()
        bringToFront(target.app) { focused in
            guard focused else {
                Clipboard.setText(fallback)
                completion(.failure(.couldNotFocus(target.name)))
                return
            }
            whenModifiersReleased {
                var steps: [(delay: TimeInterval, action: () -> Void)] = []
                var afterImage = false
                for part in parts {
                    // Give the app time to take in an image before the next paste lands.
                    let delay = steps.isEmpty ? 0.15 : (afterImage ? 0.9 : 0.35)
                    switch part {
                    case .text(let text):
                        steps.append((delay, { Clipboard.setText(text); Keys.paste() }))
                        afterImage = false
                    case .image(let url):
                        switch target.style {
                        case .path: steps.append((delay, { Clipboard.setText(url.path); Keys.paste() }))
                        case .image: steps.append((delay, { Clipboard.setImage(at: url); Keys.paste() }))
                        }
                        afterImage = true
                    }
                }
                if autoSend { steps.append((afterImage ? 0.9 : 0.45, { Keys.press(CGKeyCode(kVK_Return)) })) }
                steps.append((0.8, { saved.restore(); completion(.success(())) }))
                run(steps)
            }
        }
    }

    private static func run(_ steps: [(delay: TimeInterval, action: () -> Void)]) {
        guard let first = steps.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + first.delay) {
            first.action()
            run(Array(steps.dropFirst()))
        }
    }

    /// Tries a normal activation, then the Accessibility "frontmost" attribute, then LaunchServices.
    private static func bringToFront(_ app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        let isFront = { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        if isFront() { completion(true); return }

        let attempts: [() -> Void] = [
            { app.activate() },
            {
                let element = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            },
            {
                guard let id = app.bundleIdentifier else { return }
                let open = Process()
                open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                open.arguments = ["-b", id]
                try? open.run()
            },
        ]

        func attempt(_ index: Int) {
            guard index < attempts.count else { completion(false); return }
            attempts[index]()
            poll(timeout: index == attempts.count - 1 ? 1.5 : 0.5, until: isFront) { ok in
                ok ? completion(true) : attempt(index + 1)
            }
        }
        attempt(0)
    }

    private static func whenModifiersReleased(_ then: @escaping () -> Void) {
        let held: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        poll(timeout: 1.5, until: { NSEvent.modifierFlags.intersection(held).isEmpty }) { _ in then() }
    }

    private static func poll(timeout: TimeInterval, until condition: @escaping () -> Bool,
                             then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if condition() { then(true); return }
            if Date() > deadline { then(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: check)
        }
        check()
    }
}

enum Keys {
    static func paste() { press(CGKeyCode(kVK_ANSI_V), flags: .maskCommand) }

    static func press(_ key: CGKeyCode, flags: CGEventFlags = []) {
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

enum Clipboard {
    /// Tells clipboard managers (Raycast, Maccy, Paste) not to record Pointer's temporary contents.
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func setText(_ string: String) {
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        write(item)
    }

    static func setImage(at url: URL) {
        let item = NSPasteboardItem()
        if let png = try? Data(contentsOf: url) {
            item.setData(png, forType: .png)
            if let tiff = NSImage(data: png)?.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        }
        write(item)
    }

    private static func write(_ item: NSPasteboardItem) {
        item.setData(Data(), forType: transient)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([item])
    }
}

/// A copy of whatever was on the clipboard before Pointer borrowed it.
struct ClipboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func take() -> ClipboardSnapshot {
        let items = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
        return ClipboardSnapshot(items: items)
    }

    func restore() {
        NSPasteboard.general.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { copy -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in copy { item.setData(data, forType: type) }
            return item
        }
        NSPasteboard.general.writeObjects(restored)
    }
}
