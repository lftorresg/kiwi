import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One image moving through Kiwi: a fresh screenshot, or a file opened in the editor.
@MainActor
final class Capture {
    enum Origin {
        case screenshot
        case file(URL)
    }

    let id = UUID()
    let origin: Origin
    let scale: CGFloat
    /// File name without extension. Starts as a timestamp; the user can rename it.
    var name: String
    var image: CGImage
    /// Working copy in Kiwi's cache; backs drag-out from the preview.
    var cacheURL: URL
    /// Set once the capture has been saved to the user's folder.
    var savedURL: URL?
    /// Clipboard change count right after Kiwi copied this capture.
    var clipboardStamp: Int?
    /// Set when the user deletes the capture, so late background work cleans up after itself.
    var isDeleted = false

    init(image: CGImage, scale: CGFloat, origin: Origin = .screenshot) {
        self.image = image
        self.scale = scale
        self.origin = origin
        self.name = CaptureStore.makeName()
        self.cacheURL = CaptureStore.cacheDirectory.appendingPathComponent(name + ".png")
    }

    var isScreenshot: Bool {
        if case .screenshot = origin { return true }
        return false
    }

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
}

/// File handling for captures. Everything here is safe to call off the main thread.
enum CaptureStore {
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Kiwi/Captures", isDirectory: true)
        // Owner-only: other accounts on this Mac cannot list or read working copies.
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }

    /// Writes data atomically and makes the file readable by its owner only.
    static func writePrivately(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Deletes every working copy. Called when Kiwi quits.
    static func wipeCache() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) else {
            return
        }
        for url in items {
            try? fm.removeItem(at: url)
        }
    }

    static func makeName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Kiwi " + formatter.string(from: date)
    }

    /// Turns what the user typed into a safe file name: no path separators,
    /// no leading dots, no extension, a sensible length.
    static func sanitizedName(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var name = raw.components(separatedBy: forbidden).joined(separator: " ")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        for ext in [".png", ".jpg", ".jpeg", ".heic", ".avif", ".tiff", ".pdf"] where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
        }
        return String(name.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// PNG data tagged with the right DPI so Retina captures open at their true size.
    static func pngData(_ image: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        let dpi = 72.0 * Double(scale)
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Returns `folder/name.png`, adding " 2", " 3"… when the name is taken.
    static func uniqueURL(in folder: URL, name: String, ext: String) -> URL {
        var candidate = folder.appendingPathComponent("\(name).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    /// Writes PNG data into the save folder and returns where it landed.
    static func write(_ data: Data, toFolder folder: URL, name: String, replacing existing: URL?) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = existing ?? uniqueURL(in: folder, name: name, ext: "png")
        try writePrivately(data, to: target)
        return target
    }

    /// Removes cache files older than a day so the cache never grows unbounded.
    static func pruneCache() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let items = try? fm.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in items {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }
}

@MainActor
enum Clipboard {
    /// Puts PNG data on the clipboard and returns the new change count.
    @discardableResult
    static func copy(png data: Data) -> Int {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
        return pasteboard.changeCount
    }

    @discardableResult
    static func copy(image: CGImage, scale: CGFloat) -> Int? {
        guard let data = CaptureStore.pngData(image, scale: scale) else { return nil }
        return copy(png: data)
    }

    /// One image file is copied as an image (so it pastes into chats and docs);
    /// anything else is copied as file references.
    static func copy(files urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if urls.count == 1, ImageEngine.isImage(urls[0]), let image = NSImage(contentsOf: urls[0]) {
            pasteboard.writeObjects([image])
        } else {
            pasteboard.writeObjects(urls.map { $0 as NSURL })
        }
    }

    static func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Clears the clipboard only if it still holds what Kiwi put there.
    static func clear(ifStampIs stamp: Int?) {
        guard let stamp, NSPasteboard.general.changeCount == stamp else { return }
        NSPasteboard.general.clearContents()
    }
}

@MainActor
enum Sound {
    private static let path =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
    private static var shutterSound: NSSound?

    static func shutter() {
        if shutterSound == nil, FileManager.default.fileExists(atPath: path) {
            shutterSound = NSSound(contentsOfFile: path, byReference: true)
        }
        shutterSound?.stop()
        shutterSound?.play()
    }
}

extension CGImage {
    /// A smaller copy whose longest side is at most `maxPixel`. Used for light previews.
    func downscaled(maxPixel: Int) -> CGImage {
        let longest = max(width, height)
        guard longest > maxPixel, longest > 0 else { return self }
        let ratio = CGFloat(maxPixel) / CGFloat(longest)
        let newWidth = max(1, Int(CGFloat(width) * ratio))
        let newHeight = max(1, Int(CGFloat(height) * ratio))
        guard let context = Bitmap.context(width: newWidth, height: newHeight, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return self }
        context.interpolationQuality = .high
        context.draw(self, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        return context.makeImage() ?? self
    }
}
