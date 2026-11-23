import AppKit
import Combine

/// Editor state: the base image, the annotations on top, and undo history.
@MainActor
final class EditorModel: ObservableObject {
    private struct Snapshot {
        let base: CGImage
        let annotations: [Annotation]
    }

    @Published var tool: Tool = .pen
    @Published var colorIndex = 0
    /// A colour chosen in the system colour panel. Nil while a palette colour is in use.
    @Published private(set) var customColor: NSColor?
    /// Stroke thickness in points, set with the size slider.
    @Published private(set) var thickness: CGFloat = 4
    @Published var selectedID: UUID?
    @Published private(set) var base: CGImage
    @Published private(set) var annotations: [Annotation] = []
    /// The capture's name as typed in the editor's name field.
    @Published var captureName: String
    /// Annotations to outline for a moment, so new redactions are easy to spot.
    @Published var flashIDs: Set<UUID> = []
    /// Current zoom of the canvas, for the toolbar readout.
    @Published var zoomPercent = 100
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Pixels per point of the source image.
    let scale: CGFloat

    /// A backdrop Kiwi applied: the image before, the image after, and how
    /// far the image was moved in from each edge.
    private struct Framing {
        let source: CGImage
        let framed: CGImage
        let inset: CGFloat
    }

    /// Recent framings, so that picking another backdrop (also after an undo)
    /// replaces the current one instead of framing the frame.
    private var framings: [Framing] = []

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(image: CGImage, scale: CGFloat, name: String) {
        self.captureName = name
        self.base = image
        self.scale = max(1, scale)
    }

    // MARK: Style

    static let thicknessRange: ClosedRange<CGFloat> = 1...20

    var color: NSColor { customColor ?? Theme.palette[colorIndex] }
    var strokeWidth: CGFloat { thickness * scale }
    /// Text grows with the same slider: 22 pt at the default thickness.
    var fontSize: CGFloat { (thickness * 4.5 + 4) * scale }

    var pixelSize: CGSize { CGSize(width: base.width, height: base.height) }
    var pixelBounds: CGRect { CGRect(origin: .zero, size: pixelSize) }
    var hasEdits: Bool { canUndo }

    func setColor(_ index: Int) {
        colorIndex = index
        customColor = nil
        restyleSelection()
    }

    func setCustomColor(_ color: NSColor) {
        customColor = color.usingColorSpace(.sRGB) ?? color
        restyleSelection(coalescing: true)
    }

    func setThickness(_ value: CGFloat) {
        let range = EditorModel.thicknessRange
        thickness = min(max(value, range.lowerBound), range.upperBound)
        restyleSelection(coalescing: true)
    }

    /// The selection last restyled by a slider or the colour panel, and when.
    private var lastRestyle: (id: UUID, at: Date)?

    /// Applies the current colour and size to the selected annotation.
    /// Dragging a slider or the colour wheel sends many values in a row;
    /// with `coalescing` they count as a single undo step.
    private func restyleSelection(coalescing: Bool = false) {
        guard let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        var continuing = false
        if coalescing, let last = lastRestyle, last.id == id, now.timeIntervalSince(last.at) < 1.5 {
            continuing = true
        }
        if !continuing { checkpoint() }
        lastRestyle = coalescing ? (id, now) : nil
        annotations[index].color = color
        annotations[index].width = strokeWidth
        annotations[index].fontSize = fontSize
    }

    // MARK: Building annotations

    func makeAnnotation(_ kind: Annotation.Kind, at point: CGPoint) -> Annotation {
        var annotation = Annotation(
            kind: kind,
            start: point,
            end: point,
            color: color,
            width: strokeWidth,
            fontSize: fontSize
        )
        if kind == .pen || kind == .highlighter {
            annotation.points = [point]
        }
        if kind == .counter {
            annotation.number = annotations.filter { $0.kind == .counter }.count + 1
        }
        return annotation
    }

    func add(_ annotation: Annotation) {
        checkpoint()
        annotations.append(annotation)
    }

    /// Adds solid redaction boxes as one undoable step and returns their ids.
    @discardableResult
    func addRedactions(_ rects: [CGRect]) -> [UUID] {
        let boxes = rects.map { $0.intersection(pixelBounds) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !boxes.isEmpty else { return [] }
        checkpoint()
        let firstNew = annotations.count
        for box in boxes {
            annotations.append(Annotation(
                kind: .redact,
                start: CGPoint(x: box.minX, y: box.minY),
                end: CGPoint(x: box.maxX, y: box.maxY),
                color: .black,
                width: strokeWidth,
                fontSize: fontSize
            ))
        }
        return annotations[firstNew...].map(\.id)
    }

    // MARK: Editing

    /// Records the current state so the next change can be undone.
    func checkpoint() {
        undoStack.append(Snapshot(base: base, annotations: annotations))
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshHistoryFlags()
    }

    func annotation(at point: CGPoint, slop: CGFloat) -> Annotation? {
        annotations.last { $0.hitTest(point, slop: slop) }
    }

    func move(_ id: UUID, dx: CGFloat, dy: CGFloat) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].translate(dx: dx, dy: dy)
        if annotations[index].kind == .pixelate {
            annotations[index].patch = pixelPatch(for: annotations[index].rect)
        }
    }

    /// Moves an annotation's two defining points, for resize handles.
    func reshape(_ id: UUID, start: CGPoint, end: CGPoint) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].start = start
        annotations[index].end = end
        if annotations[index].kind == .pixelate {
            annotations[index].patch = pixelPatch(for: annotations[index].rect)
        }
    }

    func removeSelected() {
        guard let id = selectedID, annotations.contains(where: { $0.id == id }) else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func crop(to rect: CGRect) {
        let area = rect.integral.intersection(pixelBounds)
        guard area.width >= 8, area.height >= 8, area != pixelBounds,
              let cropped = base.cropping(to: area) else { return }
        checkpoint()
        base = cropped
        annotations = annotations.map { annotation in
            var moved = annotation
            moved.translate(dx: -area.minX, dy: -area.minY)
            return moved
        }
        selectedID = nil
    }

    // MARK: Backdrop

    /// The framing the current image came from, if it sits on a backdrop.
    private var currentFraming: Framing? {
        framings.last { $0.framed === base }
    }

    var hasBackdrop: Bool { currentFraming != nil }

    /// Sets the image on a backdrop with rounded corners and a shadow, or
    /// removes the backdrop when `backdrop` is nil. Returns false when the
    /// result would be too large to build.
    @discardableResult
    func setBackdrop(_ backdrop: Backdrop?) -> Bool {
        // Work from the image as it was before any backdrop.
        var source = base
        var shift: CGFloat = 0
        if let current = currentFraming {
            source = current.source
            shift = -current.inset
        }

        guard let backdrop else {
            guard shift != 0 else { return true }
            checkpoint()
            base = source
            shiftAnnotations(by: shift)
            return true
        }

        let shorter = CGFloat(min(source.width, source.height))
        let inset = min(max(shorter * 0.09, 36 * scale), 140 * scale).rounded()
        guard let framed = Self.compose(source, on: backdrop, inset: inset, scale: scale) else { return false }
        checkpoint()
        base = framed
        shiftAnnotations(by: shift + inset)
        framings.append(Framing(source: source, framed: framed, inset: inset))
        if framings.count > 8 { framings.removeFirst() }
        return true
    }

    private func shiftAnnotations(by distance: CGFloat) {
        annotations = annotations.map { annotation in
            var moved = annotation
            moved.translate(dx: distance, dy: distance)
            return moved
        }
        selectedID = nil
    }

    private static func compose(_ image: CGImage, on backdrop: Backdrop, inset: CGFloat, scale: CGFloat) -> CGImage? {
        let pad = Int(inset)
        let width = image.width + pad * 2
        let height = image.height + pad * 2
        guard width <= ImageEngine.maxPixels / max(1, height),
              let context = makeContext(width: width, height: height, like: image) else { return nil }

        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let spot = CGRect(x: pad, y: pad, width: image.width, height: image.height)
        let radius = min(14 * scale, CGFloat(min(image.width, image.height)) / 6)
        let card = NSBezierPath(roundedRect: spot, xRadius: radius, yRadius: radius).cgPath

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSGradient(starting: backdrop.colors.start, ending: backdrop.colors.end)?.draw(in: full, angle: -45)
        NSGraphicsContext.restoreGraphicsState()

        // A soft shadow under the screenshot.
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -inset * 0.16),
            blur: inset * 0.55,
            color: CGColor(gray: 0, alpha: 0.36)
        )
        context.addPath(card)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()

        // The screenshot itself, clipped to the rounded card.
        context.saveGState()
        context.addPath(card)
        context.clip()
        context.interpolationQuality = .high
        context.draw(image, in: spot)
        context.restoreGState()

        return context.makeImage()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(base: base, annotations: annotations))
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(base: base, annotations: annotations))
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        base = snapshot.base
        annotations = snapshot.annotations
        selectedID = nil
        refreshHistoryFlags()
    }

    private func refreshHistoryFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Pixelation

    /// A coarse copy of the base image under `rect`. Drawn back at full size
    /// without smoothing, it reads as large mosaic blocks.
    func pixelPatch(for rect: CGRect) -> CGImage? {
        let area = rect.integral.intersection(pixelBounds)
        guard area.width >= 2, area.height >= 2, let source = base.cropping(to: area) else { return nil }
        let block = max(8, 12 * scale)
        let columns = max(1, Int(area.width / block))
        let rows = max(1, Int(area.height / block))
        guard let context = Self.makeContext(width: columns, height: rows, like: base) else { return nil }
        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        return context.makeImage()
    }

    // MARK: Output

    /// The base image with every annotation burned in.
    func rendered() -> CGImage {
        guard !annotations.isEmpty else { return base }
        let width = base.width
        let height = base.height
        guard let context = Self.makeContext(width: width, height: height, like: base) else { return base }

        // Switch to a top-left origin so annotation coordinates apply directly.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        AnnotationRenderer.drawImage(base, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in annotations {
            AnnotationRenderer.draw(annotation, in: context)
        }
        NSGraphicsContext.restoreGraphicsState()

        return context.makeImage() ?? base
    }

    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var spaces: [CGColorSpace] = []
        if let space = image.colorSpace, space.model == .rgb {
            spaces.append(space)
        }
        spaces.append(fallback)
        for space in spaces {
            if let context = Bitmap.context(width: width, height: height, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                return context
            }
        }
        return nil
    }
}
