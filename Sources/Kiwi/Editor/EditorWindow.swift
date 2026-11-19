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
}

/// Window that turns Command-key shortcuts into editor commands.
final class EditorWindow: NSWindow {
    var onCommand: ((EditorCommand) -> Void)?

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

    init(capture: Capture) {
        let editorModel = EditorModel(image: capture.image, scale: capture.scale)
        self.capture = capture
        self.model = editorModel
        self.canvas = EditorCanvasView(model: editorModel)

        // Size the window around the image, within sensible limits.
        let visible = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let natural = capture.pointSize
        let width = min(max(natural.width + 72, 860), visible.width * 0.9)
        let height = min(max(natural.height + 156, 560), visible.height * 0.9)
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
        window.contentMinSize = NSSize(width: 860, height: 520)
        window.delegate = self
        window.onCommand = { [weak self] command in self?.perform(command) }

        canvas.onDone = { [weak self] in self?.perform(.done) }

        let root = EditorRootView(model: model, canvas: canvas) { [weak self] command in
            self?.perform(command)
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.contentView = host
        window.setFrame(frame, display: false)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // SwiftUI installs the canvas on its first layout pass, so focus it a beat later.
        after(0.05) { [weak self] in
            guard let self, self.canvas.window != nil else { return }
            self.window.makeFirstResponder(self.canvas)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Release the controller only after AppKit has finished closing the window.
        let handler = onClose
        after(0.3) {
            handler?()
        }
    }

    // MARK: Commands

    private func perform(_ command: EditorCommand) {
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
            applyEdits()
            CaptureController.shared.finishEditing(capture)
            window.close()
        case .delete:
            // A file opened from disk is only closed; Kiwi never deletes originals.
            if capture.isScreenshot {
                CaptureController.shared.delete(capture)
            }
            window.close()
        case .close:
            window.close()
        case .autoRedact:
            autoRedact()
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
        ZStack {
            CanvasRepresentable(canvas: canvas)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                toolBar
                Spacer(minLength: 0)
                HStack(alignment: .bottom, spacing: 12) {
                    styleBar
                    Spacer(minLength: 0)
                    actionBar
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 16)
        }
    }

    // Tools and history, centered at the top.
    private var toolBar: some View {
        HStack(spacing: 2) {
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

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 6)

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

            Divider()
                .frame(height: 18)
                .padding(.horizontal, 6)

            Button { perform(.autoRedact) } label: {
                Label("Redact", systemImage: "wand.and.stars")
                    .font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Find and cover emails, phone numbers, cards, IDs, keys and addresses (⌘R)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    // Colour and thickness, bottom left.
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

    // What to do with the result, bottom right.
    private var actionBar: some View {
        HStack(spacing: 8) {
            Button { perform(.delete) } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonBorderShape(.circle)
            .buttonStyle(.glass)
            .help("Delete this screenshot (⌘⌫)")

            Button { perform(.save) } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.glass)
            .help("Save to your screenshots folder (⌘S). ⇧⌘S to choose a location.")

            Button { perform(.copy) } label: {
                Label("Copy", systemImage: "doc.on.doc")
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
