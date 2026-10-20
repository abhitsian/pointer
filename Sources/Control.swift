import AppKit
import ScreenCaptureKit

/// Lets a chat (Claude Code, via `Pointer --ctl …`) start, stop and look in on a watch session, without the
/// shortcut or the share picker. Requests arrive as a distributed notification; each reply is a JSON file in
/// ~/Pictures/Pointer/.control/<id>.json that the CLI waits for and prints.
enum Control {
    static let name = Notification.Name("com.vaibhav.pointer.control")
    static let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Pointer/.control", isDirectory: true)

    /// The CLI side: posts the request, waits for the reply, prints it, and returns the exit code.
    static func send(_ args: [String]) -> Int32 {
        guard let cmd = args.first else {
            print("usage: Pointer --ctl targets | start [<screen, window or follow>] [--listen] | stop | cancel | status | peek")
            return 2
        }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.vaibhav.pointer")
            .contains(where: { $0.processIdentifier != getpid() }) else {
            print(#"{"ok":false,"error":"Pointer is not running. Start it with: open -g ~/Applications/Pointer.app"}"#)
            return 1
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let reply = folder.appendingPathComponent("\(id).json")
        let rest = Array(args.dropFirst())
        let info: [String: String] = [
            "id": id, "cmd": cmd,
            "target": rest.filter { !$0.hasPrefix("--") }.joined(separator: " "),
            "listen": rest.contains("--listen") ? "1" : "0",
        ]
        DistributedNotificationCenter.default().postNotificationName(name, object: nil, userInfo: info, deliverImmediately: true)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let data = try? Data(contentsOf: reply) {
                try? FileManager.default.removeItem(at: reply)
                print(String(decoding: data, as: UTF8.self))
                let ok = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool ?? false
                return ok ? 0 : 1
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        print(#"{"ok":false,"error":"Pointer did not answer within 20 s"}"#)
        return 1
    }

    /// The app side: writes one reply for a request.
    static func reply(_ id: String, _ body: [String: Any]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: folder.appendingPathComponent("\(id).json"), options: .atomic)
    }

    /// A screen or window that a session can follow, as listed by `targets`.
    struct Source {
        let target: ShareTarget
        let kind: String, name: String, app: String, detail: String
        let underMouse: Bool
        var json: [String: Any] {
            var out: [String: Any] = ["kind": kind, "name": name, "id": id]
            if !app.isEmpty { out["app"] = app }
            if !detail.isEmpty { out["detail"] = detail }
            if underMouse { out["underMouse"] = true }
            return out
        }
        var id: String {
            switch target {
            case .window(let window): return "window:\(window)"
            case .screen(let frame): return "screen:\(Int(frame.minX)),\(Int(frame.minY))"
            case .area: return "area"
            case .follow: return "follow"
            }
        }
    }

    /// Every screen, then every real app window, in the same order the share picker shows them.
    @MainActor static func sources() async -> [Source] {
        let mouse = NSEvent.mouseLocation
        var out = NSScreen.screens.enumerated().map { index, screen in
            Source(target: .screen(screen.frame), kind: "screen", name: screen.localizedName, app: "",
                   detail: "screen \(index + 1)\(index == 0 ? " (main)" : "") · \(Int(screen.frame.width)) × \(Int(screen.frame.height))",
                   underMouse: NSMouseInRect(mouse, screen.frame, false))
        }
        out.append(Source(target: .follow, kind: "follow", name: "Follow my pointer", app: "",
                          detail: "whichever screen the mouse is on, switching as it moves", underMouse: false))
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return out }
        let skip: Set<String> = ["com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
                                 "com.apple.notificationcenterui", "com.apple.Spotlight"]
        // Front to back, the way CGWindowList orders them, so "chrome" means the Chrome window on top.
        let order = ((CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for window in content.windows.sorted(by: { rank[$0.windowID, default: .max] < rank[$1.windowID, default: .max] }) {
            guard let app = window.owningApplication, app.processID != getpid(), !skip.contains(app.bundleIdentifier),
                  window.windowLayer == 0, window.isOnScreen, window.frame.width >= 160, window.frame.height >= 100 else { continue }
            out.append(Source(target: .window(window.windowID), kind: "window", name: window.title ?? "", app: app.applicationName,
                              detail: "\(Int(window.frame.width)) × \(Int(window.frame.height))", underMouse: false))
        }
        return out
    }

    /// Resolves what the user said ("the LG screen", "screen 2", "main", "chrome", "teams", "window:1234") to a
    /// source. Empty means the screen under the mouse. Returns nil plus the candidates when nothing matches.
    @MainActor static func resolve(_ text: String) async -> (Source?, [Source]) {
        let all = await sources()
        let query = text.lowercased().trimmingCharacters(in: .whitespaces)
        let screens = all.filter { $0.kind == "screen" }, windows = all.filter { $0.kind == "window" }
        if query.isEmpty || query == "pointer" || query == "this screen" || query == "current" {
            return (screens.first { $0.underMouse } ?? screens.first, all)
        }
        if let exact = all.first(where: { $0.id == query }) { return (exact, all) }
        if query.contains("follow") || query == "wherever i am" || query.contains("across screens") {
            return (all.first { $0.kind == "follow" }, all)
        }
        if query == "main" || query == "primary" { return (screens.first, all) }
        if query == "built-in" || query == "laptop" || query == "macbook" {
            return (screens.first { $0.name.lowercased().contains("built-in") } ?? screens.first, all)
        }
        if query == "external" || query == "monitor" {
            return (screens.first { !$0.name.lowercased().contains("built-in") }, all)
        }
        let digits = query.filter(\.isNumber)
        if query.contains("screen") || query.contains("display"), let number = Int(digits), number >= 1, number <= screens.count {
            return (screens[number - 1], all)
        }
        let words = query.replacingOccurrences(of: "screen", with: "").replacingOccurrences(of: "window", with: "")
            .split(separator: " ").map(String.init).filter { !["the", "my", "on", "app", "display"].contains($0) }
        func matches(_ source: Source) -> Bool {
            let hay = "\(source.name) \(source.app)".lowercased()
            return !words.isEmpty && words.allSatisfy { hay.contains($0) }
        }
        if let screen = screens.first(where: matches) { return (screen, all) }
        // The front-most matching window.
        if let window = windows.first(where: matches) { return (window, all) }
        return (nil, all)
    }

    /// A full-size PNG of what a session is following, right now, saved under .control/.
    @MainActor static func screenshot(_ target: ShareTarget) async -> URL? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let filter: SCContentFilter, size: CGSize
        switch target {
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
            filter = SCContentFilter(desktopIndependentWindow: window)
            size = window.frame.size
        case .screen(let frame):
            let number = NSScreen.screens.first { $0.frame == frame }?
                .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == number }) ?? content.displays.first else { return nil }
            filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == getpid() },
                                     exceptingWindows: [])
            size = CGSize(width: display.width, height: display.height)
        case .area, .follow:
            return nil
        }
        let config = SCStreamConfiguration()
        // Within Claude's 2000 px image limit.
        let scale = min(2, 2000 / max(size.width, size.height))
        config.width = Int(size.width * scale)
        config.height = Int(size.height * scale)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = folder.appendingPathComponent("peek-\(stamp.string(from: Date())).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: url)
        return url
    }
}
