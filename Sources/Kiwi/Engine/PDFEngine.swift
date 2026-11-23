import AppKit
import PDFKit

/// PDF tools built on PDFKit. Results go next to the original; originals are
/// never modified.
enum PDFEngine {
    /// Largest document Kiwi will take apart, to bound time and disk use.
    static let maxPages = 500
    /// Longest side of a rendered page, in pixels.
    static let maxPixel: CGFloat = 4000

    static func isPDF(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "pdf"
    }

    private static func open(_ url: URL) throws -> PDFDocument {
        let name = url.lastPathComponent
        guard let document = PDFDocument(url: url) else {
            throw KiwiError("\(name) is not a readable PDF.")
        }
        guard !document.isLocked else {
            throw KiwiError("\(name) is password protected.")
        }
        guard document.pageCount > 0 else {
            throw KiwiError("\(name) has no pages.")
        }
        guard document.pageCount <= maxPages else {
            throw KiwiError("\(name) has more than \(maxPages) pages.")
        }
        return document
    }

    /// All the text in the document, or nil when it has no text layer.
    static func string(of url: URL) -> String? {
        guard let document = try? open(url) else { return nil }
        let text = (document.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: Pages to images

    /// One image per page: a single file for a one-page PDF, otherwise a
    /// folder of numbered pages.
    static func images(of url: URL, format: ImageFormat, quality: Double, progress: ProgressHandler) throws -> URL {
        let document = try open(url)
        let count = document.pageCount
        let stem = url.deletingPathExtension().lastPathComponent

        if count == 1, let page = document.page(at: 0) {
            let output = ImageEngine.outputURL(for: url, fileExtension: format.fileExtension)
            let image = try render(page)
            try ImageEngine.write(image, format: format, to: output, quality: quality, scale: 2)
            return output
        }

        let folder = try makeFolder(beside: url, name: "\(stem) pages")
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let file = folder.appendingPathComponent("\(stem) \(number(index + 1, of: count)).\(format.fileExtension)")
            let image = try render(page)
            try ImageEngine.write(image, format: format, to: file, quality: quality, scale: 2)
            progress(Double(index + 1) / Double(count))
        }
        return folder
    }

    /// Draws a page on white at twice its point size (144 dpi), capped at `maxPixel`.
    static func render(_ page: PDFPage) throws -> CGImage {
        var size = page.bounds(for: .mediaBox).size
        if page.rotation % 180 != 0 {
            size = CGSize(width: size.height, height: size.width)
        }
        guard size.width >= 1, size.height >= 1 else {
            throw KiwiError("A page has no readable size.")
        }
        let scale = min(2, maxPixel / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = Bitmap.context(
            width: width, height: height, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw KiwiError("Not enough memory to render a page.")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else {
            throw KiwiError("Couldn't render a page.")
        }
        return image
    }

    // MARK: Word document

    /// A Word document with the PDF's structure rebuilt: flowing paragraphs,
    /// headings, bullet lists, tables, pictures and links. See `PDFToDocx`.
    static func docx(of url: URL, progress: ProgressHandler) throws -> URL {
        let document = try open(url)
        // `defaults write io.github.lftorresg.kiwi debugLayout -bool YES` also
        // writes what was read from the pages, with the text masked, next to
        // the result. It is for tuning the conversion and is off otherwise.
        let wantsLayout = UserDefaults.standard.bool(forKey: "debugLayout")
        let rebuilt = try PDFToDocx.convert(document, wantsLayout: wantsLayout, progress: progress)
        guard !rebuilt.document.blocks.isEmpty else {
            throw KiwiError("\(url.lastPathComponent) has nothing Kiwi can convert.")
        }
        let output = ImageEngine.outputURL(for: url, fileExtension: "docx")
        try DocxWriter.data(for: rebuilt.document).write(to: output, options: .atomic)
        if wantsLayout {
            let report = output.deletingPathExtension().appendingPathExtension("layout.txt")
            try? rebuilt.layout.write(to: report, atomically: true, encoding: .utf8)
        }
        return output
    }

    // MARK: Text

    static func text(of url: URL) throws -> URL {
        guard let text = string(of: url) else {
            _ = try open(url) // surfaces "not readable" or "password protected" first
            throw KiwiError("\(url.lastPathComponent) has no text layer.")
        }
        let output = ImageEngine.outputURL(for: url, fileExtension: "txt")
        try text.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    // MARK: Merge and split

    /// Joins the documents, in the order they were dropped, into "Merged.pdf".
    static func merge(_ urls: [URL], progress: ProgressHandler) throws -> URL {
        guard let first = urls.first else {
            throw KiwiError("Nothing to merge.")
        }
        let merged = PDFDocument()
        for (index, url) in urls.enumerated() {
            try Task.checkCancellation()
            let document = try open(url)
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                merged.insert(page, at: merged.pageCount)
            }
            guard merged.pageCount <= maxPages * 4 else {
                throw KiwiError("The merged PDF would be too large.")
            }
            progress(Double(index + 1) / Double(urls.count))
        }
        let output = CaptureStore.uniqueURL(in: first.deletingLastPathComponent(), name: "Merged", ext: "pdf")
        guard merged.write(to: output) else {
            throw KiwiError("Couldn't write the merged PDF.")
        }
        return output
    }

    /// One PDF per page, in a folder next to the original.
    static func split(_ url: URL, progress: ProgressHandler) throws -> URL {
        let document = try open(url)
        let count = document.pageCount
        guard count > 1 else {
            throw KiwiError("\(url.lastPathComponent) has only one page.")
        }
        let stem = url.deletingPathExtension().lastPathComponent
        let folder = try makeFolder(beside: url, name: "\(stem) pages")
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            let file = folder.appendingPathComponent("\(stem) \(number(index + 1, of: count)).pdf")
            guard single.write(to: file) else {
                throw KiwiError("Couldn't write page \(index + 1).")
            }
            progress(Double(index + 1) / Double(count))
        }
        return folder
    }

    // MARK: Helpers

    /// A new folder beside `url`: `name`, or `name 2`, `name 3`… when taken.
    private static func makeFolder(beside url: URL, name: String) throws -> URL {
        let parent = url.deletingLastPathComponent()
        var candidate = parent.appendingPathComponent(name, isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name) \(counter)", isDirectory: true)
            counter += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        return candidate
    }

    /// Page numbers padded with zeros so the files sort in order.
    private static func number(_ value: Int, of count: Int) -> String {
        let digits = String(count).count
        let text = String(value)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }
}
