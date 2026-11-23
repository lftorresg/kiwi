import Foundation
import Combine

/// User preferences, backed by UserDefaults.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    private enum Key {
        static let copyOnCapture = "copyOnCapture"
        static let saveOnCapture = "saveOnCapture"
        static let saveFolder = "saveFolder"
        static let playSound = "playSound"
        static let showCursor = "showCursor"
        static let previewSeconds = "previewSeconds"
        static let wheelEnabled = "wheelEnabled"
        static let didOnboard = "didOnboard"
        static let autoRedact = "autoRedact"
        static let redactFaces = "redactFaces"
        static let redactCategories = "redactCategories"
        static let convertQuality = "convertQuality"
        static let recordSystemAudio = "recordSystemAudio"
        static let editAfterCapture = "editAfterCapture"
        static let recordHEVC = "recordHEVC"
        static let shortcuts = "shortcuts"
        static let recordMicrophone = "recordMicrophone"
        static let excludedApps = "excludedApps"
        static let recordTarget = "recordTarget"
        static let recordMaxHeight = "recordMaxHeight"
        static let recordFrameRate = "recordFrameRate"
    }

    @Published var copyOnCapture: Bool {
        didSet { UserDefaults.standard.set(copyOnCapture, forKey: Key.copyOnCapture) }
    }
    @Published var saveOnCapture: Bool {
        didSet { UserDefaults.standard.set(saveOnCapture, forKey: Key.saveOnCapture) }
    }
    @Published var saveFolder: String {
        didSet { UserDefaults.standard.set(saveFolder, forKey: Key.saveFolder) }
    }
    @Published var playSound: Bool {
        didSet { UserDefaults.standard.set(playSound, forKey: Key.playSound) }
    }
    @Published var showCursor: Bool {
        didSet { UserDefaults.standard.set(showCursor, forKey: Key.showCursor) }
    }
    @Published var previewSeconds: Double {
        didSet { UserDefaults.standard.set(previewSeconds, forKey: Key.previewSeconds) }
    }
    @Published var wheelEnabled: Bool {
        didSet { UserDefaults.standard.set(wheelEnabled, forKey: Key.wheelEnabled) }
    }
    /// Bundle identifiers of apps whose drags never bring up the wheel.
    @Published var excludedApps: [String] {
        didSet { UserDefaults.standard.set(excludedApps, forKey: Key.excludedApps) }
    }
    @Published var didOnboard: Bool {
        didSet { UserDefaults.standard.set(didOnboard, forKey: Key.didOnboard) }
    }

    /// Redact sensitive text in every capture before it is copied or saved.
    @Published var autoRedact: Bool {
        didSet { UserDefaults.standard.set(autoRedact, forKey: Key.autoRedact) }
    }
    @Published var redactFaces: Bool {
        didSet { UserDefaults.standard.set(redactFaces, forKey: Key.redactFaces) }
    }
    @Published var redactCategories: Set<PIICategory> {
        didSet {
            UserDefaults.standard.set(redactCategories.map(\.rawValue).sorted(), forKey: Key.redactCategories)
        }
    }

    /// Quality for lossy conversions on the wheel, 0.5 to 1.
    @Published var convertQuality: Double {
        didSet { UserDefaults.standard.set(convertQuality, forKey: Key.convertQuality) }
    }
    @Published var recordSystemAudio: Bool {
        didSet { UserDefaults.standard.set(recordSystemAudio, forKey: Key.recordSystemAudio) }
    }

    /// Record your voice along with the screen. Off unless you turn it on.
    @Published var recordMicrophone: Bool {
        didSet { UserDefaults.standard.set(recordMicrophone, forKey: Key.recordMicrophone) }
    }

    /// Tallest video Kiwi records, in pixels. 0 keeps the screen's own
    /// resolution (up to 4K). Smaller is lighter on the Mac and on disk.
    @Published var recordMaxHeight: Int {
        didSet { UserDefaults.standard.set(recordMaxHeight, forKey: Key.recordMaxHeight) }
    }
    /// Frames a second: 60 is smoother, 30 takes about half the work.
    @Published var recordFrameRate: Int {
        didSet { UserDefaults.standard.set(recordFrameRate, forKey: Key.recordFrameRate) }
    }

    /// For menus: "1080p · 30 fps".
    var recordQualityTitle: String {
        let size = recordMaxHeight == 0 ? "Native" : "\(recordMaxHeight)p"
        return "\(size) · \(recordFrameRate) fps"
    }

    /// What the recording bar was last set to record.
    @Published var recordTarget: RecordTarget {
        didSet { UserDefaults.standard.set(recordTarget.rawValue, forKey: Key.recordTarget) }
    }

    /// Record in HEVC (sharper and smaller) instead of H.264 (plays in more places).
    @Published var recordHEVC: Bool {
        didSet { UserDefaults.standard.set(recordHEVC, forKey: Key.recordHEVC) }
    }

    /// Open the editor straight after a capture instead of showing the corner preview.
    @Published var editAfterCapture: Bool {
        didSet { UserDefaults.standard.set(editAfterCapture, forKey: Key.editAfterCapture) }
    }

    /// Global shortcuts, keyed by `ShortcutAction` raw value.
    /// An action without an entry has no shortcut.
    @Published var shortcuts: [String: Shortcut] {
        didSet { UserDefaults.standard.set(Prefs.encode(shortcuts), forKey: Key.shortcuts) }
    }

    func shortcut(for action: ShortcutAction) -> Shortcut? {
        shortcuts[action.rawValue]
    }

    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) {
        shortcuts[action.rawValue] = shortcut
    }

    private static func encode(_ shortcuts: [String: Shortcut]) -> [String: Any] {
        var stored: [String: Any] = [:]
        for action in ShortcutAction.allCases {
            // "off" records that the user removed a shortcut, so the default does not come back.
            let off: [String: Any] = ["off": true]
            stored[action.rawValue] = shortcuts[action.rawValue]?.propertyList ?? off
        }
        return stored
    }

    private static func decodeShortcuts(_ stored: [String: Any]) -> [String: Shortcut] {
        var shortcuts: [String: Shortcut] = [:]
        for action in ShortcutAction.allCases {
            guard let entry = stored[action.rawValue] as? [String: Any] else {
                shortcuts[action.rawValue] = action.defaultShortcut
                continue
            }
            if entry["off"] as? Bool == true { continue }
            // An entry that cannot be read falls back to the default.
            shortcuts[action.rawValue] = Shortcut(propertyList: entry) ?? action.defaultShortcut
        }
        return shortcuts
    }

    var saveFolderURL: URL { URL(fileURLWithPath: saveFolder, isDirectory: true) }

    var redactOptions: PIIScanner.Options {
        PIIScanner.Options(categories: redactCategories, faces: redactFaces)
    }

    private init() {
        let defaults = UserDefaults.standard
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
        let defaultFolder = pictures.appendingPathComponent("Kiwi").path
        let allCategories = PIICategory.allCases.map(\.rawValue)

        defaults.register(defaults: [
            Key.copyOnCapture: true,
            Key.saveOnCapture: false,
            Key.saveFolder: defaultFolder,
            Key.playSound: true,
            Key.showCursor: false,
            Key.previewSeconds: 6.0,
            Key.wheelEnabled: true,
            Key.didOnboard: false,
            Key.autoRedact: false,
            Key.redactFaces: false,
            Key.redactCategories: allCategories,
            Key.convertQuality: 0.9,
            Key.recordSystemAudio: false,
            Key.editAfterCapture: true,
            Key.recordHEVC: true,
            Key.recordMicrophone: false,
            Key.recordMaxHeight: 0,
            Key.recordFrameRate: 60,
        ])

        copyOnCapture = defaults.bool(forKey: Key.copyOnCapture)
        saveOnCapture = defaults.bool(forKey: Key.saveOnCapture)
        saveFolder = defaults.string(forKey: Key.saveFolder) ?? defaultFolder
        playSound = defaults.bool(forKey: Key.playSound)
        showCursor = defaults.bool(forKey: Key.showCursor)
        previewSeconds = defaults.double(forKey: Key.previewSeconds)
        wheelEnabled = defaults.bool(forKey: Key.wheelEnabled)
        didOnboard = defaults.bool(forKey: Key.didOnboard)
        autoRedact = defaults.bool(forKey: Key.autoRedact)
        redactFaces = defaults.bool(forKey: Key.redactFaces)
        let storedCategories = defaults.stringArray(forKey: Key.redactCategories) ?? allCategories
        redactCategories = Set(storedCategories.compactMap { PIICategory(rawValue: $0) })
        let quality = defaults.double(forKey: Key.convertQuality)
        convertQuality = min(1, max(0.5, quality == 0 ? 0.9 : quality))
        recordSystemAudio = defaults.bool(forKey: Key.recordSystemAudio)
        editAfterCapture = defaults.bool(forKey: Key.editAfterCapture)
        recordHEVC = defaults.bool(forKey: Key.recordHEVC)
        recordMicrophone = defaults.bool(forKey: Key.recordMicrophone)
        excludedApps = defaults.stringArray(forKey: Key.excludedApps) ?? []
        let storedHeight = defaults.integer(forKey: Key.recordMaxHeight)
        recordMaxHeight = [0, 720, 1080, 1440, 2160].contains(storedHeight) ? storedHeight : 0
        recordFrameRate = defaults.integer(forKey: Key.recordFrameRate) == 30 ? 30 : 60
        recordTarget = RecordTarget(rawValue: defaults.string(forKey: Key.recordTarget) ?? "") ?? .area
        shortcuts = Prefs.decodeShortcuts(defaults.dictionary(forKey: Key.shortcuts) ?? [:])
    }
}
