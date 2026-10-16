import Foundation

public struct BookCollection: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public init(id: UUID = UUID(), title: String) { self.id = id; self.title = title }
}
public enum LibraryFilter: Hashable, Sendable {
    case all, reading, favorites, finished, trash, collection(UUID)
}
public enum LibrarySort: String, CaseIterable, Sendable {
    case recent, title, author
    public var title: String { switch self { case .recent: "最近阅读"; case .title: "书名"; case .author: "作者" } }
}
public enum BookChange: Sendable {
    case favorite(Bool), finished(Bool), trash(Bool), collection(UUID, Bool)
}
public enum LibraryQuery {
    public static func books(_ books: [Book], filter: LibraryFilter, query: String, sort: LibrarySort) -> [Book] {
        books.filter { book in
            if filter == .trash { return book.trashedAt != nil && matches(book, query) }
            guard book.trashedAt == nil, matches(book, query) else { return false }
            switch filter {
            case .all: return true
            case .reading: return book.lastOpened != nil && book.isFinished != true
            case .favorites: return book.isFavorite == true
            case .finished: return book.isFinished == true
            case .collection(let id): return book.collectionIDs?.contains(id) == true
            case .trash: return false
            }
        }.sorted { left, right in
            switch sort {
            case .recent:
                if left.lastOpened != right.lastOpened { return (left.lastOpened ?? .distantPast) > (right.lastOpened ?? .distantPast) }
            case .title:
                if left.title != right.title { return left.title.localizedStandardCompare(right.title) == .orderedAscending }
            case .author:
                if left.author != right.author { return (left.author ?? "").localizedStandardCompare(right.author ?? "") == .orderedAscending }
            }
            return left.id.uuidString < right.id.uuidString
        }
    }
    private static func matches(_ book: Book, _ query: String) -> Bool {
        query.isEmpty || book.title.localizedStandardContains(query) || (book.author?.localizedStandardContains(query) ?? false)
    }
}

public struct SpeechHistoryEntry: Codable, Equatable, Sendable {
    public let bookID: UUID
    public let lastSpokenAt: Date
    public init(bookID: UUID, lastSpokenAt: Date = Date()) {
        self.bookID = bookID; self.lastSpokenAt = lastSpokenAt
    }
}
public enum SpeechHistoryQuery {
    public static func books(_ books: [Book], history: [SpeechHistoryEntry]) -> [Book] {
        let available = Dictionary(books.filter { $0.trashedAt == nil }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<UUID>()
        return Array(history.sorted { $0.lastSpokenAt > $1.lastSpokenAt }.compactMap {
            seen.insert($0.bookID).inserted ? available[$0.bookID] : nil
        }.prefix(3))
    }
}

public enum MarkKind: String, Codable, Sendable { case bookmark, highlight }
public enum HighlightColor: String, Codable, CaseIterable, Sendable {
    case gold, mint, rose
    public var title: String { switch self { case .gold: "金黄"; case .mint: "薄荷"; case .rose: "玫瑰" } }
}
public struct PageRectangle: Codable, Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}
public struct ReadingMark: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let bookID: UUID
    public let kind: MarkKind
    public let position: Int
    public let resourceID: String?
    public let paragraphIndex: Int?
    public let utf16Offset: Int
    public let utf16Length: Int
    public let quote: String
    public let color: HighlightColor
    public let rectangles: [PageRectangle]?
    public let createdAt: Date
    public init(id: UUID = UUID(), bookID: UUID, kind: MarkKind, position: Int, resourceID: String? = nil,
                paragraphIndex: Int? = nil, utf16Offset: Int = 0, utf16Length: Int = 0, quote: String,
                color: HighlightColor = .gold, rectangles: [PageRectangle]? = nil) {
        self.id = id; self.bookID = bookID; self.kind = kind; self.position = position
        self.resourceID = resourceID; self.paragraphIndex = paragraphIndex
        self.utf16Offset = utf16Offset; self.utf16Length = utf16Length
        self.quote = quote; self.color = color; self.rectangles = rectangles; self.createdAt = Date()
    }
    public func validate() throws {
        guard position >= 0, utf16Offset >= 0, utf16Length >= 0,
              utf16Offset <= Int.max - utf16Length, paragraphIndex.map({ $0 >= 0 }) ?? true,
              kind != .highlight || utf16Length > 0 || rectangles?.isEmpty == false else { throw ReadingDataError.invalidMark }
        if let rectangles {
            guard rectangles.count <= 1000, rectangles.allSatisfy({
                $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0
            }) else { throw ReadingDataError.invalidMark }
        }
    }
    public func range(in slice: NSRange) -> NSRange? {
        guard utf16Offset >= 0, utf16Length > 0, utf16Offset <= Int.max - utf16Length,
              slice.location >= 0, slice.length >= 0, slice.location <= Int.max - slice.length else { return nil }
        let lower = max(utf16Offset, slice.location), upper = min(utf16Offset + utf16Length, slice.location + slice.length)
        return lower < upper ? NSRange(location: lower - slice.location, length: upper - lower) : nil
    }
}

extension LibraryStore {
    public func collections() throws -> [BookCollection] { try readFeatureFile("collections.json", fallback: []) }
    public func addCollection(title: String) throws -> [BookCollection] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 60 else { throw ReadingDataError.invalidPreferences }
        var collections = try collections()
        if !collections.contains(where: { $0.title.caseInsensitiveCompare(title) == .orderedSame }) {
            collections.append(BookCollection(title: title))
            try writeFeatureFile(collections, name: "collections.json")
        }
        return collections
    }
    public func changeBook(id: UUID, change: BookChange) throws -> [Book] {
        _ = try load()
        var next = books
        guard let index = next.firstIndex(where: { $0.id == id }) else { return books }
        switch change {
        case .favorite(let value): next[index].isFavorite = value
        case .finished(let value): next[index].isFinished = value
        case .trash(let value): next[index].trashedAt = value ? Date() : nil
        case .collection(let id, let included):
            var ids = next[index].collectionIDs ?? []
            if included, !ids.contains(id) { ids.append(id) }
            if !included { ids.removeAll { $0 == id } }
            next[index].collectionIDs = ids
        }
        try save(next)
        return books
    }
    public func updateDocumentInfo(id: UUID, count: Int) throws -> [Book] {
        _ = try load()
        var next = books
        if let index = next.firstIndex(where: { $0.id == id }) {
            next[index].totalUnitCount = max(0, count)
            next[index].lastOpened = Date()
            try save(next)
        }
        return books
    }
    public func readingPreferences() throws -> ReadingPreferences {
        let preferences = try readFeatureFile("reading-preferences.json", fallback: ReadingPreferences())
        try preferences.validate(); return preferences
    }
    public func saveReadingPreferences(_ preferences: ReadingPreferences) throws {
        try preferences.validate(); try writeFeatureFile(preferences, name: "reading-preferences.json")
    }
    public func speechPreferences() throws -> SpeechPreferences {
        let preferences = try readFeatureFile("speech-preferences.json", fallback: SpeechPreferences())
        try preferences.validate(); return preferences
    }
    public func saveSpeechPreferences(_ preferences: SpeechPreferences) throws {
        try preferences.validate(); try writeFeatureFile(preferences, name: "speech-preferences.json")
    }
    public func marks(for bookID: UUID) throws -> [ReadingMark] {
        let all: [ReadingMark] = try readFeatureFile("marks.json", fallback: [])
        return all.filter { $0.bookID == bookID }.sorted { $0.position == $1.position ? $0.utf16Offset < $1.utf16Offset : $0.position < $1.position }
    }
    public func saveMark(_ mark: ReadingMark) throws -> [ReadingMark] {
        try mark.validate()
        var all: [ReadingMark] = try readFeatureFile("marks.json", fallback: [])
        all.removeAll { $0.id == mark.id || ($0.bookID == mark.bookID && $0.kind == mark.kind && $0.position == mark.position && $0.resourceID == mark.resourceID && $0.utf16Offset == mark.utf16Offset && $0.utf16Length == mark.utf16Length && $0.rectangles == mark.rectangles) }
        all.append(mark)
        try writeFeatureFile(all, name: "marks.json")
        return try marks(for: mark.bookID)
    }
    public func removeMark(id: UUID, bookID: UUID) throws -> [ReadingMark] {
        var all: [ReadingMark] = try readFeatureFile("marks.json", fallback: [])
        all.removeAll { $0.id == id && $0.bookID == bookID }
        try writeFeatureFile(all, name: "marks.json")
        return try marks(for: bookID)
    }
    public func speechHistory() throws -> [SpeechHistoryEntry] {
        let name = "speech-history.json"
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            // Preserve the prior recent-reading shelf once on upgrade. An empty
            // history file is an intentional clear and must never be reseeded.
            let previous = try load()
            let recent = LibraryQuery.books(previous, filter: .all, query: "", sort: .recent)
                .filter { $0.lastOpened != nil }.prefix(3)
                .map { SpeechHistoryEntry(bookID: $0.id, lastSpokenAt: $0.lastOpened!) }
            try writeFeatureFile(recent, name: name)
            return recent
        }
        return try readFeatureFile(name, fallback: [SpeechHistoryEntry]())
    }
    public func recordSpeech(bookID: UUID, at date: Date = Date()) throws -> [SpeechHistoryEntry] {
        let history = try speechHistory()
        guard try load().contains(where: { $0.id == bookID && $0.trashedAt == nil }) else { return history }
        var updated = history.filter { $0.bookID != bookID }
        updated.insert(SpeechHistoryEntry(bookID: bookID, lastSpokenAt: date), at: 0)
        updated = Array(updated.prefix(3))
        try writeFeatureFile(updated, name: "speech-history.json")
        return updated
    }
    public func clearSpeechHistory() throws {
        try writeFeatureFile([SpeechHistoryEntry](), name: "speech-history.json")
    }
    public func aiModelRegistry() throws -> AIModelRegistry {
        let name = "ai-models.json"
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            let previous = try aiConfiguration()
            let registry = AIModelRegistry(profiles: previous.model.isEmpty ? [] : [AIModelProfile(configuration: previous)])
            try writeFeatureFile(registry, name: name)
            return registry
        }
        let registry = try readFeatureFile(name, fallback: AIModelRegistry())
        try registry.validate(); return registry
    }
    public func saveAIModelRegistry(_ registry: AIModelRegistry) throws {
        try registry.validate(); try writeFeatureFile(registry, name: "ai-models.json")
    }
    public func aiConfiguration() throws -> AIConfiguration {
        try readFeatureFile("ai-configuration.json", fallback: AIConfiguration())
    }
    public func saveAIConfiguration(_ configuration: AIConfiguration) throws {
        try configuration.validate(requireModel: configuration.enabled)
        try writeFeatureFile(configuration, name: "ai-configuration.json")
    }
    private func readFeatureFile<T: Decodable>(_ name: String, fallback: T) throws -> T {
        let file = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return fallback }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: file))
    }
    private func writeFeatureFile<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: root.appendingPathComponent(name), options: .atomic)
    }
}

extension LibraryStore {
    /// Only the exact IDs displayed in a confirmation can be removed. Books
    /// restored while the confirmation is open cause the operation to fail.
    public func deleteTrashedBooks(ids: Set<UUID>) throws -> [Book] {
        let all = try load()
        let targets = all.filter { ids.contains($0.id) }
        guard !ids.isEmpty else { return all }
        guard targets.count == ids.count, targets.allSatisfy({ $0.trashedAt != nil }) else { throw ReadingDataError.invalidMark }
        let survivors = all.filter { !ids.contains($0.id) }
        let marks: [ReadingMark] = try readFeatureFile("marks.json", fallback: [])
        let history = try speechHistory()
        let manager = FileManager.default, base = root.resolvingSymlinksInPath()
        var files = Set<URL>()
        for book in targets {
            guard book.hash.count == 64, book.hash.allSatisfy({ $0.isHexDigit }),
                  book.filename == book.hash + "." + book.format,
                  book.coverFilename == nil || book.coverFilename == book.hash + ".cover" else { throw ReadingDataError.invalidMark }
            if !survivors.contains(where: { $0.filename == book.filename }) { files.insert(root.appendingPathComponent(book.filename)) }
            if let cover = book.coverFilename, !survivors.contains(where: { $0.coverFilename == cover }) { files.insert(root.appendingPathComponent(cover)) }
            let cache = root.appendingPathComponent("Cache", isDirectory: true)
            if cache.resolvingSymlinksInPath() == base.appendingPathComponent("Cache", isDirectory: true), !survivors.contains(where: { $0.hash == book.hash }) {
                for entry in (try? manager.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] where entry.lastPathComponent.hasPrefix(book.hash + "-epub-v") && entry.pathExtension == "plist" { files.insert(entry) }
            }
        }
        // Move files first so a failed move can be reversed without deleting bytes.
        let staging = root.appendingPathComponent(".deletion-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        var moved: [(URL, URL)] = []
        let metadata = ["library.json", "marks.json", "speech-history.json"]
        var backups: [String: Data] = [:]
        var backupsComplete = false
        do {
            for name in metadata {
                let file = root.appendingPathComponent(name)
                if manager.fileExists(atPath: file.path) { backups[name] = try Data(contentsOf: file) }
            }
            backupsComplete = true
            let plan = files.map { source in
                DeletionJournal.Entry(original: source.path.replacingOccurrences(of: root.path + "/", with: "", options: .anchored), temporary: UUID().uuidString)
            }
            let journal = DeletionJournal(entries: plan, backups: backups)
            try JSONEncoder().encode(journal).write(to: staging.appendingPathComponent("journal.json"), options: .atomic)
            for item in plan {
                let source = root.appendingPathComponent(item.original)
                guard manager.fileExists(atPath: source.path) else { continue }
                let destination = staging.appendingPathComponent(item.temporary)
                try manager.moveItem(at: source, to: destination); moved.append((source, destination))
            }
            try writeFeatureFile(marks.filter { !ids.contains($0.bookID) }, name: "marks.json")
            try writeFeatureFile(history.filter { !ids.contains($0.bookID) }, name: "speech-history.json")
            try save(survivors)
            try Data().write(to: staging.appendingPathComponent("committed"), options: .atomic)
        } catch {
            if !backupsComplete { try? manager.removeItem(at: staging); throw error }
            var rollbackFailed = false
            for (original, temporary) in moved.reversed() {
                do { try manager.moveItem(at: temporary, to: original) } catch { rollbackFailed = true }
            }
            for name in metadata {
                let file = root.appendingPathComponent(name)
                do {
                    if let backup = backups[name] { try backup.write(to: file, options: .atomic) }
                    else if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
                } catch { rollbackFailed = true }
            }
            books = all
            if !rollbackFailed { try? manager.removeItem(at: staging) }
            throw error
        }
        try manager.removeItem(at: staging)
        return survivors
    }
    public func renameCollection(id: UUID, title: String) throws -> [BookCollection] {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = try collections()
        guard !name.isEmpty, name.count <= 60, let index = items.firstIndex(where: { $0.id == id }),
              !items.contains(where: { $0.id != id && $0.title.caseInsensitiveCompare(name) == .orderedSame }) else { throw ReadingDataError.invalidPreferences }
        items[index].title = name; try writeFeatureFile(items, name: "collections.json"); return items
    }
    public func deleteCollection(id: UUID) throws -> [BookCollection] {
        let old = try collections()
        guard old.contains(where: { $0.id == id }) else { return old }
        let original = try load()
        let updated = original.map { book in
            var book = book; book.collectionIDs?.removeAll { $0 == id }; return book
        }
        let remaining = old.filter { $0.id != id }
        try writeFeatureFile(remaining, name: "collections.json")
        do { try save(updated) }
        catch { try? writeFeatureFile(old, name: "collections.json"); throw error }
        return remaining
    }
}


private struct DeletionJournal: Codable {
    struct Entry: Codable { let original: String; let temporary: String }
    let entries: [Entry]
    let backups: [String: Data]
}
extension LibraryStore {
    func recoverPendingDeletions() throws {
        let manager = FileManager.default
        for directory in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) where directory.lastPathComponent.hasPrefix(".deletion-") {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let journalFile = directory.appendingPathComponent("journal.json")
            guard manager.fileExists(atPath: journalFile.path) else {
                if try manager.contentsOfDirectory(atPath: directory.path).isEmpty { try manager.removeItem(at: directory) }
                continue
            }
            if manager.fileExists(atPath: directory.appendingPathComponent("committed").path) { try manager.removeItem(at: directory); continue }
            let journal = try JSONDecoder().decode(DeletionJournal.self, from: Data(contentsOf: journalFile))
            for entry in journal.entries.reversed() {
                let parts = entry.original.split(separator: "/")
                guard UUID(uuidString: entry.temporary) != nil, !entry.original.hasPrefix("/"),
                      !parts.contains(".."), (parts.count == 1 || (parts.count == 2 && parts.first == "Cache")),
                      let filename = parts.last, filename.count > 64, filename.prefix(64).allSatisfy({ $0.isHexDigit }),
                      filename.dropFirst(64).hasPrefix(".") || filename.dropFirst(64).hasPrefix("-epub-v") else { throw ReadingDataError.invalidMark }
                let temporary = directory.appendingPathComponent(entry.temporary), original = root.appendingPathComponent(entry.original)
                if manager.fileExists(atPath: temporary.path) {
                    guard !manager.fileExists(atPath: original.path) else { throw CocoaError(.fileWriteFileExists) }
                    try manager.moveItem(at: temporary, to: original)
                }
            }
            for name in ["library.json", "marks.json", "speech-history.json"] {
                let file = root.appendingPathComponent(name)
                if let backup = journal.backups[name] { try backup.write(to: file, options: .atomic) }
                else if manager.fileExists(atPath: file.path) { try manager.removeItem(at: file) }
            }
            try manager.removeItem(at: directory)
        }
    }
}
