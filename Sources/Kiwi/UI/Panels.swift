import AppKit
import SwiftUI

/// Borderless, transparent, non-activating panel used for every floating
/// piece of Kiwi UI (preview, toast, wheel). It never steals focus from the
/// app the user is working in.
final class FloatingPanel: NSPanel {
    var allowsKey = false

    init(size: NSSize, level: NSWindow.Level = .floating) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.level = level
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Hosting view for floating panels. Its controls respond to the very first
/// click even though Kiwi is not the active app, and it reports pointer hover
/// through AppKit tracking so hover works while another app is in front.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    var onHoverChange: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChange?(false)
    }
}

/// Hover flag shared between an AppKit host and its SwiftUI content.
@MainActor
final class HoverState: ObservableObject {
    @Published var hovering = false
}

extension NSScreen {
    /// The screen currently containing the mouse pointer.
    static var underMouse: NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main
    }

    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

/// Runs work on the main actor after a delay.
@MainActor
func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        MainActor.assumeIsolated { work() }
    }
}
