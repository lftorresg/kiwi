import CoreGraphics
import Foundation
import Vision

/// Reads the text in an image with on-device recognition. Nothing leaves the Mac.
enum TextReader {
    private static let bandHeight = 3200
    private static let bandOverlap = 320

    /// Recognised text, one line per recognised line, top to bottom.
    static func read(_ image: CGImage) throws -> String {
        var lines: [String] = []
        if image.height <= bandHeight + bandOverlap {
            lines = try readBand(image, keepFrom: 0, keepTo: 1)
        } else {
            // Tall scrolling captures are read in overlapping bands. Each band
            // keeps only the lines in the part it owns, so nothing is read twice.
            var top = 0
            while top < image.height {
                let height = min(bandHeight, image.height - top)
                let isFirst = (top == 0)
                let isLast = (top + height >= image.height)
                let band = CGRect(x: 0, y: top, width: image.width, height: height)
                guard let slice = image.cropping(to: band) else {
                    throw KiwiError("Couldn't read part of the image.")
                }
                let half = CGFloat(bandOverlap) / 2 / CGFloat(height)
                lines += try readBand(slice, keepFrom: isFirst ? 0 : half, keepTo: isLast ? 1 : 1 - half)
                if isLast { break }
                top += bandHeight - bandOverlap
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Lines whose vertical centre, as a fraction from the top, lies in `keepFrom..<keepTo`.
    private static func readBand(_ image: CGImage, keepFrom: CGFloat, keepTo: CGFloat) throws -> [String] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = makeRequest(languages: ["pt-BR", "en-US"])
        do {
            try handler.perform([request])
        } catch {
            // Fall back to the recognizer's default language if that pair is not available.
            let fallback = makeRequest(languages: nil)
            try handler.perform([fallback])
            return lines(from: fallback, keepFrom: keepFrom, keepTo: keepTo)
        }
        return lines(from: request, keepFrom: keepFrom, keepTo: keepTo)
    }

    private static func makeRequest(languages: [String]?) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let languages {
            request.recognitionLanguages = languages
        }
        return request
    }

    private static func lines(from request: VNRecognizeTextRequest, keepFrom: CGFloat, keepTo: CGFloat) -> [String] {
        var result: [String] = []
        for observation in request.results ?? [] {
            // Vision's boxes are normalized with a bottom-left origin.
            let fromTop = 1 - observation.boundingBox.midY
            guard fromTop >= keepFrom, fromTop < keepTo || keepTo >= 1 else { continue }
            if let text = observation.topCandidates(1).first?.string, !text.isEmpty {
                result.append(text)
            }
        }
        return result
    }
}
