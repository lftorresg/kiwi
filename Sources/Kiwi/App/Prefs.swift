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
    }
}
