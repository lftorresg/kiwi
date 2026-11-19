import AppKit

/// Orchestrates the screenshot flow: select, grab, copy, preview, and the
/// follow-up actions (copy, save, edit, delete).
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private let selection = SelectionController()
    private(set) var last: Capture?

    /// Called when a capture is attempted without Screen Recording permission.
    var onNeedsSetup: (() -> Void)?

    private init() {}

    // MARK: Entry points

    func captureArea() { startSelection(.area) }

    func captureWindow() { startSelection(.window) }

    func captureScreen() {
        guard ensurePermission() else { return }
        guard let screen = NSScreen.underMouse, let displayID = screen.displayID else { return }
        let showCursor = Prefs.shared.showCursor
        run(on: screen) {
            try await ScreenGrabber.captureDisplay(displayID, rect: nil, showCursor: showCursor)
        }
    }

    func editLast() {
        if let last {
            edit(last)
        } else {
            Toast.show("No capture yet", symbol: "camera.viewfinder")
        }
    }

    // MARK: Selection and grabbing

    private func startSelection(_ mode: CaptureMode) {
        // Pressing the shortcut again while selecting cancels, like the native tool.
        if selection.isActive {
            selection.finish(.cancelled)
            return
        }
        guard ensurePermission() else { return }

        selection.begin(mode: mode) { [weak self] result in
            guard let self else { return }
            switch result {
            case .cancelled:
                break
            case .area(let displayID, let rect, let screen):
                self.run(on: screen) {
                    try await ScreenGrabber.captureDisplay(displayID, rect: rect, showCursor: false)
                }
            case .window(let id, _, let screen):
                self.run(on: screen) {
                    try await ScreenGrabber.captureWindow(id)
                }
            }
        }
    }

    /// Picks a region (or window) and hands it to `use`.
    private func selectRegion(_ use: @escaping (CGDirectDisplayID, CGRect, NSScreen) -> Void) {
        if selection.isActive {
            selection.finish(.cancelled)
            return
        }
        guard ensurePermission() else { return }
        selection.begin(mode: .area) { result in
            switch result {
            case .cancelled:
                break
            case .area(let displayID, let rect, let screen):
                use(displayID, rect, screen)
            case .window(_, let rect, let screen):
                guard let displayID = screen.displayID, rect.width >= 8, rect.height >= 8 else { return }
                use(displayID, rect, screen)
            }
        }
    }

    /// Scrolling capture: press once to pick the area, again to finish.
    func captureScrolling() {
        let scroller = ScrollCaptureController.shared
        if scroller.isActive {
            scroller.finish()
            return
        }
        guard !RecordingController.shared.isRecording else {
            Toast.error("Stop the recording first")
            return
        }
        selectRegion { displayID, rect, screen in
            scroller.start(displayID: displayID, rect: rect, screen: screen)
        }
    }

    /// Recording: press once to pick the area and start, again to stop.
    func toggleRecording() {
        let recorder = RecordingController.shared
        if recorder.isRecording {
            recorder.stop()
            return
        }
        guard !ScrollCaptureController.shared.isActive else { return }
        selectRegion { displayID, rect, screen in
            recorder.start(displayID: displayID, rect: rect, screen: screen)
        }
    }

    func recordScreen() {
        let recorder = RecordingController.shared
        if recorder.isRecording {
            recorder.stop()
            return
        }
        guard ensurePermission() else { return }
        guard let screen = NSScreen.underMouse, let displayID = screen.displayID else { return }
        recorder.start(displayID: displayID, rect: nil, screen: screen)
    }

    private func run(
        on screen: NSScreen,
        _ work: @escaping @MainActor () async throws -> (image: CGImage, scale: CGFloat)
    ) {
        Task { @MainActor in
            do {
                let result = try await work()
                self.ingest(image: result.image, scale: result.scale, screen: screen)
            } catch {
                NSLog("Kiwi: capture failed: %@", String(describing: error))
                if ScreenGrabber.hasPermission {
                    Toast.error("Capture failed")
                } else {
                    self.onNeedsSetup?()
                }
            }
        }
    }

    private enum RedactionOutcome {
        case off
        case done(Int)
        case failed
    }

    /// Takes a freshly grabbed image through redaction (when enabled), the
    /// preview, the clipboard and the save folder.
    func ingest(image: CGImage, scale: CGFloat, screen: NSScreen?) {
        let prefs = Prefs.shared
        if prefs.playSound { Sound.shutter() }

        guard prefs.autoRedact else {
            deliver(image: image, scale: scale, screen: screen, redaction: .off)
            return
        }

        // Redact first: nothing reaches the clipboard or disk until the scan is done.
        let options = prefs.redactOptions
        let displayID = screen?.displayID
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<(image: CGImage, count: Int), Error> = Result {
                let rects = try PIIScanner.scan(image, options: options)
                let redacted = try PIIScanner.apply(rects, to: image)
                return (redacted, rects.count)
            }
            Task { @MainActor in
                let screen = NSScreen.matching(displayID)
                switch outcome {
                case .success(let value):
                    self.deliver(image: value.image, scale: scale, screen: screen, redaction: .done(value.count))
                case .failure(let error):
                    NSLog("Kiwi: auto-redact failed: %@", error.localizedDescription)
                    self.deliver(image: image, scale: scale, screen: screen, redaction: .failed)
                }
            }
        }
    }

    private func deliver(image: CGImage, scale: CGFloat, screen: NSScreen?, redaction: RedactionOutcome) {
        let prefs = Prefs.shared
        let capture = Capture(image: image, scale: scale)
        last = capture
        if prefs.editAfterCapture {
            PreviewHUD.shared.dismiss(animated: false)
            EditorCoordinator.shared.open(capture)
        } else {
            PreviewHUD.shared.show(capture, on: screen)
        }

        switch redaction {
        case .off:
            persist(capture, copy: prefs.copyOnCapture, save: prefs.saveOnCapture)
        case .done(let count):
            persist(capture, copy: prefs.copyOnCapture, save: prefs.saveOnCapture)
            if count > 0 {
                Toast.show("Redacted \(count) \(count == 1 ? "item" : "items")", symbol: "eye.slash.fill")
            }
        case .failed:
            // Fail closed: an unredacted image is never copied or saved automatically.
            persist(capture, copy: false, save: false)
            Toast.error("Auto-redact failed, so nothing was copied")
        }
    }

    private func ensurePermission() -> Bool {
        if ScreenGrabber.hasPermission { return true }
        ScreenGrabber.requestPermission()
        onNeedsSetup?()
        return false
    }

    // MARK: Actions

    /// Encodes the capture once, off the main thread, then refreshes the cache
    /// file and optionally the clipboard and the save folder.
    func persist(
        _ capture: Capture,
        copy: Bool,
        save: Bool,
        then completion: (@MainActor (_ saved: URL?) -> Void)? = nil
    ) {
        let image = capture.image
        let scale = capture.scale
        let cacheURL = capture.cacheURL
        let name = capture.name
        let existing = capture.savedURL
        let folder = Prefs.shared.saveFolderURL

        DispatchQueue.global(qos: .userInitiated).async {
            let data = CaptureStore.pngData(image, scale: scale)
            if let data {
                try? CaptureStore.writePrivately(data, to: cacheURL)
            }
            let saved: URL?
            let failed: Bool
            if save, let data {
                let written = try? CaptureStore.write(data, toFolder: folder, name: name, replacing: existing)
                saved = written
                failed = (written == nil)
            } else {
                saved = nil
                failed = save
            }

            Task { @MainActor in
                if capture.isDeleted {
                    try? FileManager.default.removeItem(at: cacheURL)
                    if let saved { NSWorkspace.shared.recycle([saved]) }
                    return
                }
                if copy, let data {
                    capture.clipboardStamp = Clipboard.copy(png: data)
                }
                if let saved {
                    capture.savedURL = saved
                }
                if failed {
                    Toast.error("Couldn't save to \(folder.lastPathComponent)")
                }
                completion?(saved)
            }
        }
    }

    func copy(_ capture: Capture) {
        persist(capture, copy: true, save: false) { _ in
            Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
        }
    }

    func save(_ capture: Capture) {
        let folderName = Prefs.shared.saveFolderURL.lastPathComponent
        persist(capture, copy: false, save: true) { saved in
            if saved != nil {
                Toast.show("Saved to \(folderName)", symbol: "square.and.arrow.down.fill")
            }
        }
    }

    /// Called when the editor is done: copies the edited image and refreshes
    /// the saved file if one already exists.
    func finishEditing(_ capture: Capture) {
        persist(capture, copy: true, save: capture.savedURL != nil) { _ in
            Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
        }
    }

    func edit(_ capture: Capture) {
        PreviewHUD.shared.dismiss()
        EditorCoordinator.shared.open(capture)
    }

    /// Removes every trace of the capture: cache file, saved copy (to the Trash),
    /// and the clipboard if it still holds this image.
    func delete(_ capture: Capture) {
        capture.isDeleted = true
        try? FileManager.default.removeItem(at: capture.cacheURL)
        if let saved = capture.savedURL {
            NSWorkspace.shared.recycle([saved])
            capture.savedURL = nil
        }
        Clipboard.clear(ifStampIs: capture.clipboardStamp)
        if last === capture { last = nil }
        PreviewHUD.shared.dismiss(ifShowing: capture)
        Toast.show("Deleted", symbol: "trash.fill")
    }

    func revealSaveFolder() {
        let folder = Prefs.shared.saveFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
