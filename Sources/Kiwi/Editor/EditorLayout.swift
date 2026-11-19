import AppKit

/// How the editor's floating controls arrange themselves at a given window
/// width. The SwiftUI chrome and the AppKit canvas both ask this, so the canvas
/// always leaves exactly the room the controls need. Nothing is ever hidden:
/// narrower windows drop text labels first, then wrap the controls onto a second row.
enum EditorLayout {
    enum Top {
        /// Name field and the whole toolbar on one row.
        case full
        /// One row, with a shorter name field and an icon-only Redact button.
        case medium
        /// Two rows: name, history, redact and zoom above; the tools below.
        case stacked
    }

    enum Bottom {
        /// Colours on the left, labelled actions on the right.
        case full
        /// One row, with icon-only actions.
        case icons
        /// Two rows: colours above, icon-only actions below.
        case stacked
    }

    static let minimumWindowSize = NSSize(width: 520, height: 500)
    /// Width the editor opens at when the image itself is small.
    static let comfortableWidth: CGFloat = 1060

    static func top(forWidth width: CGFloat) -> Top {
        if width >= 1040 { return .full }
        if width >= 900 { return .medium }
        return .stacked
    }

    static func bottom(forWidth width: CGFloat) -> Bottom {
        if width >= 940 { return .full }
        if width >= 760 { return .icons }
        return .stacked
    }

    /// Space the canvas keeps clear for the controls above and below the image.
    static func canvasInsets(forWidth width: CGFloat) -> NSEdgeInsets {
        let oneRow: CGFloat = 78
        let twoRows: CGFloat = 128
        return NSEdgeInsets(
            top: top(forWidth: width) == .stacked ? twoRows : oneRow,
            left: 36,
            bottom: bottom(forWidth: width) == .stacked ? twoRows : oneRow,
            right: 36
        )
    }
}
