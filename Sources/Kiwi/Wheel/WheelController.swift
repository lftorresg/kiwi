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
        model.ring = ring
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

    // MARK: Drop handling (called by WheelDropView)

    func item(at point: NSPoint, in bounds: NSRect) -> (index: Int, item: WheelItem)? {
        guard model.visible else { return nil }
        let items = model.ring.items
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        _ = controller?.hover(at: nil, in: bounds)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let point = convert(sender.draggingLocation, from: nil)
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        let urls = objects.compactMap { $0 as? URL }
        return controller?.drop(urls, at: point, in: bounds) ?? false
    }
}

/// Runs wheel actions off the main thread and reports the outcome with a toast.
@MainActor
enum WheelRunner {
    static func run(_ action: WheelAction, on urls: [URL]) {
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

        case .edit:
            guard let first = urls.first(where: ImageEngine.isImage) else {
                Toast.error("Edit works with images")
                return
            }
            EditorCoordinator.shared.open(fileURL: first)

        case .share:
            break // handled by WheelController, which owns the anchor view

        case .convert(let format):
            let quality = Prefs.shared.convertQuality
            process(urls, verb: "Converted", suffix: "to \(format.title)") { url in
                try ImageEngine.convert(url, to: format, quality: quality)
            }

        case .resizeHalf:
            process(urls, verb: "Resized", suffix: "to half size") { url in
                try ImageEngine.resize(url, factor: 0.5)
            }

        case .fit(let maxPixel):
            process(urls, verb: "Resized", suffix: "to fit \(maxPixel) px") { url in
                try ImageEngine.resize(url, maxPixel: maxPixel)
            }

        case .compress:
            process(urls, verb: "Compressed", suffix: "") { url in
                try ImageEngine.compress(url)
            }

        case .stripMetadata:
            process(urls, verb: "Stripped info from", suffix: "") { url in
                try ImageEngine.stripMetadata(url)
            }

        case .redact:
            let options = Prefs.shared.redactOptions
            guard !options.categories.isEmpty || options.faces else {
                Toast.error("Turn on something to redact in Settings")
                return
            }
            Toast.show("Looking for sensitive text…", symbol: "eye.slash")
            process(urls, verb: "Redacted", suffix: "") { url in
                try ImageEngine.redact(url, options: options).url
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

    private static func process(
        _ urls: [URL],
        verb: String,
        suffix: String,
        work: @escaping @Sendable (URL) throws -> URL
    ) {
        let images = urls.filter(ImageEngine.isImage)
        let skipped = urls.count - images.count
        guard !images.isEmpty else {
            Toast.error("That only works with images")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            var done = 0
            var firstError: String?
            // One bad file never stops the rest.
            for url in images {
                do {
                    _ = try work(url)
                    done += 1
                } catch {
                    if firstError == nil { firstError = error.localizedDescription }
                }
            }
            let succeeded = done
            let failed = images.count - done + skipped
            let errorText = firstError

            Task { @MainActor in
                if succeeded == 0 {
                    Toast.error(errorText ?? "Nothing was changed")
                    return
                }
                var message = "\(verb) \(succeeded) \(succeeded == 1 ? "image" : "images")"
                if !suffix.isEmpty { message += " \(suffix)" }
                if failed > 0 { message += " · \(failed) skipped" }
                Toast.show(message)
            }
        }
    }
}
