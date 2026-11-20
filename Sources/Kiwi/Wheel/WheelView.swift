import SwiftUI

/// A ring segment between two angles, measured in degrees clockwise from the top.
struct SectorShape: Shape {
    var startDegrees: Double
    var endDegrees: Double
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        let steps = max(2, Int(abs(endDegrees - startDegrees) / 3))

        func point(_ degrees: Double, _ radius: CGFloat) -> CGPoint {
            // SwiftUI's y axis points down, so clockwise-from-top is sin for x and -cos for y.
            let radians = degrees * Double.pi / 180
            return CGPoint(
                x: center.x + radius * CGFloat(sin(radians)),
                y: center.y - radius * CGFloat(cos(radians))
            )
        }

        for step in 0...steps {
            let degrees = startDegrees + (endDegrees - startDegrees) * Double(step) / Double(steps)
            let p = point(degrees, outerRadius)
            if step == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        for step in (0...steps).reversed() {
            let degrees = startDegrees + (endDegrees - startDegrees) * Double(step) / Double(steps)
            path.addLine(to: point(degrees, innerRadius))
        }
        path.closeSubpath()
        return path
    }
}

/// The full ring: an outer circle with the hub cut out.
struct RingShape: Shape {
    var innerRadius: CGFloat
    var outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        SectorShape(startDegrees: 0, endDegrees: 360, innerRadius: innerRadius, outerRadius: outerRadius)
            .path(in: rect)
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let inner: CGFloat = WheelMetrics.innerRadius
    private let outer: CGFloat = WheelMetrics.outerRadius
    private let diameter: CGFloat = WheelMetrics.diameter

    var body: some View {
        ZStack {
            glass
            highlights
            separators
            labels
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(model.visible || reduceMotion ? 1 : 0.72)
        .opacity(model.visible ? 1 : 0)
        .animation(
            reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.26, dampingFraction: 0.74),
            value: model.visible
        )
        .animation(.easeInOut(duration: 0.15), value: model.ring)
        .animation(.easeInOut(duration: 0.15), value: model.kind)
        .frame(width: WheelMetrics.panelSide, height: WheelMetrics.panelSide)
        .allowsHitTesting(false)
    }

    private var items: [WheelItem] { model.items }

    /// Angular size of one slice, in degrees.
    private var slice: Double { 360.0 / Double(max(items.count, 1)) }

    /// Centre angle of a slice, in degrees clockwise from the top.
    private func centre(_ index: Int) -> Double { Double(index) * slice }

    private func labelPosition(_ index: Int) -> CGPoint {
        let radians: Double = centre(index) * Double.pi / 180
        let radius: CGFloat = (inner + outer) / 2 + 4
        let x: CGFloat = diameter / 2 + radius * CGFloat(sin(radians))
        let y: CGFloat = diameter / 2 - radius * CGFloat(cos(radians))
        return CGPoint(x: x, y: y)
    }

    // The ring and the hub: two pieces of glass.
    private var glass: some View {
        GlassEffectContainer(spacing: 2) {
            ZStack {
                Color.clear
                    .frame(width: diameter, height: diameter)
                    .glassEffect(.regular, in: RingShape(innerRadius: inner + 6, outerRadius: outer))

                VStack(spacing: 1) {
                    Text(model.ring.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.ring.hint)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: inner * 2 - 8, height: inner * 2 - 8)
                .glassEffect(.regular, in: .circle)
            }
        }
    }

    // Kiwi-green fill for the slice under the pointer.
    private var highlights: some View {
        ForEach(0..<items.count, id: \.self) { index in
            SectorShape(
                startDegrees: centre(index) - slice / 2 + 1.5,
                endDegrees: centre(index) + slice / 2 - 1.5,
                innerRadius: inner + 10,
                outerRadius: outer - 4
            )
            .fill(Theme.kiwi.opacity(0.9))
            .opacity(model.highlighted == index ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: model.highlighted)
        }
    }

    // Hairlines between slices.
    private var separators: some View {
        ForEach(0..<items.count, id: \.self) { index in
            SectorShape(
                startDegrees: centre(index) + slice / 2 - 0.15,
                endDegrees: centre(index) + slice / 2 + 0.15,
                innerRadius: inner + 14,
                outerRadius: outer - 8
            )
            .fill(Color.primary.opacity(0.12))
        }
    }

    private var labels: some View {
        ForEach(0..<items.count, id: \.self) { index in
            WheelLabel(item: items[index], selected: model.highlighted == index)
                .animation(.spring(response: 0.22, dampingFraction: 0.7), value: model.highlighted)
                .position(labelPosition(index))
        }
    }
}

private struct WheelLabel: View {
    let item: WheelItem
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: item.symbol)
                .font(.system(size: 19, weight: .medium))
            Text(item.title)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .scaleEffect(selected ? 1.12 : 1)
    }
}
