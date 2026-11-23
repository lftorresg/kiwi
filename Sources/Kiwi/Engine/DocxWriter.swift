import Foundation
import CoreGraphics

/// A stretch of text with one look.
struct DocxRun {
    var text: String
    var bold = false
    var italic = false
    /// Points. 0 means "the paragraph's own size".
    var size: CGFloat = 0
    /// "RRGGBB", or nil for the default text colour.
    var color: String?
    var font: String?
    var link: String?

    func looksLike(_ other: DocxRun) -> Bool {
        bold == other.bold && italic == other.italic && size == other.size
            && color == other.color && font == other.font && link == other.link
    }
}

struct DocxParagraph {
    enum Kind: Equatable {
        case body
        /// 1 is the largest.
        case heading(Int)
        /// A bullet at an indent level, starting at 0.
        case bullet(Int)
    }

    enum Alignment {
        case left, center, right, justified
    }

    var runs: [DocxRun]
    var kind: Kind = .body
    var alignment: Alignment = .left
}

enum DocxBlock {
    case paragraph(DocxParagraph)
    /// Column widths in points, then rows of cells.
    case table(columns: [CGFloat], rows: [[[DocxRun]]])
    /// An encoded picture and the size to show it at, in points.
    case image(data: Data, isJPEG: Bool, size: CGSize)
}

struct DocxDocument {
    var blocks: [DocxBlock] = []
    /// Points.
    var pageSize = CGSize(width: 595, height: 842)
    var margin: CGFloat = 72
    var bodySize: CGFloat = 11
    /// Text size of each heading level, largest first.
    var headingSizes: [CGFloat] = [20, 16, 14, 12]
}

/// Writes a Word document: real paragraphs, heading styles, bullet lists,
/// tables, pictures and links, so the structure survives in Word, Pages and
/// Google Docs. The parts are written by hand and zipped with `ZipWriter`.
enum DocxWriter {
    private static let main = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    private static let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func data(for document: DocxDocument) -> Data {
        var body = ""
        var links: [(id: String, kind: String, target: String)] = []
        var media: [(name: String, data: Data)] = []
        var nextID = 3
        var usesJPEG = false
        let textWidth = max(72, document.pageSize.width - document.margin * 2)

        func linkID(for target: String) -> String {
            if let known = links.first(where: { $0.kind == "hyperlink" && $0.target == target }) {
                return known.id
            }
            let id = "rId\(nextID)"
            nextID += 1
            links.append((id, "hyperlink", target))
            return id
        }

        func paragraphXML(_ paragraph: DocxParagraph) -> String {
            var properties = ""
            switch paragraph.kind {
            case .body:
                break
            case .heading(let level):
                properties += "<w:pStyle w:val=\"Heading\(min(max(level, 1), 4))\"/>"
            case .bullet(let level):
                properties += "<w:pStyle w:val=\"ListParagraph\"/>"
                properties += "<w:numPr><w:ilvl w:val=\"\(min(max(level, 0), 2))\"/><w:numId w:val=\"1\"/></w:numPr>"
            }
            switch paragraph.alignment {
            case .left: break
            case .center: properties += "<w:jc w:val=\"center\"/>"
            case .right: properties += "<w:jc w:val=\"right\"/>"
            case .justified: properties += "<w:jc w:val=\"both\"/>"
            }

            var content = ""
            var index = 0
            let runs = paragraph.runs
            while index < runs.count {
                if let target = runs[index].link {
                    // Neighbouring runs with the same target share one link.
                    var inner = ""
                    while index < runs.count, runs[index].link == target {
                        inner += runXML(runs[index])
                        index += 1
                    }
                    content += "<w:hyperlink r:id=\"\(linkID(for: target))\" w:history=\"1\">\(inner)</w:hyperlink>"
                } else {
                    content += runXML(runs[index])
                    index += 1
                }
            }
            let wrapped = properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>"
            return "<w:p>\(wrapped)\(content)</w:p>"
        }

        for block in document.blocks {
            switch block {
            case .paragraph(let paragraph):
                body += paragraphXML(paragraph)

            case .table(let columns, let rows):
                let widths = columns.map { max(200, Int(($0 * 20).rounded())) }
                var table = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/><w:tblBorders>"
                for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
                    table += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>"
                }
                table += "</w:tblBorders><w:tblCellMar><w:left w:w=\"100\" w:type=\"dxa\"/><w:right w:w=\"100\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
                for width in widths {
                    table += "<w:gridCol w:w=\"\(width)\"/>"
                }
                table += "</w:tblGrid>"
                for row in rows {
                    table += "<w:tr>"
                    for column in 0..<widths.count {
                        let runs = column < row.count ? row[column] : []
                        table += "<w:tc><w:tcPr><w:tcW w:w=\"\(widths[column])\" w:type=\"dxa\"/></w:tcPr>"
                        table += paragraphXML(DocxParagraph(runs: runs))
                        table += "</w:tc>"
                    }
                    table += "</w:tr>"
                }
                // Word wants a paragraph after a table.
                body += table + "</w:tbl><w:p/>"

            case .image(let data, let isJPEG, let size):
                let number = media.count + 1
                let name = "image\(number).\(isJPEG ? "jpg" : "png")"
                media.append((name, data))
                if isJPEG { usesJPEG = true }
                let id = "rId\(nextID)"
                nextID += 1
                links.append((id, "image", "media/\(name)"))

                // Never wider than the text; 12700 EMU to the point.
                let fit = min(1, textWidth / max(1, size.width))
                let cx = Int((size.width * fit * 12700).rounded())
                let cy = Int((size.height * fit * 12700).rounded())
                body += "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r><w:drawing>"
                body += "<wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/>"
                body += "<wp:docPr id=\"\(number)\" name=\"Picture \(number)\"/><a:graphic>"
                body += "<a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic>"
                body += "<pic:nvPicPr><pic:cNvPr id=\"\(number)\" name=\"\(name)\"/><pic:cNvPicPr/></pic:nvPicPr>"
                body += "<pic:blipFill><a:blip r:embed=\"\(id)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"
                body += "<pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm>"
                body += "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData>"
                body += "</a:graphic></wp:inline></w:drawing></w:r></w:p>"
            }
        }

        let pageWidth = Int((document.pageSize.width * 20).rounded())
        let pageHeight = Int((document.pageSize.height * 20).rounded())
        let margin = Int((document.margin * 20).rounded())
        var documentXML = header + "<w:document xmlns:w=\"\(main)\" xmlns:r=\"\(relationships)\""
        documentXML += " xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\""
        documentXML += " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
        documentXML += " xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><w:body>"
        documentXML += body
        documentXML += "<w:sectPr><w:pgSz w:w=\"\(pageWidth)\" w:h=\"\(pageHeight)\"/>"
        documentXML += "<w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\""
        documentXML += " w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>"

        var contentTypes = header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        contentTypes += "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        contentTypes += "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        contentTypes += "<Default Extension=\"png\" ContentType=\"image/png\"/>"
        if usesJPEG {
            contentTypes += "<Default Extension=\"jpg\" ContentType=\"image/jpeg\"/>"
        }
        contentTypes += "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        contentTypes += "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
        contentTypes += "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/></Types>"

        let package = "http://schemas.openxmlformats.org/package/2006/relationships"
        let rootRelationships = header + "<Relationships xmlns=\"\(package)\"><Relationship Id=\"rId1\" Type=\"\(relationships)/officeDocument\" Target=\"word/document.xml\"/></Relationships>"

        var documentRelationships = header + "<Relationships xmlns=\"\(package)\">"
        documentRelationships += "<Relationship Id=\"rId1\" Type=\"\(relationships)/styles\" Target=\"styles.xml\"/>"
        documentRelationships += "<Relationship Id=\"rId2\" Type=\"\(relationships)/numbering\" Target=\"numbering.xml\"/>"
        for link in links {
            if link.kind == "image" {
                documentRelationships += "<Relationship Id=\"\(link.id)\" Type=\"\(relationships)/image\" Target=\"\(link.target)\"/>"
            } else {
                documentRelationships += "<Relationship Id=\"\(link.id)\" Type=\"\(relationships)/hyperlink\" Target=\"\(escape(link.target))\" TargetMode=\"External\"/>"
            }
        }
        documentRelationships += "</Relationships>"

        var entries: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rootRelationships.utf8)),
            ("word/document.xml", Data(documentXML.utf8)),
            ("word/styles.xml", Data(stylesXML(document).utf8)),
            ("word/numbering.xml", Data(numberingXML().utf8)),
            ("word/_rels/document.xml.rels", Data(documentRelationships.utf8)),
        ]
        for file in media {
            entries.append(("word/media/\(file.name)", file.data))
        }
        return ZipWriter.archive(entries)
    }

    private static func runXML(_ run: DocxRun) -> String {
        guard !run.text.isEmpty else { return "" }
        var properties = ""
        if run.link != nil { properties += "<w:rStyle w:val=\"Hyperlink\"/>" }
        if let font = run.font {
            let name = escape(font)
            properties += "<w:rFonts w:ascii=\"\(name)\" w:hAnsi=\"\(name)\" w:cs=\"\(name)\"/>"
        }
        if run.bold { properties += "<w:b/>" }
        if run.italic { properties += "<w:i/>" }
        if let color = run.color, run.link == nil { properties += "<w:color w:val=\"\(color)\"/>" }
        if run.size > 0 {
            let half = max(2, Int((run.size * 2).rounded()))
            properties += "<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>"
        }
        let wrapped = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return "<w:r>\(wrapped)<w:t xml:space=\"preserve\">\(escape(run.text))</w:t></w:r>"
    }

    private static func stylesXML(_ document: DocxDocument) -> String {
        let body = max(2, Int((document.bodySize * 2).rounded()))
        var xml = header + "<w:styles xmlns:w=\"\(main)\"><w:docDefaults><w:rPrDefault><w:rPr>"
        xml += "<w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\"/><w:sz w:val=\"\(body)\"/><w:szCs w:val=\"\(body)\"/>"
        xml += "</w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=\"160\" w:line=\"259\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
        xml += "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
        for level in 1...4 {
            let size = level <= document.headingSizes.count ? document.headingSizes[level - 1] : document.bodySize
            let half = max(2, Int((size * 2).rounded()))
            xml += "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/>"
            xml += "<w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/>"
            xml += "<w:pPr><w:keepNext/><w:spacing w:before=\"320\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr>"
            xml += "<w:rPr><w:b/><w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/></w:rPr></w:style>"
        }
        xml += "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>"
        xml += "<w:pPr><w:ind w:left=\"720\"/><w:contextualSpacing/></w:pPr></w:style>"
        xml += "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/></w:style>"
        xml += "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:basedOn w:val=\"DefaultParagraphFont\"/>"
        xml += "<w:rPr><w:color w:val=\"0563C1\"/><w:u w:val=\"single\"/></w:rPr></w:style></w:styles>"
        return xml
    }

    private static func numberingXML() -> String {
        var xml = header + "<w:numbering xmlns:w=\"\(main)\"><w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
        let levels: [(String, Int)] = [("\u{2022}", 720), ("\u{25E6}", 1440), ("\u{25AA}", 2160)]
        for (index, level) in levels.enumerated() {
            xml += "<w:lvl w:ilvl=\"\(index)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(level.0)\"/>"
            xml += "<w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(level.1)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
        }
        xml += "</w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num></w:numbering>"
        return xml
    }

    /// Text made safe for XML: the five special characters are escaped and
    /// characters XML does not allow, which PDFs sometimes contain, are dropped.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\n", "\r", "\t": out += " "
            default:
                let value = scalar.value
                if value >= 0x20, value != 0xFFFE, value != 0xFFFF {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}
