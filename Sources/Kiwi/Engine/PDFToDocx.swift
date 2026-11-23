import AppKit
import ImageIO
import PDFKit

/// Rebuilds the structure of a PDF so it can be written as a Word document.
///
/// A PDF only says where each character is drawn. This reads those positions
/// and works out what they mean: lines that belong to one paragraph are joined
/// so the text reflows, larger or bold lines become headings, bullets become
/// real list items, aligned columns become tables, and everything that is not
/// text (photos, charts, diagrams, scanned pages) is kept as a picture in its
/// place. Running headers, footers and page numbers are left out.
///
/// It is a set of rules of thumb, not a perfect reconstruction: unusual
/// layouts will need tidying afterwards.
enum PDFToDocx {
    // MARK: What is read from a page

    /// One character, with where it is and how it looks. Spaces have no box.
    private struct Glyph {
        var text: String
        var box: CGRect
        var bold: Bool
        var italic: Bool
        var size: CGFloat
        var color: String?
        var font: String?
        var link: String?

        var isSpace: Bool { box.isNull }
    }

    /// One line of text. Boxes are in points from the top-left of the page.
    private struct Line {
        var glyphs: [Glyph]
        var box: CGRect
        var size: CGFloat
        var page: Int

        var text: String { glyphs.map(\.text).joined() }
    }

    private struct Figure {
        var box: CGRect
        var data: Data
        var isJPEG: Bool
    }

    /// Something on a page, in reading order.
    private enum Element {
        case line(Line)
        case block(DocxBlock, top: CGFloat)

        var top: CGFloat {
            switch self {
            case .line(let line): return line.box.minY
            case .block(_, let top): return top
            }
        }
    }

    private static let bullets: Set<String> = ["•", "◦", "▪", "■", "●", "○", "‣", "·", "∙", "–", "—", "-", "*", "➢", "➤", "✓", "\u{F0B7}", "\u{F0A7}"]
    private static let maxImageBytes = 400_000_000

    // MARK: Entry point

    static func convert(_ document: PDFDocument, progress: ProgressHandler) throws -> DocxDocument {
        let count = document.pageCount
        var pages: [[Line]] = []
        var figures: [[Figure]] = []
        var pageSizes: [CGSize] = []
        var imageBytes = 0

        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                pages.append([])
                figures.append([])
                pageSizes.append(.zero)
                continue
            }
            let box = page.bounds(for: .mediaBox)
            pageSizes.append(box.size)

            // A rotated page has its text sideways; keep it whole as a picture.
            let rotated = page.rotation % 360 != 0
            var lines = rotated ? [] : readLines(of: page, index: index, box: box)
            var found = try readFigures(of: page, box: box, lines: lines, rotated: rotated)
            for figure in found {
                // Text that sits inside a picture is already part of the picture.
                lines.removeAll { figure.box.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
                imageBytes += figure.data.count
            }
            guard imageBytes <= maxImageBytes else {
                throw KiwiError("This PDF has too many pictures to convert in one go.")
            }
            found.sort { $0.box.minY < $1.box.minY }
            pages.append(lines)
            figures.append(found)
            progress(Double(index + 1) / Double(count) * 0.9)
        }

        dropRunningText(&pages, pageSizes: pageSizes)

        // The size most of the text is set in.
        var weights: [CGFloat: Int] = [:]
        for line in pages.joined() {
            weights[line.size, default: 0] += line.glyphs.count
        }
        let bodySize = weights.max { $0.value < $1.value }?.key ?? 11

        var builder = Builder(bodySize: bodySize)
        for index in 0..<count {
            let lines = pages[index]
            let left = lines.map(\.box.minX).min() ?? 0
            let right = lines.map(\.box.maxX).max() ?? pageSizes[index].width
            var elements = tablesAndLines(lines, left: left, right: right)
            for figure in figures[index] {
                let size = figure.box.size
                let block = DocxBlock.image(data: figure.data, isJPEG: figure.isJPEG, size: size)
                let position = elements.firstIndex { $0.top >= figure.box.minY } ?? elements.count
                elements.insert(.block(block, top: figure.box.minY), at: position)
            }
            builder.add(elements, left: left, right: right)
        }
        builder.finish()

        var result = DocxDocument()
        result.blocks = builder.blocks
        result.bodySize = bodySize
        result.headingSizes = builder.headingSizes
        if let first = pageSizes.first(where: { $0.width > 72 && $0.height > 72 }) {
            result.pageSize = first
        }
        // Margins as in the PDF, within sensible limits.
        let lefts = pages.joined().map(\.box.minX)
        if let smallest = lefts.min() {
            result.margin = min(max(smallest, 36), 90)
        }
        progress(1)
        return result
    }

    // MARK: Reading text

    private static func readLines(of page: PDFPage, index: Int, box: CGRect) -> [Line] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let text = string as NSString
        let length = text.length
        guard length == page.numberOfCharacters else { return [] }

        // Fonts and colours, when they line up with the text.
        var styles: [(range: NSRange, font: NSFont?, color: NSColor?)] = []
        if let attributed = page.attributedString, attributed.length == length {
            styles = TextAttributes.styles(of: attributed)
        }
        var styleIndex = 0

        let links: [(box: CGRect, url: String)] = page.annotations.compactMap { annotation in
            guard annotation.type == "Link", let url = annotation.url else { return nil }
            let scheme = url.scheme?.lowercased() ?? ""
            guard scheme == "http" || scheme == "https" || scheme == "mailto" else { return nil }
            return (annotation.bounds, url.absoluteString)
        }

        var lines: [Line] = []
        var current: [Glyph] = []

        func endLine() {
            defer { current.removeAll() }
            let inked = current.filter { !$0.isSpace }
            guard !inked.isEmpty else { return }
            var union = CGRect.null
            var sizes: [CGFloat: Int] = [:]
            for glyph in inked {
                union = union.union(glyph.box)
                sizes[glyph.size, default: 0] += 1
            }
            let size = sizes.max { $0.value < $1.value }?.key ?? 11
            // Trim spaces at both ends.
            var glyphs = current
            while let first = glyphs.first, first.isSpace { glyphs.removeFirst() }
            while let last = glyphs.last, last.isSpace { glyphs.removeLast() }
            lines.append(Line(glyphs: glyphs, box: union, size: size, page: index))
        }

        var position = 0
        while position < length {
            let range = text.rangeOfComposedCharacterSequence(at: position)
            position = range.location + range.length
            let piece = text.substring(with: range)
            if piece == "\n" || piece == "\r" || piece == "\r\n" || piece == "\u{2028}" || piece == "\u{2029}" {
                endLine()
                continue
            }

            while styleIndex < styles.count, NSMaxRange(styles[styleIndex].range) <= range.location {
                styleIndex += 1
            }
            let style = styleIndex < styles.count && NSLocationInRange(range.location, styles[styleIndex].range)
                ? styles[styleIndex] : nil

            let raw = page.characterBounds(at: range.location)
            let blank = piece.trimmingCharacters(in: .whitespaces).isEmpty
            if blank || raw.width <= 0 || raw.height <= 0 {
                if blank, let last = current.last, !last.isSpace {
                    var space = last
                    space.text = " "
                    space.box = .null
                    current.append(space)
                }
                continue
            }

            // From the page's bottom-left origin to a top-left one.
            let glyphBox = CGRect(
                x: raw.minX - box.minX, y: box.maxY - raw.maxY, width: raw.width, height: raw.height
            )
            let font = style?.font
            let name = (font?.fontName ?? "").lowercased()
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            var size = font?.pointSize ?? 0
            if size < 4 { size = raw.height / 1.2 }
            size = (size * 2).rounded() / 2

            let centre = CGPoint(x: raw.midX, y: raw.midY)
            current.append(Glyph(
                text: piece,
                box: glyphBox,
                bold: traits.contains(.bold) || ["bold", "black", "heavy", "semibold", "demi"].contains { name.contains($0) },
                italic: traits.contains(.italic) || name.contains("italic") || name.contains("oblique"),
                size: size,
                color: hex(style?.color),
                font: family(font),
                link: links.first { $0.box.contains(centre) }?.url
            ))
        }
        endLine()
        return lines
    }

    /// "RRGGBB" for a colour that is clearly not black.
    private static func hex(_ color: NSColor?) -> String? {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        let red = rgb.redComponent, green = rgb.greenComponent, blue = rgb.blueComponent
        guard 0.299 * red + 0.587 * green + 0.114 * blue > 0.16 || max(red, green, blue) > 0.4 else { return nil }
        func part(_ value: CGFloat) -> String {
            let number = String(Int((min(max(value, 0), 1) * 255).rounded()), radix: 16, uppercase: true)
            return number.count < 2 ? "0" + number : number
        }
        return part(red) + part(green) + part(blue)
    }

    /// A font family worth naming in the document. Anything else falls back
    /// to the document's default, which is safer than an unknown name.
    private static func family(_ font: NSFont?) -> String? {
        guard let name = font?.familyName else { return nil }
        let known = [
            "Times New Roman", "Times", "Courier New", "Courier", "Calibri", "Cambria", "Georgia", "Verdana",
            "Tahoma", "Trebuchet MS", "Garamond", "Roboto", "Open Sans", "Lato", "Montserrat", "Helvetica Neue",
        ]
        guard let match = known.first(where: { name.caseInsensitiveCompare($0) == .orderedSame }) else { return nil }
        if match == "Times" { return "Times New Roman" }
        if match == "Courier" { return "Courier New" }
        return match
    }

    // MARK: Pictures

    /// Finds the parts of a page that are not text and keeps each as a picture.
    /// A page with no readable text at all (a scan) is kept whole.
    private static func readFigures(of page: PDFPage, box: CGRect, lines: [Line], rotated: Bool) throws -> [Figure] {
        let width = Int(box.width.rounded())
        let height = Int(box.height.rounded())
        guard width >= 8, height >= 8, width * height <= 6_000_000 else { return [] }

        if rotated {
            // The picture comes out the right way up, so its size is its own.
            let rendered = try PDFEngine.render(page)
            let sideways = page.rotation % 180 != 0
            let factor = CGFloat(rendered.width) / max(1, sideways ? box.height : box.width)
            guard let data = encode(rendered, jpeg: true) else { return [] }
            let shown = CGRect(x: 0, y: 0, width: CGFloat(rendered.width) / factor, height: CGFloat(rendered.height) / factor)
            return [Figure(box: shown, data: data, isJPEG: true)]
        }

        var regions: [CGRect] = []
        do {
            guard let gray = Bitmap.context(
                width: width, height: height, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return [] }
            gray.setFillColor(gray: 1, alpha: 1)
            gray.fill(CGRect(x: 0, y: 0, width: width, height: height))
            gray.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
            page.draw(with: .mediaBox, to: gray)
            guard let image = gray.makeImage(), let data = image.dataProvider?.data else { return [] }
            var pixels = [UInt8](data as Data)
            let stride = image.bytesPerRow
            guard pixels.count >= stride * (height - 1) + width else { return [] }

            // Wipe the text, so only what is not text is left.
            for line in lines {
                let x0 = max(0, Int(line.box.minX) - 1), x1 = min(width - 1, Int(line.box.maxX) + 1)
                let y0 = max(0, Int(line.box.minY) - 1), y1 = min(height - 1, Int(line.box.maxY) + 1)
                guard x0 <= x1, y0 <= y1 else { continue }
                for y in y0...y1 {
                    for x in x0...x1 { pixels[y * stride + x] = 255 }
                }
            }

            // Rows that still have something on them, grouped into bands.
            var inked = [Bool](repeating: false, count: height)
            for y in 0..<height {
                var dark = 0
                let start = y * stride
                for x in 0..<width where pixels[start + x] < 236 {
                    dark += 1
                    if dark >= 2 { break }
                }
                inked[y] = dark >= 2
            }
            if lines.isEmpty {
                // Nothing readable: the whole page is one picture, unless it is blank.
                if inked.contains(true) {
                    regions = [CGRect(x: 0, y: 0, width: width, height: height)]
                }
                inked = []
            }
            var bands: [(Int, Int)] = []
            var y = 0
            while y < inked.count {
                guard inked[y] else { y += 1; continue }
                var end = y
                var gap = 0
                var next = y + 1
                while next < inked.count, gap <= 5 {
                    if inked[next] { end = next; gap = 0 } else { gap += 1 }
                    next += 1
                }
                bands.append((y, end))
                y = end + 1
            }

            for band in bands where band.1 - band.0 >= 26 {
                var minX = width, maxX = -1
                for row in band.0...band.1 {
                    let start = row * stride
                    for x in 0..<width where pixels[start + x] < 236 {
                        if x < minX { minX = x }
                        if x > maxX { maxX = x }
                    }
                }
                guard maxX - minX >= 26 else { continue }
                let region = CGRect(x: minX, y: band.0, width: maxX - minX + 1, height: band.1 - band.0 + 1)
                    .insetBy(dx: -2, dy: -2)
                    .intersection(CGRect(x: 0, y: 0, width: width, height: height))
                // Mostly text with lines or shading around it (a table, a
                // boxed note) is text, not a picture.
                var covered: CGFloat = 0
                for line in lines {
                    let overlap = line.box.intersection(region)
                    if !overlap.isNull { covered += overlap.width * overlap.height }
                }
                if covered / max(1, region.width * region.height) > 0.18 { continue }
                regions.append(region)
            }
        }
        guard !regions.isEmpty else { return [] }

        let rendered = try PDFEngine.render(page)
        let factor = CGFloat(rendered.width) / box.width
        let pageArea = box.width * box.height
        var figures: [Figure] = []
        for region in regions {
            let crop = CGRect(
                x: region.minX * factor, y: region.minY * factor,
                width: region.width * factor, height: region.height * factor
            ).integral
            guard let piece = rendered.cropping(to: crop) else { continue }
            // Big pictures (scans, full-page photos) are much smaller as JPEG.
            let large = region.width * region.height > pageArea * 0.5
            guard let data = encode(piece, jpeg: large) else { continue }
            figures.append(Figure(box: region, data: data, isJPEG: large))
        }
        return figures
    }

    private static func encode(_ image: CGImage, jpeg: Bool) -> Data? {
        let data = NSMutableData()
        let type = (jpeg ? "public.jpeg" : "public.png") as CFString
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else { return nil }
        let options: [CFString: Any] = jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.82] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    // MARK: Headers, footers, page numbers

    /// Removes text that repeats at the top or bottom of the pages, and
    /// lone page numbers there.
    private static func dropRunningText(_ pages: inout [[Line]], pageSizes: [CGSize]) {
        func key(_ line: Line) -> String {
            let digits = line.text.map { $0.isNumber ? "#" : String($0) }.joined()
            return digits.lowercased().trimmingCharacters(in: .whitespaces) + "@\(Int(line.box.minY / 10))"
        }
        func inMargin(_ line: Line, _ size: CGSize) -> Bool {
            line.box.maxY < size.height * 0.09 || line.box.minY > size.height * 0.91
        }

        var seen: [String: Int] = [:]
        for (index, lines) in pages.enumerated() {
            for name in Set(lines.filter { inMargin($0, pageSizes[index]) }.map(key)) {
                seen[name, default: 0] += 1
            }
        }
        let needed = max(3, pages.count / 2)
        for index in pages.indices {
            let size = pageSizes[index]
            pages[index].removeAll { line in
                guard inMargin(line, size) else { return false }
                if seen[key(line), default: 0] >= needed { return true }
                let text = line.text.trimmingCharacters(in: .whitespaces)
                return text.count <= 4 && !text.isEmpty && text.allSatisfy(\.isNumber)
            }
        }
    }

    // MARK: Tables

    /// The stretches of a line that are text, split wherever there is a wide gap.
    private static func segments(of line: Line) -> [ClosedRange<CGFloat>] {
        var result: [ClosedRange<CGFloat>] = []
        let threshold = max(line.size * 1.6, 12)
        var start: CGFloat?
        var end: CGFloat = 0
        for glyph in line.glyphs where !glyph.isSpace {
            if let known = start, glyph.box.minX - end <= threshold, glyph.box.minX >= known - line.size {
                end = max(end, glyph.box.maxX)
            } else {
                if let known = start { result.append(known...max(known, end)) }
                start = glyph.box.minX
                end = glyph.box.maxX
            }
        }
        if let known = start { result.append(known...max(known, end)) }
        return result.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Turns runs of lines whose columns line up into tables and leaves the rest as lines.
    private static func tablesAndLines(_ lines: [Line], left: CGFloat, right: CGFloat) -> [Element] {
        var elements: [Element] = []
        var index = 0
        while index < lines.count {
            let seed = segments(of: lines[index])
            guard seed.count >= 2 else {
                elements.append(.line(lines[index]))
                index += 1
                continue
            }
            // The blank channels between columns. A table keeps every channel
            // clear on every one of its rows.
            var channels: [ClosedRange<CGFloat>] = []
            for pair in zip(seed, seed.dropFirst()) where pair.1.lowerBound - pair.0.upperBound >= 5 {
                channels.append(pair.0.upperBound...pair.1.lowerBound)
            }
            guard !channels.isEmpty else {
                elements.append(.line(lines[index]))
                index += 1
                continue
            }
            var rows = [index]
            var next = index + 1
            while next < lines.count {
                let line = lines[next]
                let previous = lines[rows[rows.count - 1]]
                guard line.box.minY - previous.box.maxY <= max(line.size, previous.size) * 2.2,
                      line.box.minY >= previous.box.minY - 1 else { break }
                var narrowed: [ClosedRange<CGFloat>] = []
                var kept = true
                for channel in channels {
                    var low = channel.lowerBound
                    var high = channel.upperBound
                    for segment in segments(of: line) where segment.upperBound > low && segment.lowerBound < high {
                        // Text reaches into the channel: keep the wider clear side.
                        if segment.lowerBound - low >= high - segment.upperBound {
                            high = segment.lowerBound
                        } else {
                            low = segment.upperBound
                        }
                    }
                    if high - low < 5 { kept = false; break }
                    narrowed.append(low...high)
                }
                guard kept else { break }
                channels = narrowed
                rows.append(next)
                next += 1
            }

            // Columns are separated at the middle of each channel.
            let cuts = channels.map { ($0.lowerBound + $0.upperBound) / 2 }
            func column(of x: CGFloat) -> Int { cuts.filter { x > $0 }.count }
            func filled(_ line: Line) -> Set<Int> {
                Set(line.glyphs.filter { !$0.isSpace }.map { column(of: $0.box.midX) })
            }
            let proper = rows.filter { filled(lines[$0]).count >= 2 }.count
            let isTable = (rows.count >= 3 && proper >= 2) || (rows.count >= 2 && proper >= 2 && cuts.count >= 2)
            guard isTable else {
                elements.append(.line(lines[index]))
                index += 1
                continue
            }

            var cells: [[[Glyph]]] = []
            var lastBottom: CGFloat = 0
            for row in rows {
                let line = lines[row]
                var split = [[Glyph]](repeating: [], count: cuts.count + 1)
                var currentColumn = 0
                for glyph in line.glyphs {
                    if !glyph.isSpace { currentColumn = column(of: glyph.box.midX) }
                    split[currentColumn].append(glyph)
                }
                // A line with text in one column only, tight under the row
                // above, is that cell wrapping onto another line.
                let wraps = !cells.isEmpty && filled(line).count == 1 && line.box.minY - lastBottom < line.size * 0.6
                if wraps {
                    for (position, glyphs) in split.enumerated() where glyphs.contains(where: { !$0.isSpace }) {
                        var space = glyphs[0]
                        space.text = " "
                        space.box = .null
                        cells[cells.count - 1][position].append(space)
                        cells[cells.count - 1][position].append(contentsOf: glyphs)
                    }
                } else {
                    cells.append(split)
                }
                lastBottom = line.box.maxY
            }

            var edges = [left] + cuts + [right]
            edges.sort()
            let widths = zip(edges, edges.dropFirst()).map { max(20, $0.1 - $0.0) }
            let table = DocxBlock.table(
                columns: widths,
                rows: cells.map { $0.map { runs(from: $0, baseSize: 0, plain: false) } }
            )
            elements.append(.block(table, top: lines[index].box.minY))
            index = next
        }
        return elements
    }

    // MARK: Runs

    /// Joins characters that look the same into runs. `baseSize` is the size
    /// that needs no mention; `plain` drops bold and size, for headings.
    private static func runs(from glyphs: [Glyph], baseSize: CGFloat, plain: Bool) -> [DocxRun] {
        var result: [DocxRun] = []
        var trimmed = glyphs
        while let first = trimmed.first, first.isSpace { trimmed.removeFirst() }
        while let last = trimmed.last, last.isSpace { trimmed.removeLast() }
        var lastWasSpace = false
        for glyph in trimmed {
            if glyph.isSpace {
                if lastWasSpace { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            var run = DocxRun(text: glyph.text)
            run.bold = plain ? false : glyph.bold
            run.italic = glyph.italic
            run.size = plain || abs(glyph.size - baseSize) <= 0.6 ? 0 : glyph.size
            run.color = glyph.color
            run.font = glyph.font
            run.link = glyph.link
            if var last = result.last, last.looksLike(run) {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        return result
    }

    // MARK: Paragraphs

    /// Collects lines into paragraphs, headings and list items.
    private struct Builder {
        let bodySize: CGFloat
        var blocks: [DocxBlock] = []

        private var pending: [Line] = []
        private var pendingLeft: CGFloat = 0
        private var pendingRight: CGFloat = 0
        /// Paragraphs waiting for their heading level, by position in `blocks`.
        private var headings: [(index: Int, size: CGFloat, boldOnly: Bool)] = []
        private var bulletIndents: [(index: Int, indent: CGFloat)] = []

        init(bodySize: CGFloat) {
            self.bodySize = bodySize
        }

        var headingSizes: [CGFloat] {
            var sizes = Array(Set(headings.filter { !$0.boldOnly }.map(\.size))).sorted(by: >)
            if sizes.count > 3 { sizes = Array(sizes.prefix(3)) }
            while sizes.count < 4 { sizes.append(sizes.last.map { max(bodySize, $0 - 2) } ?? bodySize) }
            return sizes
        }

        mutating func add(_ elements: [Element], left: CGFloat, right: CGFloat) {
            for element in elements {
                switch element {
                case .block(let block, _):
                    flush()
                    blocks.append(block)
                case .line(let line):
                    if let previous = pending.last, startsNewParagraph(previous, line, left: left, right: right) {
                        flush()
                    }
                    if pending.isEmpty {
                        pendingLeft = left
                        pendingRight = right
                    }
                    pending.append(line)
                }
            }
        }

        private func isFull(_ line: Line, right: CGFloat, left: CGFloat) -> Bool {
            line.box.maxX >= right - max((right - left) * 0.12, line.size * 2.5)
        }

        private func isCentred(_ line: Line, left: CGFloat, right: CGFloat) -> Bool {
            let before = line.box.minX - left
            let after = right - line.box.maxX
            return before > 12 && abs(before - after) <= max(6, (right - left) * 0.03)
        }

        private func startsNewParagraph(_ previous: Line, _ line: Line, left: CGFloat, right: CGFloat) -> Bool {
            if abs(line.size - previous.size) > 0.6 { return true }
            if PDFToDocx.marker(of: line) != nil { return true }
            let first = line.glyphs.first { !$0.isSpace }?.text ?? ""
            let startsLower = first.first?.isLowercase ?? false

            if line.page != previous.page {
                // Across a page break, only an unfinished line carries on.
                return !(isFull(previous, right: pendingRight, left: pendingLeft) && startsLower)
            }
            let gap = line.box.minY - previous.box.maxY
            if gap > max(line.size, previous.size) * 0.75 { return true }
            if gap < -previous.box.height * 0.5 { return true }
            if isCentred(previous, left: left, right: right), isCentred(line, left: left, right: right) {
                return false
            }
            if !isFull(previous, right: right, left: left) { return true }
            // A first-line indent marks a new paragraph.
            // A line set in from the one above starts a new paragraph (a
            // first-line indent), unless the one above is the paragraph's own
            // first line: then this is a hanging indent, as in a list item.
            if line.box.minX > previous.box.minX + line.size * 0.8 {
                return pending.count > 1
            }
            return false
        }

        mutating func flush() {
            guard !pending.isEmpty else { return }
            let lines = pending
            let left = pendingLeft
            let right = pendingRight
            pending.removeAll()

            // Join the lines: a space between them, or nothing after a hyphen
            // that only split a word.
            var glyphs: [PDFToDocx.Glyph] = []
            for line in lines {
                var incoming = line.glyphs
                if let last = glyphs.last(where: { !$0.isSpace }) {
                    let startsLower = incoming.first { !$0.isSpace }?.text.first?.isLowercase ?? false
                    if ["-", "\u{00AD}", "\u{2010}"].contains(last.text), startsLower {
                        while let tail = glyphs.last, tail.isSpace { glyphs.removeLast() }
                        glyphs.removeLast()
                    } else {
                        var space = last
                        space.text = " "
                        space.box = .null
                        glyphs.append(space)
                    }
                }
                incoming.removeAll { $0.text == "\u{00AD}" }
                glyphs.append(contentsOf: incoming)
            }

            let inked = glyphs.filter { !$0.isSpace }
            guard !inked.isEmpty else { return }
            let text = glyphs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            var sizes: [CGFloat: Int] = [:]
            for glyph in inked { sizes[glyph.size, default: 0] += 1 }
            let size = sizes.max { $0.value < $1.value }?.key ?? bodySize
            let allBold = inked.allSatisfy(\.bold)

            var paragraph = DocxParagraph(runs: [])
            var heading: (size: CGFloat, boldOnly: Bool)?
            var bulletIndent: CGFloat?
            if let marker = PDFToDocx.marker(of: lines[0]) {
                // Drop the bullet itself; Word draws its own.
                var rest = glyphs
                var removed = 0
                while removed < marker, !rest.isEmpty {
                    if !rest[0].isSpace { removed += 1 }
                    rest.removeFirst()
                }
                paragraph.kind = .bullet(0)
                paragraph.runs = PDFToDocx.runs(from: rest, baseSize: bodySize, plain: false)
                bulletIndent = lines[0].box.minX
            } else {
                let bigger = size >= bodySize * 1.15 && text.count <= 200 && lines.count <= 3
                let last = text.last ?? " "
                let boldTitle = allBold && lines.count == 1 && text.count <= 80 && size >= bodySize - 0.3
                    && !".,;".contains(last) && text.contains(where: \.isLetter)
                if bigger || boldTitle {
                    paragraph.kind = .heading(1)
                    paragraph.runs = PDFToDocx.runs(from: glyphs, baseSize: size, plain: true)
                    heading = (size, !bigger)
                } else {
                    paragraph.runs = PDFToDocx.runs(from: glyphs, baseSize: bodySize, plain: false)
                }
            }

            if lines.allSatisfy({ isCentred($0, left: left, right: right) }) {
                paragraph.alignment = .center
            } else if lines.allSatisfy({ $0.box.maxX >= right - 4 && $0.box.minX - left > 20 }) {
                paragraph.alignment = .right
            } else if lines.count >= 3, lines.dropLast().allSatisfy({
                isFull($0, right: right, left: left) && $0.box.maxX >= right - 3
            }) {
                paragraph.alignment = .justified
            }
            guard !paragraph.runs.isEmpty else { return }
            if let heading { headings.append((blocks.count, heading.size, heading.boldOnly)) }
            if let bulletIndent { bulletIndents.append((blocks.count, bulletIndent)) }
            blocks.append(.paragraph(paragraph))
        }

        /// Settles heading levels and bullet indents once everything is known.
        mutating func finish() {
            flush()
            let sizes = Array(Set(headings.filter { !$0.boldOnly }.map(\.size))).sorted(by: >)
            for heading in headings {
                guard case .paragraph(var paragraph) = blocks[heading.index] else { continue }
                let level: Int
                if heading.boldOnly {
                    level = min(4, min(sizes.count, 3) + 1)
                } else {
                    level = min(3, (sizes.firstIndex(of: heading.size) ?? 0) + 1)
                }
                paragraph.kind = .heading(level)
                blocks[heading.index] = .paragraph(paragraph)
            }
            guard let base = bulletIndents.map(\.indent).min() else { return }
            for bullet in bulletIndents {
                guard case .paragraph(var paragraph) = blocks[bullet.index] else { continue }
                let level = Int(((bullet.indent - base) / 18).rounded())
                paragraph.kind = .bullet(min(max(level, 0), 2))
                blocks[bullet.index] = .paragraph(paragraph)
            }
        }
    }

    /// How many characters at the start of the line are a bullet, if it begins with one.
    private static func marker(of line: Line) -> Int? {
        let inked = line.glyphs.filter { !$0.isSpace }
        guard inked.count >= 2, let first = line.glyphs.first, !first.isSpace, bullets.contains(first.text) else {
            return nil
        }
        // A bullet stands alone: a space or a clear gap follows it.
        if line.glyphs.count > 1, line.glyphs[1].isSpace { return 1 }
        return inked[1].box.minX - inked[0].box.maxX > line.size * 0.3 ? 1 : nil
    }
}
