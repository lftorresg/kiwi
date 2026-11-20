import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a recording into a looping animated GIF, written next to the video.
///
/// GIF is a heavy format, so the result is bounded: at most `maxFrames` frames
/// no larger than `maxPixel` on their longest side. Short clips get
/// `preferredRate` frames a second; longer ones get fewer.
enum GIFExporter {
    static let maxFrames = 180
    static let maxPixel: CGFloat = 640
    static let preferredRate = 12.0

    static func export(video: URL) async throws -> URL {
        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw KiwiError("This recording is empty.")
        }

        let rate = min(preferredRate, max(1, Double(maxFrames) / duration))
        let count = max(1, min(maxFrames, Int(duration * rate)))
        let delay = 1 / rate

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // Nearby frames are fine and much faster than seeking to exact times.
        let tolerance = CMTime(seconds: delay / 2, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let output = CaptureStore.uniqueURL(
            in: video.deletingLastPathComponent(),
            name: video.deletingPathExtension().lastPathComponent,
            ext: "gif"
        )
        guard let destination = CGImageDestinationCreateWithURL(
            output as CFURL, UTType.gif.identifier as CFString, count, nil
        ) else {
            throw KiwiError("Couldn't create the GIF.")
        }
        let loopForever = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        CGImageDestinationSetProperties(destination, loopForever as CFDictionary)
        let timing = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ]

        // The destination expects exactly `count` frames, so a frame that
        // cannot be read is replaced by the one before it.
        var last: CGImage?
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) * delay, preferredTimescale: 600)
            let frame = (try? await generator.image(at: time).image) ?? last
            guard let frame else {
                throw KiwiError("Couldn't read the recording.")
            }
            CGImageDestinationAddImage(destination, frame, timing as CFDictionary)
            last = frame
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: output)
            throw KiwiError("Couldn't write the GIF.")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        return output
    }
}
