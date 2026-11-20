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

    /// One thing to cover: where it is (image pixels, top-left origin) and what it is.
    struct Finding {
        let rect: CGRect
        let label: String
    }

    /// Rectangles to cover, in image pixels with a top-left origin.
    static func scan(_ image: CGImage, options: Options) throws -> [CGRect] {
        try findings(in: image, options: options).map(\.rect)
    }

    /// Everything sensitive found in the image, with what each item is.
    static func findings(in image: CGImage, options: Options) throws -> [Finding] {
        guard !options.categories.isEmpty || options.faces else { return [] }

        var found: [Finding] = []
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

    /// "2 emails, 1 ID number": a one-line account of what was found.
    static func summary(of findings: [Finding]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for finding in findings {
            if counts[finding.label] == nil { order.append(finding.label) }
            counts[finding.label, default: 0] += 1
        }
        return order.map { label in
            let count = counts[label] ?? 0
            if count == 1 { return "1 \(label)" }
            return "\(count) \(label.hasSuffix("s") ? label + "es" : label + "s")"
        }.joined(separator: ", ")
    }

    private static func scanBand(_ image: CGImage, offsetY: CGFloat, options: Options) throws -> [Finding] {
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

        var found: [Finding] = []

        if !options.categories.isEmpty {
            let wantsIDs = options.categories.contains(.nationalID)
            var previousWasIDLabel = false
            for observation in textRequest.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                // A caption such as "RG" on one line and the number on the next.
                if wantsIDs, previousWasIDLabel, PIIDetector.looksLikeIDNumber(text) {
                    let rect = pixelRect(observation.boundingBox, padding: 0.1)
                    found.append(Finding(rect: rect, label: PIICategory.nationalID.noun))
                }
                previousWasIDLabel = PIIDetector.isIDLabel(text)
                for match in PIIDetector.matches(in: text, categories: options.categories) {
                    let rect: CGRect
                    if let located = try? candidate.boundingBox(for: match.range) {
                        rect = pixelRect(located.boundingBox, padding: 0.18)
                    } else {
                        // Could not locate the exact characters: cover the whole line instead.
                        rect = pixelRect(observation.boundingBox, padding: 0.1)
                    }
                    found.append(Finding(rect: rect, label: match.category.noun))
                }
            }
        }

        if options.faces {
            for face in faceRequest.results ?? [] {
                found.append(Finding(rect: pixelRect(face.boundingBox, padding: 0.12), label: "face"))
            }
        }
        return found
    }

    /// Drops findings that are mostly inside one already kept (band overlap finds things twice).
    private static func deduplicated(_ findings: [Finding]) -> [Finding] {
        var kept: [Finding] = []
        for finding in findings where finding.rect.width > 0 && finding.rect.height > 0 {
            let rect = finding.rect
            let area = rect.width * rect.height
            let duplicate = kept.contains { other in
                let overlap = other.rect.intersection(rect)
                return !overlap.isNull && (overlap.width * overlap.height) > area * 0.6
            }
            if !duplicate { kept.append(finding) }
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
