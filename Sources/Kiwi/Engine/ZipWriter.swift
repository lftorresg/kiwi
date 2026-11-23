import Foundation

/// A minimal ZIP writer, for the Office files Kiwi produces (a DOCX is a ZIP
/// of XML parts). Entries are stored without compression, which every reader
/// accepts and which needs no decompressor, pointers or external tool.
enum ZipWriter {
    private static let table: [UInt32] = (0..<256).map { value -> UInt32 in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
        }
        return crc
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The archive for `entries`, in order. Names are paths inside the archive.
    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        // A fixed date, so the same input always gives the same file.
        let date = UInt16(((2026 - 1980) << 9) | (1 << 5) | 1)

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(out.count)

            out.append32(0x0403_4B50)       // local file header
            out.append16(20)                // version needed
            out.append16(0x0800)            // names are UTF-8
            out.append16(0)                 // stored
            out.append16(0)                 // time
            out.append16(date)
            out.append32(crc)
            out.append32(size)
            out.append32(size)
            out.append16(UInt16(name.count))
            out.append16(0)
            out.append(name)
            out.append(entry.data)

            central.append32(0x0201_4B50)   // central directory entry
            central.append16(20)            // version made by
            central.append16(20)            // version needed
            central.append16(0x0800)
            central.append16(0)
            central.append16(0)
            central.append16(date)
            central.append32(crc)
            central.append32(size)
            central.append32(size)
            central.append16(UInt16(name.count))
            central.append16(0)             // extra
            central.append16(0)             // comment
            central.append16(0)             // disk
            central.append16(0)             // internal attributes
            central.append32(0)             // external attributes
            central.append32(offset)
            central.append(name)
        }

        let directoryStart = UInt32(out.count)
        out.append(central)
        out.append32(0x0605_4B50)           // end of central directory
        out.append16(0)
        out.append16(0)
        out.append16(UInt16(entries.count))
        out.append16(UInt16(entries.count))
        out.append32(UInt32(central.count))
        out.append32(directoryStart)
        out.append16(0)
        return out
    }
}

private extension Data {
    mutating func append16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
