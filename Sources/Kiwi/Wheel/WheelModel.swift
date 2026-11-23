import AppKit
import Combine

/// What kind of files are being dragged. It decides which slices the wheel offers.
enum FileKind: Equatable {
    case image
    case video
    case audio
    case pdf
    case document
    /// Folders, types Kiwi does not convert, or a mix of kinds.
    case other

    static func of(_ urls: [URL]) -> FileKind {
        var found: FileKind?
        for url in urls {
            let kind = of(url)
            if let found, found != kind { return .other }
            found = kind
        }
        return found ?? .other
    }

    private static func of(_ url: URL) -> FileKind {
        if url.hasDirectoryPath { return .other }
        if DocumentEngine.isDocument(url) { return .document }
        if PDFEngine.isPDF(url) { return .pdf }
        if ImageEngine.isImage(url) { return .image }
        if MediaEngine.isVideo(url) { return .video }
        if MediaEngine.isAudio(url) { return .audio }
        return .other
    }
}

enum WheelAction {
    // Images
    case convert(ImageFormat)
    case resizeHalf
    case fit(Int)
    case compress
    case stripMetadata
    case redact
    case edit
    // Video and audio
    case video(VideoJob)
    case gif
    case audio(AudioFormat)
    // PDF and documents
    case pdfImages(ImageFormat)
    case pdfText
    case pdfMerge
    case pdfSplit
    case document(DocumentFormat)
    // Any file
    case copy
    case copyPath
    case reveal
    case rename
    case zip
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

    /// Slices for the files being dragged. They start at the top and run clockwise.
    func items(for kind: FileKind) -> [WheelItem] {
        switch self {
        case .convert: return WheelRing.convertItems(kind)
        case .tools: return WheelRing.toolItems(kind)
        case .actions: return WheelRing.actionItems(kind)
        }
    }

    private static func convertItems(_ kind: FileKind) -> [WheelItem] {
        switch kind {
        case .image:
            return [
                WheelItem(id: "png", title: "PNG", symbol: "photo", action: .convert(.png)),
                WheelItem(id: "jpeg", title: "JPEG", symbol: "photo.fill", action: .convert(.jpeg)),
                WheelItem(id: "heic", title: "HEIC", symbol: "camera.aperture", action: .convert(.heic)),
                WheelItem(id: "avif", title: "AVIF", symbol: "sparkles", action: .convert(.avif)),
                WheelItem(id: "tiff", title: "TIFF", symbol: "square.stack.3d.up", action: .convert(.tiff)),
                WheelItem(id: "pdf", title: "PDF", symbol: "doc.richtext", action: .convert(.pdf)),
            ]
        case .video:
            return [
                WheelItem(id: "mp4", title: "MP4", symbol: "film", action: .video(.mp4)),
                WheelItem(id: "hevc", title: "HEVC", symbol: "film.stack", action: .video(.hevc)),
                WheelItem(id: "mov", title: "MOV", symbol: "video", action: .video(.mov)),
                WheelItem(id: "gif", title: "GIF", symbol: "photo.stack", action: .gif),
                WheelItem(id: "audio", title: "Audio", symbol: "music.note", action: .video(.audio)),
            ]
        case .audio:
            return [
                WheelItem(id: "m4a", title: "M4A", symbol: "music.note", action: .audio(.m4a)),
                WheelItem(id: "wav", title: "WAV", symbol: "waveform", action: .audio(.wav)),
                WheelItem(id: "aiff", title: "AIFF", symbol: "waveform.path", action: .audio(.aiff)),
                WheelItem(id: "flac", title: "FLAC", symbol: "music.quarternote.3", action: .audio(.flac)),
            ]
        case .pdf:
            return [
                WheelItem(id: "pdf-png", title: "PNG", symbol: "photo", action: .pdfImages(.png)),
                WheelItem(id: "pdf-jpeg", title: "JPEG", symbol: "photo.fill", action: .pdfImages(.jpeg)),
                WheelItem(id: "pdf-text", title: "Text", symbol: "text.alignleft", action: .pdfText),
            ]
        case .document:
            return [
                WheelItem(id: "doc-pdf", title: "PDF", symbol: "doc.richtext", action: .document(.pdf)),
                WheelItem(id: "doc-docx", title: "DOCX", symbol: "doc.text", action: .document(.docx)),
                WheelItem(id: "doc-rtf", title: "RTF", symbol: "doc.plaintext", action: .document(.rtf)),
                WheelItem(id: "doc-odt", title: "ODT", symbol: "doc", action: .document(.odt)),
                WheelItem(id: "doc-txt", title: "TXT", symbol: "text.alignleft", action: .document(.txt)),
                WheelItem(id: "doc-html", title: "HTML", symbol: "globe", action: .document(.html)),
            ]
        case .other:
            return [
                WheelItem(id: "zip", title: "ZIP", symbol: "doc.zipper", action: .zip),
            ]
        }
    }

    private static func toolItems(_ kind: FileKind) -> [WheelItem] {
        switch kind {
        case .image:
            return [
                WheelItem(id: "half", title: "Half size", symbol: "arrow.down.right.and.arrow.up.left", action: .resizeHalf),
                WheelItem(id: "fit", title: "Fit 1920", symbol: "aspectratio", action: .fit(1920)),
                WheelItem(id: "compress", title: "Compress", symbol: "rectangle.compress.vertical", action: .compress),
                WheelItem(id: "clean", title: "Strip info", symbol: "tag.slash", action: .stripMetadata),
                WheelItem(id: "redact", title: "Redact", symbol: "eye.slash", action: .redact),
                WheelItem(id: "edit", title: "Edit", symbol: "pencil.tip.crop.circle", action: .edit),
            ]
        case .video:
            return [
                WheelItem(id: "v-compress", title: "Compress", symbol: "rectangle.compress.vertical", action: .video(.compress)),
                WheelItem(id: "v-1080", title: "1080p", symbol: "aspectratio", action: .video(.fit1080)),
                WheelItem(id: "v-720", title: "720p", symbol: "arrow.down.right.and.arrow.up.left", action: .video(.fit720)),
                WheelItem(id: "v-mute", title: "Mute", symbol: "speaker.slash", action: .video(.mute)),
                WheelItem(id: "v-edit", title: "Edit", symbol: "scissors", action: .edit),
            ]
        case .pdf:
            return [
                WheelItem(id: "pdf-merge", title: "Merge", symbol: "arrow.triangle.merge", action: .pdfMerge),
                WheelItem(id: "pdf-split", title: "Split", symbol: "square.split.2x1", action: .pdfSplit),
            ]
        case .audio, .document, .other:
            // Nothing specific: the wheel shows Actions instead.
            return []
        }
    }

    private static func actionItems(_ kind: FileKind) -> [WheelItem] {
        var items = [
            WheelItem(id: "copy", title: "Copy", symbol: "doc.on.doc", action: .copy),
            WheelItem(id: "path", title: "Copy path", symbol: "link", action: .copyPath),
            WheelItem(id: "reveal", title: "Reveal", symbol: "folder", action: .reveal),
            WheelItem(id: "rename", title: "Rename", symbol: "character.cursor.ibeam", action: .rename),
            WheelItem(id: "zip", title: "ZIP", symbol: "doc.zipper", action: .zip),
            WheelItem(id: "sha", title: "SHA-256", symbol: "number", action: .checksum),
        ]
        if kind == .image || kind == .pdf {
            items.append(WheelItem(id: "text", title: "Copy text", symbol: "text.viewfinder", action: .copyText))
        }
        items.append(WheelItem(id: "share", title: "Share", symbol: "square.and.arrow.up", action: .share))
        return items
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
    /// Nil until the dragged files reach the wheel and Kiwi can see what they are.
    @Published var kind: FileKind?

    var items: [WheelItem] {
        guard let kind else { return [] }
        return ring.items(for: kind)
    }
    @Published var highlighted: Int?
    @Published var visible = false
}
