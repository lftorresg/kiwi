import AppKit
import Combine

enum WheelAction {
    case convert(ImageFormat)
    case resizeHalf
    case fit(Int)
    case compress
    case stripMetadata
    case redact
    case edit
    case copy
    case copyPath
    case reveal
    case checksum
    case copyText
    case share
}

struct WheelItem: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let action: WheelAction
}

enum WheelRing: String {
    case convert
    case tools
    case actions

    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }

    var hint: String {
        switch self {
        case .convert: return "⌘ tools · ⌃ actions"
        case .tools: return "⇧ convert · ⌃ actions"
        case .actions: return "⇧ convert · ⌘ tools"
        }
    }

    /// Slices start at the top and run clockwise.
    var items: [WheelItem] {
        switch self {
        case .convert:
            return [
                WheelItem(id: "png", title: "PNG", symbol: "photo", action: .convert(.png)),
                WheelItem(id: "jpeg", title: "JPEG", symbol: "photo.fill", action: .convert(.jpeg)),
                WheelItem(id: "heic", title: "HEIC", symbol: "camera.aperture", action: .convert(.heic)),
                WheelItem(id: "avif", title: "AVIF", symbol: "sparkles", action: .convert(.avif)),
                WheelItem(id: "tiff", title: "TIFF", symbol: "square.stack.3d.up", action: .convert(.tiff)),
                WheelItem(id: "pdf", title: "PDF", symbol: "doc.richtext", action: .convert(.pdf)),
            ]
        case .tools:
            return [
                WheelItem(id: "half", title: "Half size", symbol: "arrow.down.right.and.arrow.up.left", action: .resizeHalf),
                WheelItem(id: "fit", title: "Fit 1920", symbol: "aspectratio", action: .fit(1920)),
                WheelItem(id: "compress", title: "Compress", symbol: "rectangle.compress.vertical", action: .compress),
                WheelItem(id: "clean", title: "Strip info", symbol: "tag.slash", action: .stripMetadata),
                WheelItem(id: "redact", title: "Redact", symbol: "eye.slash", action: .redact),
                WheelItem(id: "edit", title: "Edit", symbol: "pencil.tip.crop.circle", action: .edit),
            ]
        case .actions:
            return [
                WheelItem(id: "copy", title: "Copy", symbol: "doc.on.doc", action: .copy),
                WheelItem(id: "path", title: "Copy path", symbol: "link", action: .copyPath),
                WheelItem(id: "reveal", title: "Reveal", symbol: "folder", action: .reveal),
                WheelItem(id: "sha", title: "SHA-256", symbol: "number", action: .checksum),
                WheelItem(id: "text", title: "Copy text", symbol: "text.viewfinder", action: .copyText),
                WheelItem(id: "share", title: "Share", symbol: "square.and.arrow.up", action: .share),
            ]
        }
    }
}

/// Geometry shared by the SwiftUI wheel and the AppKit drop target.
enum WheelMetrics {
    static let diameter: CGFloat = 316
    static let innerRadius: CGFloat = 54
    static let outerRadius: CGFloat = 158
    /// Extra transparent room around the wheel for shadows and the scale animation.
    static let margin: CGFloat = 28
    static var panelSide: CGFloat { diameter + margin * 2 }

    /// The slice under a point, or nil over the hub or outside the wheel.
    /// `offset` is measured from the wheel's centre with y pointing up.
    static func sliceIndex(dx: CGFloat, dy: CGFloat, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let distance = hypot(dx, dy)
        guard distance >= innerRadius, distance <= outerRadius + 10 else { return nil }
        let slice = 360.0 / Double(count)
        // Degrees clockwise from straight up.
        var clockwise = 90.0 - Double(atan2(dy, dx)) * 180.0 / Double.pi
        clockwise = clockwise.truncatingRemainder(dividingBy: 360)
        if clockwise < 0 { clockwise += 360 }
        let index = Int(((clockwise + slice / 2) / slice).rounded(.down)) % count
        return index
    }
}

@MainActor
final class WheelModel: ObservableObject {
    @Published var ring: WheelRing = .convert
    @Published var highlighted: Int?
    @Published var visible = false
}
