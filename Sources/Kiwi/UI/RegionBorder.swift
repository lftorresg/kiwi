import AppKit

/// A click-through outline around a screen region, used while Kiwi is
/// recording or capturing a scrolling area. It sits just outside the region,
/// and Kiwi's windows are excluded from capture anyway.
@MainActor
enum RegionBorder {
    static let thickness: CGFloat = 3

    /// - Parameter rect: Region in the display's point space, origin top-left.
    static func make(around rect: CGRect, on screen: NSScreen, color: NSColor) -> FloatingPanel {
        let frame = globalFrame(for: rect, on: screen).insetBy(dx: -thickness, dy: -thickness)
        let panel = FloatingPanel(size: frame.size, level: .statusBar)
        panel.ignoresMouseEvents = true
        let view = BorderView(frame: NSRect(origin: .zero, size: frame.size))
        view.color = color
        panel.contentView = view
        panel.setFrame(frame, display: true)
        return panel
    }

    /// Display-local top-left rectangle -> global AppKit coordinates.
    static func globalFrame(for rect: CGRect, on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

private final class BorderView: NSView {
    var color: NSColor = .white

    override func draw(_ dirtyRect: NSRect) {
        let inset = RegionBorder.thickness / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset), xRadius: 4, yRadius: 4)
        path.lineWidth = RegionBorder.thickness - 1
        color.setStroke()
        path.stroke()
    }
}
