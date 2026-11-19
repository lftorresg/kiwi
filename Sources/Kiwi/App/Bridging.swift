import AppKit

// The few places where Kiwi has to touch an API that Swift's strict memory
// safety checking flags. Each one is safe as used here, and keeping them in
// this file (plus the Carbon bridge in HotKey.swift) keeps the audit surface small.

enum Bitmap {
    /// A bitmap context whose pixel buffer Core Graphics allocates and owns.
    static func context(width: Int, height: Int, space: CGColorSpace, bitmapInfo: UInt32) -> CGContext? {
        // Flagged only because the initializer can take a raw pointer. Passing nil
        // asks Core Graphics to manage the memory, so no pointer of ours is involved.
        return unsafe CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: space,
            bitmapInfo: bitmapInfo
        )
    }
}

extension NSView {
    /// The window this view is in. AppKit declares `NSView.window` as
    /// unowned(unsafe); reading it on the main thread from a live view is safe.
    var hostWindow: NSWindow? {
        return unsafe window
    }
}

extension NSScreen {
    /// Finds a screen again from its display ID, which can cross threads where NSScreen cannot.
    static func matching(_ displayID: CGDirectDisplayID?) -> NSScreen? {
        guard let displayID else { return nil }
        return screens.first { $0.displayID == displayID }
    }
}
