import SwiftUI
import ReadoraCore

struct MobileAssistant: View {
    @Bindable var library: MobileLibrary
    let excerpt: String
    var currentBookID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""
    @State private var history: [AIChatMessage] = []
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if library.registry.defaultProfile == nil {
                            ContentUnavailableView("先添加 AI 模型", systemImage: "sparkles", description: Text("在书库菜单的设置中配置服务、模型与 API Key。"))
                        } else if answer.isEmpty && !working {
                            Text(excerpt.isEmpty ? "可以问我如何使用，也可以说：创建一个科幻书架、把某本书加入书架、切换夜间主题。" : "可以解释、总结或翻译当前段落。")
                                .foregroundStyle(.secondary).padding(.vertical, 30)
                        } else { Text(answer).textSelection(.enabled) }
                        if let error { Text(error).foregroundStyle(.red) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                VStack(alignment: .leading, spacing: 12) {
                    TextField("输入问题…", text: $question, axis: .vertical).lineLimit(3...6).disabled(working)
                    HStack {
                        if !excerpt.isEmpty {
                            Button("解释") { question = "解释当前引用" }
                            Button("摘要") { question = "概括当前引用" }
                        }
                        Spacer()
                        if working {
                            ProgressView()
                            Button("停止") { task?.cancel(); working = false }
                        } else {
                            Button("发送", systemImage: "arrow.up.circle.fill") { send() }
                                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.registry.defaultProfile == nil)
                        }
                    }
                    Text("发送问题、引用、最近对话及必要书库信息给所选服务；模型需支持工具调用。")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(16).background(.regularMaterial)
            }
            .navigationTitle("AI 助手").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { task?.cancel(); dismiss() } } }
            .onChange(of: question) { _, value in if value.count > 1200 { question = String(value.prefix(1200)) } }
            .onDisappear { task?.cancel() }
        }
    }
    private func send() {
        guard let profile = library.registry.defaultProfile else { return }
        task?.cancel(); working = true; error = nil; answer = ""
        let prompt = question
        task = Task {
            do {
                let key = try await AICredentialStore.shared.key(account: profile.configuration.credentialAccount) ?? ""
                let reply = try await AIAppAgent.run(client: .shared, configuration: profile.configuration, key: key, question: prompt, excerpt: String(excerpt.prefix(6000)), history: history, actions: MobileLibrary.assistantActions, platformContext: MobileLibrary.assistantGuide + "\n当前阅读书籍ID：" + (currentBookID?.uuidString ?? "无，操作书籍必须先查询ID"), perform: { command in
                    var resolved = command
                    if resolved.bookID == nil { resolved.bookID = currentBookID }
                    return try await library.performAssistant(resolved)
                }, progress: { _ in }, answer: { answer = $0 })
                try Task.checkCancellation()
                answer = reply; history = AIConversation.appending(history, question: prompt, answer: reply); question = ""
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { working = false }
        }
    }
}

extension MobileLibrary {
    static let assistantActions: [AIAppAction] = [.state, .listBooks, .searchBooks, .listShelves, .createShelf, .renameShelf, .shelfMembership, .favorite, .finished, .readingPreference, .sortBooks]
    static let assistantGuide = """
    当前平台是iPhone。书库顶部“书架”可创建、重命名、删除和浏览书架；长按书籍选择“加入或移出书架”，一本书可加入多个书架。左上书库菜单可筛选收藏/正在读/已读、排序、打开回收站和设置；右上加号从文件导入EPUB/PDF/TXT。阅读页提供目录、书签、外观和朗读。设置中配置AI模型与API Key。仅可调用提供的手机工具，其他功能给出上述真实操作路径，不声称执行。当前工具不支持打开书籍、翻页、控制朗读、删除或修改模型。先查询state了解能力，整理书籍前用search_books查询准确UUID；list_books/search_books的text可搜索书名作者，最多返回30本，未找到时缩小或更换搜索词。shelf_membership需要book_id、书架id、flag；favorite/finished需要book_id和flag；create_shelf用text，rename_shelf用id和text。reading_preference仅支持theme/font/layout/fontSize/lineSpacing/paragraphSpacing/brightness/animateTransitions。不要将同名书架的创建当成重复书架。
    """
    func performAssistant(_ command: AIAppCommand) async throws -> String {
        try Task.checkCancellation()
        guard Self.assistantActions.contains(command.action) else { throw AIError.invalidResponse }
        func encode<T: Encodable>(_ value: T) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        }
        func book() throws -> Book {
            guard let id = command.bookID, let book = books.first(where: { $0.id == id && $0.trashedAt == nil }) else {
                throw MobileReadingError.missingBook
            }
            return book
        }
        switch command.action {
        case .state:
            return Self.assistantGuide + "\n当前筛选：" + filterTitle + "\n书籍数：\(books.filter { $0.trashedAt == nil }.count)\n外观：" + (try encode(preferences))
        case .listBooks, .searchBooks:
            let matches = LibraryQuery.books(books, filter: .all, query: command.text ?? "", sort: sort)
            let rows = matches.prefix(30).map { ["book_id": $0.id.uuidString, "title": $0.title, "author": $0.author ?? "", "shelf_ids": ($0.collectionIDs ?? []).map(\.uuidString).joined(separator: ",")] }
            return "共\(matches.count)本，返回前30本：" + (try encode(rows))
        case .listShelves: return try encode(shelves)
        case .createShelf:
            guard let title = command.text else { throw AIError.invalidResponse }
            shelves = try await store.addCollection(title: title)
            return try encode(shelves)
        case .renameShelf:
            guard let id = command.id, let title = command.text else { throw AIError.invalidResponse }
            shelves = try await store.renameCollection(id: id, title: title)
            return try encode(shelves)
        case .shelfMembership:
            let selected = try book()
            guard let id = command.id, shelves.contains(where: { $0.id == id }), let included = command.flag else { throw AIError.invalidResponse }
            books = try await store.changeBook(id: selected.id, change: .collection(id, included))
            return "已更新《\(selected.title)》的书架归属。"
        case .favorite, .finished:
            let selected = try book()
            guard let flag = command.flag else { throw AIError.invalidResponse }
            books = try await store.changeBook(id: selected.id, change: command.action == .favorite ? .favorite(flag) : .finished(flag))
            return "已更新《\(selected.title)》的\(command.action == .favorite ? "收藏" : "已读")状态：\(flag)。"
        case .sortBooks:
            guard let sort = LibrarySort(rawValue: command.text ?? "") else { throw AIError.invalidResponse }
            self.sort = sort; return "已按\(sort.title)排序。"
        case .readingPreference:
            var next = preferences
            switch command.target {
            case "theme":
                guard let value = ReaderTheme(rawValue: command.text ?? "") else { throw AIError.invalidResponse }; next.theme = value
            case "font":
                guard let value = ReaderFont(rawValue: command.text ?? "") else { throw AIError.invalidResponse }; next.font = value
            case "layout":
                guard let value = ReadingLayout(rawValue: command.text ?? "") else { throw AIError.invalidResponse }; next.layout = value
            case "animateTransitions":
                guard let value = command.flag else { throw AIError.invalidResponse }; next.animateTransitions = value
            case "fontSize", "lineSpacing", "paragraphSpacing", "brightness":
                guard let value = command.number else { throw AIError.invalidResponse }
                switch command.target {
                case "fontSize": next.fontSize = value
                case "lineSpacing": next.lineSpacing = value
                case "paragraphSpacing": next.paragraphSpacing = value
                default: next.brightness = value
                }
            default: throw AIError.invalidResponse
            }
            try next.validate(); try await store.saveReadingPreferences(next); preferences = next
            return "阅读外观已保存：" + (try encode(next))
        default: throw AIError.invalidResponse
        }
    }
}
