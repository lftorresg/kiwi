import AppKit
import AVKit

/// Keeps video editor windows alive while they are open.
@MainActor
final class VideoEditorCoordinator {
    static let shared = VideoEditorCoordinator()
    private var controllers: [VideoEditorController] = []

    private init() {}

    func open(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            Toast.error("That recording is no longer there")
            return
        }
        if let existing = controllers.first(where: { $0.url.path == url.path }) {
            existing.show()
            return
        }
        let controller = VideoEditorController(url: url)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.show()
    }
}

/// A window for one recording: play it, trim it, remove its sound, and
/// save, copy, convert or delete it. Trimming uses the system's own trim bar.
@MainActor
final class VideoEditorController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private(set) var url: URL
    var onClose: (() -> Void)?

    private let window: NSWindow
    private let playerView = AVPlayerView()
    private let player: AVPlayer

    /// The part to keep, once a trim has been confirmed.
    private var trim: CMTimeRange?
    private var muted = false
    private var isBusy = false
    private var closesAfterSave = false

    private var muteItem: NSToolbarItem?
    private var saveItem: NSToolbarItem?

    private var hasEdits: Bool { trim != nil || muted }

    init(url: URL) {
        self.url = url
        self.player = AVPlayer(url: url)

        let visible = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1040, visible.width * 0.8)
        let height = min(680, visible.height * 0.8)
        let frame = NSRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        self.window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 560, height: 380)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "kiwi.video")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false
        window.contentView = playerView
        window.setFrame(frame, display: false)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasEdits, !isBusy else { return !isBusy }
        let alert = NSAlert()
        alert.messageText = "Save the changes to this recording?"
        alert.informativeText = "The trim and sound changes have not been saved yet."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            closesAfterSave = true
            saveEdits(then: nil)
            return false
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        let handler = onClose
        after(0.3) {
            handler?()
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.videoTrim, .videoMute, .flexibleSpace, .videoSave, .videoCopy, .videoGIF, .videoConvert, .videoReveal, .videoDelete]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case .videoTrim:
            return button(identifier, "Trim", "timeline.selection", #selector(trimPicked),
                          tip: "Trim: drag the yellow handles, then press Trim")
        case .videoMute:
            let item = button(identifier, "Mute", "speaker.wave.2", #selector(mutePicked),
                              tip: "Remove the sound from this recording")
            muteItem = item
            return item
        case .videoSave:
            let item = button(identifier, "Save", "square.and.arrow.down", #selector(savePicked),
                              tip: "Save the trim and sound changes. The untouched recording goes to the Trash.")
            item.autovalidates = false
            item.isEnabled = hasEdits
            saveItem = item
            return item
        case .videoCopy:
            return button(identifier, "Copy", "doc.on.doc", #selector(copyPicked), tip: "Copy the video file")
        case .videoGIF:
            return button(identifier, "GIF", "photo.stack", #selector(gifPicked), tip: "Make an animated GIF")
        case .videoConvert:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Convert"
            item.image = Self.symbol("arrow.triangle.2.circlepath", "Convert")
            item.toolTip = "Save a copy in another format"
            let menu = NSMenu()
            let choices: [(String, Int)] = [("MP4 (H.264)", 0), ("MP4 (HEVC)", 1), ("MOV", 2), ("Audio only (M4A)", 3)]
            for (title, tag) in choices {
                let entry = NSMenuItem(title: title, action: #selector(convertPicked(_:)), keyEquivalent: "")
                entry.target = self
                entry.tag = tag
                menu.addItem(entry)
            }
            item.menu = menu
            return item
        case .videoReveal:
            return button(identifier, "Show", "folder", #selector(revealPicked), tip: "Show in Finder")
        case .videoDelete:
            return button(identifier, "Delete", "trash", #selector(deletePicked), tip: "Move this recording to the Trash")
        default:
            return nil
        }
    }

    private func button(
        _ identifier: NSToolbarItem.Identifier, _ label: String, _ symbolName: String, _ action: Selector, tip: String
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.image = Self.symbol(symbolName, label)
        item.toolTip = tip
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    private func refresh() {
        saveItem?.isEnabled = hasEdits && !isBusy
        muteItem?.label = muted ? "Muted" : "Mute"
        muteItem?.image = Self.symbol(muted ? "speaker.slash.fill" : "speaker.wave.2", "Mute")
        window.isDocumentEdited = hasEdits
    }

    // MARK: Editing

    @objc private func trimPicked() {
        guard playerView.canBeginTrimming else {
            Toast.error("This video can't be trimmed")
            return
        }
        playerView.beginTrimming { [weak self] result in
            MainActor.assumeIsolated {
                self?.finishTrimming(confirmed: result == .okButton)
            }
        }
    }

    private func finishTrimming(confirmed: Bool) {
        guard confirmed, let item = player.currentItem else { return }
        let start = item.reversePlaybackEndTime
        let end = item.forwardPlaybackEndTime
        guard start.isValid, end.isValid, start.isNumeric, end.isNumeric, end > start else { return }
        trim = CMTimeRange(start: start, end: end)
        refresh()
    }

    @objc private func mutePicked() {
        muted.toggle()
        player.isMuted = muted
        refresh()
    }

    @objc private func savePicked() {
        saveEdits(then: nil)
    }

    /// Writes the trimmed or silenced video, then swaps it in: the untouched
    /// recording goes to the Trash and the edited one takes its name.
    /// `action` runs with the file once there is nothing left to save.
    private func saveEdits(then action: (@MainActor (URL) -> Void)?) {
        guard hasEdits else {
            action?(url)
            return
        }
        guard !isBusy else { return }
        isBusy = true
        refresh()
        player.pause()

        let source = url
        let range = trim
        let silent = muted
        let panel = ProgressPanel.shared
        panel.begin(title: "Saving the recording")
        panel.update(detail: source.lastPathComponent)

        Task { @MainActor in
            do {
                let edited = try await MediaEngine.exportEdited(source, range: range, muted: silent) { fraction in
                    Task { @MainActor in panel.update(fraction: fraction) }
                }
                panel.end()
                self.player.replaceCurrentItem(with: nil)
                let saved = try Self.swap(edited, for: source)
                self.url = saved
                self.trim = nil
                self.muted = false
                self.player.isMuted = false
                self.player.replaceCurrentItem(with: AVPlayerItem(url: saved))
                self.window.title = saved.lastPathComponent
                RecordingController.shared.replace(source, with: saved)
                self.isBusy = false
                self.refresh()
                Toast.show("Saved", symbol: "checkmark.circle.fill")
                if self.closesAfterSave {
                    self.window.close()
                } else {
                    action?(saved)
                }
            } catch {
                panel.end()
                self.isBusy = false
                self.closesAfterSave = false
                self.refresh()
                NSLog("Kiwi: saving a recording failed: %@", error.localizedDescription)
                Toast.error("Couldn't save the recording")
            }
        }
    }

    /// Puts `edited` where `original` was. The original is moved to the Trash,
    /// so it can still be recovered.
    private static func swap(_ edited: URL, for original: URL) throws -> URL {
        let fm = FileManager.default
        try Trash.move(original)
        var target = original.deletingPathExtension().appendingPathExtension(edited.pathExtension)
        if fm.fileExists(atPath: target.path) {
            target = ImageEngine.outputURL(for: original, fileExtension: edited.pathExtension)
        }
        try fm.moveItem(at: edited, to: target)
        return target
    }

    // MARK: Actions on the file

    @objc private func copyPicked() {
        saveEdits { file in
            Clipboard.copy(files: [file])
            Toast.show("Recording copied", symbol: "doc.on.doc.fill")
        }
    }

    @objc private func gifPicked() {
        saveEdits { file in
            CaptureController.shared.makeGIF(from: file)
        }
    }

    @objc private func convertPicked(_ sender: NSMenuItem) {
        let jobs: [VideoJob] = [.mp4, .hevc, .mov, .audio]
        guard jobs.indices.contains(sender.tag) else { return }
        let job = jobs[sender.tag]
        saveEdits { file in
            WheelRunner.run(.video(job), on: [file])
        }
    }

    @objc private func revealPicked() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func deletePicked() {
        guard !isBusy else { return }
        player.pause()
        player.replaceCurrentItem(with: nil)
        do {
            try Trash.move(url)
        } catch {
            Toast.error("Couldn't move the recording to the Trash")
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            return
        }
        RecordingController.shared.forget(url)
        trim = nil
        muted = false
        window.close()
        Toast.show("Recording moved to Trash", symbol: "trash.fill")
    }
}

private extension NSToolbarItem.Identifier {
    static let videoTrim = NSToolbarItem.Identifier("kiwi.video.trim")
    static let videoMute = NSToolbarItem.Identifier("kiwi.video.mute")
    static let videoSave = NSToolbarItem.Identifier("kiwi.video.save")
    static let videoCopy = NSToolbarItem.Identifier("kiwi.video.copy")
    static let videoGIF = NSToolbarItem.Identifier("kiwi.video.gif")
    static let videoConvert = NSToolbarItem.Identifier("kiwi.video.convert")
    static let videoReveal = NSToolbarItem.Identifier("kiwi.video.reveal")
    static let videoDelete = NSToolbarItem.Identifier("kiwi.video.delete")
}
