import SwiftUI
import ReadoraCore
import ReadoraRendering

struct ReaderView: View {
    @Bindable var model: AppModel
    let book: Book
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visibleParagraph: Int?
    @State private var restored = false
    @State private var appearance = false
    @State private var pages: [ReaderPage] = []
    @State private var pageIndex = 0
    @State private var paginating = false
    @State private var pageDirection = 1
    @State private var dragOffset: CGFloat = 0
    @State private var speechPanel = false
    private var background: Color { Color(nsColor: ReaderTypography.background(model.preferences.theme)) }
    private var foreground: Color { Color(nsColor: ReaderTypography.textColor(model.preferences.theme)) }
    private var animation: Animation? { reduceMotion || !model.preferences.animateTransitions ? nil : .easeInOut(duration: 0.2) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                Group {
                    if model.isLoading { ProgressView("正在打开书籍…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if let document = model.pdf {
                        PDFReader(document: document, position: model.position, jumpID: model.jumpRequest.id,
                                  layout: model.preferences.layout, marks: model.marks, markRevision: model.markRevision,
                                  background: ReaderTypography.background(model.preferences.theme),
                                  onPageChange: { model.savePosition($0) },
                                  onHighlight: { page, rectangles, quote, color in Task { await model.addPDFHighlight(page: page, rectangles: rectangles, quote: quote, color: color) } })
                    } else if model.paragraphs.isEmpty {
                        ContentUnavailableView("没有可显示的正文", systemImage: "doc.text.magnifyingglass", description: Text("请返回书库重试，或检查文件内容。"))
                    } else if model.preferences.layout == .pages { pagedReader }
                    else { textReader }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay { Color.black.opacity((1 - model.preferences.brightness) * 0.65).allowsHitTesting(false).accessibilityHidden(true) }
            }
            playbackBar
        }.background(background).foregroundStyle(foreground)
            .environment(\.colorScheme, model.preferences.theme == .night ? .dark : .light)
            .onChange(of: model.pageRequest) { _, request in turnPage(to: request.index) }
            .onChange(of: model.jumpRequest) { _, request in jump(to: request.position, offset: request.offset) }
            .onChange(of: model.speech.failure) { _, failure in if let failure { model.error = failure } }
            .onChange(of: model.preferences.layout) { _, _ in restored = false }
    }
    private var toolbar: some View {
        ZStack {
            Text(book.title).font(.system(size: 14, weight: .semibold))
                .lineLimit(1).padding(.horizontal, 250)
            HStack {
                HStack(spacing: 20) {
                    Button { model.showLibrary() } label: { Image(systemName: "books.vertical") }
                        .help("返回书库").accessibilityLabel("返回书库")
                    Button { model.showReaderNavigation.toggle() } label: { Image(systemName: "list.bullet") }
                        .help("目录、书签与高亮").accessibilityLabel("目录、书签与高亮")
                        .popover(isPresented: $model.showReaderNavigation, arrowEdge: .bottom) {
                            ReaderNavigationPanel(model: model).frame(height: 470)
                        }
                    Button { Task { await model.toggleBookmark() } } label: {
                        Image(systemName: model.marks(at: model.position, kind: .bookmark).isEmpty ? "bookmark" : "bookmark.fill")
                    }.help("切换当前位置书签").accessibilityLabel("切换当前位置书签")
                }.padding(.horizontal, 20).padding(.vertical, 13).background(background, in: Capsule())
                    .shadow(color: .black.opacity(0.055), radius: 20, y: 8)
                Spacer()
                HStack(spacing: 20) {
                    Button { model.presentAI() } label: { Image(systemName: "sparkles") }
                        .help("AI 阅读助手").accessibilityLabel("AI 阅读助手")
                    Button { appearance.toggle() } label: { Image(systemName: "textformat.size") }
                        .help("主题、字体与亮度").accessibilityLabel("阅读外观")
                        .popover(isPresented: $appearance, arrowEdge: .bottom) { ReaderAppearancePanel(model: model) }
                    Button { speechPanel.toggle() } label: { Image(systemName: "speaker.wave.2") }
                        .help("朗读控制").accessibilityLabel("朗读控制")
                        .popover(isPresented: $speechPanel, arrowEdge: .bottom) {
                            VStack(spacing: 18) {
                                Button(model.speech.isPlaying ? "暂停朗读" : "开始或继续朗读", systemImage: model.speech.isPlaying ? "pause.fill" : "play.fill") { model.toggleSpeech() }
                                    .disabled(book.format == "pdf" || model.paragraphs.isEmpty)
                                if model.speech.isActive {
                                    Button("停止朗读", systemImage: "stop.fill") { model.speech.stop() }
                                    Toggle("跟随朗读位置", isOn: $model.followSpeech)
                                }
                                Toggle("高亮朗读位置", isOn: Binding(get: { model.speechPreferences.highlightSpokenText }, set: { value in
                                    var preferences = model.speechPreferences; preferences.highlightSpokenText = value
                                    Task { _ = await model.saveSpeechPreferences(preferences) }
                                }))
                                Button("音色、速度与上限…") { model.settingsSection = .speech; openSettings() }
                            }.padding(24).frame(width: 240)
                        }
                }.padding(.horizontal, 20).padding(.vertical, 13).background(background, in: Capsule())
                    .shadow(color: .black.opacity(0.055), radius: 20, y: 8)
            }
        }.font(.system(size: 19)).buttonStyle(.plain)
            .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 18)
    }
    private var playbackBar: some View {
        HStack {
            Spacer()
            if book.format == "pdf" {
                pageControls(current: model.position, count: model.pdf?.pageCount ?? 0) { model.jump(to: $0) }
            } else if model.preferences.layout == .pages {
                pageControls(current: pageIndex, count: pages.count) { turnPage(to: $0) }
            } else {
                Text("\(model.position + 1) / \(model.paragraphs.count)").font(.caption).monospacedDigit()
            }
            Spacer()
        }.foregroundStyle(foreground.opacity(0.5)).padding(.top, 10).padding(.bottom, 20)
    }
    private func pageControls(current: Int, count: Int, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 14) {
            Button { action(current - 1) } label: { Image(systemName: "chevron.left") }.disabled(current <= 0 || paginating).help("上一页")
            Text(count > 0 ? "\(current + 1) / \(count)" : "排版中…").font(.caption).monospacedDigit()
            Button { action(current + 1) } label: { Image(systemName: "chevron.right") }.disabled(current + 1 >= count || paginating).help("下一页")
        }.buttonStyle(.plain)
    }
    private var textReader: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: model.preferences.paragraphSpacing) {
                ForEach(model.paragraphs.indices, id: \.self) { index in
                    paragraph(index)
                        .padding(.horizontal, 4)
                        .background(model.speechPreferences.highlightSpokenText && model.speech.isActive && model.speech.index == index ? foreground.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .id(index)
                }
            }.scrollTargetLayout()
                .frame(maxWidth: model.preferences.contentWidth).padding(.horizontal, 40).padding(.vertical, 40).frame(maxWidth: .infinity)
        }.scrollPosition(id: $visibleParagraph, anchor: .top)
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in if model.speech.isActive { model.followSpeech = false } })
            .task(id: model.contentRevision) {
                restored = false; visibleParagraph = model.position; await Task.yield(); restored = true
            }
            .onChange(of: visibleParagraph) { _, index in
                if restored, !model.speech.isActive, let index { model.savePosition(index) }
            }
            .onChange(of: model.speech.index) { _, index in
                if model.speech.isActive, model.followSpeech, model.paragraphs.indices.contains(index) {
                    withAnimation(animation) { visibleParagraph = index }
                }
            }
    }
    private var pagedReader: some View {
        GeometryReader { geometry in
            let width = max(140, min(model.preferences.contentWidth, geometry.size.width - 144))
            let height = max(140, geometry.size.height - 32)
            let key = PaginationKey(revision: model.contentRevision, width: Int(width), height: Int(height), preferences: model.preferences)
            ZStack {
                if pages.indices.contains(pageIndex) {
                    let page = pages[pageIndex]
                    VStack(alignment: .leading, spacing: model.preferences.paragraphSpacing) {
                        if let index = page.imageIndex { paragraph(index).frame(maxHeight: height) }
                        else {
                            ForEach(page.slices.indices, id: \.self) { i in
                                let slice = page.slices[i]
                                paragraph(slice.paragraph, range: slice.range).frame(height: slice.height, alignment: .top)
                            }
                        }
                        Spacer(minLength: 0)
                    }.frame(width: width, height: height, alignment: .topLeading)
                        .frame(width: geometry.size.width)
                        .offset(x: dragOffset)
                        .id(pageIndex)
                        .transition(.asymmetric(
                            insertion: .offset(x: pageDirection > 0 ? geometry.size.width : -geometry.size.width),
                            removal: .offset(x: pageDirection > 0 ? -geometry.size.width : geometry.size.width)))
                } else { ProgressView("正在为你排版…") }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .background(PageSwipeSurface(enabled: !paginating && !pages.isEmpty,
                    onChange: { offset in dragOffset = offset * ((offset > 0 && pageIndex == 0) || (offset < 0 && pageIndex + 1 == pages.count) ? 0.18 : 1) },
                    onEnd: { offset in
                        let destination = pageIndex + (offset < 0 ? 1 : -1)
                        withAnimation(animation) { dragOffset = 0 }
                        if abs(offset) >= 55 { turnPage(to: destination) }
                    }))
                 .task(id: key) {
                    do { try await Task.sleep(for: .milliseconds(100)); await paginate(width: width, height: height) }
                    catch is CancellationError {} catch { model.error = error.localizedDescription }
                }
                .onChange(of: model.speech.index) { _, index in
                    if model.speech.isActive, model.followSpeech { moveToPage(containing: index, offset: 0) }
                }
                .focusable()
                .onKeyPress(.leftArrow) { turnPage(to: pageIndex - 1); return .handled }
                .onKeyPress(.rightArrow) { turnPage(to: pageIndex + 1); return .handled }
        }
    }
    @ViewBuilder private func paragraph(_ index: Int, range: NSRange? = nil) -> some View {
        if model.paragraphs.indices.contains(index) {
            let block = model.publication?.blocks[index]
            if let path = block?.imagePath {
                EPUBIllustration(loadData: { await model.imageData(for: book, path: path) }, alt: model.paragraphs[index])
            } else {
                let full = model.paragraphs[index] as NSString
                let source = range ?? NSRange(location: 0, length: full.length)
                if source.location >= 0, source.location <= full.length, source.length <= full.length - source.location {
                    SelectableParagraph(text: full.substring(with: source), sourceOffset: source.location,
                                        preferences: model.preferences, heading: block?.headingLevel != nil,
                                        highlights: model.marks(at: index, kind: .highlight),
                                        onHighlight: { range, color in Task { await model.addHighlight(at: index, range: range, color: color) } },
                                        onBookmark: { Task { await model.toggleBookmark(at: index) } },
                                        spokenRange: model.speechPreferences.highlightSpokenText && model.speech.isActive && model.speech.index == index ? model.speech.spokenRange : nil,
                                        onSelect: { model.selectForSpeech(index: index, range: $0) },
                                        onRead: { model.startSpeech(from: index, offset: $0.location) },
                                        onAI: { model.presentAI(index: index, range: $0) })
                }
            }
        }
    }
    private func jump(to position: Int, offset: Int) {
        guard book.format != "pdf" else { return }
        if model.preferences.layout == .pages { moveToPage(containing: position, offset: offset) }
        else { withAnimation(animation) { visibleParagraph = position } }
    }
    private func moveToPage(containing position: Int, offset: Int) {
        if let index = pages.firstIndex(where: { $0.contains(position: position, offset: offset) }) { turnPage(to: index, stopSpeech: false) }
    }
    private func turnPage(to index: Int, stopSpeech: Bool = true) {
        guard pages.indices.contains(index), index != pageIndex, !paginating else { return }
        if stopSpeech { model.speech.stop() }
        pageDirection = index >= pageIndex ? 1 : -1
        withAnimation(animation) { pageIndex = index }
        model.readerPageIndex = index
        model.savePosition(pages[index].position, offset: pages[index].textOffset)
    }
    private func paginate(width: Double, height: Double) async {
        paginating = true
        let position = model.position, offset = model.positionOffset
        let paragraphs = model.paragraphs, preferences = model.preferences
        let headings = Set(model.publication?.blocks.indices.filter { model.publication?.blocks[$0].headingLevel != nil } ?? [])
        let images = Set(model.publication?.blocks.indices.filter { model.publication?.blocks[$0].imagePath != nil } ?? [])
        let task = Task.detached(priority: .userInitiated) {
            try TextPaginator.paginate(paragraphs, headings: headings, images: images, preferences: preferences, width: width, height: height)
        }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            pages = result
            pageIndex = result.firstIndex(where: { $0.contains(position: position, offset: offset) }) ?? 0
            model.readerPageIndex = pageIndex; model.readerPageCount = result.count
            paginating = false
        } catch is CancellationError {} catch { paginating = false; model.error = "分页失败：\(error.localizedDescription)" }
    }
}

private struct PaginationKey: Hashable {
    let revision: UUID
    let width: Int, height: Int
    let font: ReaderFont
    let fontSize: Double, lineSpacing: Double, paragraphSpacing: Double
    init(revision: UUID, width: Int, height: Int, preferences: ReadingPreferences) {
        self.revision = revision; self.width = width; self.height = height
        font = preferences.font; fontSize = preferences.fontSize
        lineSpacing = preferences.lineSpacing; paragraphSpacing = preferences.paragraphSpacing
    }
}
