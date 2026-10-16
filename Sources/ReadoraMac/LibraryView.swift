import SwiftUI
import ReadoraCore
import ReadoraRendering
import AppKit

struct LibrarySidebar: View {
    @Bindable var model: AppModel
    @State private var newShelf = false
    @State private var shelfName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().scaledToFit().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Readora").font(.system(size: 20, weight: .semibold))
                    Text("让每一页，从容展开").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(22).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    Text("书库").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                    row("全部书籍", icon: "books.vertical", filter: .all, count: model.activeBooks.count)
                    row("正在阅读", icon: "book", filter: .reading, count: model.activeBooks.filter { $0.lastOpened != nil && $0.isFinished != true }.count)
                    row("收藏", icon: "heart", filter: .favorites, count: model.activeBooks.filter { $0.isFavorite == true }.count)
                    row("已读完", icon: "checkmark.circle", filter: .finished, count: model.activeBooks.filter { $0.isFinished == true }.count)
                    Text("我的书架").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 22).padding(.bottom, 4)
                    ForEach(model.collections) { shelf in
                        row(shelf.title, icon: "rectangle.stack", filter: .collection(shelf.id), count: model.activeBooks.filter { $0.collectionIDs?.contains(shelf.id) == true }.count)
                    }
                    Button("新建书架", systemImage: "plus") { shelfName = ""; newShelf = true }
                        .buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 7)
                    Divider().padding(.vertical, 16)
                    row("回收站", icon: "trash", filter: .trash, count: model.books.filter { $0.trashedAt != nil }.count)
                }.padding(16)
            }
            Divider().padding(.horizontal, 16)
            HStack {
                SettingsLink { Label("设置", systemImage: "gearshape") }
                Spacer()
                Text("本地书库").font(.caption2).foregroundStyle(.secondary)
            }.buttonStyle(.plain).padding(20)
        }.background(LibraryPalette.canvas(model.preferences.theme))
        .alert("新建书架", isPresented: $newShelf) {
            TextField("书架名称", text: $shelfName)
            Button("取消", role: .cancel) {}
            Button("创建") { Task { await model.addCollection(shelfName) } }.disabled(shelfName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: { Text("为喜欢的书，留一处专属位置。") }
    }
    private func row(_ title: String, icon: String, filter: LibraryFilter, count: Int) -> some View {
        Button { model.showLibrary(filter) } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }.padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
                .background(model.libraryFilter == filter && model.current == nil ? LibraryPalette.accent(model.preferences.theme).opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel("\(title)，\(count) 本")
    }
}

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var clearingHistory = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("READORA LIBRARY").font(.system(size: 10, weight: .medium)).tracking(2).foregroundStyle(.secondary)
                        Text(model.libraryTitle).font(.system(size: 28, weight: .semibold))
                        Text(model.libraryFilter == .trash ? "书籍可随时还原，原始文件仍保留。" : (model.query.isEmpty ? "\(model.filtered.count) 本藏书" : "找到 \(model.filtered.count) 本书"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("AI 助手", systemImage: "sparkles") { model.presentAI() }.buttonStyle(.bordered)
                    if model.libraryFilter == .trash {
                        Button("清空回收站", systemImage: "trash", role: .destructive) {
                            model.manualDeletion = model.books.filter { $0.trashedAt != nil }.map(\.id)
                        }.disabled(!model.books.contains { $0.trashedAt != nil })
                    }
                    if model.libraryFilter != .trash {
                        Button("导入书籍", systemImage: "plus") { model.chooseFile() }.buttonStyle(.borderedProminent)
                    }
                }
                if model.libraryFilter == .all, !model.recentSpeechBooks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("最近朗读", systemImage: "headphones").font(.headline)
                            Spacer()
                            Button("清除朗读记录") { clearingHistory = true }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14, alignment: .top)], spacing: 12) {
                            ForEach(model.recentSpeechBooks) { recent in recentSpeechCard(recent) }
                        }
                    }
                }
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索书名或作者", text: $model.query).textFieldStyle(.plain)
                    }.padding(10).frame(maxWidth: 300)
                        .background(LibraryPalette.surface(model.preferences.theme), in: RoundedRectangle(cornerRadius: 9))
                    Spacer()
                    Picker("排序", selection: $model.librarySort) {
                        ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.frame(width: 150)
                    Picker("视图", selection: $model.libraryListMode) {
                        Image(systemName: "square.grid.2x2").tag(false)
                        Image(systemName: "list.bullet").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 76)
                }
                if model.filtered.isEmpty {
                    ContentUnavailableView {
                        Label(model.query.isEmpty ? (model.libraryFilter == .trash ? "回收站为空" : "这里还没有书") : "没有找到匹配的书", systemImage: model.libraryFilter == .trash ? "trash" : "books.vertical")
                    } description: {
                        Text(model.query.isEmpty ? (model.libraryFilter == .trash ? "移入回收站的书籍会显示在这里，可随时还原。" : "导入 EPUB、PDF 或 TXT，开始一段新的阅读旅程。") : "试试其他书名或作者，或清除搜索条件。")
                    } actions: {
                        if !model.query.isEmpty { Button("清除搜索") { model.query = "" } }
                    }.frame(maxWidth: .infinity, minHeight: 260)
                } else if model.libraryListMode {
                    LazyVStack(spacing: 10) { ForEach(model.filtered) { book in libraryRow(book) } }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 190), spacing: 28, alignment: .top)], alignment: .leading, spacing: 30) {
                        ForEach(model.filtered) { book in bookCard(book) }
                    }
                }
            }.padding(36)
        }.background(LibraryPalette.canvas(model.preferences.theme))
            .confirmationDialog("清除最近朗读记录？", isPresented: $clearingHistory, titleVisibility: .visible) {
                Button("清除朗读记录", role: .destructive) { Task { await model.clearSpeechHistory() } }
                Button("取消", role: .cancel) {}
            } message: { Text("仅清除最近朗读列表，书籍、阅读进度、书签和高亮都会保留。下次开始朗读时会重新记录。") }
    }
    private func recentSpeechCard(_ book: Book) -> some View {
        Button { model.requestedBookID = book.id } label: {
            HStack(spacing: 12) {
                BookCoverView(book: book, model: model).frame(width: 42, height: 60)
                VStack(alignment: .leading, spacing: 6) {
                    Text(book.title).font(.system(size: 13, weight: .medium)).lineLimit(2, reservesSpace: true)
                    Text(book.author ?? book.format.uppercased()).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    readingProgress(book)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(LibraryPalette.surface(model.preferences.theme), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
            .accessibilityRepresentation {
                Button("最近朗读：\(book.title)") { model.requestedBookID = book.id }
            }
    }
    private func bookCard(_ book: Book) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { if book.trashedAt == nil { model.requestedBookID = book.id } } label: {
                BookCoverView(book: book, model: model).frame(height: 218)
                    .shadow(color: .black.opacity(0.13), radius: 7, x: 0, y: 5)
            }.buttonStyle(.plain).accessibilityLabel("打开 \(book.title)")
            HStack(alignment: .top) {
                Text(book.title).font(.system(size: 14, weight: .semibold)).lineLimit(2, reservesSpace: true)
                Spacer(minLength: 0)
                Menu { BookActions(model: model, book: book) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20).accessibilityLabel("书籍管理")
            }
            Text(book.author?.isEmpty == false ? book.author! : book.format.uppercased()).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack {
                if book.isFavorite == true { Image(systemName: "heart.fill").foregroundStyle(.red.opacity(0.75)) }
                if book.isFinished == true { Label("已读完", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                else { readingProgress(book) }
            }.font(.caption2)
        }.contextMenu { BookActions(model: model, book: book) }
    }
    private func libraryRow(_ book: Book) -> some View {
        HStack(spacing: 16) {
            BookCoverView(book: book, model: model).frame(width: 42, height: 58)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                Text(book.author ?? book.format.uppercased()).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if book.isFavorite == true { Image(systemName: "heart.fill").foregroundStyle(.red.opacity(0.75)) }
            readingProgress(book).frame(width: 100)
            Menu { BookActions(model: model, book: book) } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel("书籍管理")
        }.padding(.horizontal, 18).padding(.vertical, 14)
            .background(LibraryPalette.surface(model.preferences.theme), in: RoundedRectangle(cornerRadius: 11))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if book.trashedAt == nil { model.requestedBookID = book.id } }
            .contextMenu { BookActions(model: model, book: book) }
    }
    @ViewBuilder private func readingProgress(_ book: Book) -> some View {
        if let count = book.totalUnitCount, count > 0 {
            ProgressView(value: min(1, Double(book.position + 1) / Double(count))).tint(LibraryPalette.accent(model.preferences.theme)).accessibilityLabel("阅读进度")
        } else { Text(book.lastOpened == nil ? "未开始" : "正在阅读").font(.caption2).foregroundStyle(.secondary) }
    }
}

struct BookActions: View {
    let model: AppModel
    let book: Book
    var body: some View {
        if book.trashedAt != nil {
            Button("还原书籍", systemImage: "arrow.uturn.backward") { Task { await model.changeBook(book, .trash(false)) } }
            Button("永久删除…", systemImage: "trash", role: .destructive) { model.manualDeletion = [book.id] }
        } else {
            Button("打开阅读", systemImage: "book") { model.requestedBookID = book.id }
            Button(book.isFavorite == true ? "取消收藏" : "加入收藏", systemImage: book.isFavorite == true ? "heart.slash" : "heart") {
                Task { await model.changeBook(book, .favorite(book.isFavorite != true)) }
            }
            Button(book.isFinished == true ? "标记为未读完" : "标记为已读完", systemImage: "checkmark.circle") {
                Task { await model.changeBook(book, .finished(book.isFinished != true)) }
            }
            if !model.collections.isEmpty {
                Menu("添加至书架") {
                    ForEach(model.collections) { shelf in
                        let included = book.collectionIDs?.contains(shelf.id) == true
                        Button((included ? "✓ " : "") + shelf.title) { Task { await model.changeBook(book, .collection(shelf.id, !included)) } }
                    }
                }
            }
            Divider()
            Button("移至回收站", systemImage: "trash", role: .destructive) { Task { await model.changeBook(book, .trash(true)) } }
        }
    }
}


enum LibraryPalette {
    static func accent(_ theme: ReaderTheme) -> Color {
        theme == .night ? Color(red: 0.76, green: 0.66, blue: 0.49) : Color(red: 0.39, green: 0.36, blue: 0.29)
    }
    static func canvas(_ theme: ReaderTheme) -> Color {
        return Color(nsColor: ReaderTypography.background(theme))
    }
    static func surface(_ theme: ReaderTheme) -> Color {
        theme == .night ? Color.white.opacity(0.055) : Color.primary.opacity(0.025)
    }
}
