import AppKit
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
final class EditorWindowController: NSObject, NSWindowDelegate {
    let capture: Capture
    var onClose: (() -> Void)?

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
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .underPageBackgroundColor
        window.isReleasedWhenClosed = false
        window.contentMinSize = EditorLayout.minimumWindowSize
        window.delegate = self
        window.onCommand = { [weak self] command in self?.perform(command) }

        window.gestureTarget = canvas
        canvas.onDone = { [weak self] in self?.perform(.done) }

        let root = EditorRootView(model: model, canvas: canvas) { [weak self] command in
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
        let applied = CaptureController.shared.rename(capture, to: model.captureName)
        if model.captureName != applied {
            model.captureName = applied
        }
        window.title = applied
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
            let outcome: Result<[CGRect], Error> = Result { try PIIScanner.scan(image, options: options) }
            Task { @MainActor in
                self.isScanning = false
                guard self.model.base === image else {
                    Toast.error("The image changed. Run Redact again.")
                    return
                }
                switch outcome {
                case .success(let rects) where rects.isEmpty:
                    Toast.show("Nothing sensitive found", symbol: "checkmark.shield.fill")
                case .success(let rects):
                    self.model.addRedactions(rects)
                    Toast.show("Covered \(rects.count) \(rects.count == 1 ? "item" : "items")", symbol: "eye.slash.fill")
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

// MARK: - SwiftUI chrome

private struct CanvasRepresentable: NSViewRepresentable {
    let canvas: EditorCanvasView

    func makeNSView(context: Context) -> EditorCanvasView { canvas }
    func updateNSView(_ nsView: EditorCanvasView, context: Context) {}
}

private struct EditorRootView: View {
    @ObservedObject var model: EditorModel
    let canvas: EditorCanvasView
    let perform: (EditorCommand) -> Void

    var body: some View {
        GeometryReader { geometry in
            chrome(width: geometry.size.width)
        }
    }

    /// The canvas with the floating controls on top, arranged for `width`.
    private func chrome(width: CGFloat) -> some View {
        ZStack {
            CanvasRepresentable(canvas: canvas)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topControls(EditorLayout.top(forWidth: width))
                Spacer(minLength: 0)
                bottomControls(EditorLayout.bottom(forWidth: width))
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func topControls(_ layout: EditorLayout.Top) -> some View {
        switch layout {
        case .full:
            HStack(alignment: .top, spacing: 12) {
                nameField(maxWidth: 230)
                Spacer(minLength: 0)
                toolBar(redactLabel: true)
            }
        case .medium:
            HStack(alignment: .top, spacing: 12) {
                nameField(maxWidth: 150)
                Spacer(minLength: 0)
                toolBar(redactLabel: false)
            }
        case .stacked:
            VStack(spacing: 6) {
                HStack(spacing: 12) {
                    nameField(maxWidth: .infinity)
                    utilityBar
                }
                toolStrip
            }
        }
    }

    @ViewBuilder
    private func bottomControls(_ layout: EditorLayout.Bottom) -> some View {
        switch layout {
        case .full:
            HStack(alignment: .bottom, spacing: 12) {
                styleBar
                Spacer(minLength: 0)
                actionBar(showLabels: true)
            }
        case .icons:
            HStack(alignment: .bottom, spacing: 12) {
                styleBar
                Spacer(minLength: 0)
                actionBar(showLabels: false)
            }
        case .stacked:
            VStack(spacing: 8) {
                styleBar
                actionBar(showLabels: false)
            }
        }
    }

    // MARK: Top pieces

    /// The capture's name. Editing it renames the capture.
    private func nameField(maxWidth: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Name this capture", text: $model.captureName)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .onSubmit { perform(.rename) }
        }
        .padding(.horizontal, 14)
        .frame(minWidth: 110, maxWidth: maxWidth)
        .frame(height: 42)
        .glassEffect(.regular, in: .capsule)
        .help("Rename this capture: type a name and press Return")
    }

    /// Everything on one capsule: tools, history, redact, zoom.
    private func toolBar(redactLabel: Bool) -> some View {
        HStack(spacing: 2) {
            toolButtons
            separator
            historyButtons
            separator
            redactButton(showLabel: redactLabel)
            separator
            zoomControls
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    /// The drawing tools alone, for the second row of a narrow window.
    private var toolStrip: some View {
        HStack(spacing: 2) {
            toolButtons
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    /// History, redact and zoom, beside the name in a narrow window.
    private var utilityBar: some View {
        HStack(spacing: 2) {
            historyButtons
            separator
            redactButton(showLabel: false)
            separator
            zoomControls
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private var separator: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, 6)
    }

    private var toolButtons: some View {
        ForEach(Tool.allCases) { tool in
            Button {
                canvas.commitText()
                model.tool = tool
            } label: {
                Image(systemName: tool.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.tool == tool ? Color.white : Color.primary)
                    .frame(width: 32, height: 32)
                    .background {
                        if model.tool == tool {
                            Circle().fill(Theme.kiwi)
                        }
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("\(tool.title) (\(tool.key.uppercased()))")
        }
    }

    private var historyButtons: some View {
        HStack(spacing: 2) {
            Button { perform(.undo) } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canUndo)
            .help("Undo (⌘Z)")

            Button { perform(.redo) } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canRedo)
            .help("Redo (⇧⌘Z)")
        }
    }

    private func redactButton(showLabel: Bool) -> some View {
        Button { perform(.autoRedact) } label: {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                if showLabel {
                    Text("Redact")
                }
            }
            .font(.system(size: 12.5, weight: .semibold))
            .padding(.horizontal, showLabel ? 10 : 8)
            .frame(height: 30)
            .background(Capsule().fill(Color.primary.opacity(0.1)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Redact: find and cover emails, phone numbers, cards, IDs, keys and addresses (⌘R)")
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button { perform(.zoomOut) } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom out (⌘−)")

            Button { perform(.zoomFit) } label: {
                Text("\(model.zoomPercent)%")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .frame(width: 44, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fit to window (⌘0). ⌘1 shows actual size. Pinch or ⌘-scroll to zoom.")

            Button { perform(.zoomIn) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom in (⌘+)")
        }
    }

    // MARK: Bottom pieces

    /// Colour and thickness.
    private var styleBar: some View {
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
                            if model.colorIndex == index {
                                Circle().strokeBorder(Color.primary, lineWidth: 1.5)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 4)

            ForEach(Weight.allCases) { weight in
                Button {
                    model.setWeight(weight)
                } label: {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: dotSize(weight), height: dotSize(weight))
                        .frame(width: 24, height: 24)
                        .background {
                            if model.weight == weight {
                                Circle().fill(Color.primary.opacity(0.15))
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Thickness")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
    }

    private func dotSize(_ weight: Weight) -> CGFloat {
        switch weight {
        case .small: return 4
        case .medium: return 8
        case .large: return 12
        }
    }

    /// A button label that keeps its icon and drops its text when space is short.
    @ViewBuilder
    private func actionLabel(_ title: String, _ symbol: String, showLabel: Bool) -> some View {
        if showLabel {
            Label(title, systemImage: symbol)
        } else {
            Image(systemName: symbol)
        }
    }

    /// What to do with the result.
    private func actionBar(showLabels: Bool) -> some View {
        HStack(spacing: 8) {
            Button { perform(.delete) } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonBorderShape(.circle)
            .buttonStyle(.glass)
            .help("Delete this screenshot (⌘⌫)")

            Button { perform(.save) } label: {
                actionLabel("Save", "square.and.arrow.down", showLabel: showLabels)
            }
            .buttonStyle(.glass)
            .help("Save to your screenshots folder (⌘S). ⇧⌘S to choose a location.")

            Menu {
                ForEach(ImageFormat.allCases, id: \.self) { format in
                    Button("Save as \(format.title)") { perform(.export(format)) }
                }
            } label: {
                actionLabel("Convert", "arrow.triangle.2.circlepath", showLabel: showLabels)
            }
            .buttonStyle(.glass)
            .fixedSize()
            .help("Convert: save the edited image to your screenshots folder in another format")

            Button { perform(.copy) } label: {
                actionLabel("Copy", "doc.on.doc", showLabel: showLabels)
            }
            .buttonStyle(.glass)
            .help("Copy to clipboard (⌘C)")

            Button { perform(.done) } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.kiwi)
            .help("Copy and close (Return)")
        }
        .controlSize(.large)
    }
}
