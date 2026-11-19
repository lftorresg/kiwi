import AppKit
import Combine

/// Editor state: the base image, the annotations on top, and undo history.
@MainActor
final class EditorModel: ObservableObject {
    private struct Snapshot {
        let base: CGImage
        let annotations: [Annotation]
    }

    @Published var tool: Tool = .arrow
    @Published var colorIndex = 0
    @Published var weight: Weight = .medium
    @Published var selectedID: UUID?
    @Published private(set) var base: CGImage
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Pixels per point of the source image.
    let scale: CGFloat

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    init(image: CGImage, scale: CGFloat) {
        self.base = image
        self.scale = max(1, scale)
    }

    // MARK: Style

    var color: NSColor { Theme.palette[colorIndex] }
    var strokeWidth: CGFloat { weight.stroke * scale }
    var fontSize: CGFloat { weight.font * scale }

    var pixelSize: CGSize { CGSize(width: base.width, height: base.height) }
    var pixelBounds: CGRect { CGRect(origin: .zero, size: pixelSize) }
    var hasEdits: Bool { canUndo }

    func setColor(_ index: Int) {
        colorIndex = index
        restyleSelection()
    }

    func setWeight(_ newWeight: Weight) {
        weight = newWeight
        restyleSelection()
    }

    private func restyleSelection() {
        guard let id = selectedID, let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
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

    /// Adds solid redaction boxes as one undoable step.
    func addRedactions(_ rects: [CGRect]) {
        let boxes = rects.map { $0.intersection(pixelBounds) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
        guard !boxes.isEmpty else { return }
        checkpoint()
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
            if let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                return context
            }
        }
        return nil
    }
}
