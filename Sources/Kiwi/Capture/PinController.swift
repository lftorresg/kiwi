import AppKit

/// Keeps captures floating above other windows, for reference while you work.
/// Pins are Kiwi windows, so they never appear in later captures.
@MainActor
final class PinController {
    static let shared = PinController()

    private var panels: [FloatingPanel] = []

    private init() {}

    func pin(_ image: CGImage, scale: CGFloat) {
        let screen = NSScreen.underMouse ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)

        let divisor = max(1, scale)
        var size = NSSize(width: CGFloat(image.width) / divisor, height: CGFloat(image.height) / divisor)
        guard size.width > 0, size.height > 0 else { return }
        // Start no larger than about half the screen.
        let fit = min(1, area.width * 0.5 / size.width, area.height * 0.6 / size.height)
        size = NSSize(width: max(60, size.width * fit), height: max(40, size.height * fit))

        let panel = FloatingPanel(size: size, level: .floating)
        panel.hasShadow = true
        panel.isMovable = true

        let view = PinView(frame: NSRect(origin: .zero, size: size))
        view.show(image, scale: scale, naturalSize: size)
        view.onClose = { [weak self, weak panel] in
            guard let panel else { return }
            self?.close(panel)
        }
        view.onCloseAll = { [weak self] in
            self?.closeAll()
        }
        panel.contentView = view

        // Top right, stepping down and left so several pins do not stack exactly.
        let step = CGFloat(panels.count % 6) * 26
        let origin = NSPoint(
            x: area.maxX - size.width - 24 - step,
            y: area.maxY - size.height - 24 - step
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        panels.append(panel)
    }

    private func close(_ panel: FloatingPanel) {
        panel.orderOut(nil)
        panels.removeAll { $0 === panel }
    }

    func closeAll() {
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
    }
}

/// The content of a pin: drag to move, pinch or scroll to resize,
/// double-click to close, right-click for a menu.
final class PinView: NSView {
    var onClose: (() -> Void)?
    var onCloseAll: (() -> Void)?

    private var image: CGImage?
    private var scale: CGFloat = 1
    private var naturalSize = NSSize(width: 100, height: 100)

    func show(_ image: CGImage, scale: CGFloat, naturalSize: NSSize) {
        self.image = image
        self.scale = scale
        self.naturalSize = naturalSize
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspect
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        toolTip = "Drag to move · pinch or scroll to resize · double-click to close"
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onClose?()
        } else {
            hostWindow?.performDrag(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        resize(by: 1 + event.scrollingDeltaY * 0.01)
    }

    override func magnify(with event: NSEvent) {
        resize(by: 1 + event.magnification)
    }

    /// Scales the pin about its centre, between a fifth and four times its starting size.
    private func resize(by factor: CGFloat) {
        guard let window = hostWindow, factor > 0 else { return }
        let frame = window.frame
        var width = frame.width * factor
        width = min(max(width, naturalSize.width * 0.2), naturalSize.width * 4)
        let height = width * naturalSize.height / max(1, naturalSize.width)
        let resized = NSRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )
        window.setFrame(resized, display: true)
        window.invalidateShadow()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: #selector(copyImage), keyEquivalent: "")
        copy.target = self
        menu.addItem(copy)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Pin", action: #selector(closePin), keyEquivalent: "")
        close.target = self
        menu.addItem(close)
        let closeAll = NSMenuItem(title: "Close All Pins", action: #selector(closeAllPins), keyEquivalent: "")
        closeAll.target = self
        menu.addItem(closeAll)
        return menu
    }

    @objc private func copyImage() {
        guard let image else { return }
        Clipboard.copy(image: image, scale: scale)
        Toast.show("Copied to clipboard", symbol: "doc.on.doc.fill")
    }

    @objc private func closePin() {
        onClose?()
    }

    @objc private func closeAllPins() {
        onCloseAll?()
    }
}
