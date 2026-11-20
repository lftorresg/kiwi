import AppKit

/// A coloured background to set a screenshot on, for sharing.
enum Backdrop: String, CaseIterable, Identifiable {
    case kiwi
    case ocean
    case sunset
    case graphite
    case mist

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kiwi: return "Kiwi"
        case .ocean: return "Ocean"
        case .sunset: return "Sunset"
        case .graphite: return "Graphite"
        case .mist: return "Mist"
        }
    }

    /// Gradient from the top left to the bottom right.
    var colors: (start: NSColor, end: NSColor) {
        switch self {
        case .kiwi:
            return (NSColor(srgbRed: 0.68, green: 0.86, blue: 0.36, alpha: 1),
                    NSColor(srgbRed: 0.16, green: 0.54, blue: 0.36, alpha: 1))
        case .ocean:
            return (NSColor(srgbRed: 0.27, green: 0.62, blue: 0.98, alpha: 1),
                    NSColor(srgbRed: 0.36, green: 0.26, blue: 0.82, alpha: 1))
        case .sunset:
            return (NSColor(srgbRed: 1.00, green: 0.66, blue: 0.32, alpha: 1),
                    NSColor(srgbRed: 0.92, green: 0.26, blue: 0.48, alpha: 1))
        case .graphite:
            return (NSColor(srgbRed: 0.33, green: 0.35, blue: 0.40, alpha: 1),
                    NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1))
        case .mist:
            return (NSColor(srgbRed: 0.96, green: 0.97, blue: 0.99, alpha: 1),
                    NSColor(srgbRed: 0.80, green: 0.84, blue: 0.90, alpha: 1))
        }
    }
}
