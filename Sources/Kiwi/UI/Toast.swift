import AppKit
import SwiftUI

/// A small glass capsule that confirms an action, then fades away.
@MainActor
enum Toast {
    private static var panel: FloatingPanel?
    private static var generation = 0

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", on screen: NSScreen? = nil) {
        generation += 1
        let current = generation

        Toast.panel?.orderOut(nil)

        let host = FirstMouseHostingView(rootView: ToastView(text: text, symbol: symbol))
        let fitting = host.fittingSize
        let size = NSSize(width: ceil(fitting.width), height: ceil(fitting.height))

        let toast = FloatingPanel(size: size, level: .statusBar)
        toast.ignoresMouseEvents = true
        toast.contentView = host
        host.frame = NSRect(origin: .zero, size: size)

        let target = screen ?? NSScreen.underMouse ?? NSScreen.main
        let area = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = NSPoint(x: area.midX - size.width / 2, y: area.maxY - size.height - 10)
        toast.setFrame(NSRect(origin: origin, size: size), display: true)
        toast.alphaValue = 0
        toast.orderFrontRegardless()
        Toast.panel = toast

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            toast.animator().alphaValue = 1
        }

        after(1.7) {
            guard current == generation else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                toast.animator().alphaValue = 0
            }
            after(0.3) {
                guard current == generation else { return }
                toast.orderOut(nil)
                Toast.panel = nil
            }
        }
    }

    static func error(_ text: String) {
        show(text, symbol: "exclamationmark.triangle.fill")
    }
}

private struct ToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(symbol.hasPrefix("exclamationmark") ? Color.orange : Theme.kiwi)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
        .padding(14) // room for the glass shadow inside the transparent panel
        .fixedSize()
    }
}
