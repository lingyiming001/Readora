import Foundation
import CZlib

public enum EPUBError: LocalizedError {
    case invalidArchive, unsafePath, limitExceeded, invalidDocument(String), encrypted, fixedLayout, empty
    public var errorDescription: String? {
        switch self {
        case .invalidArchive: "EPUB 压缩包已损坏，或使用了不支持的压缩格式。"
        case .unsafePath: "EPUB 包含不安全或无效的资源路径。"
        case .limitExceeded: "EPUB 内容超过安全限制，请使用较小的书籍。"
        case .invalidDocument(let name): "无法解析 EPUB 文档：\(name)。请检查文件是否完整。"
        case .encrypted: "此 EPUB 含加密资源；当前版本仅支持无 DRM、无加密资源的书籍。"
        case .fixedLayout: "当前版本仅支持重排 EPUB，暂不支持固定版式。"
        case .empty: "此 EPUB 没有可读取的正文。"
        }
    }
}

// Read entries in memory only. No untrusted archive path is ever written to disk.
struct EPUBArchive {
    struct Entry {
        let name: String
        let method: UInt16
        let flags: UInt16
        let crc: UInt32
        let compressedSize: Int
        let size: Int
        let offset: Int
    }
    let data: Data
    let entries: [String: Entry]
    static let maxEntrySize = 64 * 1024 * 1024
    static let maxTotalSize = 1024 * 1024 * 1024

    init(data: Data) throws {
        guard data.count >= 22 else { throw EPUBError.invalidArchive }
        self.data = data
        // EOCD must end exactly at EOF, including its comment. Reject split and ZIP64 archives.
        let lower = max(0, data.count - 65_557)
        guard let end = stride(from: data.count - 22, through: lower, by: -1).first(where: {
            data.u32($0) == 0x06054b50 && $0 + 22 + Int(data.u16($0 + 20)) == data.count
        }) else { throw EPUBError.invalidArchive }
        guard data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              data.u16(end + 8) == data.u16(end + 10) else { throw EPUBError.invalidArchive }
        let count = Int(data.u16(end + 10))
        let directorySize = Int(data.u32(end + 12)), directoryStart = Int(data.u32(end + 16))
        guard count > 0, count <= 10_000, directoryStart + directorySize == end else { throw EPUBError.invalidArchive }
        var cursor = directoryStart, total = 0, parsed: [String: Entry] = [:]
        for _ in 0..<count {
            try Task.checkCancellation()
            guard cursor >= 0, cursor + 46 <= end, data.u32(cursor) == 0x02014b50 else { throw EPUBError.invalidArchive }
            let flags = data.u16(cursor + 8), method = data.u16(cursor + 10)
            guard flags & 0x41 == 0 else { throw EPUBError.encrypted }
            guard [0, 8].contains(method), data.u16(cursor + 34) == 0 else { throw EPUBError.invalidArchive }
            let compressed = Int(data.u32(cursor + 20)), size = Int(data.u32(cursor + 24))
            let nameLength = Int(data.u16(cursor + 28)), extra = Int(data.u16(cursor + 30)), comment = Int(data.u16(cursor + 32))
            let next = cursor + 46 + nameLength + extra + comment
            guard nameLength > 0, next <= end,
                  let name = String(data: data.subdata(in: cursor + 46..<cursor + 46 + nameLength), encoding: .utf8) else { throw EPUBError.invalidArchive }
            try Self.validatePath(name)
            guard parsed[name] == nil else { throw EPUBError.invalidArchive }
            let mode = (data.u32(cursor + 38) >> 16) & 0xF000
            guard mode != 0xA000 else { throw EPUBError.unsafePath }
            total += size
            guard size <= Self.maxEntrySize, total <= Self.maxTotalSize,
                  size <= max(1, compressed) * 250 else { throw EPUBError.limitExceeded }
            let offset = Int(data.u32(cursor + 42))
            guard offset + 30 <= directoryStart, data.u32(offset) == 0x04034b50,
                  data.u16(offset + 6) == flags, data.u16(offset + 8) == method else { throw EPUBError.invalidArchive }
            let localName = Int(data.u16(offset + 26)), localExtra = Int(data.u16(offset + 28))
            let start = offset + 30 + localName + localExtra
            guard start + compressed <= directoryStart,
                  localName == nameLength,
                  data.subdata(in: offset + 30..<offset + 30 + localName) == Data(name.utf8) else { throw EPUBError.invalidArchive }
            parsed[name] = Entry(name: name, method: method, flags: flags, crc: data.u32(cursor + 16),
                                 compressedSize: compressed, size: size, offset: start)
            cursor = next
        }
        guard cursor == end else { throw EPUBError.invalidArchive }
        entries = parsed
    }
    static func validatePath(_ path: String) throws {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 }),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw EPUBError.unsafePath }
    }
    func read(_ name: String) throws -> Data {
        try Task.checkCancellation()
        guard let entry = entries[name], !name.hasSuffix("/") else { throw EPUBError.invalidDocument(name) }
        let compressed = data.subdata(in: entry.offset..<entry.offset + entry.compressedSize)
        let output: Data
        if entry.method == 0 {
            guard entry.size == entry.compressedSize else { throw EPUBError.invalidArchive }
            output = compressed
        } else {
            var result = Data(count: max(1, entry.size))
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw EPUBError.invalidArchive }
            defer { inflateEnd(&stream) }
            let status = compressed.withUnsafeBytes { input in
                result.withUnsafeMutableBytes { buffer in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size,
                  stream.total_in == entry.compressedSize else { throw EPUBError.invalidArchive }
            result.count = entry.size
            output = result
        }
        let checksum = output.withUnsafeBytes { bytes in
            crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(output.count))
        }
        guard UInt32(checksum) == entry.crc else { throw EPUBError.invalidArchive }
        return output
    }
}

private extension Data {
    func u16(_ index: Int) -> UInt16 {
        guard index >= 0, index + 2 <= count else { return 0 }
        return UInt16(self[index]) | UInt16(self[index + 1]) << 8
    }
    func u32(_ index: Int) -> UInt32 {
        guard index >= 0, index + 4 <= count else { return 0 }
        return UInt32(self[index]) | UInt32(self[index + 1]) << 8 | UInt32(self[index + 2]) << 16 | UInt32(self[index + 3]) << 24
    }
}
