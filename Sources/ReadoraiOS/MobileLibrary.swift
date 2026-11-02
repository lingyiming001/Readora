import SwiftUI
import PDFKit
import ReadoraCore

@MainActor @Observable
final class MobileLibrary {
    let store: LibraryStore
    var books: [Book] = []
    var preferences = ReadingPreferences()
    var registry = AIModelRegistry()
    var mcp = MobileMCPService()
    var externalCommand: AIAppCommand?
    var assistantBusy = false
    private var externalContinuation: CheckedContinuation<Bool, Never>?
    func resolveExternal(_ accepted: Bool) {
        let continuation = externalContinuation; externalContinuation = nil; externalCommand = nil
        continuation?.resume(returning: accepted)
    }
    func startMCP() async {
        await mcp.start { [weak self] command in
            guard let self else { throw CancellationError() }
            return try await self.executeExternal(command)
        }
    }
    private func executeExternal(_ input: AIAppCommand) async throws -> String {
        guard !assistantBusy, externalContinuation == nil else { throw NSError(domain: "Readora", code: 429, userInfo: [NSLocalizedDescriptionKey: "应用内AI正在处理请求，请稍后重试。"] ) }
        var command = input
        if command.bookID == nil { command.bookID = currentReader?.book.id }
        if command.action == .emptyTrash { command.ids = books.filter { $0.trashedAt != nil }.map(\.id) }
        if command.requiresConfirmation {
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(45)); self?.resolveExternal(false) } catch {}
            }
            defer { timeout.cancel() }
            let accepted = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in externalCommand = command; externalContinuation = continuation }
            } onCancel: { Task { @MainActor [weak self] in self?.resolveExternal(false) } }
            guard accepted else { throw AIAppAgentError.userDeclined }
        }
        try Task.checkCancellation()
        return try await performAssistant(command)
    }
    var query = ""
    var navigationPath: [UUID] = []
    var currentReader: MobileReader?
    var requestedPanel: String?
    var recentSpeech: [SpeechHistoryEntry] = []
    var listMode = UserDefaults.standard.object(forKey: "mobileLibraryListMode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(listMode, forKey: "mobileLibraryListMode") }
    }
    var recentSpeechBooks: [Book] {
        recentSpeech.prefix(3).compactMap { item in books.first { $0.id == item.bookID && $0.trashedAt == nil } }
    }
    func recordSpeech(_ id: UUID) async {
        do { recentSpeech = try await store.recordSpeech(bookID: id) }
        catch { self.error = error.localizedDescription }
    }
    var filter: LibraryFilter = .all
    var shelves: [BookCollection] = []
    var sort: LibrarySort = .recent
    var importing = false
    var error: String?
    private var loaded = false
    var visibleBooks: [Book] {
        LibraryQuery.books(books, filter: filter, query: query, sort: sort)
    }
    init(root: URL? = nil) {
        store = LibraryStore(root: root ?? URL.applicationSupportDirectory.appendingPathComponent("Readora", isDirectory: true))
    }
    func load() async {
        guard !loaded else { return }
        do {
            books = try await store.load()
            // One-time migration authorized by the user: prefer short first audio on this phone.
            // Mark only after saving so a failed write can be retried; later manual choices persist.
            let startupMigration = "ReadoraMobile.fastSpeechDefault.v1"
            if !UserDefaults.standard.bool(forKey: startupMigration) {
                var speech = try await store.speechPreferences()
                speech.cacheBeforePlayback = false
                try await store.saveSpeechPreferences(speech)
                UserDefaults.standard.set(true, forKey: startupMigration)
            }
            preferences = try await store.readingPreferences()
            registry = try await store.aiModelRegistry()
            shelves = try await store.collections()
            recentSpeech = try await store.speechHistory()
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
    var filterTitle: String {
        switch filter {
        case .all: "全部书籍"
        case .reading: "正在阅读"
        case .favorites: "收藏"
        case .finished: "已读"
        case .trash: "回收站"
        case .collection(let id): shelves.first { $0.id == id }?.title ?? "书架"
        }
    }
    func saveShelf(title: String, id: UUID? = nil) async {
        do {
            if let id { shelves = try await store.renameCollection(id: id, title: title) }
            else { shelves = try await store.addCollection(title: title) }
        } catch { self.error = error.localizedDescription }
    }
    func deleteShelf(_ shelf: BookCollection) async {
        do {
            shelves = try await store.deleteCollection(id: shelf.id)
            if filter == .collection(shelf.id) { filter = .all }
            books = try await store.load()
        } catch { self.error = error.localizedDescription }
    }
    func membership(_ book: Book, shelf: BookCollection, included: Bool) async {
        do { books = try await store.changeBook(id: book.id, change: .collection(shelf.id, included)) }
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
    var pdfSelection: PDFSelection?
    var position: Int? = nil
    var textOffset = 0
    var loaded = false
    var error: String?
    var marks: [ReadingMark] = []
    var selectionParagraph: Int?
    var selectionRange = NSRange(location: 0, length: 0)
    var pageNumber = 1
    var pageCount = 0
    var pageRequest: Int?
    func addHighlight(color: HighlightColor = .gold, quote: String? = nil, paragraph: Int? = nil) async {
        do {
            if let pdf {
                guard let selection = pdfSelection, pdf.allowsCommenting else { throw ReadingDataError.invalidMark }
                for page in selection.pages {
                    let rectangles = selection.selectionsByLine().filter { $0.pages.contains(page) }.compactMap { line -> PageRectangle? in
                        let rect = line.bounds(for: page)
                        guard !rect.isEmpty, !rect.isNull else { return nil }
                        return PageRectangle(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
                    }
                    if !rectangles.isEmpty {
                        let mark = ReadingMark(bookID: book.id, kind: .highlight, position: pdf.index(for: page), quote: selection.string ?? "", color: color, rectangles: rectangles)
                        marks = try await store.saveMark(mark)
                    }
                }
                return
            }
            let index = paragraph ?? position ?? 0
            guard paragraphs.indices.contains(index) else { throw ReadingDataError.invalidMark }
            let source = paragraphs[index] as NSString
            let range: NSRange
            if let quote, !quote.isEmpty {
                range = source.range(of: quote)
                guard range.location != NSNotFound else { throw ReadingDataError.invalidMark }
            } else if selectionParagraph == index, selectionRange.length > 0, selectionRange.location >= 0,
                      selectionRange.location <= source.length, selectionRange.length <= source.length - selectionRange.location {
                range = selectionRange
            } else {
                guard let value = SpeechTextSegment.range(in: paragraphs[index], from: textOffset, maximumLength: 120) else { throw ReadingDataError.invalidMark }
                range = value
            }
            let block = publication?.blocks.indices.contains(index) == true ? publication?.blocks[index] : nil
            let mark = ReadingMark(bookID: book.id, kind: .highlight, position: index, resourceID: block?.resourceID,
                paragraphIndex: block?.paragraphIndex, utf16Offset: range.location, utf16Length: range.length,
                quote: source.substring(with: range), color: color)
            marks = try await store.saveMark(mark)
        } catch { self.error = error.localizedDescription }
    }
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
            textOffset = book.textOffset ?? 0
            var speechPreferences = try await store.speechPreferences()
            if !UserDefaults.standard.bool(forKey: "mobileSpeechMaximumConfigured") {
                speechPreferences = speechPreferences.capped(to: 2)
            }
            speech.configure(speechPreferences)
            loaded = true
            await saveProgress()
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func selectText(paragraph: Int, range: NSRange) {
        guard paragraphs.indices.contains(paragraph) else { return }
        if let valid = SpeechTextSegment.sourceSelection(range, in: paragraphs[paragraph]) {
            selectionParagraph = paragraph; selectionRange = valid
        } else if selectionParagraph == paragraph { selectionParagraph = nil; selectionRange = NSRange(location: 0, length: 0) }
    }
    func startSpeechFromSelection(paragraph: Int, range: NSRange) {
        guard paragraphs.indices.contains(paragraph),
              let valid = SpeechTextSegment.sourceSelection(range, in: paragraphs[paragraph]) else { return }
        speech.start(paragraphs, from: paragraph, offset: valid.location)
    }
    func startSpeechFromReadingPosition(streaming: Bool = false) {
        if let index = selectionParagraph, paragraphs.indices.contains(index), selectionRange.length > 0,
           selectionRange.location >= 0, selectionRange.location < (paragraphs[index] as NSString).length {
            speech.start(paragraphs, from: index, offset: selectionRange.location, streaming: streaming)
        } else { speech.start(paragraphs, from: position ?? 0, offset: textOffset, streaming: streaming) }
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
            _ = try await store.updatePosition(id: book.id, position: position, resourceID: block?.resourceID, paragraphIndex: block?.paragraphIndex, textOffset: textOffset)
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func finish() {
        saveTask?.cancel(); speech.finish(); speech.onPosition = nil
    }
    func addBookmark() async {
        do {
            let index = position ?? 0
            let block = publication?.blocks.indices.contains(index) == true ? publication?.blocks[index] : nil
            let mark = ReadingMark(bookID: book.id, kind: .bookmark, position: index, resourceID: block?.resourceID,
                paragraphIndex: block?.paragraphIndex, utf16Offset: textOffset, quote: String(currentText.prefix(120)))
            marks = try await store.saveMark(mark)
        } catch { self.error = error.localizedDescription }
    }
    func removeBookmark(_ mark: ReadingMark) async {
        do { marks = try await store.removeMark(id: mark.id, bookID: book.id) }
        catch { self.error = error.localizedDescription }
    }
}
