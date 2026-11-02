import SwiftUI
import ReadoraCore
import AVFoundation

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
    @State private var voice = VoiceConversation()
    @State private var pendingCommand: AIAppCommand?
    @State private var confirmation: CheckedContinuation<Bool, Never>?
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
                        if let error = error ?? voice.error { Text(error).foregroundStyle(.red) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                VStack(alignment: .leading, spacing: 12) {
                    TextField("输入问题…", text: $question, axis: .vertical).lineLimit(3...6).disabled(working)
                    HStack {
                        if !excerpt.isEmpty {
                            Button("解释") { question = "解释当前引用" }
                            Button("摘要") { question = "概括当前引用" }
                        }
                        Button(voice.listening ? "完成录音" : "语音输入", systemImage: voice.listening ? "stop.circle.fill" : "mic") {
                            if voice.listening { voice.finishRecording() }
                            else {
                                if let speech = library.currentReader?.speech, speech.playing && !speech.paused { speech.togglePause() }
                                Task { await voice.start() }
                            }
                        }.disabled(working || voice.authorizing)
                        Menu {
                            Toggle("朗读AI回复", isOn: $voice.readReplies)
                            Toggle("录音完成后自动发送", isOn: $voice.sendAfterRecording)
                            Picker("识别语言", selection: $voice.locale) { Text("中文").tag("zh-CN"); Text("English").tag("en-US") }
                            if voice.speaking { Button("停止朗读回复") { voice.stopReply() } }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("语音聊天设置")
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
            .modifier(MobileExternalApproval(library: library))
            .onChange(of: working) { _, value in library.assistantBusy = value }
            .navigationTitle("AI 助手").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { task?.cancel(); dismiss() } } }
            .onChange(of: question) { _, value in if value.count > 1200 { question = String(value.prefix(1200)) } }
            .alert("确认应用操作", isPresented: Binding(get: { pendingCommand != nil }, set: { if !$0 { resolveConfirmation(false) } })) {
                Button("取消", role: .cancel) { resolveConfirmation(false) }
                Button("确认执行", role: .destructive) { resolveConfirmation(true) }
            } message: { Text(pendingCommand.map { library.confirmationText($0) } ?? "") }
            .onAppear {
                voice.onTranscript = { text in question = text; if voice.sendAfterRecording && !working { send() } }
            }
            .onChange(of: voice.transcript) { _, text in if voice.listening { question = text } }
            .onDisappear { task?.cancel(); voice.stop(); voice.onTranscript = nil; library.assistantBusy = false; resolveConfirmation(false) }
        }
    }
    private func resolveConfirmation(_ accepted: Bool) {
        let continuation = confirmation; confirmation = nil; pendingCommand = nil
        continuation?.resume(returning: accepted)
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
                    if resolved.action == .emptyTrash { resolved.ids = library.books.filter { $0.trashedAt != nil }.map(\.id) }
                    if resolved.requiresConfirmation {
                        let accepted = await withTaskCancellationHandler {
                            await withCheckedContinuation { continuation in pendingCommand = resolved; confirmation = continuation }
                        } onCancel: { Task { @MainActor in resolveConfirmation(false) } }
                        guard accepted else { throw AIAppAgentError.userDeclined }
                    }
                    try Task.checkCancellation()
                    return try await library.performAssistant(resolved)
                }, progress: { _ in }, answer: { answer = $0 })
                try Task.checkCancellation()
                answer = reply; history = AIConversation.appending(history, question: prompt, answer: reply); question = ""
                if library.requestedPanel != nil { dismiss() }
                else { voice.speakReply(reply, voice: (try? await library.store.speechPreferences())?.voiceIdentifier) }
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { working = false }
        }
    }
}

extension MobileLibrary {
    static let assistantActions = AIAppAction.allCases
    static let assistantGuide = """
    当前平台为iPhone，支持书库/书架/收藏/已读/回收站、阅读导航、目录/书签/高亮、朗读与模型配置。先查询state/list_books/list_shelves/list_models取得真实ID。工具必须实际执行后才报告完成；删除类由应用询问具体确认。open_book打开书，show_library返回书库，settings打开设置，import_books打开系统文件选择器，不能读取任意系统路径。speech_preference支持rate/maximumRate/voice/highlight/follow，voice可用list_voices查询的kokoro:编号；rate默认最大2倍，可配置至8。jump/page使用从1起的段落/PDF页或排版页。highlight用text指定当前段落中的准确原文，target可gold/mint/rose。模型增删启停排序都用真实配置ID，add_model复制已有连接与密钥，仅text改新模型名。不会读取密钥。阅读工具要求目标书籍已打开，不能误操作其他书。navigation的text为chapters/bookmarks/highlights。show_library的text为all/reading/favorites/finished/trash或书架UUID。
    """
    func confirmationText(_ command: AIAppCommand) -> String {
        let title = books.first { $0.id == command.bookID }?.title ?? currentReader?.book.title ?? "未指定书籍"
        switch command.action {
        case .trash: return "将《\(title)》移入回收站？可在回收站还原。"
        case .deleteBook: return "永久删除回收站中的《\(title)》及应用内文件副本？原始导入文件保留。"
        case .emptyTrash: return "永久删除以下回收站书籍及应用内副本：\n" + books.filter { command.ids?.contains($0.id) == true }.map(\.title).joined(separator: "\n")
        case .deleteShelf: return "删除书架“\(shelves.first { $0.id == command.id }?.title ?? command.id?.uuidString ?? "未知")”？书籍保留。"
        case .deleteModel: return "删除模型配置“\(registry.profiles.first { $0.id == command.id }?.title ?? "未知")”？"
        case .removeMark: return "移除《\(title)》中的标记 \(command.id?.uuidString ?? "未指定")？"
        case .clearHistory: return "清除最近朗读记录？书籍和阅读进度保留。"
        default: return "移除《\(title)》当前位置的书签？"
        }
    }
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
        func activeReader() throws -> MobileReader {
            guard let reader = currentReader, reader.loaded, command.bookID == nil || command.bookID == reader.book.id else { throw MobileReadingError.missingBook }
            return reader
        }
        func requiredFlag() throws -> Bool { guard let value = command.flag else { throw AIError.invalidResponse }; return value }
        switch command.action {
        case .openBook:
            let selected = try book(); navigationPath = [selected.id]; requestedPanel = "openBook"
            return "已打开《\(selected.title)》。等待state确认加载完成后再操作阅读。"
        case .showLibrary:
            switch command.text ?? "all" {
            case "all": filter = .all
            case "reading": filter = .reading
            case "favorites": filter = .favorites
            case "finished": filter = .finished
            case "trash": navigationPath = []; requestedPanel = "trash"; return "已打开回收站。"
            default:
                guard let id = UUID(uuidString: command.text ?? ""), shelves.contains(where: { $0.id == id }) else { throw AIError.invalidResponse }
                filter = .collection(id)
            }
            navigationPath = []; requestedPanel = "showLibrary"; return "已返回\(filterTitle)。"
        case .settings: requestedPanel = command.text == "speech" || command.target == "speech" ? "speech" : "settings"; return "已打开设置。"
        case .importBooks: requestedPanel = "import"; return "已打开文件选择器，请在系统界面选择书籍。"
        case .listMode: listMode = try requiredFlag(); return listMode ? "已切换列表" : "已切换网格"
        case .trash, .restore:
            guard let id = command.bookID, books.contains(where: { $0.id == id }) else { throw MobileReadingError.missingBook }
            books = try await store.changeBook(id: id, change: .trash(command.action == .trash)); return "书籍状态已更新。"
        case .deleteBook:
            guard let id = command.bookID else { throw MobileReadingError.missingBook }
            books = try await store.deleteTrashedBooks(ids: [id]); return "已永久删除指定回收站书籍。"
        case .emptyTrash:
            guard let ids = command.ids else { throw AIError.invalidResponse }
            books = try await store.deleteTrashedBooks(ids: Set(ids)); return "已永久删除确认清单中的回收站书籍。"
        case .deleteShelf:
            guard let id = command.id, shelves.contains(where: { $0.id == id }) else { throw AIError.invalidResponse }
            shelves = try await store.deleteCollection(id: id); books = try await store.load()
            if filter == .collection(id) { filter = .all }; return "已删除书架，书籍保留。"
        case .clearHistory:
            try await store.clearSpeechHistory(); recentSpeech = []; return "已清除最近朗读记录。"
        case .importLimit:
            guard let number = command.number, number.rounded() == number, (1...2048).contains(number) else { throw ImportSettingsError.invalidLimit }
            try await store.saveImportSettings(ImportSettings(maxBookSizeMB: Int(number))); return "导入上限已保存。"
        case .listModels:
            return try encode(registry.profiles.map { ["id": $0.id.uuidString, "title": $0.title, "model": $0.configuration.model, "enabled": String($0.configuration.enabled)] })
        case .addModel, .deleteModel, .modelEnabled, .moveModel:
            guard let id = command.id, let index = registry.profiles.firstIndex(where: { $0.id == id }) else { throw AIError.invalidResponse }
            var next = registry
            switch command.action {
            case .addModel:
                guard let model = command.text, !model.isEmpty else { throw AIError.invalidResponse }
                var config = next.profiles[index].configuration; config.model = model
                next.profiles.append(AIModelProfile(name: command.target ?? model, configuration: config))
            case .deleteModel: next.profiles.remove(at: index)
            case .modelEnabled: next.profiles[index].configuration.enabled = try requiredFlag()
            default:
                guard let number = command.number, number.rounded() == number, (1...Double(next.profiles.count)).contains(number) else { throw AIError.invalidResponse }
                let profile = next.profiles.remove(at: index); next.profiles.insert(profile, at: Int(number) - 1)
            }
            try next.validate(); try await store.saveAIModelRegistry(next); registry = next; return "模型配置已更新。"
        case .listVoices:
            let neural = NeuralSpeechVoice.all.map { ["id": $0.id, "title": $0.title] }
            return try encode(neural)
        case .speechPreference:
            var next = try await store.speechPreferences()
            let target = command.target ?? ""
            if target == "follow" {
                UserDefaults.standard.set(try requiredFlag(), forKey: "mobileFollowSpeech"); return "自动跟随已更新。"
            }
            if target == "voice", let value = command.text, let voice = NeuralSpeechVoice.all.first(where: { $0.id == value }) {
                let parts = voice.id.split(separator: ":"); let id = String(parts[1])
                let engine: MobileSpeechEngine = .kokoro
                next.voiceIdentifier = value; try await store.saveSpeechPreferences(next)
                UserDefaults.standard.set(engine.rawValue, forKey: "mobileSpeechEngine")
                UserDefaults.standard.set(Int(id) ?? 56, forKey: "mobileKokoroVoice")
                currentReader?.speech.configure(next, engine: engine, voice: Int(id).flatMap(MobileKokoroVoice.init(rawValue:)))
                return "离线音色已切换：" + voice.title
            }
            switch target {
            case "rate": guard let value = command.number else { throw AIError.invalidResponse }; next.rate = value
            case "maximumRate": guard let value = command.number else { throw AIError.invalidResponse }; next.maximumRate = value; next.rate = min(next.rate, value)
            case "highlight": next.highlightSpokenText = try requiredFlag()
            case "voice":
                guard command.text == "auto" else { throw AIError.invalidResponse }; next.voiceIdentifier = NeuralSpeechVoice.defaultIdentifier
            default: throw AIError.invalidResponse
            }
            try next.validate(); try await store.saveSpeechPreferences(next)
            UserDefaults.standard.set(true, forKey: "mobileSpeechMaximumConfigured")
            currentReader?.speech.configure(next, engine: target == "voice" ? .kokoro : nil)
            return "朗读设置已保存。"
        case .speak, .pause, .resume, .stop:
            let reader = try activeReader()
            guard reader.pdf == nil else { throw AIError.invalidResponse }
            switch command.action {
            case .speak: reader.speech.start(reader.paragraphs, from: reader.position ?? 0, offset: reader.textOffset); await recordSpeech(reader.book.id)
            case .pause: if reader.speech.playing && !reader.speech.paused { reader.speech.togglePause() }
            case .resume: if reader.speech.paused { reader.speech.togglePause() }
            default: reader.speech.stop()
            }
            return "朗读状态已更新。"
        case .jump, .page:
            let reader = try activeReader()
            guard let number = command.number, number.rounded() == number, number >= 1,
                  number <= Double(command.action == .page && reader.pdf == nil ? reader.pageCount : reader.count) else { throw AIError.invalidResponse }
            reader.speech.stop()
            if command.action == .page && reader.pdf == nil { reader.pageRequest = Int(number) - 1 }
            else { reader.textOffset = 0; reader.position = Int(number) - 1 }
            return "阅读位置已更新。"
        case .navigation:
            _ = try activeReader(); requestedPanel = "navigation"; return "已打开目录与标记。"
        case .listMarks:
            let id = command.bookID ?? currentReader?.book.id
            guard let id else { throw MobileReadingError.missingBook }
            return try encode(try await store.marks(for: id))
        case .bookmark:
            let reader = try activeReader()
            if command.flag == false {
                for mark in reader.marks where mark.kind == .bookmark && mark.position == reader.position { reader.marks = try await store.removeMark(id: mark.id, bookID: reader.book.id) }
            } else { await reader.addBookmark() }
            if let error = reader.error { throw NSError(domain: "Readora", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            return "书签已更新。"
        case .highlight:
            let reader = try activeReader()
            guard let text = command.text, !text.isEmpty else { throw ReadingDataError.invalidMark }
            await reader.addHighlight(color: HighlightColor(rawValue: command.target ?? "gold") ?? .gold, quote: text)
            if let error = reader.error { throw NSError(domain: "Readora", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            return "高亮已保存。"
        case .removeMark:
            let reader = try activeReader(); guard let id = command.id else { throw ReadingDataError.invalidMark }
            reader.marks = try await store.removeMark(id: id, bookID: reader.book.id); return "标记已移除。"
        case .state:
            return Self.assistantGuide + "\n当前书籍：\(currentReader?.book.title ?? "无")；加载完成：\(currentReader?.loaded ?? false)；段落/PDF页：\((currentReader?.position ?? 0) + 1)；排版页：\(currentReader?.pageNumber ?? 0)/\(currentReader?.pageCount ?? 0)\n当前筛选：" + filterTitle + "\n书籍数：\(books.filter { $0.trashedAt == nil }.count)\n外观：" + (try encode(preferences))
        case .listBooks, .searchBooks:
            let matches = LibraryQuery.books(books, filter: command.target == "trash" ? .trash : .all, query: command.text ?? "", sort: sort)
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
            case "fontSize", "lineSpacing", "paragraphSpacing", "brightness", "contentWidth":
                guard let value = command.number else { throw AIError.invalidResponse }
                switch command.target {
                case "fontSize": next.fontSize = value
                case "lineSpacing": next.lineSpacing = value
                case "paragraphSpacing": next.paragraphSpacing = value
                case "contentWidth": next.contentWidth = value
                default: next.brightness = value
                }
            default: throw AIError.invalidResponse
            }
            try next.validate(); try await store.saveReadingPreferences(next); preferences = next
            return "阅读外观已保存：" + (try encode(next))
        }
    }
}
