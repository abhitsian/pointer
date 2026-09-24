import AppKit
import Carbon

/// A system-wide shortcut registered through Carbon. Works without Input Monitoring permission.
final class HotKey {
    static let keyC: UInt32 = 8
    static let keyV: UInt32 = 9
    static let keyD: UInt32 = 2
    static let keyW: UInt32 = 13
    static let keyQ: UInt32 = 12
    static let keySpace: UInt32 = 49
    static let keyReturn: UInt32 = 36
    static let keyEscape: UInt32 = 53

    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var installed = false

    private var ref: EventHotKeyRef?
    private let id: UInt32
    let registered: Bool

    init(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        HotKey.installHandler()
        id = HotKey.nextID
        HotKey.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_544C), id: id) // 'SHTL'
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        registered = status == noErr
        if registered { HotKey.handlers[id] = handler }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        HotKey.handlers[id] = nil
    }

    deinit { unregister() }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let handler = HotKey.handlers[hotKeyID.id]
            DispatchQueue.main.async { handler?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// The shortcut choices offered in the menu. Video and document use the same modifiers with V and D.
struct Shortcut: Equatable {
    let label: String
    let keyCode: UInt32
    let modifiers: UInt32
    let menuKey: String
    let menuModifiers: NSEvent.ModifierFlags

    /// The modifier symbols, e.g. "⌃⌥".
    var prefix: String { label.hasSuffix("Space") ? String(label.dropLast(5)) : String(label.dropLast()) }
    var videoLabel: String { prefix + "V" }
    var documentLabel: String { prefix + "D" }
    var watchLabel: String { prefix + "W" }
    var listenLabel: String { prefix + "Q" }

    static let presets: [Shortcut] = [
        Shortcut(label: "⌃⌥C", keyCode: HotKey.keyC, modifiers: UInt32(controlKey | optionKey),
                 menuKey: "c", menuModifiers: [.control, .option]),
        Shortcut(label: "⌥⇧Space", keyCode: HotKey.keySpace, modifiers: UInt32(optionKey | shiftKey),
                 menuKey: " ", menuModifiers: [.option, .shift]),
        Shortcut(label: "⌃⌥⌘C", keyCode: HotKey.keyC, modifiers: UInt32(controlKey | optionKey | cmdKey),
                 menuKey: "c", menuModifiers: [.control, .option, .command]),
    ]
}
