import Foundation
import ReadoraCore

extension AppModel {
    var libraryTitle: String {
        switch libraryFilter {
        case .all: "我的书库"
        case .reading: "正在阅读"
        case .favorites: "心头好书"
        case .finished: "已读完"
        case .trash: "回收站"
        case .collection(let id): collections.first(where: { $0.id == id })?.title ?? "书架"
        }
    }
    var activeBooks: [Book] { books.filter { $0.trashedAt == nil } }
    var recentSpeechBooks: [Book] { SpeechHistoryQuery.books(books, history: speechHistory) }
    func clearSpeechHistory() async {
        do { try await store.clearSpeechHistory(); speechHistory = [] }
        catch { self.error = "清除朗读记录失败：\(error.localizedDescription)" }
    }
    func showLibrary(_ filter: LibraryFilter = .all) {
        libraryFilter = filter; requestedBookID = nil
    }
    func changeBook(_ book: Book, _ change: BookChange) async {
        do {
            books = try await store.changeBook(id: book.id, change: change)
            if current?.trashedAt != nil { requestedBookID = nil; speech.stop() }
        } catch { self.error = error.localizedDescription }
    }
    func deleteConfirmedTrash(_ ids: Set<UUID>) async throws {
        books = try await store.deleteTrashedBooks(ids: ids)
        speechHistory = try await store.speechHistory()
        if let selected, ids.contains(selected) { showLibrary(.trash); speech.stop() }
    }
    func addCollection(_ title: String) async {
        do { collections = try await store.addCollection(title: title) }
        catch { self.error = "创建书架失败：\(error.localizedDescription)" }
    }
    func jump(to position: Int, offset: Int = 0) {
        speech.stop()
        jumpRequest = ReaderJump(position: position, offset: offset)
        savePosition(position, offset: offset)
    }
    func rebuildMarkIndex() {
        resourcePositions = [:]
        if let publication {
            for (index, block) in publication.blocks.enumerated() {
                resourcePositions[ResourceParagraphKey(resource: block.resourceID, paragraph: block.paragraphIndex)] = index
            }
        }
        markPositions = [:]; bookmarkIndex = [:]; highlightIndex = [:]
        for mark in marks {
            let position: Int
            if let resource = mark.resourceID, let paragraph = mark.paragraphIndex {
                position = resourcePositions[ResourceParagraphKey(resource: resource, paragraph: paragraph)] ?? mark.position
            } else { position = mark.position }
            markPositions[mark.id] = position
            if mark.kind == .bookmark { bookmarkIndex[position, default: []].append(mark) }
            else { highlightIndex[position, default: []].append(mark) }
        }
    }
    func position(for mark: ReadingMark) -> Int { markPositions[mark.id] ?? mark.position }
    func marks(at position: Int, kind: MarkKind) -> [ReadingMark] {
        kind == .bookmark ? bookmarkIndex[position] ?? [] : highlightIndex[position] ?? []
    }
    func toggleBookmark(at position: Int? = nil) async {
        guard let book = current else { return }
        let index = position ?? self.position
        let count = pdf?.pageCount ?? paragraphs.count
        guard index >= 0, index < count else { return }
        if let existing = marks(at: index, kind: .bookmark).first { await deleteMark(existing); return }
        let block = publication?.blocks[index]
        let quote = paragraphs.indices.contains(index) ? String(paragraphs[index].prefix(160)) : "第 \(index + 1) 页"
        let mark = ReadingMark(bookID: book.id, kind: .bookmark, position: index,
                               resourceID: block?.resourceID, paragraphIndex: block?.paragraphIndex, quote: quote)
        await addMark(mark)
    }
    func addHighlight(at position: Int, range: NSRange, color: HighlightColor) async {
        guard let book = current, paragraphs.indices.contains(position) else { return }
        let text = paragraphs[position] as NSString
        guard range.location >= 0, range.length > 0, range.location <= text.length,
              range.length <= text.length - range.location else { return }
        let block = publication?.blocks[position]
        let mark = ReadingMark(bookID: book.id, kind: .highlight, position: position,
                               resourceID: block?.resourceID, paragraphIndex: block?.paragraphIndex,
                               utf16Offset: range.location, utf16Length: range.length,
                               quote: String(text.substring(with: range).prefix(2000)), color: color)
        await addMark(mark)
    }
    func addPDFHighlight(page: Int, rectangles: [PageRectangle], quote: String, color: HighlightColor) async {
        guard let book = current, let pdf, page >= 0, page < pdf.pageCount else { return }
        await addMark(ReadingMark(bookID: book.id, kind: .highlight, position: page,
                                  quote: String(quote.prefix(2000)), color: color, rectangles: rectangles))
    }
    private func addMark(_ mark: ReadingMark) async {
        do {
            let updated = try await store.saveMark(mark)
            if selected == mark.bookID { marks = updated; markRevision = UUID() }
        } catch { self.error = "保存标记失败：\(error.localizedDescription)" }
    }
    func deleteMark(_ mark: ReadingMark) async {
        do {
            let updated = try await store.removeMark(id: mark.id, bookID: mark.bookID)
            if selected == mark.bookID { marks = updated; markRevision = UUID() }
        } catch { self.error = error.localizedDescription }
    }
}

struct ResourceParagraphKey: Hashable {
    let resource: String
    let paragraph: Int
}
