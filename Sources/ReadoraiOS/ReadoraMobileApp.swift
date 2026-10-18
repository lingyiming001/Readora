import SwiftUI
import UniformTypeIdentifiers
import ReadoraCore

@main
struct ReadoraMobileApp: App {
    @State private var library = MobileLibrary()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            MobileLibraryView(library: library)
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
    var body: some View {
        NavigationStack {
            Group {
                if library.visibleBooks.isEmpty {
                    ContentUnavailableView {
                        Label(library.query.isEmpty ? "你的随身书库" : "没有找到书籍", systemImage: "books.vertical")
                    } description: { Text("从“文件”导入 EPUB、PDF 或 TXT，开始阅读。") }
                    actions: { Button("导入书籍", systemImage: "plus") { importer = true }.buttonStyle(.borderedProminent) }
                } else {
                    List(library.visibleBooks) { book in
                        NavigationLink(value: book.id) {
                            MobileBookRow(book: book, store: library.store)
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
            .navigationTitle("Readora")
            .searchable(text: $library.query, prompt: "搜索书名或作者")
            .navigationDestination(for: UUID.self) { id in
                if let book = library.books.first(where: { $0.id == id }) {
                    MobileReaderView(book: book, library: library)
                } else { ContentUnavailableView("书籍不可用", systemImage: "book.closed") }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("只看收藏", isOn: $library.favoritesOnly)
                        Button("AI 助手", systemImage: "sparkles") { assistant = true }
                        Button("回收站", systemImage: "trash") { trash = true }
                        Button("设置", systemImage: "gearshape") { settings = true }
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("书库菜单")
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
