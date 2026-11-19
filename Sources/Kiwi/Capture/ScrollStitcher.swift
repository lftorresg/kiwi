import CoreGraphics
import Foundation

/// Joins successive frames of a scrolling region into one tall image.
///
/// Each frame is reduced to a small signature (one value per row and band).
/// Rows that did not change between two frames are treated as fixed chrome
/// (sticky headers and footers). The remaining rows are matched against the
/// previous frame to find how far the content moved, and only the rows that
/// are new get appended. Frames that cannot be matched are skipped, so
/// scrolling back up or pausing never corrupts the result.
///
/// Not thread-safe: use from one serial queue.
final class ScrollStitcher: @unchecked Sendable {
    enum Step {
        /// First frame stored.
        case first
        /// Nothing moved.
        case idle
        /// New rows appended; `height` is the stitched height in pixels so far.
        case scrolled(height: Int)
        /// The frame did not line up with the last good one.
        case lost
        /// The image reached the maximum height.
        case full
    }

    /// Hard cap on the result, to bound memory.
    static let maxHeight = 24_000

    private let bands = 24
    private let minRegion = 32
    private let minTexture = 8

    private var previous: [UInt8]?
    private var firstFrame: CGImage?
    private var lastFrame: CGImage?
    private var frameWidth = 0
    private var frameHeight = 0
    /// Row of the last accepted frame up to which the canvas already has content.
    private var previousBottom = 0

    private var canvas: CGContext?
    private var capacity = 0
    private var used = 0

    // MARK: Adding frames

    func add(_ frame: CGImage) -> Step {
        guard let signature = Self.signature(of: frame, bands: bands) else { return .lost }
        let height = frame.height

        guard let previous else {
            self.previous = signature
            firstFrame = frame
            lastFrame = frame
            frameWidth = frame.width
            frameHeight = height
            return .first
        }
        guard frame.width == frameWidth, height == frameHeight else { return .lost }

        let b = bands
        let staticLimit = b          // mean difference of 1 per band
        let mismatchLimit = b * 6    // mean difference of 6 per band

        // Rows that did not change are fixed chrome or blank space.
        var top = 0
        while top < height, Self.rowDistance(previous, top, signature, top, b) <= staticLimit {
            top += 1
        }
        if top == height { return .idle }
        var bottom = 0
        while bottom < height - top,
              Self.rowDistance(previous, height - 1 - bottom, signature, height - 1 - bottom, b) <= staticLimit {
            bottom += 1
        }
        let regionStart = top
        let regionEnd = height - bottom
        let region = regionEnd - regionStart
        if region < minRegion { return .idle }

        let previousSums = Self.rowSums(previous, rows: height, bands: b)
        let currentSums = Self.rowSums(signature, rows: height, bands: b)

        // A row is textured when it differs from the row below; blank areas are not.
        var texturedBefore = [Int](repeating: 0, count: height + 1)
        for row in 0..<height {
            let next = min(row + 1, height - 1)
            let textured = abs(currentSums[row] - currentSums[next]) > b * 2
            texturedBefore[row + 1] = texturedBefore[row] + (textured ? 1 : 0)
        }

        // Coarse search over every possible shift using one value per row.
        let maxShift = region - max(16, region / 6)
        guard maxShift >= 1 else { return .idle }
        var candidates: [(error: Double, shift: Int)] = []
        candidates.reserveCapacity(maxShift)
        for shift in 1...maxShift {
            let rows = regionEnd - shift - regionStart
            if texturedBefore[regionEnd - shift] - texturedBefore[regionStart] < minTexture { continue }
            var total = 0
            for row in regionStart..<(regionEnd - shift) {
                total += abs(previousSums[row + shift] - currentSums[row])
            }
            candidates.append((Double(total) / Double(rows * b), shift))
        }
        candidates.sort { ($0.error, $0.shift) < ($1.error, $1.shift) }

        // Verify the best few with the full signature. A shift is accepted only
        // when practically every row lines up, so blank areas cannot fake a match.
        var best: (Int, Double, Int)? // (mismatched rows, coarse error, shift)
        for candidate in candidates.prefix(4) {
            let shift = candidate.shift
            var mismatched = 0
            for row in regionStart..<(regionEnd - shift)
            where Self.rowDistance(previous, row + shift, signature, row, b) > mismatchLimit {
                mismatched += 1
            }
            let textured = texturedBefore[regionEnd - shift] - texturedBefore[regionStart]
            if mismatched > max(1, textured / 32) { continue }
            let key: (Int, Double, Int) = (mismatched, candidate.error, shift)
            if let current = best {
                if key < current { best = key }
            } else {
                best = key
            }
        }
        guard let match = best else { return .lost }
        let shift = match.2

        // Append.
        if used == 0 {
            guard let first = firstFrame, append(first, from: 0, to: height - bottom) else { return .lost }
            previousBottom = height - bottom
        }
        let newBottom = height - bottom
        var covered = previousBottom - shift // where the canvas ends, in this frame's rows
        if newBottom > covered {
            guard covered >= 0, append(frame, from: covered, to: newBottom) else { return .lost }
            covered = newBottom
        }
        previousBottom = covered
        self.previous = signature
        lastFrame = frame

        let total = used + (height - previousBottom)
        return total >= Self.maxHeight ? .full : .scrolled(height: total)
    }

    // MARK: Result

    /// The stitched image, or the single frame when nothing was scrolled.
    func finish() -> CGImage? {
        guard used > 0, let last = lastFrame else { return firstFrame }
        // Fixed footer from the final frame.
        if previousBottom < frameHeight {
            _ = append(last, from: previousBottom, to: frameHeight)
        }
        guard let canvas, let full = canvas.makeImage(),
              let cropped = full.cropping(to: CGRect(x: 0, y: 0, width: frameWidth, height: used)) else {
            return firstFrame
        }
        // Copy into an exactly sized bitmap so the oversized canvas can be freed.
        guard let exact = Self.makeContext(width: frameWidth, height: used, like: last) else { return cropped }
        exact.draw(cropped, in: CGRect(x: 0, y: 0, width: frameWidth, height: used))
        return exact.makeImage() ?? cropped
    }

    // MARK: Canvas

    /// Appends rows `from..<to` (top-origin) of `image` to the bottom of the canvas.
    private func append(_ image: CGImage, from: Int, to: Int) -> Bool {
        let rows = to - from
        guard rows > 0, from >= 0, to <= image.height else { return rows == 0 }
        guard used + rows <= Self.maxHeight + frameHeight else { return false }
        guard ensureCapacity(used + rows, like: image),
              let canvas,
              let strip = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: rows)) else {
            return false
        }
        // The context's origin is bottom-left; row 0 of the canvas is at the top.
        let y = capacity - used - rows
        canvas.draw(strip, in: CGRect(x: 0, y: y, width: image.width, height: rows))
        used += rows
        return true
    }

    private func ensureCapacity(_ rows: Int, like image: CGImage) -> Bool {
        if canvas != nil, rows <= capacity { return true }
        var newCapacity = max(capacity, frameHeight * 4)
        while newCapacity < rows { newCapacity *= 2 }
        guard let grown = Self.makeContext(width: frameWidth, height: newCapacity, like: image) else { return false }
        if let canvas, let old = canvas.makeImage() {
            // Keep existing rows pinned to the top.
            grown.draw(old, in: CGRect(x: 0, y: newCapacity - capacity, width: frameWidth, height: capacity))
        }
        canvas = grown
        capacity = newCapacity
        return true
    }

    private static func makeContext(width: Int, height: Int, like image: CGImage) -> CGContext? {
        let fallback = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var spaces: [CGColorSpace] = []
        if let own = image.colorSpace, own.model == .rgb { spaces.append(own) }
        spaces.append(fallback)
        for space in spaces {
            if let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                context.interpolationQuality = .none
                return context
            }
        }
        return nil
    }

    // MARK: Signatures

    /// `rows x bands` bytes: the average grey level of each band of each row, top row first.
    static func signature(of image: CGImage, bands: Int) -> [UInt8]? {
        let width = image.width
        let height = image.height
        guard width >= bands, height > 0 else { return nil }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let grey = context.makeImage(), let data = grey.dataProvider?.data else { return nil }

        let pixels = [UInt8](data as Data)
        let stride = grey.bytesPerRow
        guard pixels.count >= stride * (height - 1) + width else { return nil }

        var result = [UInt8](repeating: 0, count: height * bands)
        for row in 0..<height {
            let rowStart = row * stride
            for band in 0..<bands {
                let from = band * width / bands
                let to = (band + 1) * width / bands
                var total = 0
                var column = from
                while column < to {
                    total += Int(pixels[rowStart + column])
                    column += 1
                }
                result[row * bands + band] = UInt8(total / max(1, to - from))
            }
        }
        return result
    }

    private static func rowSums(_ signature: [UInt8], rows: Int, bands: Int) -> [Int] {
        var sums = [Int](repeating: 0, count: rows)
        for row in 0..<rows {
            var total = 0
            for band in 0..<bands {
                total += Int(signature[row * bands + band])
            }
            sums[row] = total
        }
        return sums
    }

    /// Sum of absolute band differences between row `ra` of `a` and row `rb` of `b`.
    private static func rowDistance(_ a: [UInt8], _ ra: Int, _ b: [UInt8], _ rb: Int, _ bands: Int) -> Int {
        var total = 0
        let aStart = ra * bands
        let bStart = rb * bands
        for band in 0..<bands {
            total += abs(Int(a[aStart + band]) - Int(b[bStart + band]))
        }
        return total
    }
}
