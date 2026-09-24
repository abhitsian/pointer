import AppKit
import AVFoundation
import Speech

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let tracker = TargetTracker()
    private let hud = HUDController()
    private var hotKey: HotKey?
    private var videoHotKey: HotKey?
    private var documentHotKey: HotKey?
    private var watchHotKey: HotKey?
    private var listenHotKey: HotKey?
    private var watching: WatchSession?
    private var session: ActiveCapture?
    /// Stopped watch sessions still being written up. Held here so they finish after the next one starts.
    private var writingUp: [WatchSession] = []
    private var lastCapture: CaptureRecord?
    private var lastRecording: URL?
    private var lastWatchPage: URL?

    private let folder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/Pointer", isDirectory: true)

    private var autoSend: Bool {
        get { UserDefaults.standard.bool(forKey: "autoSend") }
        set { UserDefaults.standard.set(newValue, forKey: "autoSend") }
    }

    private var shortcut: Shortcut {
        get { Shortcut.presets.first { $0.label == UserDefaults.standard.string(forKey: "shortcut") } ?? Shortcut.presets[0] }
        set { UserDefaults.standard.set(newValue.label, forKey: "shortcut") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Mark.menuBarImage()
        statusItem.button?.toolTip = "Pointer"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        registerShortcut()
        askForPermissions()
        Transcriber.warmUp()
        lastRecording = newestRecording()
        hud.flash("Pointer is ready", hint: "\(shortcut.label) shot   \(shortcut.videoLabel) video   \(shortcut.documentLabel) doc   \(shortcut.watchLabel) watch   \(shortcut.listenLabel) listen", tone: .live, for: 2.5)
    }

    /// Opening Pointer again (Finder, Spotlight, `open`) drops its menu down, so you can find the icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        hud.flash("Pointer is running", hint: "\(shortcut.label) screenshot   \(shortcut.videoLabel) video   \(shortcut.documentLabel) document", tone: .live, for: 2.5)
        DispatchQueue.main.async { [weak self] in self?.statusItem.button?.performClick(nil) }
        return false
    }

    // MARK: Capture

    private func registerShortcut() {
        hotKey?.unregister()
        videoHotKey?.unregister()
        documentHotKey?.unregister()
        hotKey = HotKey(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
            self?.shortcutPressed(.screenshot)
        }
        videoHotKey = HotKey(keyCode: HotKey.keyV, modifiers: shortcut.modifiers) { [weak self] in
            self?.shortcutPressed(.video)
        }
        documentHotKey = HotKey(keyCode: HotKey.keyD, modifiers: shortcut.modifiers) { [weak self] in
            self?.shortcutPressed(.document)
        }
        watchHotKey = HotKey(keyCode: HotKey.keyW, modifiers: shortcut.modifiers) { [weak self] in
            self?.shortcutPressed(.watch)
        }
        listenHotKey?.unregister()
        listenHotKey = HotKey(keyCode: HotKey.keyQ, modifiers: shortcut.modifiers) { [weak self] in
            self?.shortcutPressed(.listen)
        }
        let keys = [(hotKey, shortcut.label), (videoHotKey, shortcut.videoLabel), (documentHotKey, shortcut.documentLabel),
                    (watchHotKey, shortcut.watchLabel), (listenHotKey, shortcut.listenLabel)]
        Log.write("hotkeys: " + keys.map { "\($0.1) registered=\($0.0?.registered == true)" }.joined(separator: " "))
        let taken = keys.filter { $0.0?.registered == false }.map(\.1)
        if !taken.isEmpty {
            hud.flash("\(taken.joined(separator: " and ")) taken by another app", hint: "pick another in the Pointer menu")
        }
    }

    private enum Kind: String { case screenshot, video, document, watch, listen }

    private func shortcutPressed(_ kind: Kind) {
        Log.write("hotkey: \(kind.rawValue) pressed, capture=\(session != nil) watching=\(watching != nil)")
        if kind == .watch { return watching == nil ? startWatching() : watching?.shortcutPressed() ?? () }
        if kind == .listen { return watching == nil ? startListening() : watching?.shortcutPressed() ?? () }
        if let session { return session.shortcutPressed() }
        switch kind {
        case .screenshot: startCapture()
        case .video: startVideo()
        case .document: startDocument()
        case .watch, .listen: break
        }
    }

    /// Watch mode: a silent session that records and writes itself up, with nothing pasted anywhere.
    @objc private func startWatching() { beginWatch(listen: false) }

    /// Listen and ask: watch mode that also suggests questions worth asking as you listen.
    @objc private func startListening() { beginWatch(listen: true) }

    private func beginWatch(listen: Bool) {
        guard watching == nil else { return watching?.shortcutPressed() ?? () }
        guard CGPreflightScreenCaptureAccess() else {
            hud.flash("Pointer needs Screen Recording", hint: "allow it, then relaunch Pointer", for: 5)
            CGRequestScreenCaptureAccess()
            openSettings("Privacy_ScreenCapture")
            return
        }
        weak var this: WatchSession?
        let session = WatchSession(hud: hud, stopLabel: listen ? shortcut.listenLabel : shortcut.watchLabel, capturesFolder: folder,
                                   listen: listen) { [weak self] page in
            guard let self else { return }
            if let this, self.watching === this { self.watching = nil }
            self.writingUp.removeAll { $0 === this }
            if let page { self.lastWatchPage = page }
            self.refreshWatchTitle()
        }
        this = session
        session.hudFree = { [weak self] in self?.session == nil }
        session.onTick = { [weak self] elapsed in
            guard let self, self.watching === session else { return }
            self.statusItem.button?.title = elapsed.map { " ● \($0)" } ?? ""
        }
        // Stopping frees the shortcut at once; the write-up carries on in the background.
        session.onStopped = { [weak self] in
            guard let self, self.watching === session else { return }
            self.watching = nil
            self.writingUp.append(session)
            self.refreshWatchTitle()
        }
        watching = session
        session.start()
    }

    /// The menu bar title: the running watch's clock, else how many sessions are still being written up.
    private func refreshWatchTitle() {
        guard watching == nil else { return }
        statusItem.button?.title = writingUp.isEmpty ? "" : " Writing up\(writingUp.count > 1 ? " \(writingUp.count)" : "")"
    }

    @objc private func stopWatching() {
        watching?.shortcutPressed()
    }

    @objc private func discardWatching() {
        watching?.cancel()
        watching = nil
        statusItem.button?.title = ""
    }

    @objc private func openLastWatch() {
        if let page = lastWatchPage { NSWorkspace.shared.open(page) }
    }

    @objc private func toggleMeetingAudio() {
        WatchSession.recordMeetingAudio.toggle()
    }

    /// Checks shared by both modes. Returns the target, or nil after telling the user what's missing.
    private func readyTarget() -> Target? {
        guard session == nil else { return nil }
        guard CGPreflightScreenCaptureAccess() else {
            hud.flash("Pointer needs Screen Recording", hint: "allow it, then relaunch Pointer", for: 5)
            CGRequestScreenCaptureAccess()
            openSettings("Privacy_ScreenCapture")
            return nil
        }
        guard let target = tracker.current() else {
            hud.flash("No assistant open", hint: "open Terminal or Claude first")
            return nil
        }
        return target
    }

    @objc private func startVideo() {
        record(.screen)
    }

    @objc private func startAreaVideo() {
        record(.area)
    }

    @objc private func startDocument() {
        record(.document)
    }

    private func record(_ mode: VideoSession.Mode) {
        guard let target = readyTarget() else { return }
        let stop = mode == .document ? shortcut.documentLabel : shortcut.videoLabel
        let session = VideoSession(mode: mode, target: target, hud: hud, autoSend: autoSend, stopLabel: stop,
                                   capturesFolder: folder) { [weak self] record in
            self?.session = nil
            if let record {
                self?.lastCapture = record
                self?.lastRecording = record.video
            }
        }
        self.session = session
        session.start()
    }

    @objc private func stopActive() {
        session?.shortcutPressed()
    }

    @objc private func cancelActive() {
        session?.cancel()
    }

    @objc private func startCapture() {
        guard let target = readyTarget() else { return }
        let session = CaptureSession(target: target, hud: hud, autoSend: autoSend, folder: folder) { [weak self] record in
            self?.session = nil
            if let record { self?.lastCapture = record }
        }
        self.session = session
        session.start()
    }

    @objc private func pasteLastAgain() {
        guard let capture = lastCapture, let target = tracker.current() else { return }
        Deliverer.deliver(capture.parts, to: target, autoSend: autoSend) { [weak self] result in
            if case .failure(let error) = result { self?.hud.flash(error.message) }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if watching != nil {
            let stop = NSMenuItem(title: watching?.listen == true ? "Stop listening and write it up" : "Stop watching and write it up",
                                  action: #selector(stopWatching), keyEquivalent: watching?.listen == true ? "q" : "w")
            stop.keyEquivalentModifierMask = shortcut.menuModifiers
            stop.target = self
            menu.addItem(stop)
            let discard = NSMenuItem(title: "Discard this watch session", action: #selector(discardWatching), keyEquivalent: "")
            discard.target = self
            menu.addItem(discard)
            menu.addItem(.separator())
        }
        if session != nil {
            let stop = NSMenuItem(title: "Stop and send", action: #selector(stopActive), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            let cancel = NSMenuItem(title: "Cancel capture", action: #selector(cancelActive), keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
        } else {
            let capture = NSMenuItem(title: "Screenshot", action: #selector(startCapture), keyEquivalent: shortcut.menuKey)
            capture.keyEquivalentModifierMask = shortcut.menuModifiers
            capture.target = self
            menu.addItem(capture)
            let video = NSMenuItem(title: "Record screen", action: #selector(startVideo), keyEquivalent: "v")
            video.keyEquivalentModifierMask = shortcut.menuModifiers
            video.target = self
            menu.addItem(video)
            let area = NSMenuItem(title: "Record an area…", action: #selector(startAreaVideo), keyEquivalent: "")
            area.target = self
            menu.addItem(area)
            let document = NSMenuItem(title: "Read a document (front window)", action: #selector(startDocument), keyEquivalent: "d")
            document.keyEquivalentModifierMask = shortcut.menuModifiers
            document.target = self
            menu.addItem(document)
            if watching == nil {
                let watch = NSMenuItem(title: "Watch this screen (silent)", action: #selector(startWatching), keyEquivalent: "w")
                watch.keyEquivalentModifierMask = shortcut.menuModifiers
                watch.target = self
                menu.addItem(watch)
                let listen = NSMenuItem(title: "Listen and suggest questions", action: #selector(startListening), keyEquivalent: "q")
                listen.keyEquivalentModifierMask = shortcut.menuModifiers
                listen.target = self
                menu.addItem(listen)
            }
        }
        menu.addItem(.separator())

        menu.addItem(disabled("Send to"))
        let lastName = tracker.lastUsed?.localizedName
        let auto = NSMenuItem(title: lastName.map { "Last used (\($0))" } ?? "Last used assistant",
                              action: #selector(pickTarget(_:)), keyEquivalent: "")
        auto.target = self
        auto.indentationLevel = 1
        auto.state = tracker.pinned == nil ? .on : .off
        menu.addItem(auto)
        for app in tracker.runningAssistants {
            let item = NSMenuItem(title: app.localizedName ?? app.bundleIdentifier ?? "App",
                                  action: #selector(pickTarget(_:)), keyEquivalent: "")
            item.target = self
            item.indentationLevel = 1
            item.representedObject = app.bundleIdentifier
            item.state = tracker.pinned == app.bundleIdentifier ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let send = NSMenuItem(title: "Press Return after pasting", action: #selector(toggleAutoSend), keyEquivalent: "")
        send.target = self
        send.state = autoSend ? .on : .off
        menu.addItem(send)

        let meeting = NSMenuItem(title: "Record meeting audio while watching", action: #selector(toggleMeetingAudio), keyEquivalent: "")
        meeting.target = self
        meeting.state = WatchSession.recordMeetingAudio ? .on : .off
        menu.addItem(meeting)

        let voice = NSMenuItem(title: "Record my voice into videos", action: #selector(toggleVoice), keyEquivalent: "")
        voice.target = self
        voice.state = VideoSession.includeVoice ? .on : .off
        menu.addItem(voice)

        let builtIn = NSMenuItem(title: "Use Mac mic with Bluetooth headphones", action: #selector(toggleBuiltInMic), keyEquivalent: "")
        builtIn.target = self
        builtIn.state = Transcriber.preferBuiltInMic ? .on : .off
        menu.addItem(builtIn)

        let shortcuts = NSMenu()
        for preset in Shortcut.presets {
            let item = NSMenuItem(title: "\(preset.label) screenshot, \(preset.videoLabel) video, \(preset.documentLabel) document",
                                  action: #selector(pickShortcut(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.label
            item.state = preset == shortcut ? .on : .off
            shortcuts.addItem(item)
        }
        let shortcutItem = NSMenuItem(title: "Shortcut", action: nil, keyEquivalent: "")
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)
        menu.addItem(permissionsItem())
        menu.addItem(.separator())

        let again = NSMenuItem(title: "Paste last capture again", action: lastCapture == nil ? nil : #selector(pasteLastAgain), keyEquivalent: "")
        again.target = self
        menu.addItem(again)
        if lastWatchPage != nil {
            let watchPage = NSMenuItem(title: "Open last watch session", action: #selector(openLastWatch), keyEquivalent: "")
            watchPage.target = self
            menu.addItem(watchPage)
        }
        let library = NSMenuItem(title: "Open recordings library", action: #selector(openLibrary), keyEquivalent: "")
        library.target = self
        menu.addItem(library)
        let copy = NSMenuItem(title: "Copy last recording (to paste into Teams, Slack, mail)",
                              action: lastRecording == nil ? nil : #selector(copyLastRecording), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        let reveal = NSMenuItem(title: "Show last recording in Finder", action: lastRecording == nil ? nil : #selector(revealLastRecording),
                                keyEquivalent: "")
        reveal.target = self
        menu.addItem(reveal)
        let open = NSMenuItem(title: "Open captures folder", action: #selector(openFolder), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Pointer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func pickTarget(_ sender: NSMenuItem) {
        tracker.pinned = sender.representedObject as? String
    }

    @objc private func toggleAutoSend() {
        autoSend.toggle()
    }

    @objc private func toggleVoice() {
        VideoSession.includeVoice.toggle()
    }

    /// Puts the .mov on the clipboard the way Finder copies a file, so ⌘V in a chat or mail attaches it.
    /// A bare file URL is not enough: Teams, Slack and Mail read the older file-name list Finder also writes.
    @objc private func copyLastRecording() {
        guard let url = lastRecording else { return }
        let pasteboard = NSPasteboard.general
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.addTypes([filenames, .string], owner: nil)
        pasteboard.setPropertyList([url.path], forType: filenames)
        pasteboard.setString(url.lastPathComponent, forType: .string)
        hud.flash("Recording copied", hint: "paste it into a chat or email", tone: .done, for: 2)
    }

    /// The most recent recording.mov under the captures folder, so the copy and reveal items work after a relaunch.
    private func newestRecording() -> URL? {
        let folders = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return folders.map { $0.appendingPathComponent("recording.mov") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .max { $0.deletingLastPathComponent().lastPathComponent < $1.deletingLastPathComponent().lastPathComponent }
    }

    @objc private func revealLastRecording() {
        guard let url = lastRecording else { return }
        let captions = url.deletingLastPathComponent().appendingPathComponent("captions.srt")
        let files = FileManager.default.fileExists(atPath: captions.path) ? [url, captions] : [url]
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    @objc private func toggleBuiltInMic() {
        Transcriber.preferBuiltInMic.toggle()
    }

    @objc private func pickShortcut(_ sender: NSMenuItem) {
        guard let preset = Shortcut.presets.first(where: { $0.label == sender.representedObject as? String }) else { return }
        shortcut = preset
        registerShortcut()
    }

    /// Rebuilds the library page (adding pages for any older captures) and opens it in the browser.
    @objc private func openLibrary() {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = Viewer.rebuildLibrary()
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
    }

    @objc private func openFolder() {
        NSWorkspace.shared.open(folder)
    }

    // MARK: Permissions

    private struct Permission {
        let name: String
        let granted: Bool
        let pane: String
    }

    private var permissions: [Permission] {
        [
            Permission(name: "Microphone", granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, pane: "Privacy_Microphone"),
            Permission(name: "Screen Recording", granted: CGPreflightScreenCaptureAccess(), pane: "Privacy_ScreenCapture"),
            Permission(name: "Accessibility (to paste)", granted: AXIsProcessTrusted(), pane: "Privacy_Accessibility"),
        ]
    }

    private func permissionsItem() -> NSMenuItem {
        let list = permissions
        let submenu = NSMenu()
        for permission in list {
            let item = NSMenuItem(title: permission.name, action: #selector(openPermission(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = permission.pane
            item.state = permission.granted ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let relaunch = NSMenuItem(title: "Relaunch Pointer", action: #selector(relaunch), keyEquivalent: "")
        relaunch.target = self
        submenu.addItem(relaunch)

        let missing = list.filter { !$0.granted }.count
        let item = NSMenuItem(title: missing == 0 ? "Permissions" : "Permissions (\(missing) missing)", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func openPermission(_ sender: NSMenuItem) {
        if let pane = sender.representedObject as? String { openSettings(pane) }
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func relaunch() {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", Bundle.main.bundlePath]
        try? open.run()
        NSApp.terminate(nil)
    }

    /// Asks once for each permission that hasn't been decided yet, one after another.
    private func askForPermissions() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
                if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
                if !AXIsProcessTrusted() {
                    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                    AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                }
            }
        }
    }
}
