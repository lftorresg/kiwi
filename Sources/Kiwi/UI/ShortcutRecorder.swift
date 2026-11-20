import AppKit
import SwiftUI
import Carbon.HIToolbox

/// A button that shows an action's shortcut and records a new one when clicked.
struct ShortcutRecorder: NSViewRepresentable {
    let action: ShortcutAction
    let shortcut: Shortcut?

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(shortcutAction: action)
        button.shortcut = shortcut
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcut = shortcut
    }
}

/// Click, then press the new keys. Esc cancels, ⌫ removes the shortcut.
/// The key presses are read only while this button is recording, from
/// events sent to Kiwi's own Settings window.
final class ShortcutRecorderButton: NSButton {
    var shortcut: Shortcut? {
        didSet { refreshTitle() }
    }

    private let shortcutAction: ShortcutAction
    private var isRecording = false
    private var monitor: Any?

    init(shortcutAction: ShortcutAction) {
        self.shortcutAction = shortcutAction
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        toolTip = "Click, then press the new shortcut. Esc cancels, ⌫ removes it."
        refreshTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func refreshTitle() {
        if isRecording {
            title = "Press keys…"
        } else {
            title = shortcut?.display ?? "None"
        }
    }

    @objc private func toggleRecording() {
        if isRecording {
            endRecording()
            ShortcutManager.shared.apply()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        guard !isRecording else { return }
        isRecording = true
        // Kiwi's own shortcuts would otherwise fire instead of being recorded.
        ShortcutManager.shared.suspend()
        refreshTitle()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.isRecording else { return event }
            self.record(event)
            return nil
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowLostFocus),
            name: NSWindow.didResignKeyNotification,
            object: hostWindow
        )
    }

    /// Stops listening. The caller decides which shortcuts to register next.
    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        refreshTitle()
    }

    @objc private func windowLostFocus() {
        guard isRecording else { return }
        endRecording()
        ShortcutManager.shared.apply()
    }

    private func record(_ event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let code = Int(event.keyCode)

        if held.isEmpty, code == kVK_Escape {
            endRecording()
            ShortcutManager.shared.apply()
            return
        }
        if held.isEmpty, code == kVK_Delete || code == kVK_ForwardDelete {
            endRecording()
            _ = ShortcutManager.shared.set(nil, for: shortcutAction)
            return
        }
        guard let candidate = Shortcut(event: event), candidate.isUsable else {
            // Needs ⌘, ⌃ or ⌥. Keep listening.
            NSSound.beep()
            return
        }

        endRecording()
        switch ShortcutManager.shared.set(candidate, for: shortcutAction) {
        case .ok:
            break
        case .reserved:
            Toast.error("\(candidate.display) is used by every app, pick another")
        case .duplicate(let other):
            Toast.error("\(candidate.display) is already \(other.shortTitle)")
        case .refused:
            Toast.error("\(candidate.display) is taken by another app")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if hostWindow == nil, isRecording {
            endRecording()
            ShortcutManager.shared.apply()
        }
    }
}
