import AppKit
import Combine

/// The drawing surface of the editor. Shows the image fitted to the window (or
/// zoomed and panned) and turns mouse and keyboard input into annotations.
final class EditorCanvasView: NSView, NSTextFieldDelegate {
    let model: EditorModel

    /// Called when the user presses Return on the canvas.
    var onDone: (() -> Void)?

    /// Space reserved for the floating toolbars above and below the image.
    private let insets = NSEdgeInsets(top: 78, left: 36, bottom: 78, right: 36)

    private var draft: Annotation?
    private var cropStart: CGPoint?
    private var cropRect: CGRect?
    private var movingID: UUID?
    private var lastMovePoint: CGPoint?
    private var didCheckpointMove = false
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var subscription: AnyCancellable?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        subscription = model.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the change lands; redraw on the next turn.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.needsDisplay = true
                    self.hostWindow?.invalidateCursorRects(for: self)
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hostWindow?.makeFirstResponder(self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        chooseInitialViewIfNeeded()
        viewChanged()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Geometry

    /// Explicit zoom as a fraction of actual size (1 = 100%). Nil means "fit the window".
    private var zoomFactor: CGFloat?
    /// How far the image centre is pushed from the viewport centre, in view points.
    private var pan = CGPoint.zero
    private var didChooseInitialView = false

    /// The part of the view not covered by the floating toolbars.
    private var viewport: CGRect {
        CGRect(
            x: insets.left,
            y: insets.top,
            width: max(1, bounds.width - insets.left - insets.right),
            height: max(1, bounds.height - insets.top - insets.bottom)
        )
    }

    /// Image size in points at 100%.
    private var naturalSize: CGSize {
        CGSize(width: model.pixelSize.width / model.scale, height: model.pixelSize.height / model.scale)
    }

    private var fitFactor: CGFloat {
        let natural = naturalSize
        guard natural.width > 0, natural.height > 0 else { return 1 }
        let area = viewport
        return min(1, area.width / natural.width, area.height / natural.height)
    }

    private var currentFactor: CGFloat { zoomFactor ?? fitFactor }

    /// Largest pan in each direction that still keeps an image edge at the viewport edge.
    private func panLimit(for factor: CGFloat) -> CGSize {
        let natural = naturalSize
        let area = viewport
        return CGSize(
            width: max(0, (natural.width * factor - area.width) / 2),
            height: max(0, (natural.height * factor - area.height) / 2)
        )
    }

    private func clampedPan(_ value: CGPoint, factor: CGFloat) -> CGPoint {
        let limit = panLimit(for: factor)
        return CGPoint(
            x: min(max(value.x, -limit.width), limit.width),
            y: min(max(value.y, -limit.height), limit.height)
        )
    }

    /// Where the image sits inside the view, in view points.
    var imageRect: CGRect {
        let natural = naturalSize
        let area = viewport
        guard natural.width > 0, natural.height > 0 else { return area }
        let factor = currentFactor
        let size = CGSize(width: natural.width * factor, height: natural.height * factor)
        let offset = clampedPan(pan, factor: factor)
        return CGRect(
            x: (area.midX - size.width / 2 + offset.x).rounded(),
            y: (area.midY - size.height / 2 + offset.y).rounded(),
            width: size.width,
            height: size.height
        )
    }

    // MARK: Zoom and pan

    /// Changes the zoom, keeping the image point under `anchor` (view coordinates) where it is.
    private func setZoom(_ factor: CGFloat, anchor: CGPoint? = nil) {
        commitText()
        let area = viewport
        let pivot = anchor ?? CGPoint(x: area.midX, y: area.midY)
        let before = imageRect
        let oldZoom = zoom
        guard oldZoom > 0, model.scale > 0 else { return }
        let imageX = (pivot.x - before.minX) / oldZoom
        let imageY = (pivot.y - before.minY) / oldZoom

        let lowest = fitFactor * 0.5
        let clamped = min(max(factor, lowest), 8)
        let natural = naturalSize
        let newZoom = clamped / model.scale
        let size = CGSize(width: natural.width * clamped, height: natural.height * clamped)
        let wanted = CGPoint(
            x: pivot.x - imageX * newZoom - (area.midX - size.width / 2),
            y: pivot.y - imageY * newZoom - (area.midY - size.height / 2)
        )
        zoomFactor = clamped
        pan = clampedPan(wanted, factor: clamped)
        viewChanged()
    }

    func zoomIn() { setZoom(currentFactor * 1.25) }
    func zoomOut() { setZoom(currentFactor / 1.25) }
    func zoomToActualSize() { setZoom(1) }

    func zoomToFit() {
        commitText()
        zoomFactor = nil
        pan = .zero
        viewChanged()
    }

    /// A long scrolling capture would be a sliver when fitted whole, so it
    /// opens fitted to the window's width, scrolled to the top.
    private func chooseInitialViewIfNeeded() {
        guard !didChooseInitialView, bounds.width > 200, bounds.height > 200 else { return }
        didChooseInitialView = true
        let natural = naturalSize
        let area = viewport
        guard natural.width > 0 else { return }
        let widthFit = min(1, area.width / natural.width)
        if natural.height * widthFit > area.height * 1.5 {
            zoomFactor = widthFit
            pan = CGPoint(x: 0, y: panLimit(for: widthFit).height)
        }
    }

    private func viewChanged() {
        needsDisplay = true
        hostWindow?.invalidateCursorRects(for: self)
        // Publish on the next turn: this can run while SwiftUI is laying the view out.
        after(0) { [weak self] in
            guard let self else { return }
            let percent = Int((self.currentFactor * 100).rounded())
            if self.model.zoomPercent != percent {
                self.model.zoomPercent = percent
            }
        }
    }

    override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        setZoom(currentFactor * (1 + event.magnification), anchor: anchor)
    }

    override func smartMagnify(with event: NSEvent) {
        if zoomFactor == nil {
            setZoom(1, anchor: convert(event.locationInWindow, from: nil))
        } else {
            zoomToFit()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let anchor = convert(event.locationInWindow, from: nil)
            setZoom(currentFactor * (1 + event.scrollingDeltaY * 0.01), anchor: anchor)
            return
        }
        let factor = currentFactor
        let limit = panLimit(for: factor)
        guard limit.width > 0 || limit.height > 0 else {
            super.scrollWheel(with: event)
            return
        }
        commitText()
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let moved = CGPoint(
            x: pan.x + event.scrollingDeltaX * step,
            y: pan.y + event.scrollingDeltaY * step
        )
        pan = clampedPan(moved, factor: factor)
        viewChanged()
    }

    /// View points per image pixel.
    private var zoom: CGFloat {
        let width = model.pixelSize.width
        return width > 0 ? imageRect.width / width : 1
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        let z = zoom
        return CGPoint(x: (point.x - rect.minX) / z, y: (point.y - rect.minY) / z)
    }

    private func viewRect(for imageSpace: CGRect) -> CGRect {
        let rect = imageRect
        let z = zoom
        return CGRect(
            x: rect.minX + imageSpace.minX * z,
            y: rect.minY + imageSpace.minY * z,
            width: imageSpace.width * z,
            height: imageSpace.height * z
        )
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), model.pixelSize.width),
            y: min(max(point.y, 0), model.pixelSize.height)
        )
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(imageRect, cursor: cursor)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let rect = imageRect
        let z = zoom

        // Soft shadow under the image.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -8),
            blur: 28,
            color: NSColor.black.withAlphaComponent(0.35).cgColor
        )
        NSColor.underPageBackgroundColor.setFill()
        rect.fill()
        context.restoreGState()

        // Image and annotations, drawn in image-pixel space.
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: z, y: z)
        context.interpolationQuality = .high
        AnnotationRenderer.drawImage(model.base, in: model.pixelBounds, context: context)
        for annotation in model.annotations {
            AnnotationRenderer.draw(annotation, in: context)
        }
        if let draft {
            AnnotationRenderer.draw(draft, in: context)
        }
        context.restoreGState()

        drawSelectionOutline()
        drawCropOverlay(in: rect)
    }

    private func drawSelectionOutline() {
        guard let id = model.selectedID,
              let selected = model.annotations.first(where: { $0.id == id }) else { return }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let outline = viewRect(for: selected.bounds).insetBy(dx: -4, dy: -4)
        context.saveGState()
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [5, 4])
        context.setStrokeColor(Theme.kiwiNS.cgColor)
        context.addPath(NSBezierPath(roundedRect: outline, xRadius: 6, yRadius: 6).cgPath)
        context.strokePath()
        context.restoreGState()
    }

    private func drawCropOverlay(in rect: CGRect) {
        guard let cropRect else { return }
        let keep = viewRect(for: cropRect)
        let shade = NSBezierPath(rect: rect)
        shade.append(NSBezierPath(rect: keep))
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        shade.fill()

        let border = NSBezierPath(rect: keep)
        border.lineWidth = 1.5
        NSColor.white.setStroke()
        border.stroke()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        hostWindow?.makeFirstResponder(self)
        commitText()

        let point = imagePoint(for: event)
        let inside = model.pixelBounds.contains(point)

        switch model.tool {
        case .select:
            if let hit = model.annotation(at: point, slop: 6 / zoom) {
                model.selectedID = hit.id
                movingID = hit.id
                lastMovePoint = point
                didCheckpointMove = false
            } else {
                model.selectedID = nil
            }

        case .text:
            guard inside else { return }
            model.selectedID = nil
            beginText(at: point)

        case .counter:
            guard inside else { return }
            model.selectedID = nil
            model.add(model.makeAnnotation(.counter, at: point))

        case .crop:
            model.selectedID = nil
            cropStart = clamp(point)
            cropRect = nil

        default:
            guard let kind = model.tool.dragKind else { return }
            model.selectedID = nil
            draft = model.makeAnnotation(kind, at: clamp(point))
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        var point = imagePoint(for: event)
        let shift = event.modifierFlags.contains(.shift)

        if let movingID, let last = lastMovePoint {
            if !didCheckpointMove {
                model.checkpoint()
                didCheckpointMove = true
            }
            model.move(movingID, dx: point.x - last.x, dy: point.y - last.y)
            lastMovePoint = point
            return
        }

        if let start = cropStart {
            point = clamp(point)
            if shift { point = clamp(Geometry.snapSquare(from: start, to: point)) }
            cropRect = CGRect(
                x: min(start.x, point.x),
                y: min(start.y, point.y),
                width: abs(point.x - start.x),
                height: abs(point.y - start.y)
            )
            needsDisplay = true
            return
        }

        guard var current = draft else { return }
        switch current.kind {
        case .pen, .highlighter:
            current.points.append(point)
            current.end = point
        case .line, .arrow:
            current.end = shift ? Geometry.snapAngle(from: current.start, to: point) : point
        case .rect, .ellipse:
            current.end = shift ? Geometry.snapSquare(from: current.start, to: point) : point
        case .pixelate:
            current.end = clamp(point)
            current.patch = model.pixelPatch(for: current.rect)
        case .redact:
            current.end = clamp(point)
        case .text, .counter:
            break
        }
        draft = current
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { needsDisplay = true }

        if movingID != nil {
            movingID = nil
            lastMovePoint = nil
            return
        }

        if cropStart != nil {
            cropStart = nil
            if let rect = cropRect {
                cropRect = nil
                model.crop(to: rect)
            }
            return
        }

        guard let finished = draft else { return }
        draft = nil

        switch finished.kind {
        case .pen, .highlighter:
            model.add(finished)
        case .pixelate:
            if finished.rect.width >= 4, finished.rect.height >= 4, finished.patch != nil {
                model.add(finished)
            }
        default:
            // Ignore accidental clicks that never became a shape.
            let travelled = hypot(finished.end.x - finished.start.x, finished.end.y - finished.start.y)
            if travelled >= 3 / zoom {
                model.add(finished)
            }
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.control) {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 51, 117: // delete, forward delete
            model.removeSelected()
        case 53: // escape
            if draft != nil || cropStart != nil || cropRect != nil {
                draft = nil
                cropStart = nil
                cropRect = nil
                needsDisplay = true
            } else if model.selectedID != nil {
                model.selectedID = nil
            } else {
                model.tool = .select
            }
        case 36, 76: // return, enter
            onDone?()
        default:
            if let key = event.charactersIgnoringModifiers?.lowercased(), let tool = Tool.forKey(key) {
                model.tool = tool
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Text

    private func beginText(at point: CGPoint) {
        let z = zoom
        let font = NSFont.systemFont(ofSize: max(9, model.fontSize * z), weight: .semibold)
        let origin = viewRect(for: CGRect(origin: point, size: .zero)).origin
        let height = ceil(font.ascender - font.descender + font.leading) + 6

        let field = NSTextField(frame: NSRect(
            x: origin.x - 2,
            y: origin.y - 2,
            width: max(120, bounds.maxX - origin.x - 16),
            height: height
        ))
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = model.color
        field.placeholderString = "Type, then press Return"
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self

        addSubview(field)
        textField = field
        textOrigin = point
        hostWindow?.makeFirstResponder(field)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    /// Turns the inline text field into a text annotation.
    func commitText() {
        guard let field = textField else { return }
        textField = nil // clear first: removing the field can re-enter this method

        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.delegate = nil
        field.removeFromSuperview()

        if !string.isEmpty {
            var annotation = model.makeAnnotation(.text, at: textOrigin)
            annotation.text = string
            model.add(annotation)
        }
        if let window = hostWindow, window.firstResponder !== self {
            window.makeFirstResponder(self)
        }
        needsDisplay = true
    }
}
