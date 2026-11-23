import AppKit

/// Orchestrates the screenshot flow: select, grab, copy, preview, and the
/// follow-up actions (copy, save, edit, delete).
@MainActor
final class CaptureController {
    static let shared = CaptureController()

    private let selection = SelectionController()
    /// The latest capture, while something still has it open. It is held
    /// weakly on purpose: the editor or the corner preview keeps it alive
    /// while it is on screen, and after that it is read back from its working
    /// copy when needed. A full-size screenshot is tens of megabytes, and
    /// should not sit in memory for as long as Kiwi runs.
    private(set) weak var last: Capture?
    private var lastID: UUID?

    /// The latest screenshots of this session, newest first. They live in the
    /// cache, so the list is empty again after Kiwi quits.
    private(set) var recents: [RecentCapture] = []
    /// Called whenever the recent list changes.
    var onRecentsChange: (() -> Void)?
    private let recentLimit = 12
    private var isMakingGIF = false

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
        } else if let lastID, recents.contains(where: { $0.id == lastID }) {
            reopen(lastID)
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

    /// Picks a region (or window) and hands it to `use`. The picker opens in
    /// `mode`; Space switches between dragging an area and clicking a window.
    private func selectRegion(
        mode: CaptureMode = .area, _ use: @escaping (CGDirectDisplayID, CGRect, NSScreen) -> Void
    ) {
        if selection.isActive {
            selection.finish(.cancelled)
            return
        }
        guard ensurePermission() else { return }
        selection.begin(mode: mode) { result in
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

    /// Timed capture: pick the area now, and Kiwi captures it after a countdown.
    /// That leaves time to open a menu or hover over something first.
    func captureAfterDelay(seconds: Int) {
        selectRegion { [weak self] displayID, rect, screen in
            guard let self else { return }
            let border = RegionBorder.make(around: rect, on: screen, color: Theme.kiwiNS)
            border.orderFrontRegardless()
            let showCursor = Prefs.shared.showCursor
            self.countDown(from: max(1, seconds), on: screen) {
                border.orderOut(nil)
                self.run(on: screen) {
                    try await ScreenGrabber.captureDisplay(displayID, rect: rect, showCursor: showCursor)
                }
            }
        }
    }

    private func countDown(from remaining: Int, on screen: NSScreen, then action: @escaping @MainActor () -> Void) {
        guard remaining > 0 else {
            action()
            return
        }
        Toast.show("Capturing in \(remaining)…", symbol: "timer", on: screen)
        after(1) { [weak self] in
            self?.countDown(from: remaining - 1, on: screen, then: action)
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

    /// Recording: press once for the recording bar, again to stop a recording
    /// (or to close the bar).
    func toggleRecording() {
        let recorder = RecordingController.shared
        if recorder.isRecording {
            recorder.stop()
            return
        }
        guard !ScrollCaptureController.shared.isActive else { return }
        guard RecordingBar.shared.isVisible || ensurePermission() else { return }
        RecordingBar.shared.toggle()
    }

    /// Starts recording straight away with whatever the bar was last set to,
    /// or stops the recording in progress.
    func recordNow() {
        let recorder = RecordingController.shared
        if recorder.isRecording {
            recorder.stop()
            return
        }
        RecordingBar.shared.hide()
        beginRecording(Prefs.shared.recordTarget)
    }

    /// Starts a recording as the recording bar was set up. `displayID` is the
    /// screen chosen in the bar; without one, the screen under the pointer is used.
    func beginRecording(_ target: RecordTarget, displayID chosen: CGDirectDisplayID? = nil) {
        let recorder = RecordingController.shared
        guard !recorder.isRecording, !ScrollCaptureController.shared.isActive else { return }
        switch target {
        case .area, .window:
            selectRegion(mode: target == .window ? .window : .area) { displayID, rect, screen in
                recorder.start(displayID: displayID, rect: rect, screen: screen)
            }
        case .screen, .follow:
            guard ensurePermission() else { return }
            guard let screen = NSScreen.matching(chosen) ?? NSScreen.underMouse,
                  let displayID = screen.displayID else { return }
            recorder.start(displayID: displayID, rect: nil, screen: screen, follows: target == .follow)
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
        case done(count: Int, summary: String)
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
            let outcome: Result<(image: CGImage, count: Int, summary: String), Error> = Result {
                let findings = try PIIScanner.findings(in: image, options: options)
                let redacted = try PIIScanner.apply(findings.map(\.rect), to: image)
                return (redacted, findings.count, PIIScanner.summary(of: findings))
            }
            Task { @MainActor in
                let screen = NSScreen.matching(displayID)
                switch outcome {
                case .success(let value):
                    self.deliver(image: value.image, scale: scale, screen: screen, redaction: .done(count: value.count, summary: value.summary))
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
        lastID = capture.id
        remember(capture)
        if prefs.editAfterCapture {
            PreviewHUD.shared.dismiss(animated: false)
            EditorCoordinator.shared.open(capture)
        } else {
            PreviewHUD.shared.show(capture, on: screen)
        }

        switch redaction {
        case .off:
            persist(capture, copy: prefs.copyOnCapture, save: prefs.saveOnCapture)
        case .done(let count, let summary):
            persist(capture, copy: prefs.copyOnCapture, save: prefs.saveOnCapture)
            if count > 0 {
                Toast.show("Redacted \(summary)", symbol: "eye.slash.fill")
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
                // Keep the recent list in step with edits, renames and saves.
                if self.recents.contains(where: { $0.id == capture.id }) {
                    self.remember(capture)
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

    /// Called when the editor window is closed with edits that were never
    /// copied or saved. The edited image replaces the original in the cache,
    /// on the clipboard (when captures are copied automatically) and in the
    /// saved file if there is one.
    func keepEdits(_ capture: Capture) {
        let copy = Prefs.shared.copyOnCapture
        persist(capture, copy: copy, save: capture.savedURL != nil) { _ in
            Toast.show(copy ? "Edited image copied" : "Edits kept", symbol: "checkmark.circle.fill")
        }
    }

    /// Renames a capture: its working copy and, if it was saved, the saved file.
    /// Returns the name actually applied (unchanged when the proposal is empty).
    @discardableResult
    func rename(_ capture: Capture, to proposed: String) -> String {
        let name = CaptureStore.sanitizedName(proposed)
        guard !name.isEmpty, name != capture.name else { return capture.name }
        let fm = FileManager.default

        let newCache = CaptureStore.cacheDirectory.appendingPathComponent(name + ".png")
        if fm.fileExists(atPath: capture.cacheURL.path) {
            try? fm.removeItem(at: newCache)
            try? fm.moveItem(at: capture.cacheURL, to: newCache)
        }
        capture.cacheURL = newCache

        if let saved = capture.savedURL, fm.fileExists(atPath: saved.path) {
            let target = CaptureStore.uniqueURL(
                in: saved.deletingLastPathComponent(), name: name, ext: saved.pathExtension
            )
            if (try? fm.moveItem(at: saved, to: target)) != nil {
                capture.savedURL = target
            }
        }
        capture.name = name
        if recents.contains(where: { $0.id == capture.id }) {
            remember(capture)
        }
        return name
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
        if lastID == capture.id { lastID = nil }
        forget(capture.id)
        PreviewHUD.shared.dismiss(ifShowing: capture)
        Toast.show("Deleted", symbol: "trash.fill")
    }

    // MARK: Recent captures

    /// Adds a screenshot to the recent list, or refreshes its entry and moves it to the top.
    private func remember(_ capture: Capture) {
        guard capture.isScreenshot, !capture.isDeleted else { return }
        let small = capture.image.downscaled(maxPixel: 96)
        let longest = CGFloat(max(small.width, small.height, 1))
        let fit = 32 / longest
        let thumbnail = NSImage(
            cgImage: small,
            size: NSSize(width: CGFloat(small.width) * fit, height: CGFloat(small.height) * fit)
        )
        let record = RecentCapture(
            id: capture.id,
            name: capture.name,
            cacheURL: capture.cacheURL,
            savedURL: capture.savedURL,
            scale: capture.scale,
            thumbnail: thumbnail
        )
        recents.removeAll { $0.id == capture.id }
        recents.insert(record, at: 0)
        while recents.count > recentLimit {
            let dropped = recents.removeLast()
            // An editor that is still open keeps using its working copy.
            if EditorCoordinator.shared.openCapture(withID: dropped.id) == nil {
                try? FileManager.default.removeItem(at: dropped.cacheURL)
            }
        }
        onRecentsChange?()
    }

    private func forget(_ id: UUID) {
        guard recents.contains(where: { $0.id == id }) else { return }
        recents.removeAll { $0.id == id }
        onRecentsChange?()
    }

    /// Opens a recent capture in the editor again.
    func reopen(_ id: UUID) {
        guard let record = recents.first(where: { $0.id == id }) else { return }
        if let last, last.id == id {
            edit(last)
            return
        }
        if let open = EditorCoordinator.shared.openCapture(withID: id) {
            edit(open)
            return
        }
        guard let source = CGImageSourceCreateWithURL(record.cacheURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            forget(id)
            Toast.error("That capture is no longer available")
            return
        }
        edit(Capture(reopening: record, image: image))
    }

    // MARK: GIF

    /// Converts a recording to a GIF next to it and shows the result in Finder.
    func makeGIF(from video: URL) {
        guard !isMakingGIF else {
            Toast.show("Still making the last GIF…", symbol: "hourglass")
            return
        }
        guard FileManager.default.fileExists(atPath: video.path) else {
            Toast.error("That recording is no longer there")
            return
        }
        isMakingGIF = true
        Toast.show("Making GIF…", symbol: "photo.stack")
        Task { @MainActor in
            do {
                let gif = try await GIFExporter.export(video: video)
                self.isMakingGIF = false
                Toast.show("GIF saved", symbol: "photo.stack.fill")
                NSWorkspace.shared.activateFileViewerSelecting([gif])
            } catch {
                self.isMakingGIF = false
                NSLog("Kiwi: GIF export failed: %@", error.localizedDescription)
                Toast.error((error as? KiwiError)?.message ?? "Couldn't make the GIF")
            }
        }
    }

    func makeGIFOfLastRecording() {
        guard let video = RecordingController.shared.lastURL else {
            Toast.show("No recording yet", symbol: "record.circle")
            return
        }
        makeGIF(from: video)
    }

    func pinLast() {
        if let last {
            PinController.shared.pin(last.image, scale: last.scale)
            return
        }
        guard let lastID, let record = recents.first(where: { $0.id == lastID }),
              let source = CGImageSourceCreateWithURL(record.cacheURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Toast.show("No capture yet", symbol: "camera.viewfinder")
            return
        }
        PinController.shared.pin(image, scale: record.scale)
    }

    func revealSaveFolder() {
        let folder = Prefs.shared.saveFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
