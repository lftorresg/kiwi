import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey.
/// This path needs no Accessibility or Input Monitoring permission.
///
/// Carbon is a C API, so the calls below are marked `unsafe`. Kiwi passes it
/// only stack values and never stores, dereferences or frees what it returns:
/// hotkeys stay registered for the life of the process.
final class HotKeyCenter: @unchecked Sendable {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
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
        var reference: EventHotKeyRef?
        let status = unsafe RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr else { return false }
        handlers[id] = handler
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
        let status = unsafe InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = unsafe GetEventParameter(
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
