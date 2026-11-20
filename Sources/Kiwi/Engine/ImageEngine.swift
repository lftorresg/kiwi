import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable {
    case png, jpeg, heic, avif, tiff, pdf

    var title: String {
        switch self {
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .tiff: return "TIFF"
        case .pdf: return "PDF"
        }
    }

    var typeIdentifier: String {
        switch self {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .heic: return "public.heic"
        case .avif: return "public.avif"
        case .tiff: return "public.tiff"
        case .pdf: return "com.adobe.pdf"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .avif: return "avif"
        case .tiff: return "tiff"
        case .pdf: return "pdf"
        }
    }

    var isLossy: Bool {
        switch self {
        case .jpeg, .heic, .avif: return true
        case .png, .tiff, .pdf: return false
        }
    }

    var supportsAlpha: Bool { self != .jpeg }

    init?(typeIdentifier: String) {
        guard let match = ImageFormat.allCases.first(where: { $0.typeIdentifier == typeIdentifier }) else {
            return nil
        }
        self = match
    }
}

/// Image conversion built only on ImageIO. Results are always written next to
/// the original under a new name; originals are never modified.
enum ImageEngine {
    /// Largest image Kiwi will decode. Guards against decompression bombs:
    /// tiny files that expand into gigabytes of pixels.
    static let maxPixels = 150_000_000

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }

    static func canWrite(_ format: ImageFormat) -> Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.contains(format.typeIdentifier)
    }

    /// `name.ext` beside the original, or `name 2.ext`, `name 3.ext`… when taken.
    static func outputURL(for source: URL, fileExtension: String) -> URL {
        let folder = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent("\(stem).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(counter).\(fileExtension)")
            counter += 1
        }
        return candidate
    }

    private static func openSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw KiwiError("\(url.lastPathComponent) is not a readable image.")
        }
        // Check the declared size before any pixels are decoded.
        let size = pixelSize(of: source)
        guard size.width > 0, size.height > 0 else {
            throw KiwiError("\(url.lastPathComponent) has no readable size.")
        }
        guard size.width <= maxPixels / size.height else {
            throw KiwiError("\(url.lastPathComponent) is too large to process safely.")
        }
        return source
    }

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int) {
        let info = properties(of: source)
        let width = (info[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (info[kCGImagePropertyPixelHeight] as? Int) ?? 0
        return (width, height)
    }

    /// Full-size pixels with the EXIF orientation applied and no metadata attached.
    private static func decodeUpright(_ source: CGImageSource, name: String) throws -> CGImage {
        let size = pixelSize(of: source)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(size.width, size.height),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw KiwiError("Couldn't decode \(name).")
        }
        return image
    }

    /// Writes bare pixels next to `url` in the source's own format when possible, else PNG.
    private static func writeCopy(_ image: CGImage, of source: CGImageSource, beside url: URL) throws -> URL {
        var format = sourceFormat(source) ?? .png
        if !canWrite(format) { format = .png }
        let output = outputURL(for: url, fileExtension: format.fileExtension)
        let destination = try makeDestination(output, format: format)
        let options = destinationOptions(format: format, quality: 0.92)
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        try finalize(destination, at: output)
        return output
    }

    private static func sourceFormat(_ source: CGImageSource) -> ImageFormat? {
        guard let identifier = CGImageSourceGetType(source) as String? else { return nil }
        return ImageFormat(typeIdentifier: identifier)
    }

    private static func properties(of source: CGImageSource) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    private static func destinationOptions(format: ImageFormat, quality: Double) -> [CFString: Any] {
        var options: [CFString: Any] = [:]
        if format.isLossy {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }
        if !format.supportsAlpha {
            // Transparent areas become white instead of black.
            options[kCGImageDestinationBackgroundColor] = CGColor(gray: 1, alpha: 1)
        }
        return options
    }

    private static func finalize(_ destination: CGImageDestination, at url: URL) throws {
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw KiwiError("Couldn't write \(url.lastPathComponent).")
        }
    }

    private static func makeDestination(_ url: URL, format: ImageFormat) throws -> CGImageDestination {
        guard canWrite(format) else {
            throw KiwiError("This Mac can't write \(format.title) files.")
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, format.typeIdentifier as CFString, 1, nil
        ) else {
            throw KiwiError("Couldn't create \(url.lastPathComponent).")
        }
        return destination
    }

    /// Encodes an in-memory image, for the editor's Convert menu. The file is
    /// readable by its owner only, like every capture Kiwi writes.
    static func write(_ image: CGImage, format: ImageFormat, to url: URL, quality: Double, scale: CGFloat) throws {
        let destination = try makeDestination(url, format: format)
        var options = destinationOptions(format: format, quality: quality)
        let dpi = 72.0 * Double(max(1, scale))
        options[kCGImagePropertyDPIWidth] = dpi
        options[kCGImagePropertyDPIHeight] = dpi
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        try finalize(destination, at: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Re-encodes the image in another format, keeping its metadata.
    @discardableResult
    static func convert(_ url: URL, to format: ImageFormat, quality: Double = 0.9) throws -> URL {
        let source = try openSource(url)
        let output = outputURL(for: url, fileExtension: format.fileExtension)
        let destination = try makeDestination(output, format: format)
        let options = destinationOptions(format: format, quality: quality)
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        try finalize(destination, at: output)
        return output
    }

    /// Scales the image down. Pass a `factor` (0.5 halves each side) or a
    /// `maxPixel` cap for the longest side. Never scales up.
    @discardableResult
    static func resize(_ url: URL, factor: Double? = nil, maxPixel: Int? = nil) throws -> URL {
        let source = try openSource(url)
        let info = properties(of: source)
        let width = (info[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let height = (info[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let longest = max(width, height)
        guard longest > 0 else {
            throw KiwiError("\(url.lastPathComponent) has no readable size.")
        }

        var target = longest
        if let factor {
            target = Int((Double(longest) * factor).rounded())
        }
        if let maxPixel {
            target = min(target, maxPixel)
        }
        target = max(1, min(target, longest))

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw KiwiError("Couldn't resize \(url.lastPathComponent).")
        }

        var format = sourceFormat(source) ?? .png
        if !canWrite(format) { format = .png }

        let output = outputURL(for: url, fileExtension: format.fileExtension)
        let destination = try makeDestination(output, format: format)
        let options = destinationOptions(format: format, quality: 0.9)
        CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
        try finalize(destination, at: output)
        return output
    }

    /// Makes the file smaller. Lossy formats keep their format at a lower
    /// quality; everything else becomes HEIC (with transparency) or JPEG.
    @discardableResult
    static func compress(_ url: URL, quality: Double = 0.55) throws -> URL {
        let source = try openSource(url)
        let info = properties(of: source)
        let hasAlpha = (info[kCGImagePropertyHasAlpha] as? Bool) ?? false

        var format: ImageFormat
        if let original = sourceFormat(source), original.isLossy, canWrite(original) {
            format = original
        } else if hasAlpha, canWrite(.heic) {
            format = .heic
        } else {
            format = .jpeg
        }
        if !canWrite(format) { format = .jpeg }

        let output = outputURL(for: url, fileExtension: format.fileExtension)
        let destination = try makeDestination(output, format: format)
        let options = destinationOptions(format: format, quality: quality)
        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        try finalize(destination, at: output)
        return output
    }

    /// The image's pixels, the right way up, after the size check. For reading text.
    static func loadUpright(_ url: URL) throws -> CGImage {
        let source = try openSource(url)
        return try decodeUpright(source, name: url.lastPathComponent)
    }

    /// A copy with all metadata removed: location, camera, software, timestamps, comments.
    /// The pixels are re-encoded, so lossy formats lose a little quality.
    @discardableResult
    static func stripMetadata(_ url: URL) throws -> URL {
        let source = try openSource(url)
        let image = try decodeUpright(source, name: url.lastPathComponent)
        return try writeCopy(image, of: source, beside: url)
    }

    /// A copy with sensitive text (and optionally faces) covered by solid boxes.
    /// Metadata is dropped as well. Throws when nothing sensitive is found, so
    /// no file is created that only looks redacted.
    static func redact(_ url: URL, options: PIIScanner.Options) throws -> (url: URL, count: Int) {
        let source = try openSource(url)
        let image = try decodeUpright(source, name: url.lastPathComponent)
        let rects = try PIIScanner.scan(image, options: options)
        guard !rects.isEmpty else {
            throw KiwiError("Nothing sensitive found in \(url.lastPathComponent).")
        }
        let redacted = try PIIScanner.apply(rects, to: image)
        let output = try writeCopy(redacted, of: source, beside: url)
        return (output, rects.count)
    }
}
