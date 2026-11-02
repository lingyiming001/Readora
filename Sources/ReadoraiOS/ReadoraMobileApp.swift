import SwiftUI
import UniformTypeIdentifiers
import ReadoraCore
#if DEBUG
import ReadoraKokoroRuntime
#endif

@main
struct ReadoraMobileApp: App {
    @State private var library = MobileLibrary()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.environment["READORA_PANEL_PREVIEW"] == "1" {
                    MobileSpeechPanelPreview()
                } else if ProcessInfo.processInfo.environment["READORA_SPEECH_SMOKE"] == "1" {
                    MobileSpeechSmokeView()
                } else if ProcessInfo.processInfo.environment["READORA_TTS_BENCHMARK"] == "1" {
                    ProgressView("正在实测 2× / 4× 连续朗读，请保持此页面…")
                } else { MobileLibraryView(library: library) }
                #else
                MobileLibraryView(library: library)
                #endif
            }
                .preferredColorScheme(library.colorScheme)
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["READORA_PANEL_PREVIEW"] == "1" { return }
                    if ProcessInfo.processInfo.environment["READORA_TTS_BENCHMARK"] == "1" {
                        await runPhoneSpeechBenchmark(); return
                    }
                    #endif
                    await library.load()
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["READORA_VERIFY_START_POLICY"] == "1" {
                        let saved = try? await library.store.speechPreferences()
                        print("PHONE_START_POLICY cacheBeforePlayback=\(saved?.cacheBeforePlayback.description ?? "unavailable") error=\(library.error ?? "none")")
                        exit(saved?.cacheBeforePlayback == false && library.error == nil ? 0 : 1)
                    }
                    #endif
                    if library.mcp.enabled { await library.startMCP() }
                }
                .onOpenURL { url in Task { await library.importFiles([url]) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { Task { await library.saveAppearance() } }
                    if phase == .background { library.mcp.stop(); library.resolveExternal(false) }
                    if phase == .active && library.mcp.enabled { Task { await library.startMCP() } }
                }
        }
    }
}

struct MobileLibraryView: View {
    @Bindable var library: MobileLibrary
    @State private var importer = false
    @State private var settings = false
    @State private var trash = false
    @State private var assistant = false
    @State private var shelves = false
    @State private var trashCandidate: Book?
    var body: some View {
        NavigationStack(path: $library.navigationPath) {
            Group {
                if library.visibleBooks.isEmpty {
                    ContentUnavailableView {
                        Label(library.query.isEmpty ? library.filterTitle : "没有找到书籍", systemImage: "books.vertical")
                    } description: { Text(library.filter == .all && library.query.isEmpty ? "从“文件”导入 EPUB、PDF 或 TXT，开始阅读。" : "当前筛选下没有书籍。可切换全部书籍，长按书籍加入书架。") }
                    actions: { Button("导入书籍", systemImage: "plus") { importer = true }.buttonStyle(.borderedProminent) }
                } else {
                    List {
                        Section(library.filterTitle) {
                        if !library.listMode {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 18)], spacing: 18) {
                                ForEach(library.visibleBooks) { book in
                                    NavigationLink(value: book.id) {
                                        MobileBookTile(book: book, store: library.store)
                                    }
                                    .contextMenu {
                                        Button(book.isFinished == true ? "标为未读" : "标为已读") {
                                            Task { do { library.books = try await library.store.changeBook(id: book.id, change: .finished(book.isFinished != true)) } catch { library.error = error.localizedDescription } }
                                        }
                                        Button("移入回收站", role: .destructive) { trashCandidate = book }
                                        Button("收藏/取消收藏") { Task { await library.favorite(book) } }
                                        Menu("书架归类") {
                                            ForEach(library.shelves) { shelf in
                                                Button(shelf.title) { Task { await library.membership(book, shelf: shelf, included: book.collectionIDs?.contains(shelf.id) != true) } }
                                            }
                                        }
                                    }
                                }
                            }.padding(.vertical, 8)
                        } else {
                        ForEach(library.visibleBooks) { book in
                        NavigationLink(value: book.id) {
                            MobileBookRow(book: book, store: library.store)
                        }
                        .contextMenu {
                            Button(book.isFinished == true ? "标为未读" : "标为已读") {
                                Task { do { library.books = try await library.store.changeBook(id: book.id, change: .finished(book.isFinished != true)) } catch { library.error = error.localizedDescription } }
                            }
                            Menu("加入或移出书架") {
                                ForEach(library.shelves) { shelf in
                                    let included = book.collectionIDs?.contains(shelf.id) == true
                                    Button(shelf.title, systemImage: included ? "checkmark.circle.fill" : "circle") {
                                        Task { await library.membership(book, shelf: shelf, included: !included) }
                                    }
                                }
                                Button("管理书架") { shelves = true }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button("移入回收站", role: .destructive) { trashCandidate = book }
                        }
                        .swipeActions(edge: .leading) {
                            Button(book.isFavorite == true ? "取消收藏" : "收藏", systemImage: "heart") { Task { await library.favorite(book) } }.tint(.orange)
                        }
                        .listRowBackground(library.background)

                        }
                        }
                        }
                    }.scrollContentBackground(.hidden)
                }
            }
            .modifier(MobileExternalApproval(library: library))
            .background(library.background)
            .navigationTitle(library.filterTitle)
            .searchable(text: $library.query, prompt: "搜索书名或作者")
            .navigationDestination(for: UUID.self) { id in
                if let book = library.books.first(where: { $0.id == id }) {
                    MobileReaderView(book: book, library: library)
                        .onAppear { library.query = "" }
                } else { ContentUnavailableView("书籍不可用", systemImage: "book.closed") }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("书库筛选", selection: $library.filter) {
                            Text("全部书籍").tag(LibraryFilter.all)
                            Text("正在阅读").tag(LibraryFilter.reading)
                            Text("收藏").tag(LibraryFilter.favorites)
                            Text("已读").tag(LibraryFilter.finished)
                            ForEach(library.shelves) { shelf in Text(shelf.title).tag(LibraryFilter.collection(shelf.id)) }
                        }
                        Toggle("列表显示", isOn: $library.listMode)
                        Button("管理书架", systemImage: "books.vertical") { shelves = true }
                        Picker("排序", selection: $library.sort) {
                            ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Button("AI 助手", systemImage: "sparkles") { assistant = true }
                        Button("回收站", systemImage: "trash") { trash = true }
                        Button("设置", systemImage: "gearshape") { settings = true }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("书库菜单")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("书架", systemImage: "books.vertical") { shelves = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if library.importing { ProgressView() }
                    else { Button("导入书籍", systemImage: "plus") { importer = true } }
                }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.pdf, .plainText, UTType(filenameExtension: "epub") ?? .data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): library.error = error.localizedDescription
                }
            }
            .confirmationDialog("将《\(trashCandidate?.title ?? "")》移入回收站？可在回收站还原。", isPresented: Binding(get: { trashCandidate != nil }, set: { if !$0 { trashCandidate = nil } }), titleVisibility: .visible) {
                Button("移入回收站", role: .destructive) { if let book = trashCandidate { Task { await library.trash(book) } }; trashCandidate = nil }
                Button("取消", role: .cancel) { trashCandidate = nil }
            }
            .sheet(isPresented: $shelves) { MobileShelvesView(library: library) }
            .sheet(isPresented: $settings) { MobileSettingsView(library: library) }
            .sheet(isPresented: $trash) { MobileTrashView(library: library) }
            .sheet(isPresented: $assistant, onDismiss: consumeRequest) { MobileAssistant(library: library, excerpt: "") }
            .onChange(of: library.requestedPanel) { _, _ in if !assistant { consumeRequest() } }
            .alert("Readora", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("好") { library.error = nil }
            } message: { Text(library.error ?? "") }
        }
    }
    private func consumeRequest() {
        guard let panel = library.requestedPanel else { return }
        if panel == "settings" || (panel == "speech" && library.currentReader == nil) { settings = true }
        else if panel == "trash" { trash = true }
        else if panel == "import" { importer = true }
        else if panel == "shelves" { shelves = true }
        if (["settings", "import", "shelves", "openBook", "showLibrary", "trash"].contains(panel) || (panel == "speech" && library.currentReader == nil)) { library.requestedPanel = nil }
    }

}

struct MobileBookTile: View {
    let book: Book
    let store: LibraryStore
    @State private var cover: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                if let cover { Image(uiImage: cover).resizable().scaledToFit() }
                else { Image(systemName: book.format == "pdf" ? "doc.richtext" : "book.closed").font(.system(size: 38)).foregroundStyle(.secondary) }
            }.frame(height: 170).clipShape(RoundedRectangle(cornerRadius: 12))
            Text(book.title).font(.subheadline.weight(.medium)).lineLimit(2)
            Text(book.author ?? book.format.uppercased()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.primary)
        .task(id: book.id) { if let data = await store.coverData(for: book) { cover = await mobileThumbnail(data, maxPixel: 440) } }
    }
}

struct MobileBookRow: View {
    let book: Book
    let store: LibraryStore
    @State private var cover: UIImage?
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(.secondary.opacity(0.1))
                if let cover { Image(uiImage: cover).resizable().scaledToFit() }
                else { Image(systemName: book.format == "pdf" ? "doc.richtext" : "book.closed").font(.title2).foregroundStyle(.secondary) }
            }.frame(width: 52, height: 72).clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 6) {
                Text(book.title).font(.headline).lineLimit(2)
                Text(book.author ?? book.format.uppercased()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let total = book.totalUnitCount, total > 0 {
                    ProgressView(value: Double(min(book.position + 1, total)), total: Double(total)).tint(.secondary)
                }
            }
            if book.isFavorite == true { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.orange) }
        }.padding(.vertical, 6)
        .task(id: book.id) { if let data = await store.coverData(for: book) { cover = await mobileThumbnail(data, maxPixel: 440) } }
    }
}

struct MobileTrashView: View {
    @Bindable var library: MobileLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: [UUID]?
    var body: some View {
        NavigationStack {
            List(library.books.filter { $0.trashedAt != nil }) { book in
                HStack { Text(book.title); Spacer(); Button("还原") { Task { await library.trash(book, restore: true) } } }
                    .swipeActions { Button("永久删除", role: .destructive) { deleting = [book.id] } }
            }
            .overlay { if !library.books.contains(where: { $0.trashedAt != nil }) { ContentUnavailableView("回收站为空", systemImage: "trash") } }
            .navigationTitle("回收站").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("清空", role: .destructive) { deleting = library.books.filter { $0.trashedAt != nil }.map(\.id) }.disabled(!library.books.contains { $0.trashedAt != nil }) }
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .confirmationDialog("永久删除以下应用内书籍副本？原始文件保留。\n" + library.books.filter { deleting?.contains($0.id) == true }.map(\.title).joined(separator: "、"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("永久删除", role: .destructive) {
                    let ids = Set(deleting ?? []); deleting = nil
                    Task { do { library.books = try await library.store.deleteTrashedBooks(ids: ids) } catch { library.error = error.localizedDescription } }
                }
                Button("取消", role: .cancel) { deleting = nil }
            }
        }
    }
}

struct MobileShelvesView: View {
    @Bindable var library: MobileLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var editing: BookCollection?
    @State private var deleting: BookCollection?
    var body: some View {
        NavigationStack {
            List {
                Section(editing == nil ? "新建书架" : "重命名书架") {
                    TextField("书架名称", text: $name)
                    Button(editing == nil ? "创建" : "保存") {
                        let title = name; let id = editing?.id
                        Task { await library.saveShelf(title: title, id: id) }
                        name = ""; editing = nil
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if editing != nil { Button("取消重命名") { editing = nil; name = "" } }
                }
                Section("我的书架 · 长按书库中的书籍可归类") {
                    ForEach(library.shelves) { shelf in
                        HStack {
                            Button {
                                library.query = ""; library.filter = .collection(shelf.id); dismiss()
                            } label: {
                                HStack {
                                    Label(shelf.title, systemImage: "books.vertical")
                                    Spacer()
                                    Text("\(LibraryQuery.books(library.books, filter: .collection(shelf.id), query: "", sort: .title).count)").foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Button { editing = shelf; name = shelf.title } label: { Image(systemName: "pencil") }
                                .accessibilityLabel("编辑书架“\(shelf.title)”")
                            Button(role: .destructive) { deleting = shelf } label: { Image(systemName: "trash") }
                                .accessibilityLabel("删除书架“\(shelf.title)”")
                        }.buttonStyle(.borderless)
                        .swipeActions {
                            Button("删除", role: .destructive) { deleting = shelf }
                            Button("重命名") { editing = shelf; name = shelf.title }.tint(.blue)
                        }
                    }
                }
                Button("显示全部书籍") { library.query = ""; library.filter = .all; dismiss() }
            }
            .alert("书架操作失败", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) { Button("好") { library.error = nil } } message: { Text(library.error ?? "") }
            .navigationTitle("书架")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("删除书架“\(deleting?.title ?? "")”？书籍仍保留在书库。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除书架", role: .destructive) {
                    if let shelf = deleting { Task { await library.deleteShelf(shelf) } }
                    deleting = nil
                }
                Button("取消", role: .cancel) { deleting = nil }
            }
        }
    }
}

#if DEBUG
/// Isolated, self-authored text for simulator/device speech regressions. Never uses the reader's real library.
struct MobileSpeechSmokeView: View {
    @State private var library = MobileLibrary(root: URL.temporaryDirectory.appendingPathComponent("ReadoraSpeechSmoke/Library"))
    @State private var book: Book?
    var body: some View {
        NavigationStack {
            if let book { MobileReaderView(book: book, library: library) }
            else { ProgressView("正在准备朗读验证…") }
        }
        .task {
            await library.load()
            let source = URL.temporaryDirectory.appendingPathComponent("ReadoraSpeechSmoke/朗读验证.txt")
            do {
                try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                let paragraph = "翻开一本书，让文字的声音陪伴你的阅读时光。这是一段自制的测试文字，用来检查高亮是否跟随声音，以及跨页时能否准确定位。中英文也可以一起朗读：Welcome to Readora。"
                if library.books.isEmpty {
                    try Array(repeating: paragraph, count: 40).joined(separator: "\n\n").write(to: source, atomically: true, encoding: .utf8)
                    await library.importFiles([source])
                }
                book = library.books.first
            } catch { library.error = error.localizedDescription }
        }
    }
}
#endif

#if DEBUG
@MainActor
private func runPhoneSpeechBenchmark() async {
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = false }
    let root = Bundle.main.bundleURL.appendingPathComponent("Kokoro")
    let text = "今天我们去重庆的银行办理业务，随后回到图书馆，分享自己喜欢的音乐和旅行故事。"
    var best = (threads: 3, seconds: Double.infinity)
    do {
        for threads in (ProcessInfo.processInfo.environment["READORA_TTS_SKIP_TUNING"] == "1" ? [] : [3, 4, 2]) {
            let engine = KokoroEngine(threadCount: threads)
            _ = try await engine.render(text: "你好，欢迎阅读。", speaker: 56, root: root, speed: 2)
            let start = ProcessInfo.processInfo.systemUptime
            let audio = try await engine.render(text: text, speaker: 56, root: root, speed: 2)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let playback4 = Double(audio.samples.count) / Double(audio.sampleRate) / 2
            print("PHONE_THREAD threads=\(threads) seconds=\(elapsed) playback4=\(playback4) rtf4=\(elapsed/playback4)")
            if elapsed < best.seconds { best = (threads, elapsed) }
            await engine.unload()
        }
        if best.seconds.isFinite { UserDefaults.standard.set(best.threads, forKey: "ReadoraKokoroThreads.v1") }
        print("PHONE_THREAD_SELECTED threads=\(UserDefaults.standard.integer(forKey: "ReadoraKokoroThreads.v1"))")
        let paragraphs = [
            "第一天，我们沿着河岸慢慢散步，讨论刚刚读过的一本小说。",
            "第二天，朋友带来一杯热茶，还分享了一段有趣的旅行经历。",
            "第三天，我们来到安静的图书馆，找到有关历史和地理的书籍。",
            "第四天，天气渐渐晴朗，窗外的树叶在微风中轻轻摇动。",
            "第五天，老师介绍了新的学习方法，大家认真记录并提出问题。",
            "第六天，我们穿过热闹的街道，准备去银行办理日常业务。",
            "第七天，行长耐心解释每个步骤，提醒大家保存好相关材料。",
            "第八天，远方的朋友打来电话，询问重庆最近的天气变化。",
            "第九天，我们整理书架，把喜欢的作品放在容易找到的位置。",
            "第十天，晚饭之后听了一首音乐，随后继续阅读剩下的章节。",
            "第十一天，大家围坐在一起，讨论人物性格和故事的发展。",
            "第十二天，我们决定把重要想法写下来，留给未来慢慢回顾。",
            "第十三天，早晨的阳光照进房间，新的一天从阅读开始。",
            "第十四天，朋友推荐了几本好书，内容涉及科学和日常生活。",
            "第十五天，我们在公园交换心得，感受文字带来的安静。",
            "第十六天，这次阅读测试即将结束，谢谢你的耐心等待。"
        ]
        var rates: [Double] = [2, 4]
        if let value = ProcessInfo.processInfo.environment["READORA_TTS_RATE"], let rate = Double(value) { rates = [rate] }
        for rate in rates {
            let speech = MobileSpeech()
            speech.configure(SpeechPreferences(rate: rate, maximumRate: 4, cacheBeforePlayback: ProcessInfo.processInfo.environment["READORA_TTS_PREPARE_ALL"] == "1"), voice: .female054, persistChoice: false)
            let started = ProcessInfo.processInfo.systemUptime
            let sample = ProcessInfo.processInfo.environment["READORA_TTS_QUICK"] == "1" ? Array(paragraphs.prefix(2)) : paragraphs
            speech.start(sample, from: 0)
            if ProcessInfo.processInfo.environment["READORA_TTS_IMMEDIATE"] == "1" {
                guard speech.canPlayImmediately else {
                    print("PHONE_START_ERROR rate=\(rate) playing=\(speech.playing) error=\(speech.error ?? "none")")
                    speech.finish(); continue
                }
                speech.playImmediately()
                if !speech.preferences.cacheBeforePlayback { print("PHONE_PREFERENCE_ERROR") }
            }
            var startup: Double?
            while speech.playing, ProcessInfo.processInfo.systemUptime - started < 240 {
                if startup == nil, speech.audioStarted {
                    startup = ProcessInfo.processInfo.systemUptime - started
                    print("PHONE_FIRST_AUDIO rate=\(rate) seconds=\(startup ?? -1)")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let done = !speech.playing
            print("PHONE_PLAYBACK rate=\(rate) startup=\(startup ?? -1) elapsed=\(ProcessInfo.processInfo.systemUptime-started) underruns=\(speech.underrunCount) completed=\(done) error=\(speech.error ?? "none")")
            speech.finish()
        }
        print("PHONE_BENCHMARK_DONE")
    } catch { print("PHONE_BENCHMARK_ERROR \(error.localizedDescription)") }
    exit(0)
}
#endif
