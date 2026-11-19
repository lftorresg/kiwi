import AppKit

/// Editor tools, in toolbar order.
enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, ellipse, pen, highlighter, text, counter, pixelate, redact, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .text: return "textformat"
        case .counter: return "1.circle"
        case .pixelate: return "checkerboard.rectangle"
        case .redact: return "eye.slash"
        case .crop: return "crop"
        }
    }

    var title: String {
        switch self {
        case .select: return "Select, move, or drag the image"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .text: return "Text"
        case .counter: return "Step number"
        case .pixelate: return "Pixelate"
        case .redact: return "Redact (solid)"
        case .crop: return "Crop"
        }
    }

    /// Single-key shortcut while the canvas has focus.
    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .line: return "l"
        case .rect: return "r"
        case .ellipse: return "o"
        case .pen: return "p"
        case .highlighter: return "h"
        case .text: return "t"
        case .counter: return "n"
        case .pixelate: return "b"
        case .redact: return "x"
        case .crop: return "c"
        }
    }

    static func forKey(_ key: String) -> Tool? {
        allCases.first { $0.key == key }
    }

    /// The annotation this tool draws by dragging, if any.
    var dragKind: Annotation.Kind? {
        switch self {
        case .arrow: return .arrow
        case .line: return .line
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .pen: return .pen
        case .highlighter: return .highlighter
        case .pixelate: return .pixelate
        case .redact: return .redact
        case .select, .text, .counter, .crop: return nil
        }
    }
}

enum Weight: Int, CaseIterable, Identifiable {
    case small, medium, large

    var id: Int { rawValue }

    /// Stroke width in points.
    var stroke: CGFloat {
        switch self {
        case .small: return 2.5
        case .medium: return 4
        case .large: return 7
        }
    }

    /// Text size in points.
    var font: CGFloat {
        switch self {
        case .small: return 15
        case .medium: return 22
        case .large: return 32
        }
    }
}

/// One mark on the screenshot. All geometry is in image pixels with a top-left origin.
struct Annotation: Identifiable {
    enum Kind {
        case arrow, line, rect, ellipse, pen, highlighter, text, counter, pixelate, redact
    }

    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var width: CGFloat
    var fontSize: CGFloat
    var text: String = ""
    var number: Int = 0
    /// Cached low-resolution image used to draw a pixelated region.
    var patch: CGImage?

    var rect: CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    var attributedText: NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    var counterRadius: CGFloat { fontSize * 0.8 }

    var bounds: CGRect {
        switch kind {
        case .arrow, .line:
            return rect.insetBy(dx: -width * 2.5, dy: -width * 2.5)
        case .rect, .ellipse:
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        case .pixelate, .redact:
            return rect
        case .pen, .highlighter:
            guard let first = points.first else { return .zero }
            var box = CGRect(origin: first, size: .zero)
            for point in points.dropFirst() {
                box = box.union(CGRect(origin: point, size: .zero))
            }
            let pad = (kind == .highlighter ? width * 3 : width / 2)
            return box.insetBy(dx: -pad, dy: -pad)
        case .text:
            let size = attributedText.size()
            return CGRect(origin: start, size: size)
        case .counter:
            let radius = counterRadius
            return CGRect(x: start.x - radius, y: start.y - radius, width: radius * 2, height: radius * 2)
        }
    }

    func hitTest(_ point: CGPoint, slop: CGFloat) -> Bool {
        switch kind {
        case .arrow, .line:
            return Geometry.distance(from: point, toSegment: start, end) <= max(width, slop)
        case .pen, .highlighter:
            let reach = max(kind == .highlighter ? width * 3 : width, slop)
            if points.count == 1 {
                return hypot(point.x - points[0].x, point.y - points[0].y) <= reach
            }
            for index in points.indices.dropFirst() {
                if Geometry.distance(from: point, toSegment: points[index - 1], points[index]) <= reach {
                    return true
                }
            }
            return false
        case .rect, .ellipse, .pixelate, .redact, .text, .counter:
            return bounds.insetBy(dx: -slop, dy: -slop).contains(point)
        }
    }

    mutating func translate(dx: CGFloat, dy: CGFloat) {
        start.x += dx
        start.y += dy
        end.x += dx
        end.y += dy
        for index in points.indices {
            points[index].x += dx
            points[index].y += dy
        }
    }
}

enum Geometry {
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Snaps `point` so the line from `origin` runs at a multiple of 45 degrees.
    static func snapAngle(from origin: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
    }

    /// Snaps `point` so the box from `origin` is square.
    static func snapSquare(from origin: CGPoint, to point: CGPoint) -> CGPoint {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: origin.x + (dx < 0 ? -side : side), y: origin.y + (dy < 0 ? -side : side))
    }
}

/// Draws annotations into a context whose coordinate space is image pixels with
/// a top-left origin. Text needs `NSGraphicsContext.current` to wrap the same context.
enum AnnotationRenderer {
    static func draw(_ annotation: Annotation, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(annotation.width)
        context.setStrokeColor(annotation.color.cgColor)
        context.setFillColor(annotation.color.cgColor)

        switch annotation.kind {
        case .line:
            context.move(to: annotation.start)
            context.addLine(to: annotation.end)
            context.strokePath()

        case .arrow:
            drawArrow(annotation, in: context)

        case .rect:
            let rect = annotation.rect
            let radius = min(annotation.width * 1.5, rect.width / 2, rect.height / 2)
            if radius > 0 {
                context.addPath(NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath)
            } else {
                context.addRect(rect)
            }
            context.strokePath()

        case .ellipse:
            context.strokeEllipse(in: annotation.rect)

        case .pen:
            strokePoints(annotation.points, in: context)

        case .highlighter:
            context.setBlendMode(.multiply)
            context.setAlpha(0.45)
            context.setLineCap(.butt)
            context.setLineWidth(annotation.width * 6)
            strokePoints(annotation.points, in: context)

        case .text:
            annotation.attributedText.draw(at: annotation.start)

        case .counter:
            let radius = annotation.counterRadius
            let circle = CGRect(
                x: annotation.start.x - radius,
                y: annotation.start.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            context.fillEllipse(in: circle)
            let label = NSAttributedString(string: "\(annotation.number)", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: radius * 1.15, weight: .bold),
                .foregroundColor: annotation.color.contrastingLabel,
            ])
            let size = label.size()
            label.draw(at: CGPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))

        case .pixelate:
            if let patch = annotation.patch {
                context.interpolationQuality = .none
                drawImage(patch, in: annotation.rect, context: context)
            } else {
                context.setFillColor(NSColor.gray.withAlphaComponent(0.5).cgColor)
                context.fill(annotation.rect)
            }

        case .redact:
            // Always opaque black: a solid fill is the only redaction that cannot be undone
            // by image processing.
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(annotation.rect)
        }
    }

    private static func strokePoints(_ points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        context.move(to: first)
        if points.count == 1 {
            context.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        } else {
            for point in points.dropFirst() {
                context.addLine(to: point)
            }
        }
        context.strokePath()
    }

    private static func drawArrow(_ annotation: Annotation, in context: CGContext) {
        let start = annotation.start
        let end = annotation.end
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.5 else { return }

        let ux = dx / length
        let uy = dy / length
        let head = min(max(annotation.width * 4.5, 12), length * 0.6)
        let halfBase = head * 0.48

        // Shaft stops inside the head so the tip stays sharp.
        let neck = CGPoint(x: end.x - ux * head * 0.8, y: end.y - uy * head * 0.8)
        context.move(to: start)
        context.addLine(to: neck)
        context.strokePath()

        let base = CGPoint(x: end.x - ux * head, y: end.y - uy * head)
        let left = CGPoint(x: base.x - uy * halfBase, y: base.y + ux * halfBase)
        let right = CGPoint(x: base.x + uy * halfBase, y: base.y - ux * halfBase)
        context.move(to: end)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }

    /// Draws an image upright in a top-left-origin (flipped) context.
    static func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }
}

extension NSColor {
    /// White or near-black, whichever reads better on top of this color.
    var contrastingLabel: NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return .white }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.72 ? NSColor(white: 0.1, alpha: 1) : .white
    }
}
