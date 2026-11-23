import AppKit
import ScreenCaptureKit

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

enum Coordination {
    /// Asks Foundation for a ZIP of `folder` and hands it to `body`. The ZIP
    /// is a temporary file that Foundation removes when `body` returns.
    static func withZippedCopy(of folder: URL, _ body: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var bodyError: Error?
        // Flagged only because the error comes back through a pointer that
        // Objective-C fills in. It points at the local variable above for the
        // length of this call and nowhere else.
        unsafe NSFileCoordinator().coordinate(
            readingItemAt: folder, options: [.forUploading], error: &coordinationError
        ) { zipped in
            do {
                try body(zipped)
            } catch {
                bodyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let bodyError { throw bodyError }
    }
}

enum StreamBackground {
    /// Lives for as long as Kiwi runs. It has to: see below.
    private static let black = CGColor(gray: 0, alpha: 1)

    /// Fills the parts of a recording that the screen does not cover with black.
    static func setBlack(on configuration: SCStreamConfiguration) {
        // ScreenCaptureKit keeps this colour without retaining it, so a colour
        // made on the spot would be freed while the stream still points at it.
        // The one above is never freed, which is what makes this safe.
        unsafe configuration.backgroundColor = black
    }
}

enum Trash {
    /// Moves a file to the Trash and waits until it is there.
    static func move(_ url: URL) throws {
        // Flagged only because the call can report where the file ended up
        // through a pointer. Passing nil asks for nothing back.
        try unsafe FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}

enum TextAttributes {
    /// The font and colour of each stretch of an attributed string, in order.
    static func styles(of text: NSAttributedString) -> [(range: NSRange, font: NSFont?, color: NSColor?)] {
        var styles: [(range: NSRange, font: NSFont?, color: NSColor?)] = []
        // Flagged only because the callback is handed a "stop" flag through a
        // pointer. This code never touches it.
        unsafe text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { attributes, range, _ in
            styles.append((range, attributes[.font] as? NSFont, attributes[.foregroundColor] as? NSColor))
        }
        return styles
    }
}

enum DocumentBridge {
    /// Reads a document as exactly the given type.
    static func read(_ url: URL, as type: NSAttributedString.DocumentType) throws -> NSAttributedString {
        // Flagged only because the initializer can hand back the document's
        // attributes through a pointer. Passing nil asks for none, so no
        // pointer of ours is involved.
        return try unsafe NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
    }
}

extension NSTextView {
    /// The view's text storage. AppKit declares `textStorage` as
    /// unowned(unsafe); reading it on the main thread from a live view is safe.
    var liveTextStorage: NSTextStorage? {
        return unsafe textStorage
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
