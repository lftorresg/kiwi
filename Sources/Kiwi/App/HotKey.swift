import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey.
/// This path needs no Accessibility or Input Monitoring permission.
final class HotKeyCenter: @unchecked Sendable {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    /// Registers a hotkey. Returns false when the system refuses it
    /// (usually because another app already owns the combination).
    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4B495749), id: id) // 'KIWI'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        handlers[id] = handler
        refs[id] = ref
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        DispatchQueue.main.async {
            self.handlers[id]?()
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if status == noErr {
                    HotKeyCenter.shared.fire(hotKeyID.id)
                }
                return noErr
            },
            1,
            &spec,
            nil,
            nil
        )
        if status != noErr {
            NSLog("Kiwi: could not install hotkey handler (%d)", status)
        }
    }
}
