import SwiftUI
import UniformTypeIdentifiers
import ReadoraCore

@main
struct ReadoraMobileApp: App {
    @State private var library = MobileLibrary()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.environment["READORA_SPEECH_SMOKE"] == "1" {
                    MobileSpeechSmokeView()
                } else { MobileLibraryView(library: library) }
                #else
                MobileLibraryView(library: library)
                #endif
            }
                .preferredColorScheme(library.colorScheme)
                .task { await library.load() }
                .onOpenURL { url in Task { await library.importFiles([url]) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { Task { await library.saveAppearance() } }
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
    var body: some View {
        NavigationStack {
            Group {
                if library.visibleBooks.isEmpty {
                    ContentUnavailableView {
                        Label(library.query.isEmpty ? library.filterTitle : "没有找到书籍", systemImage: "books.vertical")
                    } description: { Text(library.filter == .all && library.query.isEmpty ? "从“文件”导入 EPUB、PDF 或 TXT，开始阅读。" : "当前筛选下没有书籍。可切换全部书籍，长按书籍加入书架。") }
                    actions: { Button("导入书籍", systemImage: "plus") { importer = true }.buttonStyle(.borderedProminent) }
                } else {
                    List(library.visibleBooks) { book in
                        NavigationLink(value: book.id) {
                            MobileBookRow(book: book, store: library.store)
                        }
                        .contextMenu {
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
                        .swipeActions(edge: .trailing) {
                            Button("移入回收站", role: .destructive) { Task { await library.trash(book) } }
                        }
                        .swipeActions(edge: .leading) {
                            Button(book.isFavorite == true ? "取消收藏" : "收藏", systemImage: "heart") { Task { await library.favorite(book) } }.tint(.orange)
                        }
                        .listRowBackground(library.background)
                    }.scrollContentBackground(.hidden)
                }
            }
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
            .sheet(isPresented: $shelves) { MobileShelvesView(library: library) }
            .sheet(isPresented: $settings) { MobileSettingsView(library: library) }
            .sheet(isPresented: $trash) { MobileTrashView(library: library) }
            .sheet(isPresented: $assistant) { MobileAssistant(library: library, excerpt: "") }
            .alert("Readora", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("好") { library.error = nil }
            } message: { Text(library.error ?? "") }
        }
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
    var body: some View {
        NavigationStack {
            List(library.books.filter { $0.trashedAt != nil }) { book in
                HStack { Text(book.title); Spacer(); Button("还原") { Task { await library.trash(book, restore: true) } } }
            }
            .overlay { if !library.books.contains(where: { $0.trashedAt != nil }) { ContentUnavailableView("回收站为空", systemImage: "trash") } }
            .navigationTitle("回收站").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
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
                        Button {
                            library.query = ""; library.filter = .collection(shelf.id); dismiss()
                        } label: {
                            HStack {
                                Label(shelf.title, systemImage: "books.vertical")
                                Spacer()
                                Text("\(LibraryQuery.books(library.books, filter: .collection(shelf.id), query: "", sort: .title).count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { deleting = shelf }
                            Button("重命名") { editing = shelf; name = shelf.title }.tint(.blue)
                        }
                    }
                }
                Button("显示全部书籍") { library.query = ""; library.filter = .all; dismiss() }
            }
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
