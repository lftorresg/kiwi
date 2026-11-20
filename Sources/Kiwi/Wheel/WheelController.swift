import AppKit
import SwiftUI

/// Shows the wheel under the pointer during a file drag and runs the action
/// for the slice the files are dropped on.
@MainActor
final class WheelController {
    static let shared = WheelController()

    private let model = WheelModel()
    private let watcher = DragWatcher()
    private var panel: FloatingPanel?
    private var dropView: WheelDropView?
    private var hideToken = 0

    private init() {
        watcher.onTrigger = { [weak self] ring in self?.show(ring) }
        watcher.onDragEnded = { [weak self] in
            // Give a drop on the wheel a moment to be delivered first.
            after(0.12) { self?.hide() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            watcher.start()
        } else {
            watcher.stop()
            hide()
        }
    }

    // MARK: Showing and hiding

    private func makePanelIfNeeded() -> FloatingPanel {
        if let existing = self.panel { return existing }
        let side = WheelMetrics.panelSide
        let size = NSSize(width: side, height: side)
        let created = FloatingPanel(size: size, level: .popUpMenu)

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        // The drop target sits above the SwiftUI content and owns all dragging.
        let drop = WheelDropView(frame: container.bounds)
        drop.autoresizingMask = [.width, .height]
        drop.controller = self
        container.addSubview(drop)

        created.contentView = container
        self.panel = created
        self.dropView = drop
        return created
    }

    private func show(_ ring: WheelRing) {
        hideToken += 1
        let wheelPanel = makePanelIfNeeded()
        if !model.visible {
            // A new drag: what is being dragged is not known yet.
            model.kind = nil
        }
        model.ring = usable(ring)
        model.highlighted = nil

        if !model.visible {
            // Centre the wheel on the pointer, kept fully on screen.
            let mouse = NSEvent.mouseLocation
            let side = WheelMetrics.panelSide
            var origin = NSPoint(x: mouse.x - side / 2, y: mouse.y - side / 2)
            if let screen = NSScreen.underMouse {
                let frame = screen.frame
                origin.x = min(max(origin.x, frame.minX), frame.maxX - side)
                origin.y = min(max(origin.y, frame.minY), frame.maxY - side)
            }
            wheelPanel.setFrameOrigin(origin)
            wheelPanel.ignoresMouseEvents = false
            wheelPanel.orderFrontRegardless()
            model.visible = true
        }
    }

    func hide() {
        guard model.visible || panel?.isVisible == true else { return }
        model.visible = false
        model.highlighted = nil
        hideToken += 1
        let token = hideToken
        after(0.22) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// A ring with nothing to offer for these files gives way to Actions.
    private func usable(_ ring: WheelRing) -> WheelRing {
        guard let kind = model.kind, ring.items(for: kind).isEmpty else { return ring }
        return .actions
    }

    // MARK: Drop handling (called by WheelDropView)

    /// True while the wheel is up but has not seen the dragged files yet.
    var needsFiles: Bool { model.visible && model.kind == nil }

    /// The drag has reached the wheel, so Kiwi is now a drop target and may
    /// look at the files. Their kind picks the slices.
    func identify(_ urls: [URL]) {
        guard needsFiles, !urls.isEmpty else { return }
        model.kind = FileKind.of(urls)
        model.ring = usable(model.ring)
    }

    func item(at point: NSPoint, in bounds: NSRect) -> (index: Int, item: WheelItem)? {
        guard model.visible else { return nil }
        let items = model.items
        guard let index = WheelMetrics.sliceIndex(
            dx: point.x - bounds.midX,
            dy: point.y - bounds.midY,
            count: items.count
        ) else { return nil }
        return (index, items[index])
    }

    func hover(at point: NSPoint?, in bounds: NSRect) -> Bool {
        guard let point, let hit = item(at: point, in: bounds) else {
            if model.highlighted != nil { model.highlighted = nil }
            return false
        }
        if model.highlighted != hit.index { model.highlighted = hit.index }
        return true
    }

    func drop(_ urls: [URL], at point: NSPoint, in bounds: NSRect) -> Bool {
        identify(urls)
        guard !urls.isEmpty, let hit = item(at: point, in: bounds) else {
            hide()
            return false
        }
        if case .share = hit.item.action {
            share(urls)
        } else {
            hide()
            WheelRunner.run(hit.item.action, on: urls)
        }
        return true
    }

    /// The share picker needs a visible view to anchor to, so the panel stays
    /// on screen (empty and click-through) while the picker is open.
    private func share(_ urls: [URL]) {
        model.visible = false
        model.highlighted = nil
        hideToken += 1
        let token = hideToken
        guard let panel, let anchor = dropView else { return }

        NSApp.activate(ignoringOtherApps: true)
        let picker = NSSharingServicePicker(items: urls)
        let centre = NSRect(x: anchor.bounds.midX - 1, y: anchor.bounds.midY - 1, width: 2, height: 2)
        picker.show(relativeTo: centre, of: anchor, preferredEdge: .minY)

        after(0.4) { panel.ignoresMouseEvents = true }
        after(45) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.panel?.orderOut(nil)
        }
    }
}

/// Invisible view that receives the file drop and tells the controller which
/// slice the pointer is over.
final class WheelDropView: NSView {
    weak var controller: WheelController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let overSlice = controller?.hover(at: point, in: bounds) ?? false
        // Returning no operation over the hub makes a drop there a cancel.
        return overSlice ? .copy : []
    }

    private func fileURLs(of sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { $0 as? URL }
    }

    private func identifyIfNeeded(_ sender: NSDraggingInfo) {
        guard let controller, controller.needsFiles else { return }
        controller.identify(fileURLs(of: sender))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        identifyIfNeeded(sender)
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        identifyIfNeeded(sender)
        return operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        _ = controller?.hover(at: nil, in: bounds)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        return controller?.drop(fileURLs(of: sender), at: point, in: bounds) ?? false
    }
}

/// Runs wheel actions off the main thread. Quick ones end with a toast; ones
/// that take a while also get a progress panel with a Cancel button.
@MainActor
enum WheelRunner {
    /// The job in flight, if any. Kiwi runs one at a time.
    private static var current: Task<Void, Never>?

    static func run(_ action: WheelAction, on urls: [URL]) {
        let quality = Prefs.shared.convertQuality

        switch action {
        case .copy:
            Clipboard.copy(files: urls)
            Toast.show(urls.count == 1 ? "Copied to clipboard" : "Copied \(urls.count) files", symbol: "doc.on.doc.fill")

        case .copyPath:
            Clipboard.copy(text: urls.map(\.path).joined(separator: "\n"))
            Toast.show(urls.count == 1 ? "Path copied" : "Copied \(urls.count) paths", symbol: "link")

        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting(urls)

        case .checksum:
            checksum(urls)

        case .copyText:
            copyText(from: urls)

        case .edit:
            guard let first = urls.first(where: ImageEngine.isImage) else {
                Toast.error("Edit works with images")
                return
            }
            EditorCoordinator.shared.open(fileURL: first)

        case .share:
            break // handled by WheelController, which owns the anchor view

        case .rename:
            // Let the drop finish first: a dialog inside it would stall the app the files came from.
            after(0.15) { rename(urls) }

        case .zip:
            batch(urls, title: "Compressing", success: "ZIP created") { files, _ in
                try Archive.zip(files)
            }

        // MARK: Images

        case .convert(let format):
            each(urls, where: ImageEngine.isImage, noun: "image",
                 title: "Converting to \(format.title)", verb: "Converted", suffix: "to \(format.title)") { url, _ in
                try ImageEngine.convert(url, to: format, quality: quality)
            }

        case .resizeHalf:
            each(urls, where: ImageEngine.isImage, noun: "image",
                 title: "Resizing", verb: "Resized", suffix: "to half size") { url, _ in
                try ImageEngine.resize(url, factor: 0.5)
            }

        case .fit(let maxPixel):
            each(urls, where: ImageEngine.isImage, noun: "image",
                 title: "Resizing", verb: "Resized", suffix: "to fit \(maxPixel) px") { url, _ in
                try ImageEngine.resize(url, maxPixel: maxPixel)
            }

        case .compress:
            each(urls, where: ImageEngine.isImage, noun: "image",
                 title: "Compressing", verb: "Compressed", suffix: "") { url, _ in
                try ImageEngine.compress(url)
            }

        case .stripMetadata:
            each(urls, where: ImageEngine.isImage, noun: "image",
                 title: "Stripping info", verb: "Stripped info from", suffix: "") { url, _ in
                try ImageEngine.stripMetadata(url)
            }

        case .redact:
            let options = Prefs.shared.redactOptions
            guard !options.categories.isEmpty || options.faces else {
                Toast.error("Turn on something to redact in Settings")
                return
            }
            each(urls, where: ImageEngine.isImage, noun: "image",
                 title: "Looking for sensitive text", verb: "Redacted", suffix: "") { url, _ in
                try ImageEngine.redact(url, options: options).url
            }

        // MARK: Video and audio

        case .video(let job):
            each(urls, where: MediaEngine.isVideo, noun: "video",
                 title: job.working, verb: job.result.verb, suffix: job.result.suffix) { url, progress in
                try await MediaEngine.run(job, on: url, progress: progress)
            }

        case .gif:
            each(urls, where: MediaEngine.isVideo, noun: "video",
                 title: "Making GIF", verb: "Made a GIF of", suffix: "") { url, _ in
                try await GIFExporter.export(video: url)
            }

        case .audio(let format):
            each(urls, where: MediaEngine.isAudio, noun: "audio file",
                 title: "Converting to \(format.title)", verb: "Converted", suffix: "to \(format.title)") { url, progress in
                try await MediaEngine.convertAudio(url, to: format, progress: progress)
            }

        // MARK: PDF and documents

        case .pdfImages(let format):
            each(urls, where: PDFEngine.isPDF, noun: "PDF",
                 title: "Rendering pages", verb: "Rendered", suffix: "to \(format.title)") { url, progress in
                try PDFEngine.images(of: url, format: format, quality: quality, progress: progress)
            }

        case .pdfText:
            each(urls, where: PDFEngine.isPDF, noun: "PDF",
                 title: "Extracting text", verb: "Extracted the text of", suffix: "") { url, _ in
                try PDFEngine.text(of: url)
            }

        case .pdfSplit:
            each(urls, where: PDFEngine.isPDF, noun: "PDF",
                 title: "Splitting", verb: "Split", suffix: "into pages") { url, progress in
                try PDFEngine.split(url, progress: progress)
            }

        case .pdfMerge:
            let documents = urls.filter(PDFEngine.isPDF)
            guard documents.count >= 2 else {
                Toast.error("Drag two or more PDFs to merge them")
                return
            }
            batch(documents, title: "Merging", success: "Merged \(documents.count) PDFs") { files, progress in
                try PDFEngine.merge(files, progress: progress)
            }

        case .document(let format):
            each(urls, where: DocumentEngine.isDocument, noun: "document",
                 title: "Converting to \(format.title)", verb: "Converted", suffix: "to \(format.title)") { url, _ in
                try await DocumentEngine.convert(url, to: format)
            }
        }
    }

    // MARK: Running jobs

    /// Starts a job unless one is still running.
    private static func begin(title: String) -> Bool {
        guard current == nil else {
            Toast.error("Kiwi is still working on the last drop")
            return false
        }
        ProgressPanel.shared.begin(title: title)
        return true
    }

    private static func end() {
        current = nil
        ProgressPanel.shared.end()
    }

    /// Runs `work` on each matching file in turn. One bad file never stops the rest.
    private static func each(
        _ urls: [URL],
        where accepts: (URL) -> Bool,
        noun: String,
        title: String,
        verb: String,
        suffix: String,
        work: @escaping @Sendable (URL, @escaping ProgressHandler) async throws -> URL
    ) {
        let files = urls.filter(accepts)
        let skipped = urls.count - files.count
        guard !files.isEmpty else {
            Toast.error("That only works with \(noun)s")
            return
        }
        guard begin(title: title) else { return }
        let panel = ProgressPanel.shared
        let total = files.count

        let task = Task.detached(priority: .userInitiated) {
            var done = 0
            var firstError: String?
            for (index, url) in files.enumerated() {
                if Task.isCancelled { break }
                let name = url.lastPathComponent
                let base = Double(index) / Double(total)
                await MainActor.run {
                    panel.update(detail: total == 1 ? name : "\(index + 1) of \(total) · \(name)", fraction: base)
                }
                do {
                    _ = try await work(url) { fraction in
                        let overall = base + min(1, max(0, fraction)) / Double(total)
                        Task { @MainActor in panel.update(fraction: overall) }
                    }
                    done += 1
                } catch is CancellationError {
                    break
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            let succeeded = done
            let failed = total - done + skipped
            let errorText = firstError
            let cancelled = Task.isCancelled

            await MainActor.run {
                end()
                if cancelled {
                    Toast.show(succeeded > 0 ? "Stopped after \(succeeded) of \(total)" : "Cancelled", symbol: "xmark.circle")
                    return
                }
                if succeeded == 0 {
                    Toast.error(errorText ?? "Nothing was changed")
                    return
                }
                var message = "\(verb) \(succeeded) \(succeeded == 1 ? noun : noun + "s")"
                if !suffix.isEmpty { message += " \(suffix)" }
                if failed > 0 { message += " · \(failed) skipped" }
                Toast.show(message)
            }
        }
        current = task
        panel.onCancel = { task.cancel() }
    }

    /// Runs `work` once on all the files and shows the single result in Finder.
    private static func batch(
        _ files: [URL],
        title: String,
        success: String,
        work: @escaping @Sendable ([URL], @escaping ProgressHandler) async throws -> URL
    ) {
        guard !files.isEmpty, begin(title: title) else { return }
        let panel = ProgressPanel.shared
        let detail = files.count == 1 ? files[0].lastPathComponent : "\(files.count) items"
        panel.update(detail: detail)

        let task = Task.detached(priority: .userInitiated) {
            var output: URL?
            var errorText: String?
            do {
                output = try await work(files) { fraction in
                    Task { @MainActor in panel.update(fraction: fraction) }
                }
            } catch is CancellationError {
                errorText = nil
            } catch {
                errorText = error.localizedDescription
            }
            let result = output
            let message = errorText
            let cancelled = Task.isCancelled

            await MainActor.run {
                end()
                if let result {
                    Toast.show(success)
                    NSWorkspace.shared.activateFileViewerSelecting([result])
                } else if cancelled {
                    Toast.show("Cancelled", symbol: "xmark.circle")
                } else {
                    Toast.error(message ?? "That didn't work")
                }
            }
        }
        current = task
        panel.onCancel = { task.cancel() }
    }

    // MARK: Rename

    /// Asks for a name and renames the files in place. One file takes the
    /// name as typed; several get the name and a number. Extensions are kept,
    /// and nothing is ever overwritten.
    private static func rename(_ urls: [URL]) {
        guard let first = urls.first else { return }
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = urls.count == 1 ? "Rename" : "Rename \(urls.count) files"
        alert.informativeText = urls.count == 1
            ? "The extension stays the same."
            : "Each file gets this name and a number. Extensions stay the same."
        let field = NSTextField(string: first.deletingPathExtension().lastPathComponent)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = CaptureStore.sanitizedName(field.stringValue)
        guard !name.isEmpty else {
            Toast.error("That name can't be used")
            return
        }

        let fm = FileManager.default
        var renamed = 0
        for (index, url) in urls.enumerated() {
            let stem = urls.count == 1 ? name : "\(name) \(index + 1)"
            let ext = url.pathExtension
            let target = url.deletingLastPathComponent()
                .appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
            if target.path == url.path || fm.fileExists(atPath: target.path) { continue }
            if (try? fm.moveItem(at: url, to: target)) != nil {
                renamed += 1
            }
        }
        let skipped = urls.count - renamed
        if renamed == 0 {
            Toast.error("Nothing renamed: that name is already taken")
        } else if skipped > 0 {
            Toast.show("Renamed \(renamed) · \(skipped) skipped", symbol: "character.cursor.ibeam")
        } else {
            Toast.show(renamed == 1 ? "Renamed" : "Renamed \(renamed) files", symbol: "character.cursor.ibeam")
        }
    }

    // MARK: Text and checksums

    /// Reads the text in every image and PDF and copies it, files separated by a blank line.
    private static func copyText(from urls: [URL]) {
        let readable = urls.filter { ImageEngine.isImage($0) || PDFEngine.isPDF($0) }
        guard !readable.isEmpty else {
            Toast.error("Copy text works with images and PDFs")
            return
        }
        Toast.show("Reading text…", symbol: "text.viewfinder")
        DispatchQueue.global(qos: .userInitiated).async {
            var parts: [String] = []
            for url in readable {
                if PDFEngine.isPDF(url) {
                    if let text = PDFEngine.string(of: url) {
                        parts.append(text)
                    }
                } else if let image = try? ImageEngine.loadUpright(url),
                          let text = try? TextReader.read(image), !text.isEmpty {
                    parts.append(text)
                }
            }
            let text = parts.joined(separator: "\n\n")
            Task { @MainActor in
                guard !text.isEmpty else {
                    Toast.show("No text found", symbol: "text.viewfinder")
                    return
                }
                Clipboard.copy(text: text)
                Toast.show("Copied the text", symbol: "doc.on.doc.fill")
            }
        }
    }

    /// Hashes every file and copies the result: the bare digest for one file,
    /// `digest  name` lines (the sha256sum format) for several.
    private static func checksum(_ urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else {
            Toast.error("Checksums work with files, not folders")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var digests: [String] = []
            for url in files {
                if let digest = try? Checksum.sha256(of: url) {
                    digests.append(digest)
                    lines.append("\(digest)  \(url.lastPathComponent)")
                }
            }
            let text = digests.count == 1 ? digests[0] : lines.joined(separator: "\n")
            let count = digests.count
            let preview = digests.first.map { String($0.prefix(12)) } ?? ""

            Task { @MainActor in
                guard count > 0 else {
                    Toast.error("Couldn't read the file")
                    return
                }
                Clipboard.copy(text: text)
                Toast.show(
                    count == 1 ? "SHA-256 copied · \(preview)…" : "Copied \(count) SHA-256 checksums",
                    symbol: "number"
                )
            }
        }
    }
}
