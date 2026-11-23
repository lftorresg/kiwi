import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var refusedShortcuts: [ShortcutAction] = []

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
        RecordingController.shared.onRecentChange = { [weak self] in
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
        if let refused = refusedShortcuts.first, let keys = Prefs.shared.shortcut(for: refused) {
            Toast.error("Another app is using \(keys.display)")
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
        refusedShortcuts = ShortcutManager.shared.apply()
        ShortcutManager.shared.onChange = { [weak self] in
            self?.rebuildStatusMenu()
        }
    }

    // MARK: Status item

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
        menu.addItem(menuItem("Capture Area", #selector(captureArea), keys: .captureArea, symbol: "viewfinder"))
        menu.addItem(menuItem("Capture Window", #selector(captureWindow), symbol: "macwindow"))
        menu.addItem(menuItem("Capture Screen", #selector(captureScreen), keys: .captureScreen, symbol: "display"))
        menu.addItem(menuItem("Scrolling Capture", #selector(captureScrolling), keys: .captureScrolling, symbol: "arrow.down.to.line.compact"))
        menu.addItem(delayedCaptureItem())
        menu.addItem(.separator())
        menu.addItem(menuItem("Record…", #selector(recordArea), keys: .record, symbol: "record.circle"))
        menu.addItem(menuItem("Record Now", #selector(recordNow), keys: .recordNow, symbol: "record.circle.fill"))
        menu.addItem(menuItem("Make GIF of Last Recording", #selector(gifLast), symbol: "photo.stack"))
        menu.addItem(.separator())
        menu.addItem(menuItem("Edit Last Capture", #selector(editLast), keys: .editLast, symbol: "pencil.tip.crop.circle"))
        menu.addItem(menuItem("Pin Last Capture", #selector(pinLast), symbol: "pin"))
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
        let recordings = RecordingController.shared.recent.filter { FileManager.default.fileExists(atPath: $0.path) }
        if recents.isEmpty, recordings.isEmpty {
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
        if !recents.isEmpty, !recordings.isEmpty {
            submenu.addItem(.separator())
        }
        for url in recordings {
            let entry = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecording(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = url.path
            entry.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        VideoEditorCoordinator.shared.open(URL(fileURLWithPath: path))
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
        // Kiwi's menu bar item hides for the length of a recording. Profiles
        // of recordings showed that most of Kiwi's processor time was AppKit
        // redrawing this item again and again for every screen's menu bar,
        // whatever it displayed. With no item there is nothing to redraw.
        // The Stop pill, the shortcut and the recording control that macOS
        // itself puts in the menu bar all still stop the recording.
        statusItem?.isVisible = !recording
        if !recording {
            applyIdleAppearance()
            statusItem?.menu = statusMenu
        }
    }

    /// `keys` names the global shortcut to show beside the item, if it has one.
    private func menuItem(
        _ title: String, _ action: Selector, keys: ShortcutAction? = nil, symbol: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let keys, let shortcut = Prefs.shared.shortcut(for: keys) {
            item.keyEquivalent = shortcut.menuKey
            item.keyEquivalentModifierMask = shortcut.menuModifiers
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
    @objc private func recordNow() { CaptureController.shared.recordNow() }
    @objc private func gifLast() { CaptureController.shared.makeGIFOfLastRecording() }
    @objc private func editLast() { CaptureController.shared.editLast() }
    @objc private func pinLast() { CaptureController.shared.pinLast() }
    @objc private func openFolder() { CaptureController.shared.revealSaveFolder() }
    @objc private func openSettings() { WindowRouter.shared.showSettings() }
    @objc private func openSetup() { WindowRouter.shared.showSetup() }
}
