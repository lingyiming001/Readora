import SwiftUI
import PDFKit
import ReadoraCore

@MainActor @Observable
final class MobileLibrary {
    let store: LibraryStore
    var books: [Book] = []
    var preferences = ReadingPreferences()
    var registry = AIModelRegistry()
    var query = ""
    var favoritesOnly = false
    var importing = false
    var error: String?
    private var loaded = false
    var visibleBooks: [Book] {
        LibraryQuery.books(books, filter: favoritesOnly ? .favorites : .all, query: query, sort: .recent)
    }
    init() {
        let root = URL.applicationSupportDirectory.appendingPathComponent("Readora", isDirectory: true)
        store = LibraryStore(root: root)
    }
    func load() async {
        guard !loaded else { return }
        do {
            books = try await store.load()
            preferences = try await store.readingPreferences()
            registry = try await store.aiModelRegistry()
            loaded = true
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        do { books = try await store.load() } catch { self.error = error.localizedDescription }
    }
    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let settings = try await store.importSettings()
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                try settings.validateFileSize(size.map(Int64.init) ?? -1)
                if url.pathExtension.lowercased() == "pdf" {
                    guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
                        throw MobileReadingError.invalidPDF
                    }
                }
                books = try await store.importFile(url)
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
    func favorite(_ book: Book) async {
        do { books = try await store.changeBook(id: book.id, change: .favorite(!(book.isFavorite ?? false))) }
        catch { self.error = error.localizedDescription }
    }
    func trash(_ book: Book, restore: Bool = false) async {
        do { books = try await store.changeBook(id: book.id, change: .trash(!restore)) }
        catch { self.error = error.localizedDescription }
    }
    func saveAppearance() async {
        guard loaded else { return }
        do { try await store.saveReadingPreferences(preferences) }
        catch { self.error = error.localizedDescription }
    }
    var background: Color {
        switch preferences.theme {
        case .paper: Color(uiColor: .systemBackground)
        case .parchment: Color(red: 0.95, green: 0.91, blue: 0.81)
        case .sage: Color(red: 0.89, green: 0.94, blue: 0.86)
        case .night: Color(red: 0.09, green: 0.10, blue: 0.10)
        }
    }
    var colorScheme: ColorScheme? { preferences.theme == .night ? .dark : .light }
}

enum MobileReadingError: LocalizedError {
    case invalidPDF, missingBook
    var errorDescription: String? {
        switch self {
        case .invalidPDF: "PDF 已损坏或需要密码，暂时无法打开。"
        case .missingBook: "书籍已移入回收站或不存在。"
        }
    }
}

@MainActor @Observable
final class MobileReader {
    let book: Book
    let store: LibraryStore
    var publication: EPUBPublication?
    var paragraphs: [String] = []
    var pdf: PDFDocument?
    var position: Int? = nil
    var loaded = false
    var error: String?
    var marks: [ReadingMark] = []
    let speech = MobileSpeech()
    private var saveTask: Task<Void, Never>?
    init(book: Book, store: LibraryStore) { self.book = book; self.store = store }
    var count: Int { pdf?.pageCount ?? paragraphs.count }
    var currentText: String {
        let index = position ?? 0
        if let pdf { return String((pdf.page(at: index)?.string ?? "").prefix(6000)) }
        return paragraphs.indices.contains(index) ? String(paragraphs[index].prefix(6000)) : ""
    }
    func load() async {
        guard !loaded else { return }
        do {
            switch book.format {
            case "epub":
                let publication = try await store.publication(for: book)
                try Task.checkCancellation()
                self.publication = publication; paragraphs = publication.blocks.map(\.text)
            case "pdf":
                let url = await store.fileURL(for: book)
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { throw MobileReadingError.invalidPDF }
                pdf = document
            default:
                let url = await store.fileURL(for: book)
                paragraphs = try await Task.detached {
                    try TextContent.paragraphs(TextContent.decode(Data(contentsOf: url, options: .mappedIfSafe)))
                }.value
            }
            try Task.checkCancellation()
            marks = try await store.marks(for: book.id)
            position = TextContent.clampedPosition(book.position, count: count)
            loaded = true
            await saveProgress()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func scheduleSave() {
        guard loaded else { return }
        saveTask?.cancel()
        saveTask = Task {
            do { try await Task.sleep(for: .milliseconds(400)); try Task.checkCancellation(); await saveProgress() }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func saveProgress() async {
        guard loaded, let position else { return }
        do {
            let block = publication?.blocks.indices.contains(position) == true ? publication?.blocks[position] : nil
            _ = try await store.updatePosition(id: book.id, position: position, resourceID: block?.resourceID, paragraphIndex: block?.paragraphIndex)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func finish() {
        saveTask?.cancel(); speech.stop(); speech.onParagraph = nil
    }
    func addBookmark() async {
        do {
            let index = position ?? 0
            let block = publication?.blocks.indices.contains(index) == true ? publication?.blocks[index] : nil
            let mark = ReadingMark(bookID: book.id, kind: .bookmark, position: index, resourceID: block?.resourceID,
                paragraphIndex: block?.paragraphIndex, quote: String(currentText.prefix(120)))
            marks = try await store.saveMark(mark)
        } catch { self.error = error.localizedDescription }
    }
    func removeBookmark(_ mark: ReadingMark) async {
        do { marks = try await store.removeMark(id: mark.id, bookID: book.id) }
        catch { self.error = error.localizedDescription }
    }
}
