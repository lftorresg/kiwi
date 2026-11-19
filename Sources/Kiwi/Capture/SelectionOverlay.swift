import AppKit

/// What the user picked in the selection overlay.
enum SelectionResult {
    /// `rect` is in the display's own point space with a top-left origin.
    case area(displayID: CGDirectDisplayID, rect: CGRect, screen: NSScreen)
    /// `rect` is the window's frame in the display's point space, top-left origin.
    case window(id: CGWindowID, rect: CGRect, screen: NSScreen)
    case cancelled
}

enum CaptureMode {
    case area
    case window
}

/// Shows one transparent overlay per display and reports the chosen area or window.
/// The overlay is a non-activating panel, so the app in front stays in front.
@MainActor
final class SelectionController {
    private var panels: [FloatingPanel] = []
    private var completion: ((SelectionResult) -> Void)?
    private(set) var mode: CaptureMode = .area

    var isActive: Bool { !panels.isEmpty }

    func begin(mode: CaptureMode, completion: @escaping (SelectionResult) -> Void) {
        guard !isActive else { return }
        self.mode = mode
        self.completion = completion

        for screen in NSScreen.screens {
            let panel = FloatingPanel(size: screen.frame.size, level: .screenSaver)
            panel.allowsKey = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.acceptsMouseMovedEvents = true

            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.controller = self
            view.targetScreen = screen
            panel.contentView = view
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
        }

        let mouse = NSEvent.mouseLocation
        let keyPanel = panels.first { NSMouseInRect(mouse, $0.frame, false) } ?? panels.first
        keyPanel?.makeKeyAndOrderFront(nil)
        if let view = keyPanel?.contentView {
            keyPanel?.makeFirstResponder(view)
        }
        refreshAll()
        // Kiwi's overlay is on screen now, so the list includes Kiwi and its windows can be excluded.
        ScreenGrabber.prewarm()
    }

    func toggleMode() {
        mode = (mode == .area) ? .window : .area
        for panel in panels {
            (panel.contentView as? SelectionView)?.reset()
        }
        refreshAll()
    }

    func finish(_ result: SelectionResult) {
        guard isActive else { return }
        let handler = completion
        completion = nil
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        handler?(result)
    }

    /// Called when the pointer moves onto one display so the others drop their crosshair.
    func pointerMoved(in active: SelectionView) {
        for panel in panels {
            guard let view = panel.contentView as? SelectionView, view !== active else { continue }
            view.clearPointer()
        }
        if let window = active.hostWindow, !window.isKeyWindow {
            window.makeKey()
            window.makeFirstResponder(active)
        }
    }

    private func refreshAll() {
        for panel in panels {
            panel.contentView?.needsDisplay = true
        }
    }

    /// Front-most normal window under the pointer, with its frame in global
    /// top-left-origin coordinates. Needs no permission.
    static func windowUnderPointer() -> (id: CGWindowID, frame: CGRect)? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)

        for info in list {
            guard
                let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = info[kCGWindowOwnerPID as String] as? Int, pid != Int(ownPID),
                let number = info[kCGWindowNumber as String] as? Int,
                let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                bounds.width >= 40, bounds.height >= 40
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }
            if bounds.contains(point) {
                return (CGWindowID(number), bounds)
            }
        }
        return nil
    }
}

/// Draws the dimmed screen, crosshair, selection rectangle and size label.
final class SelectionView: NSView {
    weak var controller: SelectionController?
    var targetScreen: NSScreen?

    private var pointer: NSPoint?
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var hoveredWindow: (id: CGWindowID, rect: NSRect)?

    private let dim = NSColor.black.withAlphaComponent(0.26)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func reset() {
        dragStart = nil
        dragCurrent = nil
        hoveredWindow = nil
        updateHoveredWindow()
        needsDisplay = true
    }

    func clearPointer() {
        guard pointer != nil || hoveredWindow != nil else { return }
        pointer = nil
        hoveredWindow = nil
        needsDisplay = true
    }

    private var selection: NSRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        let rect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        return rect.integral.intersection(bounds)
    }

    private func updateHoveredWindow() {
        guard controller?.mode == .window, let screen = targetScreen, pointer != nil else {
            hoveredWindow = nil
            return
        }
        guard let hit = SelectionController.windowUnderPointer() else {
            hoveredWindow = nil
            return
        }
        // Global top-left coordinates -> this view's bottom-left coordinates.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - hit.frame.maxY
        let rect = NSRect(
            x: hit.frame.minX - screen.frame.minX,
            y: cocoaY - screen.frame.minY,
            width: hit.frame.width,
            height: hit.frame.height
        )
        hoveredWindow = (hit.id, rect)
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        pointer = convert(event.locationInWindow, from: nil)
        controller?.pointerMoved(in: self)
        updateHoveredWindow()
        NSCursor.crosshair.set()
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if dragStart == nil { clearPointer() }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        guard let controller, let screen = targetScreen else { return }
        if controller.mode == .window {
            updateHoveredWindow()
            if let hoveredWindow {
                let frame = hoveredWindow.rect.intersection(bounds)
                let local = CGRect(
                    x: frame.minX,
                    y: bounds.height - frame.maxY,
                    width: frame.width,
                    height: frame.height
                )
                controller.finish(.window(id: hoveredWindow.id, rect: local, screen: screen))
            }
            return
        }
        dragStart = point
        dragCurrent = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        pointer = point
        dragCurrent = NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller, let screen = targetScreen, controller.mode == .area else { return }
        defer {
            dragStart = nil
            dragCurrent = nil
        }
        guard let rect = selection, rect.width >= 4, rect.height >= 4 else {
            needsDisplay = true
            return
        }
        guard let displayID = screen.displayID else {
            controller.finish(.cancelled)
            return
        }
        // Bottom-left view coordinates -> top-left display coordinates.
        let local = CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
        controller.finish(.area(displayID: displayID, rect: local, screen: screen))
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.finish(.cancelled)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // escape
            controller?.finish(.cancelled)
        case 49: // space
            if dragStart == nil { controller?.toggleMode() }
        default:
            break
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        dim.setFill()
        bounds.fill()

        if controller?.mode == .window {
            drawWindowMode(in: context)
        } else {
            drawAreaMode(in: context)
        }
    }

    private func drawAreaMode(in context: CGContext) {
        if let rect = selection, rect.width > 0, rect.height > 0 {
            // Punch the selection out of the dim layer.
            NSColor.clear.setFill()
            rect.fill(using: .copy)

            let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.stroke()

            drawCornerTicks(for: rect)
            drawLabel("\(Int(rect.width)) × \(Int(rect.height))", anchoredTo: rect)
        } else if let pointer {
            // Full-screen hairlines make pixel-precise starts easy.
            NSColor.white.withAlphaComponent(0.55).setFill()
            NSRect(x: bounds.minX, y: pointer.y.rounded() - 0.5, width: bounds.width, height: 1).fill()
            NSRect(x: pointer.x.rounded() - 0.5, y: bounds.minY, width: 1, height: bounds.height).fill()
            drawHint("Drag to capture  ·  Space for window  ·  Esc to cancel")
        }
    }

    private func drawWindowMode(in context: CGContext) {
        if let hoveredWindow {
            let rect = hoveredWindow.rect
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            Theme.kiwiNS.withAlphaComponent(0.22).setFill()
            rect.fill(using: .sourceOver)

            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
            border.lineWidth = 2
            Theme.kiwiNS.setStroke()
            border.stroke()
        }
        if pointer != nil {
            drawHint("Click a window  ·  Space for area  ·  Esc to cancel")
        }
    }

    private func drawCornerTicks(for rect: NSRect) {
        let length: CGFloat = min(14, rect.width / 3, rect.height / 3)
        guard length >= 4 else { return }
        let path = NSBezierPath()
        let corners: [(NSPoint, CGFloat, CGFloat)] = [
            (NSPoint(x: rect.minX, y: rect.minY), 1, 1),
            (NSPoint(x: rect.maxX, y: rect.minY), -1, 1),
            (NSPoint(x: rect.minX, y: rect.maxY), 1, -1),
            (NSPoint(x: rect.maxX, y: rect.maxY), -1, -1),
        ]
        for (corner, dx, dy) in corners {
            path.move(to: NSPoint(x: corner.x + dx * length, y: corner.y))
            path.line(to: corner)
            path.line(to: NSPoint(x: corner.x, y: corner.y + dy * length))
        }
        path.lineWidth = 3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        Theme.kiwiNS.setStroke()
        path.stroke()
    }

    private func pill(_ text: String) -> (NSAttributedString, NSSize) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        return (string, NSSize(width: ceil(size.width) + 18, height: ceil(size.height) + 8))
    }

    private func drawPill(_ string: NSAttributedString, in rect: NSRect) {
        let background = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        background.fill()
        let textSize = string.size()
        string.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
    }

    /// Size label: just below the selection, or inside it when there is no room.
    private func drawLabel(_ text: String, anchoredTo rect: NSRect) {
        let (string, size) = pill(text)
        var origin = NSPoint(x: rect.maxX - size.width, y: rect.minY - size.height - 8)
        if origin.y < bounds.minY + 4 {
            origin.y = rect.minY + 8
            origin.x = rect.maxX - size.width - 8
        }
        origin.x = max(bounds.minX + 4, origin.x)
        drawPill(string, in: NSRect(origin: origin, size: size))
    }

    private func drawHint(_ text: String) {
        let (string, size) = pill(text)
        let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 96)
        drawPill(string, in: NSRect(origin: origin, size: size))
    }
}
