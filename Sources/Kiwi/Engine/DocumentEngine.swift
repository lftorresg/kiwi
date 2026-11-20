import AppKit

enum DocumentFormat: String {
    case pdf
    case docx
    case rtf
    case odt
    case txt
    case html

    var title: String { rawValue.uppercased() }
    var fileExtension: String { rawValue }

    fileprivate var documentType: NSAttributedString.DocumentType? {
        switch self {
        case .pdf: return nil
        case .docx: return .officeOpenXML
        case .rtf: return .rtf
        case .odt: return .openDocument
        case .txt: return .plain
        case .html: return .html
        }
    }
}

/// Text document conversion using the importers and exporters that ship with
/// macOS (the ones TextEdit uses). Layout is kept as far as those allow:
/// text, fonts, colours, lists and simple tables survive; page headers,
/// comments and complex layouts may not.
///
/// Two deliberate limits. Kiwi never reads HTML or web archives, because
/// loading them can fetch content from the network. And every file is opened
/// as the type its extension names, so nothing is guessed from its contents.
enum DocumentEngine {
    /// Largest document Kiwi will open.
    static let maxBytes = 50_000_000

    private static let readable: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML,
        "doc": .docFormat,
        "rtf": .rtf,
        "odt": .openDocument,
        "txt": .plain,
        "text": .plain,
        "md": .plain,
    ]

    static func isDocument(_ url: URL) -> Bool {
        readable[url.pathExtension.lowercased()] != nil
    }

    private static func load(_ url: URL) throws -> NSAttributedString {
        let name = url.lastPathComponent
        guard let type = readable[url.pathExtension.lowercased()] else {
            throw KiwiError("\(name) is not a document Kiwi can read.")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= maxBytes else {
            throw KiwiError("\(name) is too large to convert.")
        }

        if type == .plain {
            let text: String
            if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
                text = utf8
            } else {
                text = try String(contentsOf: url, encoding: .isoLatin1)
            }
            return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        do {
            return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
        } catch {
            throw KiwiError("Couldn't read \(name).")
        }
    }

    static func convert(_ url: URL, to format: DocumentFormat) async throws -> URL {
        guard let type = format.documentType else {
            return try await pdf(from: url)
        }
        let text = try load(url)
        var attributes: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if format == .txt || format == .html {
            attributes[.characterEncoding] = String.Encoding.utf8.rawValue
        }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: attributes)
        let output = ImageEngine.outputURL(for: url, fileExtension: format.fileExtension)
        try data.write(to: output, options: .atomic)
        return output
    }

    /// Lays the document out on A4 pages and saves it as a PDF, using the
    /// system's print machinery with no panel. AppKit text layout and
    /// printing belong on the main thread, so this runs there.
    @MainActor
    private static func pdf(from url: URL) throws -> URL {
        let text = try load(url)
        let output = ImageEngine.outputURL(for: url, fileExtension: "pdf")

        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)
        info.topMargin = 56
        info.bottomMargin = 56
        info.leftMargin = 56
        info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary().setObject(output, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        // Print on white with dark text whatever the system appearance is.
        view.appearance = NSAppearance(named: .aqua)
        view.backgroundColor = .white
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainerInset = .zero
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: output.path) else {
            try? FileManager.default.removeItem(at: output)
            throw KiwiError("Couldn't make a PDF of \(url.lastPathComponent).")
        }
        return output
    }
}
