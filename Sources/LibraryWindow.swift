import AppKit
import WebKit

/// Pointer's own window: the recordings library and each capture's page, shown in the app instead of the browser.
/// The Dock icon and ⌘-Tab bring it up; closing it leaves Pointer running in the menu bar.
@MainActor
final class LibraryWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandler, NSToolbarDelegate {
    static let shared = LibraryWindow()

    /// A capture button in the window's toolbar. Set by AppDelegate before the window first opens.
    struct Action {
        let id: String
        let label: String
        let symbol: String
        let tip: String
        let run: () -> Void
    }
    var actions: [Action] = []

    private var window: NSWindow?
    private var web: WKWebView?
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Pointer", isDirectory: true)

    /// Rebuilds the library (adding pages for any older captures) and shows it.
    func showLibrary() {
        DispatchQueue.global(qos: .userInitiated).async {
            let url = Viewer.rebuildLibrary()
            DispatchQueue.main.async { self.show(url) }
        }
    }

    /// Shows one page (the library or a capture's page) in the window.
    func show(_ page: URL) {
        let web = makeWindowIfNeeded()
        web.loadFileURL(page, allowingReadAccessTo: root)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Brings the window back if it exists, otherwise opens the library.
    func reopen() {
        if let window, web?.url != nil {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        } else {
            showLibrary()
        }
    }

    @objc func goBack() { web?.goBack() }
    @objc func goForward() { web?.goForward() }
    @objc func reload() { web?.reload() }

    private func makeWindowIfNeeded() -> WKWebView {
        if let web { return web }
        let config = WKWebViewConfiguration()
        // navigator.clipboard is refused on file:// pages, so the pages' Copy buttons go through the app instead.
        config.userContentController.add(self, name: "copy")
        config.userContentController.addUserScript(WKUserScript(source: """
            navigator.clipboard.writeText = (text) => { window.webkit.messageHandlers.copy.postMessage(String(text)); return Promise.resolve(); };
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.allowsBackForwardNavigationGestures = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Pointer"
        window.contentView = web
        let toolbar = NSToolbar(identifier: "PointerActions")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("PointerLibrary")
        if !window.setFrameUsingName("PointerLibrary") { window.center() }
        self.window = window
        self.web = web
        return web
    }

    // MARK: Toolbar

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        actions.map { NSToolbarItem.Identifier($0.id) } + [.flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let ids = actions.map { NSToolbarItem.Identifier($0.id) }
        // Capture modes on the left, the folder button on the right.
        return ids.dropLast() + [.flexibleSpace] + ids.suffix(1)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let action = actions.first(where: { $0.id == id.rawValue }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = action.label
        item.toolTip = action.tip
        item.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.label)
        item.isBordered = true
        item.target = self
        item.action = #selector(runAction(_:))
        return item
    }

    @objc private func runAction(_ sender: NSToolbarItem) {
        actions.first { $0.id == sender.itemIdentifier.rawValue }?.run()
    }

    // Capture pages and the library stay in the window; anything on the web opens in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, action.navigationType == .linkActivated, !url.isFileURL else {
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        window?.title = webView.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Pointer"
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The menu bar Pointer shows while it is the front app: the standard App, File, Edit, View and Window menus.
enum MainMenu {
    @MainActor static func install() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
            return menu
        }
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command,
                  target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = target
            return item
        }
        let library = LibraryWindow.shared
        _ = submenu("Pointer", [
            item("About Pointer", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide Pointer", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Pointer", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let open = item("Recordings Library", #selector(MenuActions.openLibrary), "l", target: MenuActions.shared)
        _ = submenu("File", [open, .separator(), item("Close Window", #selector(NSWindow.performClose(_:)), "w")])
        _ = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        _ = submenu("View", [
            item("Back", #selector(LibraryWindow.goBack), "[", target: library),
            item("Forward", #selector(LibraryWindow.goForward), "]", target: library),
            item("Reload", #selector(LibraryWindow.reload), "r", target: library),
        ])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

}

/// Target for main-menu items that are not tied to a window.
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()
    @objc func openLibrary() { LibraryWindow.shared.showLibrary() }
}
