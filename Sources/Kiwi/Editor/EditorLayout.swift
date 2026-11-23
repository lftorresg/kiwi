import AppKit

/// Sizes shared by the editor window and its canvas. The tools sit in the
/// window's toolbar and the style controls in a bar below the image, so the
/// canvas only keeps a small margin around the picture.
enum EditorLayout {
    static let minimumWindowSize = NSSize(width: 560, height: 460)
    /// Width the editor opens at when the image itself is small.
    static let comfortableWidth: CGFloat = 1140

    /// Space the canvas keeps clear around the image.
    static func canvasInsets(forWidth width: CGFloat) -> NSEdgeInsets {
        NSEdgeInsets(top: 28, left: 36, bottom: 28, right: 36)
    }
}
