import Foundation

/// Pure-Swift ZIP reader/writer used by data export/import. Implements the
/// "store" method only — no DEFLATE — which keeps this file dependency-free
/// (no zlib, no SPM packages) at the cost of zero compression. Receipt JPEGs
/// are already compressed and the manifest JSON is tiny, so store-mode is
/// a fine fit.
///
/// File format reference: APPNOTE.TXT §4 (PKWARE ZIP).
/// What's supported:
///   - Single-file or many-file archives
///   - UTF-8 filenames (sets bit 11 of the general-purpose flag)
///   - CRC-32 over the uncompressed payload
///   - End-of-central-directory record discovery via tail scan
/// What's NOT supported (and we explicitly reject on read):
///   - Zip64 (4 GB+ archives)
///   - DEFLATE / any non-store compression method
///   - Encryption
///   - Multi-disk archives
///
/// Archives written here open cleanly in Finder, iOS Files, `unzip`, and
/// `ditto -xk`. Archives read here accept anything other tools produce so
/// long as it sticks to store-mode + UTF-8 filenames.
enum MiniZip {

    // MARK: - Errors

    enum ReadError: LocalizedError {
        case notAZipArchive
        case truncated
        case unsupportedCompression(method: UInt16, entry: String)
        case unsupportedZip64
        case unsupportedEncryption(entry: String)
        case crcMismatch(entry: String)
        case duplicateEntry(name: String)

        var errorDescription: String? {
            switch self {
            case .notAZipArchive:                  return "The selected file isn't a ZIP archive."
            case .truncated:                       return "The archive looks truncated."
            case .unsupportedCompression(_, let e): return "Entry \(e) uses a compression method this importer doesn't support."
            case .unsupportedZip64:                return "Zip64 archives aren't supported."
            case .unsupportedEncryption(let e):    return "Entry \(e) is encrypted, which isn't supported."
            case .crcMismatch(let e):              return "Entry \(e) failed its CRC check (file is corrupt)."
            case .duplicateEntry(let n):           return "Archive has two entries called \(n)."
            }
        }
    }

    // MARK: - Public API

    /// One uncompressed entry inside an archive.
    struct Entry {
        let name: String
        let data: Data
    }

    /// Build a ZIP archive from a list of entries and write it to `url`.
    /// Caller decides directory layout via the entry names (e.g. include
    /// `"receipts/<uuid>.jpg"` to land the receipt in a subdirectory).
    static func write(entries: [Entry], to url: URL) throws {
        var archive = Data()
        var central = Data()
        var entryCount: UInt16 = 0
        let dosTime = DOSTimestamp.now()

        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            let crc = CRC32.checksum(of: entry.data)
            let localHeaderOffset = UInt32(archive.count)

            // Local file header (signature 0x04034b50)
            archive.append(uint32: 0x04034b50)
            archive.append(uint16: 20)                   // version needed
            archive.append(uint16: 0x0800)               // flags: bit 11 (UTF-8 filenames)
            archive.append(uint16: 0)                    // method: store
            archive.append(uint16: dosTime.time)
            archive.append(uint16: dosTime.date)
            archive.append(uint32: crc)
            archive.append(uint32: UInt32(entry.data.count)) // compressed size
            archive.append(uint32: UInt32(entry.data.count)) // uncompressed size
            archive.append(uint16: UInt16(nameBytes.count))
            archive.append(uint16: 0)                    // extra field length
            archive.append(contentsOf: nameBytes)
            archive.append(entry.data)

            // Central directory header (signature 0x02014b50)
            central.append(uint32: 0x02014b50)
            central.append(uint16: 20)                   // version made by
            central.append(uint16: 20)                   // version needed
            central.append(uint16: 0x0800)               // flags
            central.append(uint16: 0)                    // method
            central.append(uint16: dosTime.time)
            central.append(uint16: dosTime.date)
            central.append(uint32: crc)
            central.append(uint32: UInt32(entry.data.count))
            central.append(uint32: UInt32(entry.data.count))
            central.append(uint16: UInt16(nameBytes.count))
            central.append(uint16: 0)                    // extra field length
            central.append(uint16: 0)                    // comment length
            central.append(uint16: 0)                    // disk number
            central.append(uint16: 0)                    // internal attrs
            central.append(uint32: 0)                    // external attrs
            central.append(uint32: localHeaderOffset)
            central.append(contentsOf: nameBytes)

            entryCount += 1
        }

        let centralOffset = UInt32(archive.count)
        archive.append(central)

        // End of central directory record (signature 0x06054b50)
        archive.append(uint32: 0x06054b50)
        archive.append(uint16: 0)                        // disk number
        archive.append(uint16: 0)                        // disk with central dir start
        archive.append(uint16: entryCount)               // entries on this disk
        archive.append(uint16: entryCount)               // total entries
        archive.append(uint32: UInt32(central.count))    // central directory size
        archive.append(uint32: centralOffset)
        archive.append(uint16: 0)                        // .ZIP file comment length

        try archive.write(to: url, options: [.atomic])
    }

    /// Read every entry from a ZIP archive on disk. Throws on any
    /// unsupported feature (Zip64, encrypted, compressed-but-not-store).
    static func read(from url: URL) throws -> [Entry] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try read(data: data)
    }

    /// Read every entry from a ZIP archive already loaded into memory.
    static func read(data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ReadError.truncated }
        let eocd = try findEndOfCentralDirectory(in: data)

        var cdOffset = Int(eocd.centralDirectoryOffset)
        var entries: [Entry] = []
        var seenNames = Set<String>()

        for _ in 0..<eocd.entryCount {
            guard cdOffset + 46 <= data.count else { throw ReadError.truncated }
            let signature: UInt32 = data.readUInt32(at: cdOffset)
            guard signature == 0x02014b50 else { throw ReadError.notAZipArchive }

            let flags: UInt16 = data.readUInt16(at: cdOffset + 8)
            let method: UInt16 = data.readUInt16(at: cdOffset + 10)
            let crcExpected: UInt32 = data.readUInt32(at: cdOffset + 16)
            let compressedSize: UInt32 = data.readUInt32(at: cdOffset + 20)
            let uncompressedSize: UInt32 = data.readUInt32(at: cdOffset + 24)
            let nameLen: UInt16 = data.readUInt16(at: cdOffset + 28)
            let extraLen: UInt16 = data.readUInt16(at: cdOffset + 30)
            let commentLen: UInt16 = data.readUInt16(at: cdOffset + 32)
            let localHeaderOffset: UInt32 = data.readUInt32(at: cdOffset + 42)

            let nameRange = (cdOffset + 46)..<(cdOffset + 46 + Int(nameLen))
            guard nameRange.upperBound <= data.count else { throw ReadError.truncated }
            let name = String(data: data.subdata(in: nameRange), encoding: .utf8)
                ?? String(data: data.subdata(in: nameRange), encoding: .isoLatin1)
                ?? "<unnamed>"

            if (flags & 0x0001) != 0 { throw ReadError.unsupportedEncryption(entry: name) }
            if uncompressedSize == 0xFFFFFFFF || compressedSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                throw ReadError.unsupportedZip64
            }
            if method != 0 { throw ReadError.unsupportedCompression(method: method, entry: name) }

            // Skip past directory entries (names ending with "/"). These have
            // zero-byte payloads and don't need round-tripping for the
            // importer — the directory tree is implicit in the file paths.
            let isDirectory = name.hasSuffix("/")
            if !isDirectory {
                let payload = try readLocalPayload(
                    data: data,
                    localHeaderOffset: Int(localHeaderOffset),
                    expectedSize: Int(compressedSize),
                    entryName: name
                )
                let actualCRC = CRC32.checksum(of: payload)
                guard actualCRC == crcExpected else { throw ReadError.crcMismatch(entry: name) }
                guard seenNames.insert(name).inserted else { throw ReadError.duplicateEntry(name: name) }
                entries.append(Entry(name: name, data: payload))
            }

            cdOffset += 46 + Int(nameLen) + Int(extraLen) + Int(commentLen)
        }

        return entries
    }

    // MARK: - Internals

    private static func readLocalPayload(
        data: Data,
        localHeaderOffset: Int,
        expectedSize: Int,
        entryName: String
    ) throws -> Data {
        guard localHeaderOffset + 30 <= data.count else { throw ReadError.truncated }
        let signature: UInt32 = data.readUInt32(at: localHeaderOffset)
        guard signature == 0x04034b50 else { throw ReadError.notAZipArchive }

        let method: UInt16 = data.readUInt16(at: localHeaderOffset + 8)
        if method != 0 { throw ReadError.unsupportedCompression(method: method, entry: entryName) }

        let nameLen: UInt16 = data.readUInt16(at: localHeaderOffset + 26)
        let extraLen: UInt16 = data.readUInt16(at: localHeaderOffset + 28)
        let payloadStart = localHeaderOffset + 30 + Int(nameLen) + Int(extraLen)
        let payloadEnd = payloadStart + expectedSize
        guard payloadEnd <= data.count else { throw ReadError.truncated }
        return data.subdata(in: payloadStart..<payloadEnd)
    }

    private struct EOCD {
        let entryCount: UInt16
        let centralDirectoryOffset: UInt32
    }

    /// Locate the End-Of-Central-Directory record. The signature
    /// `0x06054b50` sits 22..65557 bytes from EOF (22 bytes minimum plus
    /// up to 65535 bytes of optional archive comment). Scan backwards
    /// from the tail.
    private static func findEndOfCentralDirectory(in data: Data) throws -> EOCD {
        let maxCommentLength = 65535
        let minRecordSize = 22
        let scanStart = max(0, data.count - (minRecordSize + maxCommentLength))
        var index = data.count - minRecordSize
        while index >= scanStart {
            if data.readUInt32(at: index) == 0x06054b50 {
                let entryCount: UInt16 = data.readUInt16(at: index + 10)
                let centralSize: UInt32 = data.readUInt32(at: index + 12)
                let centralOffset: UInt32 = data.readUInt32(at: index + 16)
                if centralOffset == 0xFFFFFFFF || centralSize == 0xFFFFFFFF || entryCount == 0xFFFF {
                    throw ReadError.unsupportedZip64
                }
                return EOCD(entryCount: entryCount, centralDirectoryOffset: centralOffset)
            }
            index -= 1
        }
        throw ReadError.notAZipArchive
    }
}

// MARK: - CRC32

private enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1
            }
            return c
        }
    }()

    static func checksum(of data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<buffer.count {
                let byte = base.load(fromByteOffset: i, as: UInt8.self)
                let index = Int((c ^ UInt32(byte)) & 0xFF)
                c = table[index] ^ (c >> 8)
            }
        }
        return c ^ 0xFFFFFFFF
    }
}

// MARK: - Helpers

private struct DOSTimestamp {
    let date: UInt16
    let time: UInt16

    static func now() -> DOSTimestamp {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = max(1980, comps.year ?? 1980)
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = (comps.second ?? 0) / 2

        let date = UInt16(((year - 1980) << 9) | (month << 5) | day)
        let time = UInt16((hour << 11) | (minute << 5) | second)
        return DOSTimestamp(date: date, time: time)
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func readUInt16(at offset: Int) -> UInt16 {
        let lo = UInt16(self[self.startIndex + offset])
        let hi = UInt16(self[self.startIndex + offset + 1])
        return lo | (hi << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[self.startIndex + offset])
        let b1 = UInt32(self[self.startIndex + offset + 1])
        let b2 = UInt32(self[self.startIndex + offset + 2])
        let b3 = UInt32(self[self.startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
