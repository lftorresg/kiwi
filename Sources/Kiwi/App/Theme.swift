import AppKit
import SwiftUI

enum Theme {
    /// Kiwi flesh green, used for highlights and selection.
    static let kiwiNS = NSColor(srgbRed: 0.55, green: 0.78, blue: 0.22, alpha: 1)
    static let kiwi = Color(nsColor: kiwiNS)

    /// Annotation palette. Index 0 is the default.
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        kiwiNS,                                                    // kiwi
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1), // purple
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
        NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1), // black
    ]
}

struct KiwiError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
