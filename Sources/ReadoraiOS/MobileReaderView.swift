import SwiftUI
import PDFKit
import ReadoraCore

struct MobileReaderView: View {
    @Bindable var library: MobileLibrary
    @State private var reader: MobileReader
    @State private var navigation = false
    @State private var appearance = false
    @State private var assistant = false
    @State private var excerpt = ""
    @Environment(\.scenePhase) private var scenePhase
    init(book: Book, library: MobileLibrary) {
        self.library = library
        _reader = State(initialValue: MobileReader(book: book, store: library.store))
    }
    var body: some View {
        Group {
            if !reader.loaded {
                if let error = reader.error { ContentUnavailableView("无法打开书籍", systemImage: "exclamationmark.triangle", description: Text(error)) }
                else { ProgressView("正在打开…") }
            } else if let pdf = reader.pdf {
                MobilePDFView(document: pdf, position: Binding(get: { reader.position ?? 0 }, set: { reader.position = $0 }))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: library.preferences.paragraphSpacing) {
                        ForEach(reader.paragraphs.indices, id: \.self) { index in
                            let block = reader.publication?.blocks[index]
                            VStack(alignment: .leading, spacing: 10) {
                                if let path = block?.imagePath {
                                    MobileIllustration(book: reader.book, path: path, store: library.store)
                                }
                                if !reader.paragraphs[index].isEmpty {
                                    Text(reader.paragraphs[index])
                                        .font(readerFont(heading: block?.headingLevel != nil))
                                        .lineSpacing(library.preferences.lineSpacing)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contextMenu {
                                            Button("询问 AI", systemImage: "sparkles") {
                                                excerpt = String(reader.paragraphs[index].prefix(6000)); assistant = true
                                            }
                                            Button("从这里朗读", systemImage: "speaker.wave.2") {
                                                reader.speech.start(reader.paragraphs, from: index)
                                            }
                                        }
                                }
                            }.id(index)
                        }
                    }.scrollTargetLayout().padding(.horizontal, 24).padding(.vertical, 20)
                }
                .scrollPosition(id: $reader.position, anchor: .top)
                .background(library.background)
            }
        }
        .navigationTitle(reader.book.title).navigationBarTitleDisplayMode(.inline)
        .background(library.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("目录与书签", systemImage: "list.bullet") { navigation = true }
                    Button("添加书签", systemImage: "bookmark") { Task { await reader.addBookmark() } }
                    Button("阅读外观", systemImage: "textformat.size") { appearance = true }
                    Button("询问 AI", systemImage: "sparkles") { excerpt = reader.currentText; assistant = true }
                    if reader.pdf == nil {
                        Button(reader.speech.playing ? "停止朗读" : "开始朗读", systemImage: "speaker.wave.2") {
                            if reader.speech.playing { reader.speech.stop() }
                            else { reader.speech.start(reader.paragraphs, from: reader.position ?? 0) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("阅读菜单").disabled(!reader.loaded)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if reader.loaded {
                VStack(spacing: 8) {
                    if reader.speech.playing {
                        HStack {
                            Label("正在朗读", systemImage: "waveform").font(.caption)
                            Spacer()
                            Button(reader.speech.paused ? "继续" : "暂停") { reader.speech.togglePause() }
                            Button("停止") { reader.speech.stop() }
                        }
                    }
                    Text("\(reader.pdf == nil ? "段落" : "页") \(min((reader.position ?? 0) + 1, reader.count)) / \(reader.count)")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.vertical, 10).background(.regularMaterial)
            }
        }
        .task {
            reader.speech.onParagraph = { index in reader.position = index }
            await reader.load()
            if reader.loaded { _ = try? await library.store.updateDocumentInfo(id: reader.book.id, count: reader.count) }
        }
        .onChange(of: reader.position) { _, _ in reader.scheduleSave() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await reader.saveProgress() } } }
        .onDisappear { reader.finish(); Task { await reader.saveProgress(); await library.refresh() } }
        .sheet(isPresented: $appearance) { MobileSettingsView(library: library) }
        .sheet(isPresented: $assistant) { MobileAssistant(library: library, excerpt: excerpt) }
        .sheet(isPresented: $navigation) {
            NavigationStack {
                List {
                    if let chapters = reader.publication?.chapters, !chapters.isEmpty {
                        Section("目录") {
                            ForEach(chapters) { chapter in
                                Button(chapter.title) { jump(to: chapter.position) }
                            }
                        }
                    }
                    Section("书签") {
                        if reader.marks.filter({ $0.kind == .bookmark }).isEmpty { Text("还没有书签").foregroundStyle(.secondary) }
                        ForEach(reader.marks.filter { $0.kind == .bookmark }) { mark in
                            Button(mark.quote.isEmpty ? "位置 \(mark.position + 1)" : mark.quote) { jump(to: mark.position) }
                                .swipeActions { Button("删除", role: .destructive) { Task { await reader.removeBookmark(mark) } } }
                        }
                    }
                    if reader.count > 1 {
                        Section("跳转位置") {
                            Slider(value: Binding(get: { Double(reader.position ?? 0) }, set: { reader.speech.stop(); reader.position = Int($0) }), in: 0...Double(reader.count - 1), step: 1)
                        }
                    }
                }.navigationTitle("目录与书签").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { navigation = false } } }
            }
        }
        .alert("Readora", isPresented: Binding(get: { reader.loaded && reader.error != nil || reader.speech.error != nil }, set: { if !$0 { reader.error = nil; reader.speech.error = nil } })) {
            Button("好") { reader.error = nil; reader.speech.error = nil }
        } message: { Text(reader.error ?? reader.speech.error ?? "") }
    }
    private func jump(to index: Int) { reader.speech.stop(); reader.position = TextContent.clampedPosition(index, count: reader.count); navigation = false }
    private func readerFont(heading: Bool) -> Font {
        let size = library.preferences.fontSize + (heading ? 4 : 0)
        switch library.preferences.font {
        case .songti: return .custom("Songti SC", size: size).weight(heading ? .semibold : .regular)
        case .pingfang: return .system(size: size, weight: heading ? .semibold : .regular)
        case .serif: return .system(size: size, weight: heading ? .semibold : .regular, design: .serif)
        case .rounded: return .system(size: size, weight: heading ? .semibold : .regular, design: .rounded)
        }
    }
}

struct MobileIllustration: View {
    let book: Book
    let path: String
    let store: LibraryStore
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 500).accessibilityLabel("书内插图") }
            else { Label("插图", systemImage: "photo").foregroundStyle(.secondary) }
        }.task(id: path) {
            if let data = try? await store.imageData(for: book, path: path), !Task.isCancelled { image = await mobileThumbnail(data, maxPixel: 1400) }
        }.onDisappear { image = nil }
    }
}

struct MobilePDFView: UIViewRepresentable {
    let document: PDFDocument
    @Binding var position: Int
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.document = document
        context.coordinator.observe(view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document { view.document = document }
        if let page = document.page(at: position), view.currentPage !== page { view.go(to: page) }
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) { NotificationCenter.default.removeObserver(coordinator) }
    final class Coordinator: NSObject {
        var parent: MobilePDFView
        init(_ parent: MobilePDFView) { self.parent = parent }
        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .PDFViewPageChanged, object: view)
        }
        @objc func changed(_ note: Notification) {
            guard let view = note.object as? PDFView, let page = view.currentPage else { return }
            let index = parent.document.index(for: page)
            guard index != NSNotFound, index != parent.position else { return }
            // Avoid publishing state while SwiftUI is updating the PDF view.
            Task { @MainActor [weak self] in self?.parent.position = index }
        }
    }
}
