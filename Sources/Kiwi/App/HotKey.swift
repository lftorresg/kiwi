import AppKit
import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey.
/// This path needs no Accessibility or Input Monitoring permission.
///
/// Carbon is a C API, so the calls below are marked `unsafe`. Kiwi passes it
/// only stack values. The handle Carbon returns for each hotkey is opaque:
/// Kiwi keeps it as a plain number, never dereferences or frees it, and only
/// hands it back to Carbon to unregister that hotkey.
final class HotKeyCenter: @unchecked Sendable {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    /// Carbon's handles for the registered hotkeys, kept as bit patterns.
    private var references: [UInt] = []
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
        references.append(UInt(bitPattern: reference))
        return true
    }

    /// Removes every hotkey, so a new set can be registered.
    func unregisterAll() {
        for bits in references where bits != 0 {
            let status = unsafe UnregisterEventHotKey(EventHotKeyRef(bitPattern: bits))
            if status != noErr {
                NSLog("Kiwi: could not unregister a hotkey (%d)", status)
            }
        }
        references.removeAll()
        handlers.removeAll()
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
