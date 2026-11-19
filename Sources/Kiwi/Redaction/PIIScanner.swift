import CoreGraphics
import Foundation
import Vision

/// Finds where sensitive text (and optionally faces) sits in an image, using
/// on-device text recognition, and paints over it.
///
/// Redaction is a solid fill. Blur and pixelation can be partially reversed;
/// a filled rectangle cannot.
enum PIIScanner {
    struct Options {
        var categories: Set<PIICategory>
        var faces: Bool
    }

    /// Images taller than this are scanned in overlapping bands so small text
    /// in long scrolling captures stays readable to the recognizer.
    private static let bandHeight = 3200
    private static let bandOverlap = 320

    /// Returns rectangles to cover, in image pixels with a top-left origin.
    static func scan(_ image: CGImage, options: Options) throws -> [CGRect] {
        guard !options.categories.isEmpty || options.faces else { return [] }

        var found: [CGRect] = []
        if image.height <= bandHeight + bandOverlap {
            found = try scanBand(image, offsetY: 0, options: options)
        } else {
            var top = 0
            while top < image.height {
                let height = min(bandHeight, image.height - top)
                let band = CGRect(x: 0, y: top, width: image.width, height: height)
                guard let slice = image.cropping(to: band) else {
                    // Never report "nothing found" for a part that was not scanned.
                    throw KiwiError("Couldn't read part of the image.")
                }
                found += try scanBand(slice, offsetY: CGFloat(top), options: options)
                if top + height >= image.height { break }
                top += bandHeight - bandOverlap
            }
        }
        return deduplicated(found)
    }

    private static func scanBand(_ image: CGImage, offsetY: CGFloat, options: Options) throws -> [CGRect] {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        // Language correction "fixes" tokens and addresses into words; keep the raw characters.
        textRequest.usesLanguageCorrection = false

        let faceRequest = VNDetectFaceRectanglesRequest()

        var requests: [VNRequest] = []
        if !options.categories.isEmpty { requests.append(textRequest) }
        if options.faces { requests.append(faceRequest) }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform(requests)

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        /// Vision reports normalized boxes with a bottom-left origin.
        func pixelRect(_ box: CGRect, padding: CGFloat) -> CGRect {
            let rect = CGRect(
                x: box.minX * width,
                y: (1 - box.maxY) * height + offsetY,
                width: box.width * width,
                height: box.height * height
            )
            let pad = max(2, rect.height * padding)
            return rect.insetBy(dx: -pad, dy: -pad).integral
        }

        var rects: [CGRect] = []

        if !options.categories.isEmpty {
            for observation in textRequest.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                for match in PIIDetector.matches(in: text, categories: options.categories) {
                    if let located = try? candidate.boundingBox(for: match.range) {
                        rects.append(pixelRect(located.boundingBox, padding: 0.18))
                    } else {
                        // Could not locate the exact characters: cover the whole line instead.
                        rects.append(pixelRect(observation.boundingBox, padding: 0.1))
                    }
                }
            }
        }

        if options.faces {
            for face in faceRequest.results ?? [] {
                rects.append(pixelRect(face.boundingBox, padding: 0.12))
            }
        }
        return rects
    }

    /// Drops rectangles that are mostly inside one already kept (band overlap finds things twice).
    private static func deduplicated(_ rects: [CGRect]) -> [CGRect] {
        var kept: [CGRect] = []
        for rect in rects where rect.width > 0 && rect.height > 0 {
            let area = rect.width * rect.height
            let duplicate = kept.contains { other in
                let overlap = other.intersection(rect)
                return !overlap.isNull && (overlap.width * overlap.height) > area * 0.6
            }
            if !duplicate { kept.append(rect) }
        }
        return kept
    }

    /// A copy of `image` with every rectangle filled solid black.
    /// Throws rather than hand back an image that was not redacted.
    static func apply(_ rects: [CGRect], to image: CGImage) throws -> CGImage {
        guard !rects.isEmpty else { return image }
        let width = image.width
        let height = image.height
        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var space = fallback
        if let own = image.colorSpace, own.model == .rgb { space = own }

        func makeContext(_ colorSpace: CGColorSpace) -> CGContext? {
            Bitmap.context(width: width, height: height, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let context = makeContext(space) ?? makeContext(fallback) else {
            throw KiwiError("Couldn't redact the image.")
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in rects {
            // Top-left image coordinates -> Core Graphics' bottom-left.
            let flipped = CGRect(
                x: rect.minX,
                y: CGFloat(height) - rect.maxY,
                width: rect.width,
                height: rect.height
            )
            context.fill(flipped)
        }
        guard let result = context.makeImage() else {
            throw KiwiError("Couldn't redact the image.")
        }
        return result
    }
}
