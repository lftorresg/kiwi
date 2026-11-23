import AppKit
import Carbon.HIToolbox

/// The things Kiwi can do from a global shortcut.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case captureArea
    case captureScreen
    case record
    case recordNow
    case captureScrolling
    case editLast

    var id: String { rawValue }

    var title: String {
        switch self {
        case .captureArea: return "Capture area or window"
        case .captureScreen: return "Capture full screen"
        case .record: return "Open the recording bar (press again to stop)"
        case .recordNow: return "Record straight away with the last settings"
        case .captureScrolling: return "Scrolling capture"
        case .editLast: return "Edit last capture"
        }
    }

    var shortTitle: String {
        switch self {
        case .captureArea: return "Capture area"
        case .captureScreen: return "Capture screen"
        case .record: return "Recording bar"
        case .recordNow: return "Record now"
        case .captureScrolling: return "Scrolling capture"
        case .editLast: return "Edit last capture"
        }
    }

    var defaultShortcut: Shortcut {
        let modifiers = cmdKey | shiftKey
        switch self {
        case .captureArea: return Shortcut(keyCode: kVK_ANSI_4, modifiers: modifiers, key: "4")
        case .captureScreen: return Shortcut(keyCode: kVK_ANSI_3, modifiers: modifiers, key: "3")
        case .record: return Shortcut(keyCode: kVK_ANSI_5, modifiers: modifiers, key: "5")
        case .recordNow: return Shortcut(keyCode: kVK_ANSI_5, modifiers: modifiers | optionKey, key: "5")
        case .captureScrolling: return Shortcut(keyCode: kVK_ANSI_6, modifiers: modifiers, key: "6")
        case .editLast: return Shortcut(keyCode: kVK_ANSI_2, modifiers: modifiers, key: "2")
        }
    }
}

/// A key plus modifiers. `modifiers` is a Carbon mask, which is what the
/// hotkey API takes; `key` is the label shown to the user.
struct Shortcut: Equatable {
    var keyCode: Int
    var modifiers: Int
    var key: String

    init(keyCode: Int, modifiers: Int, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Reads a shortcut from a key press. Nil when the key has no usable label.
    init?(event: NSEvent) {
        let flags = event.modifierFlags
        var mask = 0
        if flags.contains(.command) { mask |= cmdKey }
        if flags.contains(.shift) { mask |= shiftKey }
        if flags.contains(.option) { mask |= optionKey }
        if flags.contains(.control) { mask |= controlKey }

        let code = Int(event.keyCode)
        let label: String
        if let named = Shortcut.namedKeys[code] {
            label = named.label
        } else {
            // The key's own character, whatever modifiers are held.
            let plain = (event.characters(byApplyingModifiers: []) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            guard plain.count == 1, let scalar = plain.unicodeScalars.first else { return nil }
            // Private-use code points are function keys AppKit has no glyph for.
            guard scalar.value < 0xE000 || scalar.value > 0xF8FF else { return nil }
            label = plain
        }
        self.init(keyCode: code, modifiers: mask, key: label)
    }

    /// Restores a shortcut saved with `propertyList`.
    init?(propertyList: [String: Any]) {
        guard let keyCode = propertyList["keyCode"] as? Int,
              let modifiers = propertyList["modifiers"] as? Int,
              let key = propertyList["key"] as? String,
              keyCode >= 0, keyCode < 256, !key.isEmpty, key.count <= 8 else { return nil }
        let known = cmdKey | shiftKey | optionKey | controlKey
        self.init(keyCode: keyCode, modifiers: modifiers & known, key: key)
    }

    var propertyList: [String: Any] {
        ["keyCode": keyCode, "modifiers": modifiers, "key": key]
    }

    /// For example "⇧⌘4".
    var display: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        return text + key
    }

    /// Same keys, whatever the label says.
    func matches(_ other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    /// A global shortcut needs ⌘, ⌃ or ⌥, unless it is a function key.
    var isUsable: Bool {
        if modifiers & (cmdKey | controlKey | optionKey) != 0 { return true }
        return Shortcut.functionKeyCodes.contains(keyCode)
    }

    /// Combinations every app relies on. Taking one of these globally would
    /// break copy, paste, quit and the like everywhere.
    var isReserved: Bool {
        guard modifiers == cmdKey else { return false }
        let taken: Set<String> = [
            "A", "C", "F", "H", "M", "N", "O", "P", "Q", "S", "T", "V", "W", "X", "Z", ",", "Space", "⇥",
        ]
        return taken.contains(key)
    }

    // MARK: Menu display

    var menuModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & cmdKey != 0 { flags.insert(.command) }
        if modifiers & shiftKey != 0 { flags.insert(.shift) }
        if modifiers & optionKey != 0 { flags.insert(.option) }
        if modifiers & controlKey != 0 { flags.insert(.control) }
        return flags
    }

    var menuKey: String {
        Shortcut.namedKeys[keyCode]?.menuKey ?? key.lowercased()
    }

    // MARK: Keys without a printable character

    private static let functionKeyCodes: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
        kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
    ]

    private static let namedKeys: [Int: (label: String, menuKey: String)] = {
        var keys: [Int: (label: String, menuKey: String)] = [
            kVK_Space: ("Space", " "),
            kVK_Return: ("↩", "\r"),
            kVK_Tab: ("⇥", "\t"),
            kVK_Delete: ("⌫", "\u{8}"),
            kVK_ForwardDelete: ("⌦", "\u{7F}"),
            kVK_Escape: ("⎋", "\u{1B}"),
            kVK_LeftArrow: ("←", Shortcut.appKitKey(NSLeftArrowFunctionKey)),
            kVK_RightArrow: ("→", Shortcut.appKitKey(NSRightArrowFunctionKey)),
            kVK_UpArrow: ("↑", Shortcut.appKitKey(NSUpArrowFunctionKey)),
            kVK_DownArrow: ("↓", Shortcut.appKitKey(NSDownArrowFunctionKey)),
        ]
        for (index, code) in Shortcut.functionKeyCodes.enumerated() {
            keys[code] = ("F\(index + 1)", Shortcut.appKitKey(NSF1FunctionKey + index))
        }
        return keys
    }()

    private static func appKitKey(_ code: Int) -> String {
        guard let scalar = Unicode.Scalar(UInt32(code)) else { return "" }
        return String(Character(scalar))
    }
}

/// Keeps the registered global shortcuts in step with the preferences.
@MainActor
final class ShortcutManager {
    static let shared = ShortcutManager()

    enum Outcome {
        case ok
        case reserved
        case duplicate(ShortcutAction)
        case refused
    }

    /// Called after a shortcut changes, so menus can show the new keys.
    var onChange: (() -> Void)?

    private init() {}

    /// Registers every shortcut from scratch. Returns the actions whose
    /// shortcut the system refused, usually because another app owns it.
    @discardableResult
    func apply() -> [ShortcutAction] {
        let center = HotKeyCenter.shared
        center.unregisterAll()
        var refused: [ShortcutAction] = []
        for action in ShortcutAction.allCases {
            guard let shortcut = Prefs.shared.shortcut(for: action) else { continue }
            let registered = center.register(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers) {
                ShortcutManager.shared.perform(action)
            }
            if !registered {
                refused.append(action)
            }
        }
        return refused
    }

    /// Turns the shortcuts off while the user is typing a new one.
    func suspend() {
        HotKeyCenter.shared.unregisterAll()
    }

    /// Changes one shortcut (nil removes it) and registers the result.
    /// Nothing changes unless the outcome is `.ok`.
    func set(_ shortcut: Shortcut?, for action: ShortcutAction) -> Outcome {
        let prefs = Prefs.shared
        if let shortcut {
            if shortcut.isReserved {
                apply()
                return .reserved
            }
            let clash = ShortcutAction.allCases.first { other in
                other != action && prefs.shortcut(for: other)?.matches(shortcut) == true
            }
            if let clash {
                apply()
                return .duplicate(clash)
            }
        }

        let previous = prefs.shortcut(for: action)
        prefs.setShortcut(shortcut, for: action)
        if apply().contains(action) {
            prefs.setShortcut(previous, for: action)
            apply()
            return .refused
        }
        onChange?()
        return .ok
    }

    func restoreDefaults() {
        var defaults: [String: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            defaults[action.rawValue] = action.defaultShortcut
        }
        Prefs.shared.shortcuts = defaults
        apply()
        onChange?()
    }

    private func perform(_ action: ShortcutAction) {
        let capture = CaptureController.shared
        switch action {
        case .captureArea: capture.captureArea()
        case .captureScreen: capture.captureScreen()
        case .record: capture.toggleRecording()
        case .recordNow: capture.recordNow()
        case .captureScrolling: capture.captureScrolling()
        case .editLast: capture.editLast()
        }
    }
}
