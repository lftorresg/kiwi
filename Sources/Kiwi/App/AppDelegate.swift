import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var recordingTimer: Timer?
    private var hotKeysRegistered = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()
        registerHotKeys()

        CaptureController.shared.onNeedsSetup = {
            WindowRouter.shared.showSetup()
        }
        CaptureController.shared.onRecentsChange = { [weak self] in
            self?.rebuildStatusMenu()
        }
        RecordingController.shared.onStateChange = { [weak self] recording in
            self?.recordingStateChanged(recording)
        }
        WheelController.shared.setEnabled(Prefs.shared.wheelEnabled)

        DispatchQueue.global(qos: .utility).async {
            CaptureStore.pruneCache()
        }

        if !Prefs.shared.didOnboard || !ScreenGrabber.hasPermission {
            WindowRouter.shared.showSetup()
        }
        if !hotKeysRegistered {
            Toast.error("Another app is using ⇧⌘4")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Working copies of captures do not outlive the session.
        CaptureStore.wipeCache()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowRouter.shared.showSettings()
        return false
    }

    // MARK: Hotkeys

    private func registerHotKeys() {
        let modifiers = cmdKey | shiftKey
        let center = HotKeyCenter.shared
        let area = center.register(keyCode: kVK_ANSI_4, modifiers: modifiers) {
            CaptureController.shared.captureArea()
        }
        let screen = center.register(keyCode: kVK_ANSI_3, modifiers: modifiers) {
            CaptureController.shared.captureScreen()
        }
        center.register(keyCode: kVK_ANSI_2, modifiers: modifiers) {
            CaptureController.shared.editLast()
        }
        center.register(keyCode: kVK_ANSI_5, modifiers: modifiers) {
            CaptureController.shared.toggleRecording()
        }
        center.register(keyCode: kVK_ANSI_6, modifiers: modifiers) {
            CaptureController.shared.captureScrolling()
        }
        hotKeysRegistered = area && screen
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        applyIdleAppearance()
        rebuildStatusMenu()
    }

    /// Builds the menu from scratch. Called again whenever its contents change.
    private func rebuildStatusMenu() {
        let menu = NSMenu()
        let about = NSMenuItem(title: "Kiwi \(BuildInfo.label)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(menuItem("Capture Area", #selector(captureArea), key: "4", symbol: "viewfinder"))
        menu.addItem(menuItem("Capture Window", #selector(captureWindow), symbol: "macwindow"))
        menu.addItem(menuItem("Capture Screen", #selector(captureScreen), key: "3", symbol: "display"))
        menu.addItem(menuItem("Scrolling Capture", #selector(captureScrolling), key: "6", symbol: "arrow.down.to.line.compact"))
        menu.addItem(delayedCaptureItem())
        menu.addItem(.separator())
        menu.addItem(menuItem("Record Area", #selector(recordArea), key: "5", symbol: "record.circle"))
        menu.addItem(menuItem("Record Screen", #selector(recordScreen), symbol: "menubar.dock.rectangle"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Edit Last Capture", #selector(editLast), key: "2", symbol: "pencil.tip.crop.circle"))
        menu.addItem(recentCapturesItem())
        menu.addItem(menuItem("Open Screenshots Folder", #selector(openFolder), symbol: "folder"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettings), symbol: "gearshape"))
        menu.addItem(menuItem("Setup Guide…", #selector(openSetup), symbol: "sparkles"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Kiwi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusMenu = menu
        // While recording, the menu bar item is a stop button with no menu.
        if !RecordingController.shared.isRecording {
            statusItem?.menu = menu
        }
    }

    private func delayedCaptureItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Capture After Delay", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)
        let submenu = NSMenu()
        for seconds in [3, 5, 10] {
            let entry = NSMenuItem(title: "\(seconds) seconds", action: #selector(captureDelayed(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = seconds
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func captureDelayed(_ sender: NSMenuItem) {
        CaptureController.shared.captureAfterDelay(seconds: sender.tag)
    }

    private func recentCapturesItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recent Captures", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let submenu = NSMenu()
        let recents = CaptureController.shared.recents
        if recents.isEmpty {
            let empty = NSMenuItem(title: "No captures yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        for record in recents {
            let entry = NSMenuItem(title: record.name, action: #selector(openRecent(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = record.id.uuidString
            entry.image = record.thumbnail
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text) else { return }
        CaptureController.shared.reopen(id)
    }

    private func applyIdleAppearance() {
        guard let item = statusItem, let button = item.button else { return }
        item.length = NSStatusItem.squareLength
        let image = NSImage(systemSymbolName: "bird.fill", accessibilityDescription: "Kiwi")
        image?.isTemplate = true
        button.image = image
        button.title = image == nil ? "🥝" : ""
        button.imagePosition = .imageLeading
        button.toolTip = "Kiwi"
        button.target = nil
        button.action = nil
    }

    /// While recording, the menu bar item turns into a stop button with a timer.
    private func recordingStateChanged(_ recording: Bool) {
        recordingTimer?.invalidate()
        recordingTimer = nil
        guard let item = statusItem, let button = item.button else { return }

        if recording {
            item.menu = nil
            item.length = NSStatusItem.variableLength
            let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")?
                .withSymbolConfiguration(configuration)
            image?.isTemplate = false
            button.image = image
            button.imagePosition = .imageLeading
            button.toolTip = "Stop recording (⇧⌘5)"
            button.target = self
            button.action = #selector(stopRecording)
            updateRecordingTitle()
            let timer = Timer(
                timeInterval: 1, target: self, selector: #selector(updateRecordingTitle), userInfo: nil, repeats: true
            )
            RunLoop.main.add(timer, forMode: .common)
            recordingTimer = timer
        } else {
            applyIdleAppearance()
            item.menu = statusMenu
        }
    }

    @objc private func updateRecordingTitle() {
        guard let button = statusItem?.button else { return }
        let elapsed = Int(Date().timeIntervalSince(RecordingController.shared.startedAt ?? Date()))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        button.title = " \(minutes):\(seconds < 10 ? "0" : "")\(seconds)"
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", symbol: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if !key.isEmpty {
            item.keyEquivalentModifierMask = [.command, .shift]
        }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// Accessory apps show no menu bar, but a main menu still routes the
    /// standard editing shortcuts (copy, paste, undo) to text fields.
    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Kiwi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    // MARK: Menu actions

    @objc private func captureArea() { CaptureController.shared.captureArea() }
    @objc private func captureWindow() { CaptureController.shared.captureWindow() }
    @objc private func captureScreen() { CaptureController.shared.captureScreen() }
    @objc private func captureScrolling() { CaptureController.shared.captureScrolling() }
    @objc private func recordArea() { CaptureController.shared.toggleRecording() }
    @objc private func recordScreen() { CaptureController.shared.recordScreen() }
    @objc private func stopRecording() { RecordingController.shared.stop() }
    @objc private func editLast() { CaptureController.shared.editLast() }
    @objc private func openFolder() { CaptureController.shared.revealSaveFolder() }
    @objc private func openSettings() { WindowRouter.shared.showSettings() }
    @objc private func openSetup() { WindowRouter.shared.showSetup() }
}
