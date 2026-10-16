import Foundation
import CryptoKit

public struct Book: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let filename: String
    public let hash: String
    public let format: String
    public var position: Int
    public var lastOpened: Date?
    public var author: String?
    public var coverFilename: String?
    public var resourceID: String?
    public var paragraphIndex: Int?
    public var textOffset: Int?
    public var isFavorite: Bool?
    public var isFinished: Bool?
    public var trashedAt: Date?
    public var collectionIDs: [UUID]?
    public var totalUnitCount: Int?

    public init(id: UUID = UUID(), title: String, filename: String, hash: String,
                format: String, position: Int = 0, lastOpened: Date? = nil) {
        self.id = id; self.title = title; self.filename = filename
        self.hash = hash; self.format = format; self.position = position
        self.lastOpened = lastOpened
    }
}

public enum LibraryError: LocalizedError {
    case unsupported, unreadableText
    case tooLarge(limitMB: Int)
    public var errorDescription: String? {
        switch self {
        case .unsupported: "请选择 EPUB、TXT 或 PDF 文件。"
        case .tooLarge(let limit): "文件超过当前 \(limit) MB 的导入上限。可在 Readora 设置中调整。"
        case .unreadableText: "无法识别文本编码，请转换为 UTF-8 后重试。"
        }
    }
}

public enum TextContent {
    public static func decode(_ data: Data) throws -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf8) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
        throw LibraryError.unreadableText
    }
    public static func paragraphs(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    public static func clampedPosition(_ position: Int, count: Int) -> Int {
        min(max(0, position), max(0, count - 1))
    }
}

public actor LibraryStore {
    let root: URL
    var books: [Book] = []
    private var isLoaded = false
    private var imageArchive: (hash: String, archive: EPUBArchive)?
    public init(root: URL) { self.root = root }
    public func load() throws -> [Book] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try recoverPendingDeletions()
        let file = root.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: file.path) {
            books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: file))
        }
        isLoaded = true
        return books
    }
    public func fileURL(for book: Book) -> URL { root.appendingPathComponent(book.filename) }
    public func importSettings() throws -> ImportSettings {
        let url = root.appendingPathComponent("settings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return ImportSettings() }
        let settings = try JSONDecoder().decode(ImportSettings.self, from: Data(contentsOf: url))
        try settings.validate()
        return settings
    }
    public func saveImportSettings(_ settings: ImportSettings) throws {
        try settings.validate()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
    }
    public func importFile(_ source: URL) async throws -> [Book] {
        if !isLoaded { _ = try load() }
        let ext = source.pathExtension.lowercased()
        guard ["txt", "pdf", "epub"].contains(ext) else { throw LibraryError.unsupported }
        let settings = try importSettings()
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else { throw LibraryError.unsupported }
        try settings.validateFileSize(Int64(size))
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let temporary = staging.appendingPathComponent(UUID().uuidString + "." + ext)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let worker = Task.detached(priority: .userInitiated) {
            let hash = try Self.copyAndHash(source, to: temporary, settings: settings)
            if ext == "txt" { _ = try TextContent.decode(Data(contentsOf: temporary, options: .mappedIfSafe)) }
            let publication = ext == "epub" ? try EPUBPublication.read(url: temporary) : nil
            return PreparedImport(hash: hash, publication: publication)
        }
        let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        let hash = prepared.hash
        if let index = books.firstIndex(where: { $0.hash == hash }) {
            if books[index].trashedAt != nil {
                var next = books; next[index].trashedAt = nil; try save(next)
            }
            return books
        }
        let publication = prepared.publication
        let filename = "\(hash).\(ext)"
        let destination = root.appendingPathComponent(filename)
        let alreadyExists = FileManager.default.fileExists(atPath: destination.path)
        if !alreadyExists { try FileManager.default.moveItem(at: temporary, to: destination) }
        let parsedTitle = publication?.title ?? ""
        var book = Book(title: parsedTitle.isEmpty ? source.deletingPathExtension().lastPathComponent : parsedTitle,
                        filename: filename, hash: hash, format: ext)
        book.author = publication?.author
        if let publication {
            try? writePublicationCache(publication, hash: hash)
            if let cover = publication.cover {
                let name = "\(hash).cover"
                if (try? cover.write(to: root.appendingPathComponent(name), options: .atomic)) != nil { book.coverFilename = name }
            }
        }
        do { try save(books + [book]) }
        catch {
            if !alreadyExists { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
        return books
    }
    nonisolated private static func copyAndHash(_ source: URL, to destination: URL, settings: ImportSettings) throws -> String {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var hash = SHA256(), total: Int64 = 0
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            total += Int64(chunk.count)
            try settings.validateFileSize(total) // Also reject a source that grows while copying.
            hash.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        try output.synchronize()
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public func updatePosition(id: UUID, position: Int, resourceID: String? = nil, paragraphIndex: Int? = nil, textOffset: Int = 0) throws -> [Book] {
        try Task.checkCancellation()
        if !isLoaded { _ = try load() }
        var next = books
        if let index = next.firstIndex(where: { $0.id == id }) {
            next[index].position = max(0, position)
            next[index].lastOpened = Date()
            next[index].resourceID = resourceID
            next[index].paragraphIndex = paragraphIndex
            next[index].textOffset = max(0, textOffset)
            try save(next)
        }
        return books
    }
    public func publication(for book: Book) throws -> EPUBPublication {
        let cache = cacheURL(book.hash)
        if let bytes = try? Data(contentsOf: cache),
           let publication = try? PropertyListDecoder().decode(EPUBPublication.self, from: bytes) { return publication }
        let publication = try EPUBPublication.read(url: fileURL(for: book))
        try? writePublicationCache(publication, hash: book.hash)
        return publication
    }
    public func imageData(for book: Book, path: String) throws -> Data {
        if imageArchive?.hash != book.hash {
            imageArchive = (book.hash, try EPUBArchive(data: Data(contentsOf: fileURL(for: book), options: .mappedIfSafe)))
        }
        guard let archive = imageArchive?.archive else { throw EPUBError.invalidArchive }
        return try archive.read(path)
    }
    public func coverData(for book: Book) -> Data? {
        if let filename = book.coverFilename,
           let bytes = try? Data(contentsOf: root.appendingPathComponent(filename)) { return bytes }
        guard book.format == "epub", let publication = try? publication(for: book),
              let path = publication.coverResource else { return nil }
        return try? imageData(for: book, path: path)
    }
    private func cacheURL(_ hash: String) -> URL {
        root.appendingPathComponent("Cache", isDirectory: true)
            .appendingPathComponent("\(hash)-epub-v\(EPUBPublication.parserVersion).plist")
    }
    private func writePublicationCache(_ publication: EPUBPublication, hash: String) throws {
        let url = cacheURL(hash)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(publication).write(to: url, options: .atomic)
    }
    func save(_ next: [Book]) throws {
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        books = next
    }
}

private struct PreparedImport: Sendable {
    let hash: String
    let publication: EPUBPublication?
}
