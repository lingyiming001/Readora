import Foundation
import AVFoundation
import ReadoraCore

struct AIAppOperationError: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}

extension AppModel {
    func boundAICommand(_ command: AIAppCommand) -> AIAppCommand {
        var bound = command
        if bound.bookID == nil { bound.bookID = current?.id }
        if bound.action == .emptyTrash { bound.ids = books.filter { $0.trashedAt != nil }.map(\.id) }
        return bound
    }
    func aiCommandSummary(_ command: AIAppCommand) -> String {
        let title = books.first { $0.id == command.bookID }?.title ?? ""
        if command.action == .emptyTrash {
            let ids = command.ids ?? []
            let titles = ids.prefix(8).compactMap { id in books.first { $0.id == id }?.title }.joined(separator: "、")
            return "永久清空回收站：共\(ids.count)本，" + titles + (ids.count > 8 ? "等。" : "。") + "删除应用副本与标记，无法在应用中还原；确认后新移入的书不包括在内。"
        }
        if command.action == .deleteBook { return "永久删除：" + title + "；应用副本与标记将移除，无法在应用中还原。" }
        if command.action == .deleteShelf { return "删除书架：" + (collections.first { $0.id == command.id }?.title ?? "未知书架") + "。保留书籍与阅读进度。" }
        if command.action == .deleteModel { return "移除模型配置：" + (aiModels.profiles.first { $0.id == command.id }?.title ?? "未知模型") + "。共享密钥保留。" }
        if command.action == .clearHistory { return "清除最近朗读记录。书籍、阅读进度和标记保留。" }
        return [command.action.rawValue, title, command.target, command.text, command.number.map { String($0) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    func executeAICommand(_ command: AIAppCommand, confirmed: Bool = false) async throws -> String {
        try Task.checkCancellation()
        guard command.number?.isFinite != false else { throw AIAppOperationError(detail: "数字参数无效。") }
        guard !command.requiresConfirmation || confirmed else { throw AIAppOperationError(detail: "此操作必须由用户在界面确认，尚未执行。") }
        func fail(_ text: String) -> AIAppOperationError { AIAppOperationError(detail: text) }
        func text() throws -> String {
            guard let value = command.text, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail("缺少文字参数。") }
            return value
        }
        func number() throws -> Double {
            guard let value = command.number, value.isFinite else { throw fail("缺少有效数字参数。") }; return value
        }
        func flag() throws -> Bool { guard let value = command.flag else { throw fail("缺少明确的开关状态。") }; return value }
        func book() throws -> Book {
            guard let id = command.bookID ?? current?.id, let book = books.first(where: { $0.id == id }) else { throw fail("请先查询并指定书籍。") }; return book
        }
        func opened() throws {
            guard let current, current.trashedAt == nil, !isLoading, requestedBookID == current.id,
                  command.bookID == nil || command.bookID == current.id else { throw fail("请先打开指定书籍并等待载入完成。") }
        }
        func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
        switch command.action {
        case .listModels:
            return try json(aiModels.profiles.enumerated().map { index, profile in
                ["id": profile.id.uuidString, "name": profile.title, "model": profile.configuration.model, "provider": profile.configuration.provider.title, "enabled": profile.configuration.enabled, "order": index + 1] as [String: Any]
            })
        case .addModel:
            guard let source = aiModels.profiles.first(where: { $0.id == command.id }) else { throw fail("请先指定一个已有模型配置作为连接模板。新供应商请打开AI设置添加。") }
            var configuration = source.configuration; configuration.model = try text(); configuration.enabled = command.flag ?? false
            let profile = AIModelProfile(name: command.target ?? "", configuration: configuration)
            try await updateAIModels { $0.profiles.append(profile) }
            return "已添加模型配置：" + profile.title + "，使用模板供应商与地址；新路由下次请求生效。"
        case .modelEnabled, .moveModel, .deleteModel:
            guard let id = command.id, let index = aiModels.profiles.firstIndex(where: { $0.id == id }) else { throw fail("模型配置不存在。") }
            switch command.action {
            case .modelEnabled:
                let value = try flag(); try await updateAIModels { $0.profiles[index].configuration.enabled = value }
            case .moveModel:
                let value = try number()
                guard value.rounded() == value, value >= 1, value <= Double(aiModels.profiles.count) else { throw fail("模型顺序超出范围。") }
                try await updateAIModels { let profile = $0.profiles.remove(at: index); $0.profiles.insert(profile, at: Int(value) - 1) }
            default: try await updateAIModels { $0.profiles.removeAll { $0.id == id } }
            }
            return "模型配置已更新，路由下次请求生效；本次仍使用原模型。"
        case .renameShelf:
            guard let id = command.id else { throw fail("请指定书架ID。") }
            collections = try await store.renameCollection(id: id, title: text())
        case .state:
            return try json(["book": current?.title ?? "", "book_id": current?.id.uuidString ?? "", "loading": isLoading || requestedBookID != selected, "requested_book_id": requestedBookID?.uuidString ?? "",
                             "paragraph_or_pdf_page": position + 1, "rendered_page": readerPageIndex + 1, "rendered_page_count": readerPageCount,
                             "theme": preferences.theme.rawValue, "layout": preferences.layout.rawValue,
                             "speech_playing": speech.isPlaying, "speech_rate": speechPreferences.rate,
                             "speech_maximum": speechPreferences.maximumRate, "highlight": speechPreferences.highlightSpokenText])
        case .listBooks:
            let found = LibraryQuery.books(books, filter: command.target == "trash" ? .trash : .all, query: command.text ?? "", sort: .recent)
            let page = max(1, min(10000, Int((command.number ?? 1).rounded(.down))))
            return try json(["total": found.count, "page": page, "books": Array(found.dropFirst((page - 1) * 30).prefix(30)).map {
                ["id": $0.id.uuidString, "title": String($0.title.prefix(300)), "author": String(($0.author ?? "").prefix(200)), "favorite": $0.isFavorite == true, "finished": $0.isFinished == true] as [String: Any]
            }])
        case .searchBooks:
            query = command.text ?? ""; showLibrary()
            return "已设置书库搜索；匹配\(LibraryQuery.books(books, filter: .all, query: query, sort: .recent).count)本。最近朗读保持显示。"
        case .openBook:
            let selectedBook = try book()
            guard selectedBook.trashedAt == nil else { throw fail("此书在回收站，请先还原。") }
            requestedBookID = selectedBook.id
            return "已请求打开\(selectedBook.title)。后续操作前用state检查loading是否为false。"
        case .showLibrary:
            let filter: LibraryFilter
            switch command.text ?? "all" {
            case "all": filter = .all
            case "reading": filter = .reading
            case "favorites": filter = .favorites
            case "finished": filter = .finished
            case "trash": filter = .trash
            default:
                guard let id = UUID(uuidString: command.text ?? ""), collections.contains(where: { $0.id == id }) else { throw fail("未知书库分类或书架。") }
                filter = .collection(id)
            }
            query = ""; showLibrary(filter)
        case .sortBooks:
            guard let sort = LibrarySort(rawValue: try text()) else { throw fail("未知排序方式。") }; librarySort = sort
        case .listMode: libraryListMode = try flag()
        case .favorite, .finished, .trash, .restore, .shelfMembership:
            let selectedBook = try book(), change: BookChange
            switch command.action {
            case .favorite: change = .favorite(try flag())
            case .finished: change = .finished(try flag())
            case .trash: change = .trash(true)
            case .restore: change = .trash(false)
            default:
                guard let id = command.id, collections.contains(where: { $0.id == id }) else { throw fail("请指定已有书架ID。") }
                change = .collection(id, try flag())
            }
            books = try await store.changeBook(id: selectedBook.id, change: change)
            if command.action == .trash, current?.id == selectedBook.id { showLibrary(); speech.stop() }
        case .listShelves:
            return try json(collections.map { ["id": $0.id.uuidString, "title": $0.title] })
        case .createShelf: collections = try await store.addCollection(title: text())
        case .readingPreference:
            var updated = preferences
            switch command.target {
            case "theme": guard let value = ReaderTheme(rawValue: try text()) else { throw fail("未知主题。") }; updated.theme = value
            case "font": guard let value = ReaderFont(rawValue: try text()) else { throw fail("未知字体。") }; updated.font = value
            case "layout": guard let value = ReadingLayout(rawValue: try text()) else { throw fail("未知阅读方式。") }; updated.layout = value
            case "fontSize": updated.fontSize = try number()
            case "lineSpacing": updated.lineSpacing = try number()
            case "paragraphSpacing": updated.paragraphSpacing = try number()
            case "contentWidth": updated.contentWidth = try number()
            case "brightness": updated.brightness = try number()
            case "animateTransitions": updated.animateTransitions = try flag()
            default: throw fail("未知阅读设置。")
            }
            try updated.validate(); try await store.saveReadingPreferences(updated); changePreferences(updated)
        case .speechPreference:
            var updated = speechPreferences
            switch command.target {
            case "rate": updated.rate = try number()
            case "maximumRate": updated = updated.capped(to: try number())
            case "voice":
                let identifier = try text()
                guard identifier == "auto" || AVSpeechSynthesisVoice(identifier: identifier) != nil else { throw fail("此音色未安装，请先查询list_voices。") }
                updated.voiceIdentifier = identifier == "auto" ? nil : identifier
            case "highlight": updated.highlightSpokenText = try flag()
            case "follow": followSpeech = try flag(); return "已修改跟随朗读。"
            default: throw fail("未知朗读设置。")
            }
            try updated.validate(); try await store.saveSpeechPreferences(updated)
            speechPreferences = updated; speech.configure(updated)
        case .listVoices:
            return try json(AVSpeechSynthesisVoice.speechVoices().filter { command.text == nil || $0.language.hasPrefix(command.text!) }.prefix(150).map {
                ["id": $0.identifier, "name": $0.name, "language": $0.language]
            })
        case .speak:
            try opened(); guard !paragraphs.isEmpty else { throw fail("当前书籍没有可朗读正文。") }
            startSpeech(from: position, offset: positionOffset)
        case .pause: if speech.isPlaying { speech.togglePause() }
        case .resume:
            guard speech.isActive else { throw fail("当前没有暂停中的朗读，可使用speak开始。") }
            if !speech.isPlaying { speech.togglePause() }
        case .stop: speech.stop()
        case .jump:
            try opened(); let value = try number()
            let count = pdf?.pageCount ?? paragraphs.count
            guard value.rounded() == value, value >= 1, value <= Double(count) else { throw fail("目标段落或PDF页超出范围。") }
            jump(to: Int(value) - 1)
        case .page:
            try opened(); let value = try number()
            let count = pdf?.pageCount ?? readerPageCount
            guard value.rounded() == value, value >= 1, value <= Double(count), pdf != nil || preferences.layout == .pages else { throw fail("分页目标无效，文本请先切换分页模式。") }
            if pdf != nil { jump(to: Int(value) - 1) }
            else { pageRequest = ReaderPageRequest(index: Int(value) - 1) }
            return "已请求翻至第\(Int(value))页。"
        case .navigation:
            try opened()
            switch command.text ?? "chapters" { case "chapters": readerNavigationTab = 0; case "bookmarks": readerNavigationTab = 1; case "highlights": readerNavigationTab = 2; default: throw fail("未知导航面板。") }
            showReaderNavigation = true
        case .bookmark:
            try opened()
            let desired = try flag(), existing = !marks(at: position, kind: .bookmark).isEmpty
            if desired != existing { await toggleBookmark() }
            guard (!marks(at: position, kind: .bookmark).isEmpty) == desired else { throw fail("书签保存未成功。") }
        case .highlight:
            try opened(); guard paragraphs.indices.contains(position) else { throw fail("请在EPUB/TXT正文中添加高亮。") }
            let quote = try text(), range = (paragraphs[position] as NSString).range(of: quote)
            guard range.location != NSNotFound, range.length > 0 else { throw fail("高亮原文必须精确匹配当前段落。") }
            let color = HighlightColor(rawValue: command.target ?? "gold")
            guard let color else { throw fail("高亮颜色可选gold/mint/rose。") }
            await addHighlight(at: position, range: range, color: color)
            guard marks(at: position, kind: .highlight).contains(where: { $0.utf16Offset == range.location && $0.utf16Length == range.length }) else { throw fail("高亮保存未成功。") }
        case .listMarks:
            try opened()
            return try json(marks.prefix(100).map { ["id": $0.id.uuidString, "kind": $0.kind.rawValue, "position": position(for: $0) + 1, "quote": String($0.quote.prefix(160))] as [String: Any] })
        case .removeMark:
            try opened(); guard let mark = marks.first(where: { $0.id == command.id }) else { throw fail("标记不存在。") }
            marks = try await store.removeMark(id: mark.id, bookID: mark.bookID); markRevision = UUID()
        case .deleteBook, .emptyTrash:
            let ids: Set<UUID>
            if command.action == .deleteBook { ids = [try book().id] }
            else { guard let snapshot = command.ids else { throw fail("缺少用户确认时的回收站快照。") }; ids = Set(snapshot) }
            try await deleteConfirmedTrash(ids)
            return "已永久移除本次确认的\(ids.count)本回收站书籍。"
        case .deleteShelf:
            guard let id = command.id, collections.contains(where: { $0.id == id }) else { throw fail("请指定已有书架。") }
            collections = try await store.deleteCollection(id: id); books = try await store.load()
            if libraryFilter == .collection(id) { showLibrary() }
        case .clearHistory: try await store.clearSpeechHistory(); speechHistory = []
        case .importLimit:
            let value = try number()
            guard value.rounded() == value, (1...2048).contains(value) else { throw fail("导入上限需为1–2048整数MB。") }
            let updated = ImportSettings(maxBookSizeMB: Int(value)); try await store.saveImportSettings(updated); importSettings = updated
        case .importBooks:
            showLibrary(); pendingAIImport = true
            return "导入准备就绪。请点击助手的完成按钮，随后系统文件选择器打开，由用户选择文件；尚未导入任何书籍。"
        case .settings:
            switch command.target ?? "ai" {
            case "appearance": settingsSection = .appearance
            case "reading": settingsSection = .reading
            case "speech": settingsSection = .speech
            case "importing": settingsSection = .importing
            case "ai": settingsSection = .ai
            case "mcp": settingsSection = .mcp
            default: throw fail("未知设置面板。")
            }
            aiSettingsRequest = UUID()
        }
        return "操作已执行：\(command.action.rawValue)"
    }
}
