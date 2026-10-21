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
        installCaptureMenu()
        DistributedNotificationCenter.default().addObserver(forName: Control.name, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo as? [String: String], let id = info["id"] else { return }
            MainActor.assumeIsolated { self?.handleControl(id: id, info: info) }
        }
        hud.flash("Pointer is ready", hint: "\(shortcut.label) shot   \(shortcut.videoLabel) video   \(shortcut.documentLabel) doc   \(shortcut.watchLabel) watch   \(shortcut.listenLabel) listen", tone: .live, for: 2.5)
    }

    /// Clicking the Dock icon, or opening Pointer again from Finder or Spotlight, shows the recordings library.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { LibraryWindow.shared.reopen() }
        return true
    }

    /// The window's toolbar buttons, and a Capture menu in Pointer's own menu bar built from the same list as the
    /// menu-bar icon's menu. Toolbar buttons hide Pointer first, so the capture sees the app you were in and pastes
    /// back into it, not into Pointer's window.
    private func installCaptureMenu() {
        func fromWindow(_ start: @escaping () -> Void) -> () -> Void {
            { NSApp.hide(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: start) }
        }
        MainActor.assumeIsolated {
            LibraryWindow.shared.actions = [
                .init(id: "shot", label: "Screenshot", symbol: "camera.viewfinder",
                      tip: "Talk and drag-select an area (\(shortcut.label))", run: fromWindow { [weak self] in self?.shortcutPressed(.screenshot) }),
                .init(id: "video", label: "Record", symbol: "record.circle",
                      tip: "Record the screen, press again to stop (\(shortcut.videoLabel))", run: fromWindow { [weak self] in self?.shortcutPressed(.video) }),
                .init(id: "doc", label: "Document", symbol: "doc.text.viewfinder",
                      tip: "Read the front window as you scroll (\(shortcut.documentLabel))", run: fromWindow { [weak self] in self?.shortcutPressed(.document) }),
                .init(id: "watch", label: "Watch", symbol: "eye",
                      tip: "Silent session, written up when you stop (\(shortcut.watchLabel))", run: fromWindow { [weak self] in self?.shortcutPressed(.watch) }),
                .init(id: "listen", label: "Listen", symbol: "ear",
                      tip: "Watch and suggest questions (\(shortcut.listenLabel))", run: fromWindow { [weak self] in self?.shortcutPressed(.listen) }),
                .init(id: "folder", label: "Captures", symbol: "folder",
                      tip: "Open ~/Pictures/Pointer in Finder", run: { [weak self] in self?.openFolder() }),
            ]
            let capture = NSMenuItem(title: "Capture", action: nil, keyEquivalent: "")
            let menu = NSMenu(title: "Capture")
            menu.delegate = self
            capture.submenu = menu
            NSApp.mainMenu?.insertItem(capture, at: 2)
        }
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
        if kind == .watch { return watching == nil ? chooseAndWatch(listen: false) : watching?.shortcutPressed() ?? () }
        if kind == .listen { return watching == nil ? chooseAndWatch(listen: true) : watching?.shortcutPressed() ?? () }
        if let session { return session.shortcutPressed() }
        switch kind {
        case .screenshot: startCapture()
        case .video: chooseAndRecord()
        case .document: startDocument()
        case .watch, .listen: break
        }
    }

    /// Watch mode: a silent session that records and writes itself up, with nothing pasted anywhere.
    @objc private func startWatching() { chooseAndWatch(listen: false) }

    /// Listen and ask: watch mode that also suggests questions worth asking as you listen.
    @objc private func startListening() { chooseAndWatch(listen: true) }

    /// Asks which screen or window to watch, like Zoom's Share Screen, then starts.
    private func chooseAndWatch(listen: Bool) {
        guard watching == nil else { return watching?.shortcutPressed() ?? () }
        guard CGPreflightScreenCaptureAccess() else { return beginWatch(listen: listen, share: nil) }
        MainActor.assumeIsolated {
            SharePicker.shared.choose(title: listen ? "Choose what to listen along to" : "Choose what to watch", allowArea: false) { [weak self] target in
                if let target { self?.beginWatch(listen: listen, share: target) }
            }
        }
    }

    /// Asks which screen or window to record, or an area to drag out, then starts.
    private func chooseAndRecord() {
        guard session == nil else { return }
        guard CGPreflightScreenCaptureAccess() else { return record(.screen) }
        MainActor.assumeIsolated {
            SharePicker.shared.choose(title: "Choose what to record", allowArea: true) { [weak self] target in
                guard let self, let target else { return }
                if case .area = target { self.record(.area) } else { self.record(.screen, share: target) }
            }
        }
    }

    private func beginWatch(listen: Bool, share: ShareTarget?) {
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
        session.share = share
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
        if let page = lastWatchPage { MainActor.assumeIsolated { LibraryWindow.shared.show(page) } }
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
        chooseAndRecord()
    }

    @objc private func startAreaVideo() {
        record(.area)
    }

    @objc private func startDocument() {
        record(.document)
    }

    private func record(_ mode: VideoSession.Mode, share: ShareTarget? = nil) {
        guard let target = readyTarget() else { return }
        let stop = mode == .document ? shortcut.documentLabel : shortcut.videoLabel
        let session = VideoSession(mode: mode, target: target, hud: hud, autoSend: autoSend, stopLabel: stop,
                                   capturesFolder: folder, share: share) { [weak self] record in
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
        // The Capture menu in Pointer's own menu bar reuses this list; its single-letter keys would clash with ⌘V, ⌘W and ⌘Q.
        defer { if menu !== statusItem.menu { menu.items.forEach { $0.keyEquivalent = "" } } }

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
            let stop = NSMenuItem(title: "Stop recording", action: #selector(stopActive), keyEquivalent: "")
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

    /// Rebuilds the library page (adding pages for any older captures) and shows it in Pointer's window.
    @objc private func openLibrary() {
        MainActor.assumeIsolated { LibraryWindow.shared.showLibrary() }
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

// MARK: Control from chat

extension AppDelegate {
    /// One request from `Pointer --ctl`. Every path writes exactly one reply.
    @MainActor fileprivate func handleControl(id: String, info: [String: String]) {
        let cmd = info["cmd"] ?? "", target = info["target"] ?? ""
        Log.write("control: \(cmd) \(target)")
        switch cmd {
        case "targets":
            Task { @MainActor in
                let all = await Control.sources()
                Control.reply(id, ["ok": true, "targets": all.map(\.json)])
            }
        case "start", "watch", "record", "listen":
            if let watching {
                return Control.reply(id, ["ok": false, "error": "Already watching", "folder": watching.folder.path,
                                          "elapsed": Int(watching.elapsed)])
            }
            guard CGPreflightScreenCaptureAccess() else {
                return Control.reply(id, ["ok": false, "error": "Pointer needs Screen Recording permission"])
            }
            Task { @MainActor in
                let (source, all) = await Control.resolve(target)
                guard let source else {
                    return Control.reply(id, ["ok": false, "error": "No screen or window matches \"\(target)\"",
                                              "targets": all.map(\.json)])
                }
                self.beginWatch(listen: cmd == "listen" || info["listen"] == "1", share: source.target)
                guard let session = self.watching else {
                    return Control.reply(id, ["ok": false, "error": "The session did not start"])
                }
                // Wait for the recorder to come up so the reply says whether it is really recording.
                for _ in 0..<50 where !session.isLive { try? await Task.sleep(for: .milliseconds(100)) }
                Control.reply(id, ["ok": session.isLive, "folder": session.folder.path, "watching": source.json,
                                   "listen": session.listen, "error": session.isLive ? NSNull() : "Recorder did not start within 5 s" as Any])
            }
        case "stop":
            guard let session = watching else {
                return Control.reply(id, ["ok": false, "error": "Nothing is being watched", "writingUp": writingUp.map(\.folder.path)])
            }
            let seconds = Int(session.elapsed)
            session.shortcutPressed()
            Control.reply(id, ["ok": true, "folder": session.folder.path, "seconds": seconds,
                               "note": "Writing up in the background; session.json drops processing when done"])
        case "cancel":
            guard let session = watching else { return Control.reply(id, ["ok": false, "error": "Nothing is being watched"]) }
            let folder = session.folder.path
            discardWatching()
            Control.reply(id, ["ok": true, "discarded": folder])
        case "status":
            var body: [String: Any] = ["ok": true, "watching": watching != nil, "writingUp": writingUp.map(\.folder.path),
                                       "capture": session != nil]
            if let watching {
                body["folder"] = watching.folder.path
                body["elapsed"] = Int(watching.elapsed)
                body["listen"] = watching.listen
            }
            Control.reply(id, body)
        case "peek":
            guard let session = watching, session.isLive else { return Control.reply(id, ["ok": false, "error": "Nothing is being watched"]) }
            let minutes = Double(target).map { $0 * 60 } ?? 180
            Task { @MainActor in
                let image = await Control.screenshot(session.watched)
                var body: [String: Any] = ["ok": true, "folder": session.folder.path, "elapsed": Int(session.elapsed),
                                           "said": session.recentTranscript(seconds: minutes),
                                           "context": Array(session.contextLines.suffix(8))]
                if let image { body["screenshot"] = image.path } else { body["screenshotError"] = "Could not capture the screen" }
                Control.reply(id, body)
            }
        default:
            Control.reply(id, ["ok": false, "error": "Unknown command \(cmd)"])
        }
    }
}
