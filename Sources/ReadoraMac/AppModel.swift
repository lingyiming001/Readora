import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import ReadoraCore

@MainActor
@Observable
final class AppModel {
    var books: [Book] = []
    var selected: UUID?
    var paragraphs: [String] = []
    var publication: EPUBPublication? { didSet { rebuildMarkIndex() } }
    var pdf: PDFDocument?
    var position = 0
    var preferences = ReadingPreferences()
    var speechPreferences = SpeechPreferences()
    var speechHistory: [SpeechHistoryEntry] = []
    var aiModels = AIModelRegistry()
    var aiConfiguration: AIConfiguration { aiModels.defaultProfile?.configuration ?? AIConfiguration() }
    var showReaderNavigation = false
    var readerNavigationTab = 0
    var followSpeech = true
    var readerPageIndex = 0
    var readerPageCount = 0
    var pageRequest = ReaderPageRequest()
    var aiSettingsRequest = UUID()
    var pendingAIImport = false
    var manualDeletion: [UUID]?
    let mcp = MCPService()
    var externalSettingsRequest = UUID()
    var showAIAssistant = false
    var aiContext = ""
    var selectedAIText = ""
    var marks: [ReadingMark] = [] { didSet { rebuildMarkIndex() } }
    var resourcePositions: [ResourceParagraphKey: Int] = [:]
    var markPositions: [UUID: Int] = [:]
    var bookmarkIndex: [Int: [ReadingMark]] = [:]
    var highlightIndex: [Int: [ReadingMark]] = [:]
    var collections: [BookCollection] = []
    var libraryFilter: LibraryFilter = .all
    var librarySort: LibrarySort = .recent
    var libraryListMode = false
    var requestedBookID: UUID?
    var jumpRequest = ReaderJump(position: 0, offset: 0)
    var positionOffset = 0
    var markRevision = UUID()
    private var preferencesTask: Task<Void, Never>?
    private var preferencesDirty = false
    var isLoading = false
    var isImporting = false
    var showImporter = false
    var settingsSection = SettingsSection.appearance
    var importSettings = ImportSettings()
    var contentRevision = UUID()
    var error: String?
    var query = ""
    let speech = SpeechPlayer()
    var speechSelection: (index: Int, offset: Int)?
    let store: LibraryStore
    private var openGeneration = 0
    private var didLoad = false
    private var featuresLoaded = false
    private var progressTask: Task<Void, Never>?
    var current: Book? { books.first { $0.id == selected } }
    var filtered: [Book] { LibraryQuery.books(books, filter: libraryFilter, query: query, sort: librarySort) }
    static var testLibrary: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["READORA_TEST_LIBRARY"]
        #else
        nil
        #endif
    }
    init(libraryRoot: URL? = nil) {
        let root = libraryRoot ?? Self.testLibrary.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appendingPathComponent("Readora", isDirectory: true)
        store = LibraryStore(root: root)
    }
    func load() async {
        guard !didLoad else { return }
        do { books = try await store.load(); didLoad = true; await loadImportSettings(); await loadFeatures() }
        catch { self.error = "书库读取失败：\(error.localizedDescription)" }
    }
    func loadImportSettings() async {
        do { importSettings = try await store.importSettings() }
        catch { self.error = "读取导入设置失败：\(error.localizedDescription)" }
    }
    func saveImportSettings(_ settings: ImportSettings) async -> Bool {
        do {
            try await store.saveImportSettings(settings)
            importSettings = settings
            return true
        } catch { self.error = "保存设置失败：\(error.localizedDescription)"; return false }
    }
    func chooseFile() { if !isImporting { showImporter = true } }
    func importFiles(_ urls: [URL]) async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }
        var failures: [String] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                let settings = try await store.importSettings()
                try settings.validateFileSize(size.map(Int64.init) ?? -1)
                if url.pathExtension.lowercased() == "pdf" {
                    guard let doc = PDFDocument(url: url), !doc.isLocked, doc.pageCount > 0 else {
                        failures.append("\(url.lastPathComponent)：PDF 已损坏或需要密码。"); continue
                    }
                }
                books = try await store.importFile(url)
            } catch { failures.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
        }
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
    func open(_ id: UUID?) async {
        openGeneration += 1
        let generation = openGeneration
        await flushProgress()
        guard generation == openGeneration, !Task.isCancelled else { return }
        speech.stop(); speechSelection = nil; selectedAIText = ""
        readerPageCount = 0; readerPageIndex = 0; showReaderNavigation = false
        selected = id; paragraphs = []; pdf = nil; publication = nil; position = 0; positionOffset = 0; marks = []
        guard let book = current, book.trashedAt == nil else { selected = nil; isLoading = false; return }
        isLoading = true
        defer { if generation == openGeneration { isLoading = false } }
        let url = await store.fileURL(for: book)
        do {
            if book.format == "pdf" {
                guard let document = PDFDocument(url: url), !document.isLocked else { throw CocoaError(.fileReadCorruptFile) }
                guard generation == openGeneration, !Task.isCancelled else { return }
                pdf = document
                position = TextContent.clampedPosition(book.position, count: document.pageCount)
            } else if book.format == "epub" {
                let loaded = try await store.publication(for: book)
                guard generation == openGeneration, !Task.isCancelled else { return }
                publication = loaded
                paragraphs = loaded.blocks.map(\.text)
                position = loaded.restoredPosition(resourceID: book.resourceID, paragraphIndex: book.paragraphIndex, fallback: book.position)
            } else {
                let loaded = try await Task.detached {
                    TextContent.paragraphs(try TextContent.decode(Data(contentsOf: url, options: .mappedIfSafe)))
                }.value
                guard generation == openGeneration, !Task.isCancelled else { return }
                paragraphs = loaded
                position = TextContent.clampedPosition(book.position, count: loaded.count)
            }
            positionOffset = max(0, book.textOffset ?? 0)
            let loadedMarks = try await store.marks(for: book.id)
            let updatedBooks = try await store.updateDocumentInfo(id: book.id, count: pdf?.pageCount ?? paragraphs.count)
            guard generation == openGeneration, !Task.isCancelled else { return }
            marks = loadedMarks; books = updatedBooks
            contentRevision = UUID()
        } catch is CancellationError {} catch {
            if generation == openGeneration { self.error = "打开失败：\(error.localizedDescription)" }
        }
    }
    func savePosition(_ value: Int, offset: Int = 0) {
        let count = pdf?.pageCount ?? paragraphs.count
        guard value >= 0, value < count, let id = selected else { return }
        position = value; positionOffset = max(0, offset)
        let block = publication?.blocks[value]
        progressTask?.cancel()
        progressTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                books = try await store.updatePosition(id: id, position: value, resourceID: block?.resourceID, paragraphIndex: block?.paragraphIndex, textOffset: max(0, offset))
            } catch is CancellationError {} catch { self.error = "保存进度失败：\(error.localizedDescription)" }
        }
    }
    func flushProgress() async {
        progressTask?.cancel(); progressTask = nil
        guard let book = current, !isLoading else { return }
        let block = publication?.blocks.indices.contains(position) == true ? publication?.blocks[position] : nil
        do { books = try await store.updatePosition(id: book.id, position: position, resourceID: block?.resourceID, paragraphIndex: block?.paragraphIndex, textOffset: positionOffset) }
        catch is CancellationError {} catch { self.error = "保存进度失败：\(error.localizedDescription)" }
    }
    func coverData(for book: Book) async -> Data? { await store.coverData(for: book) }
    func imageData(for book: Book, path: String) async -> Data? {
        guard publication?.imageResources.contains(path) == true else { return nil }
        return try? await store.imageData(for: book, path: path)
    }
    func toggleSpeech() {
        if speech.isActive { speech.togglePause(); return }
        guard !paragraphs.isEmpty else { error = "此书暂无可朗读的文本。"; return }
        startSpeech(from: speechSelection?.index ?? position, offset: speechSelection?.offset ?? positionOffset)
    }
    func startSpeech(from index: Int, offset: Int = 0) {
        speechSelection = nil
        speech.play(paragraphs, from: index, offset: offset, language: publication?.language, rate: speechPreferences) { [weak self] index, offset in self?.savePosition(index, offset: offset) }
        if speech.isActive, let id = current?.id {
            Task {
                do { speechHistory = try await store.recordSpeech(bookID: id) }
                catch { self.error = "保存朗读记录失败：\(error.localizedDescription)" }
            }
        }
    }

    func selectForSpeech(index: Int, range: NSRange) {
        if paragraphs.indices.contains(index) {
            let source = paragraphs[index] as NSString
            if range.location >= 0, range.location <= source.length, range.length <= source.length - range.location {
                selectedAIText = String(source.substring(with: range).prefix(6000))
            }
        }
        speechSelection = (index, range.location)
        if speech.isActive { startSpeech(from: index, offset: range.location) }
    }

    func loadFeatures() async {
        do {
            collections = try await store.collections()
            speechHistory = try await store.speechHistory()
            aiModels = try await store.aiModelRegistry()
            preferences = try await store.readingPreferences()
            speechPreferences = try await store.speechPreferences()
            speech.configure(speechPreferences)
            featuresLoaded = true
        } catch { self.error = "读取阅读设置失败：\(error.localizedDescription)" }
    }
    func changePreferences(_ preferences: ReadingPreferences) {
        featuresLoaded = true
        self.preferences = preferences
        preferencesDirty = true
        preferencesTask?.cancel()
        preferencesTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                try await store.saveReadingPreferences(preferences)
                if self.preferences == preferences { preferencesDirty = false }
            } catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func saveSpeechPreferences(_ preferences: SpeechPreferences) async -> Bool {
        do {
            try await store.saveSpeechPreferences(preferences)
            speechPreferences = preferences; speech.configure(preferences)
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func flushPreferences() async {
        guard featuresLoaded, preferencesDirty else { return }
        preferencesTask?.cancel()
        do { try await store.saveReadingPreferences(preferences); preferencesDirty = false }
        catch { self.error = error.localizedDescription }
    }
}

struct ReaderJump: Equatable {
    let id = UUID()
    let position: Int
    let offset: Int
}

enum SettingsSection: Hashable { case appearance, importing, reading, speech, ai, mcp }

struct ReaderPageRequest: Equatable {
    var id = UUID()
    var index = 0
}
