import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Keeps editor windows alive while they are open.
@MainActor
final class EditorCoordinator {
    static let shared = EditorCoordinator()
    private var controllers: [EditorWindowController] = []

    private init() {}

    func open(_ capture: Capture) {
        if let existing = controllers.first(where: { $0.capture === capture }) {
            existing.show()
            return
        }
        let controller = EditorWindowController(capture: capture)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.show()
    }

    /// The capture with this id, if an editor window is showing it.
    func openCapture(withID id: UUID) -> Capture? {
        controllers.first { $0.capture.id == id }?.capture
    }

    /// Opens an image file from disk, for example one dropped on the wheel.
    func open(fileURL: URL) {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            Toast.error("Couldn't open \(fileURL.lastPathComponent)")
            return
        }
        var scale: CGFloat = 1
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let dpi = properties[kCGImagePropertyDPIWidth] as? Double, dpi >= 143 {
            scale = CGFloat((dpi / 72).rounded())
        }
        open(Capture(image: image, scale: scale, origin: .file(fileURL)))
    }
}

/// Commands the editor window can receive from the keyboard or its buttons.
enum EditorCommand {
    case copy, save, saveAs, delete, done, undo, redo, close, autoRedact
    case export(ImageFormat)
    case zoomIn, zoomOut, zoomFit, zoomActual
    case rename
    case copyText
    case pickText
    case pin
    case backdrop(Backdrop?)
}

/// Window that turns Command-key shortcuts into editor commands.
final class EditorWindow: NSWindow {
    var onCommand: ((EditorCommand) -> Void)?

    /// Receives pinch, smart-zoom and scroll events for the whole window.
    weak var gestureTarget: NSResponder?

    override func sendEvent(_ event: NSEvent) {
        // The canvas lives inside a SwiftUI hosting view, which forwards clicks
        // to it but not trackpad gestures. Deliver those directly.
        if let target = gestureTarget {
            switch event.type {
            case .magnify:
                target.magnify(with: event)
                return
            case .smartMagnify:
                target.smartMagnify(with: event)
                return
            case .scrollWheel:
                target.scrollWheel(with: event)
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // While typing a text annotation, leave shortcuts to the text system.
        if firstResponder is NSTextView {
            return super.performKeyEquivalent(with: event)
        }
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }
        let shift = modifiers.contains(.shift)

        if event.keyCode == 51, !shift { // Command-Delete
            onCommand?(.delete)
            return true
        }

        let command: EditorCommand?
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", shift) {
        case ("c", false): command = .copy
        case ("c", true): command = .copyText
        case ("s", false): command = .save
        case ("s", true): command = .saveAs
        case ("z", false): command = .undo
        case ("z", true): command = .redo
        case ("w", false): command = .close
        case ("r", false): command = .autoRedact
        case ("=", false), ("+", true), ("+", false): command = .zoomIn
        case ("-", false): command = .zoomOut
        case ("0", false): command = .zoomFit
        case ("1", false): command = .zoomActual
        default: command = nil
        }
        if let command {
            onCommand?(command)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    let capture: Capture
    var onClose: (() -> Void)?

    // Toolbar pieces that follow the model.
    private let nameField = NSTextField()
    private var toolsItem: NSToolbarItemGroup?
    private var historyItem: NSToolbarItemGroup?
    private var noBackdropItem: NSMenuItem?
    private var subscription: AnyCancellable?

    private let model: EditorModel
    private let canvas: EditorCanvasView
    private let window: EditorWindow
    private var isScanning = false
    /// True once Done or Delete has decided what happens to the capture.
    private var isSettled = false

    init(capture: Capture) {
        let editorModel = EditorModel(image: capture.image, scale: capture.scale, name: capture.name)
        self.capture = capture
        self.model = editorModel
        self.canvas = EditorCanvasView(model: editorModel)

        // Size the window around the image, within sensible limits.
        let visible = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let natural = capture.pointSize
        let width = min(max(natural.width + 72, EditorLayout.comfortableWidth), visible.width * 0.92)
        let height = min(max(natural.height + 156, 600), visible.height * 0.9)
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )

        self.window = EditorWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = capture.name
        installToolbar()
        window.backgroundColor = .underPageBackgroundColor
        window.isReleasedWhenClosed = false
        window.contentMinSize = EditorLayout.minimumWindowSize
        window.delegate = self
        window.onCommand = { [weak self] command in self?.perform(command) }

        window.gestureTarget = canvas
        canvas.onDone = { [weak self] in self?.perform(.done) }

        let root = EditorRootView(model: editorModel, canvas: canvas) { [weak self] command in
            self?.perform(command)
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(frame, display: false)
    }

    /// Applies whatever is in the name field. Called before any command and on
    /// close, so Save, Convert and drag-out always use the name on screen.
    @discardableResult
    private func applyName() -> Bool {
        let before = capture.name
        // The name field in the toolbar is what the user sees, so it wins.
        let typed = nameField.stringValue
        if !typed.isEmpty, typed != model.captureName {
            model.captureName = typed
        }
        let applied = CaptureController.shared.rename(capture, to: model.captureName)
        if model.captureName != applied {
            model.captureName = applied
        }
        window.title = applied
        if nameField.stringValue != applied {
            nameField.stringValue = applied
        }
        return applied != before
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // SwiftUI installs the canvas on its first layout pass, so focus it a beat later.
        after(0.05) { [weak self] in
            guard let self, self.canvas.hostWindow != nil else { return }
            self.window.makeFirstResponder(self.canvas)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window keeps the edits: the edited image replaces the
        // original wherever it already went (clipboard, saved file), so a
        // redacted capture never leaves its unredacted original behind.
        applyName()
        if !isSettled {
            isSettled = true
            canvas.commitText()
            if model.hasEdits {
                applyEdits()
                CaptureController.shared.keepEdits(capture)
            }
        }
        // Release the controller only after AppKit has finished closing the window.
        let handler = onClose
        after(0.3) {
            handler?()
        }
    }

    // MARK: Toolbar

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "kiwi.editor")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [.editorTools]
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden

        subscription = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the change lands; read it on the next turn.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.syncToolbar()
                }
            }
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.editorName, .flexibleSpace, .editorTools, .flexibleSpace,
         .editorHistory, .editorRedact, .editorText, .editorBackdrop, .editorZoom]
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
        case .editorName:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Name"
            item.toolTip = "Rename this capture: type a name and press Return"
            nameField.stringValue = model.captureName
            nameField.placeholderString = "Name"
            nameField.bezelStyle = .roundedBezel
            nameField.lineBreakMode = .byTruncatingMiddle
            nameField.target = self
            nameField.action = #selector(nameSubmitted)
            nameField.translatesAutoresizingMaskIntoConstraints = false
            nameField.widthAnchor.constraint(equalToConstant: 190).isActive = true
            item.view = nameField
            return item

        case .editorTools:
            let tools = Tool.allCases
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: tools.map { Self.symbol($0.symbol, $0.title) },
                selectionMode: .selectOne,
                labels: tools.map(\.title),
                target: self,
                action: #selector(toolPicked(_:))
            )
            group.label = "Tools"
            group.controlRepresentation = .expanded
            group.visibilityPriority = .high
            for (item, tool) in zip(group.subitems, tools) {
                item.toolTip = "\(tool.title) (\(tool.key.uppercased()))"
            }
            group.selectedIndex = tools.firstIndex(of: model.tool) ?? 0
            toolsItem = group
            return group

        case .editorHistory:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [Self.symbol("arrow.uturn.backward", "Undo"), Self.symbol("arrow.uturn.forward", "Redo")],
                selectionMode: .momentary,
                labels: ["Undo", "Redo"],
                target: self,
                action: #selector(historyPicked(_:))
            )
            group.label = "Undo and Redo"
            group.controlRepresentation = .expanded
            let tips = ["Undo (⌘Z)", "Redo (⇧⌘Z)"]
            for (item, tip) in zip(group.subitems, tips) {
                item.toolTip = tip
                item.autovalidates = false
            }
            historyItem = group
            syncToolbar()
            return group

        case .editorRedact:
            return button(identifier, "Redact", "wand.and.stars", #selector(redactPicked),
                          tip: "Redact: find and cover emails, phone numbers, cards, IDs, keys and addresses (⌘R)")

        case .editorText:
            return button(identifier, "Copy Text", "text.viewfinder", #selector(textPicked),
                          tip: "Copy text: drag over the part you want. ⇧⌘C copies all the text in the image.")

        case .editorBackdrop:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = "Background"
            item.image = Self.symbol("rectangle.inset.filled", "Background")
            item.toolTip = "Background: set the image on a coloured backdrop with rounded corners and a shadow"
            let menu = NSMenu()
            menu.autoenablesItems = false
            for backdrop in Backdrop.allCases {
                let entry = NSMenuItem(title: backdrop.title, action: #selector(backdropPicked(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = backdrop.rawValue
                menu.addItem(entry)
            }
            menu.addItem(.separator())
            let none = NSMenuItem(title: "No Background", action: #selector(backdropCleared), keyEquivalent: "")
            none.target = self
            none.isEnabled = model.hasBackdrop
            menu.addItem(none)
            noBackdropItem = none
            item.menu = menu
            return item

        case .editorZoom:
            let group = NSToolbarItemGroup(
                itemIdentifier: identifier,
                images: [
                    Self.symbol("minus.magnifyingglass", "Zoom Out"),
                    Self.symbol("arrow.up.left.and.arrow.down.right", "Fit"),
                    Self.symbol("plus.magnifyingglass", "Zoom In"),
                ],
                selectionMode: .momentary,
                labels: ["Zoom Out", "Zoom to Fit", "Zoom In"],
                target: self,
                action: #selector(zoomPicked(_:))
            )
            group.label = "Zoom"
            group.controlRepresentation = .expanded
            let tips = ["Zoom out (⌘−)", "Fit to window (⌘0). ⌘1 shows actual size.", "Zoom in (⌘+)"]
            for (item, tip) in zip(group.subitems, tips) {
                item.toolTip = tip
            }
            return group

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

    /// Brings the toolbar in line with the model after any change.
    private func syncToolbar() {
        if let index = Tool.allCases.firstIndex(of: model.tool), let tools = toolsItem, tools.selectedIndex != index {
            tools.selectedIndex = index
        }
        if let history = historyItem, history.subitems.count == 2 {
            history.subitems[0].isEnabled = model.canUndo
            history.subitems[1].isEnabled = model.canRedo
        }
        noBackdropItem?.isEnabled = model.hasBackdrop
        if nameField.currentEditor() == nil, nameField.stringValue != model.captureName {
            nameField.stringValue = model.captureName
        }
    }

    @objc private func nameSubmitted() {
        perform(.rename)
    }

    @objc private func toolPicked(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        let tools = Tool.allCases
        guard tools.indices.contains(group.selectedIndex) else { return }
        canvas.commitText()
        model.tool = tools[group.selectedIndex]
        window.makeFirstResponder(canvas)
    }

    @objc private func historyPicked(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        perform(group.selectedIndex == 0 ? .undo : .redo)
    }

    @objc private func zoomPicked(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup else { return }
        switch group.selectedIndex {
        case 0: perform(.zoomOut)
        case 1: perform(.zoomFit)
        default: perform(.zoomIn)
        }
    }

    @objc private func redactPicked() {
        perform(.autoRedact)
    }

    @objc private func textPicked() {
        perform(.pickText)
    }

    @objc private func backdropPicked(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, let backdrop = Backdrop(rawValue: name) else { return }
        perform(.backdrop(backdrop))
    }

    @objc private func backdropCleared() {
        perform(.backdrop(nil))
    }

    // MARK: Commands

    private func perform(_ command: EditorCommand) {
        let renamed = applyName()
        canvas.commitText()
        switch command {
        case .undo:
            model.undo()
        case .redo:
            model.redo()
        case .copy:
            applyEdits()
            CaptureController.shared.copy(capture)
        case .save:
            applyEdits()
            CaptureController.shared.save(capture)
        case .saveAs:
            saveAs()
        case .done:
            isSettled = true
            applyEdits()
            CaptureController.shared.finishEditing(capture)
            window.close()
        case .delete:
            isSettled = true
            // A file opened from disk is only closed; Kiwi never deletes originals.
            if capture.isScreenshot {
                CaptureController.shared.delete(capture)
            }
            window.close()
        case .close:
            window.close()
        case .autoRedact:
            autoRedact()
        case .pin:
            applyEdits()
            PinController.shared.pin(capture.image, scale: capture.scale)
            Toast.show("Pinned  ·  double-click the pin to close it", symbol: "pin.fill")
        case .backdrop(let backdrop):
            if model.setBackdrop(backdrop) {
                canvas.zoomToFit()
            } else {
                Toast.error("This image is too large for a background")
            }
        case .copyText:
            copyText(in: nil)
        case .pickText:
            Toast.show("Drag over the text you want  ·  ⇧⌘C copies all of it", symbol: "text.viewfinder")
            canvas.pickRegion { [weak self] rect in
                self?.copyText(in: rect)
            }
        case .rename:
            // Return in the name field: hand the keyboard back to the canvas.
            window.makeFirstResponder(canvas)
            if renamed {
                Toast.show("Renamed to \(capture.name)", symbol: "pencil")
            }
        case .export(let format):
            export(as: format)
        case .zoomIn:
            canvas.zoomIn()
        case .zoomOut:
            canvas.zoomOut()
        case .zoomFit:
            canvas.zoomToFit()
        case .zoomActual:
            canvas.zoomToActualSize()
        }
    }

    /// Copies text from the image to the clipboard: everything, or just what is
    /// inside `region` (image pixels). It reads the image as it will be
    /// exported, so anything under a redaction box is not copied.
    private func copyText(in region: CGRect?) {
        var image = model.rendered()
        if let region {
            // A little margin keeps letters at the edge of the box readable.
            let padded = region.insetBy(dx: -6, dy: -6).integral.intersection(model.pixelBounds)
            guard let cropped = image.cropping(to: padded) else {
                Toast.error("Couldn't read that area")
                return
            }
            image = cropped
        }
        let source = image
        Toast.show("Reading text…", symbol: "text.viewfinder")
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<String, Error> = Result { try TextReader.read(source) }
            Task { @MainActor in
                switch outcome {
                case .success(let text) where text.isEmpty:
                    Toast.show("No text found", symbol: "text.viewfinder")
                case .success(let text):
                    Clipboard.copy(text: text)
                    let count = text.split(separator: "\n").count
                    Toast.show("Copied \(count) \(count == 1 ? "line" : "lines") of text", symbol: "doc.on.doc.fill")
                case .failure:
                    Toast.error("Couldn't read the text")
                }
            }
        }
    }

    /// Writes the edited image to the screenshots folder in another format.
    private func export(as format: ImageFormat) {
        applyEdits()
        let image = capture.image
        let scale = capture.scale
        let name = capture.name
        let folder = Prefs.shared.saveFolderURL
        let quality = Prefs.shared.convertQuality

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<URL, Error> = Result {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = CaptureStore.uniqueURL(in: folder, name: name, ext: format.fileExtension)
                try ImageEngine.write(image, format: format, to: url, quality: quality, scale: scale)
                return url
            }
            Task { @MainActor in
                switch outcome {
                case .success(let url):
                    Toast.show("Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill")
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let error):
                    Toast.error(error.localizedDescription)
                }
            }
        }
    }

    /// Finds sensitive text in the image and covers it with solid boxes the
    /// user can still move, delete or undo before exporting.
    private func autoRedact() {
        guard !isScanning else { return }
        let options = Prefs.shared.redactOptions
        guard !options.categories.isEmpty || options.faces else {
            Toast.error("Turn on something to redact in Settings")
            return
        }
        isScanning = true
        let image = model.base
        Toast.show("Looking for sensitive text…", symbol: "eye.slash")

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Result<[PIIScanner.Finding], Error> = Result {
                try PIIScanner.findings(in: image, options: options)
            }
            Task { @MainActor in
                self.isScanning = false
                guard self.model.base === image else {
                    Toast.error("The image changed. Run Redact again.")
                    return
                }
                switch outcome {
                case .success(let findings) where findings.isEmpty:
                    Toast.show("Nothing sensitive found", symbol: "checkmark.shield.fill")
                case .success(let findings):
                    let added = Set(self.model.addRedactions(findings.map(\.rect)))
                    Toast.show("Covered \(PIIScanner.summary(of: findings))", symbol: "eye.slash.fill")
                    // Outline the new boxes for a few seconds so they are easy to check.
                    self.model.flashIDs = added
                    after(4) {
                        if self.model.flashIDs == added {
                            self.model.flashIDs = []
                        }
                    }
                case .failure:
                    Toast.error("Couldn't scan the image")
                }
            }
        }
    }

    /// Burns the current annotations into the capture so copy, save and
    /// drag-out all use the edited image.
    private func applyEdits() {
        capture.image = model.rendered()
    }

    private func saveAs() {
        applyEdits()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = capture.name + ".png"
        panel.directoryURL = Prefs.shared.saveFolderURL
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = CaptureStore.pngData(capture.image, scale: capture.scale) else {
            Toast.error("Couldn't encode the image")
            return
        }
        do {
            try CaptureStore.writePrivately(data, to: url)
            Toast.show("Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill")
        } catch {
            Toast.error("Couldn't save the file")
        }
    }
}

// MARK: - Toolbar identifiers

private extension NSToolbarItem.Identifier {
    static let editorName = NSToolbarItem.Identifier("kiwi.editor.name")
    static let editorTools = NSToolbarItem.Identifier("kiwi.editor.tools")
    static let editorHistory = NSToolbarItem.Identifier("kiwi.editor.history")
    static let editorRedact = NSToolbarItem.Identifier("kiwi.editor.redact")
    static let editorText = NSToolbarItem.Identifier("kiwi.editor.text")
    static let editorBackdrop = NSToolbarItem.Identifier("kiwi.editor.backdrop")
    static let editorZoom = NSToolbarItem.Identifier("kiwi.editor.zoom")
}

// MARK: - Window content

private struct CanvasRepresentable: NSViewRepresentable {
    let canvas: EditorCanvasView

    func makeNSView(context: Context) -> EditorCanvasView { canvas }
    func updateNSView(_ nsView: EditorCanvasView, context: Context) {}
}

/// The canvas, with a bar below it for colour, size and what to do with the
/// result. Tools, history and zoom are in the window's toolbar.
private struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    let canvas: EditorCanvasView
    let perform: (EditorCommand) -> Void

    var body: some View {
        VStack(spacing: 0) {
            CanvasRepresentable(canvas: canvas)
            Divider()
            // Labels go first when space is short, then the bar takes two rows.
            ViewThatFits(in: .horizontal) {
                row(labels: true)
                row(labels: false)
                VStack(spacing: 8) {
                    StyleControls(model: model)
                    actions(labels: false)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func row(labels: Bool) -> some View {
        HStack(spacing: 12) {
            StyleControls(model: model)
            Spacer(minLength: 12)
            Text("\(model.zoomPercent)%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help("Zoom. Pinch or ⌘-scroll to change it.")
            actions(labels: labels)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func actions(labels: Bool) -> some View {
        HStack(spacing: 8) {
            Button(role: .destructive) { perform(.delete) } label: {
                Image(systemName: "trash")
            }
            .help("Delete this screenshot (⌘⌫)")

            Button { perform(.pin) } label: {
                Image(systemName: "pin")
            }
            .help("Pin: keep this image floating above your other windows")

            Button { perform(.save) } label: {
                actionLabel("Save", "square.and.arrow.down", labels)
            }
            .help("Save to your screenshots folder (⌘S). ⇧⌘S to choose a location.")

            Menu {
                ForEach(ImageFormat.allCases, id: \.self) { format in
                    Button("Save as \(format.title)") { perform(.export(format)) }
                }
            } label: {
                actionLabel("Convert", "arrow.triangle.2.circlepath", labels)
            }
            .fixedSize()
            .help("Convert: save the edited image to your screenshots folder in another format")

            Button { perform(.copy) } label: {
                actionLabel("Copy", "doc.on.doc", labels)
            }
            .help("Copy to clipboard (⌘C)")

            Button("Done") { perform(.done) }
                .buttonStyle(.borderedProminent)
                .tint(Theme.kiwi)
                .help("Copy and close (Return)")
        }
        .controlSize(.large)
    }

    /// A button label that keeps its icon and drops its text when space is short.
    @ViewBuilder
    private func actionLabel(_ title: String, _ symbol: String, _ showLabel: Bool) -> some View {
        if showLabel {
            Label(title, systemImage: symbol)
        } else {
            Image(systemName: symbol)
        }
    }
}

/// Colour swatches, the system colour picker (wheel, sliders, eyedropper)
/// and the size slider.
private struct StyleControls: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Theme.palette.indices, id: \.self) { index in
                Button {
                    model.setColor(index)
                } label: {
                    Circle()
                        .fill(Color(nsColor: Theme.palette[index]))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .padding(3)
                        .overlay {
                            if model.customColor == nil, model.colorIndex == index {
                                Circle().strokeBorder(Color.primary, lineWidth: 1.5)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            ColorPicker("Custom colour", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .help("Any colour: opens the colour wheel")

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 4)

            Image(systemName: "lineweight")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Slider(value: thickness, in: 1...20)
                .controlSize(.small)
                .frame(width: 110)
                .help("Size of strokes and text")
            Circle()
                .fill(Color(nsColor: model.color))
                .frame(width: model.thickness, height: model.thickness)
                .frame(width: 22, height: 22)
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: model.color) },
            set: { model.setCustomColor(NSColor($0)) }
        )
    }

    private var thickness: Binding<Double> {
        Binding(
            get: { Double(model.thickness) },
            set: { model.setThickness(CGFloat($0)) }
        )
    }
}
