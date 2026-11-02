import SwiftUI
import PDFKit
import AVFoundation
import CoreText
import ReadoraCore

struct MobileReaderView: View {
    @Bindable var library: MobileLibrary
    @State private var reader: MobileReader
    @State private var navigation = false
    @State private var appearance = false
    @State private var assistant = false
    @State private var excerpt = ""
    @State private var speechSettings = false
    @State private var speechLocationRequest = 0
    @AppStorage("mobileFollowSpeech") private var followSpeech = true
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
                MobilePDFView(document: pdf, paged: library.preferences.layout == .pages, marks: reader.marks, onSelection: { reader.pdfSelection = $0 }, position: Binding(get: { reader.position ?? 0 }, set: { reader.position = $0 }))
            } else if library.preferences.layout == .pages {
                MobilePagedReader(reader: reader, library: library)
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
                                    MobileScrollText(text: reader.paragraphs[index], heading: block?.headingLevel != nil,
                                        preferences: library.preferences,
                                        spokenRange: reader.speech.playing && reader.speech.spokenParagraph == index ? reader.speech.spokenRange : nil,
                                        highlight: reader.speech.preferences.highlightSpokenText,
                                        follow: followSpeech, locationRequest: speechLocationRequest,
                                        marks: reader.marks.filter { $0.kind == .highlight && $0.position == index },
                                        onRead: { reader.startSpeechFromSelection(paragraph: index, range: $0) },
                                        onAI: { excerpt = String(reader.paragraphs[index].prefix(6000)); assistant = true },
                                        onHighlight: { color in Task { await reader.addHighlight(color: color, paragraph: index) } },
                                        onSelection: { reader.selectText(paragraph: index, range: $0) })
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.id(index)
                        }
                    }.scrollTargetLayout().padding(.horizontal, 24).padding(.vertical, 20)
                }
                .scrollPosition(id: $reader.position, anchor: .top)
                .background(library.background)
            }
        }
        .modifier(MobileExternalApproval(library: library))
        .overlay { Color.black.opacity(1 - library.preferences.brightness).allowsHitTesting(false).accessibilityHidden(true) }
        .navigationTitle(reader.book.title).navigationBarTitleDisplayMode(.inline)
        .background(library.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("目录与书签", systemImage: "list.bullet") { navigation = true }
                    Button("主题与设置", systemImage: "textformat.size") { appearance = true }
                    Button("询问 AI", systemImage: "sparkles") { excerpt = reader.currentText; assistant = true }
                    if reader.pdf == nil {
                        Button("朗读设置", systemImage: "slider.horizontal.3") { speechSettings = true }
                        Button(reader.speech.playing ? "停止朗读" : "开始朗读", systemImage: "speaker.wave.2") {
                            if reader.speech.playing { reader.speech.stop() }
                            else { reader.startSpeechFromReadingPosition() }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("阅读菜单").disabled(!reader.loaded)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if reader.loaded && reader.speech.playing {
                GeometryReader { geometry in
                    MobileSpeechBubble(speech: reader.speech, follow: $followSpeech, locate: locateSpeech, settings: { speechSettings = true }, availableHeight: geometry.size.height)
                        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if reader.loaded && reader.pdf != nil {
                Text("页 \(min((reader.position ?? 0) + 1, reader.count)) / \(reader.count)")
                    .font(.caption2).foregroundStyle(.secondary).padding(10)
            }
        }
        .task {
            reader.speech.onPosition = { index, range in
                guard followSpeech else { return }
                reader.textOffset = range.location; reader.position = index
            }
            await reader.load()
            library.currentReader = reader
            if reader.loaded { _ = try? await library.store.updateDocumentInfo(id: reader.book.id, count: reader.count) }
            #if DEBUG
            if reader.loaded, ProcessInfo.processInfo.environment["READORA_SPEECH_SMOKE"] == "1" {
                reader.speech.start(reader.paragraphs, from: reader.position ?? 0, offset: reader.textOffset)
            }
            #endif
        }
        .onChange(of: reader.speech.playing) { _, active in if active { Task { await library.recordSpeech(reader.book.id) } } }
        .onChange(of: library.requestedPanel) { _, _ in if !assistant { consumeReaderRequest() } }
        .onChange(of: followSpeech) { _, enabled in if enabled { locateSpeech() } }
        .onChange(of: reader.speech.preferences.highlightSpokenText) { _, _ in
            let preferences = reader.speech.preferences
            Task {
                do { try await library.store.saveSpeechPreferences(preferences) }
                catch { reader.error = error.localizedDescription }
            }
        }
        .onChange(of: reader.position) { _, _ in reader.scheduleSave() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { Task { await reader.saveProgress() } } }
        .onDisappear { if library.currentReader === reader { library.currentReader = nil }; reader.finish(); Task { await reader.saveProgress(); await library.refresh() } }
        .sheet(isPresented: $speechSettings) { MobileSpeechSettings(speech: reader.speech, store: library.store) }
        .onChange(of: reader.textOffset) { _, _ in reader.scheduleSave() }
        .safeAreaInset(edge: .bottom) {
            if reader.pdf == nil, reader.selectionParagraph != nil, reader.selectionRange.length > 0 {
                HStack(spacing: 12) {
                    Label("已选中文字", systemImage: "text.cursor").font(.subheadline).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("开始朗读", systemImage: "play.fill") { reader.startSpeechFromReadingPosition() }
                        .buttonStyle(.borderedProminent)
                    Button {
                        reader.selectionParagraph = nil; reader.selectionRange = NSRange(location: 0, length: 0)
                    } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("关闭选区朗读操作")
                }
                .padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
            }
        }
        .sheet(isPresented: $appearance) { MobileAppearancePanel(library: library) }
        .sheet(isPresented: $assistant, onDismiss: consumeReaderRequest) { MobileAssistant(library: library, excerpt: excerpt, currentBookID: reader.book.id) }
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
                        Button("添加当前页书签", systemImage: "bookmark.badge.plus") { Task { await reader.addBookmark() } }
                        if reader.marks.filter({ $0.kind == .bookmark }).isEmpty { Text("还没有书签").foregroundStyle(.secondary) }
                        ForEach(reader.marks.filter { $0.kind == .bookmark }) { mark in
                            Button(mark.quote.isEmpty ? "位置 \(mark.position + 1)" : mark.quote) { jump(to: mark.position, offset: mark.utf16Offset) }
                                .swipeActions { Button("删除", role: .destructive) { Task { await reader.removeBookmark(mark) } } }
                        }
                    }
                    Section("文字高亮") {
                        ForEach(reader.marks.filter { $0.kind == .highlight }) { mark in
                            Button(mark.quote) { jump(to: mark.position, offset: mark.utf16Offset) }
                                .swipeActions { Button("移除", role: .destructive) { Task { await reader.removeBookmark(mark) } } }
                        }
                    }
                    if reader.count > 1 {
                        Section("跳转位置") {
                            Slider(value: Binding(get: { Double(reader.position ?? 0) }, set: { reader.speech.stop(); reader.textOffset = 0; reader.position = Int($0) }), in: 0...Double(reader.count - 1), step: 1)
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
    private func consumeReaderRequest() {
        if library.requestedPanel == "navigation" { navigation = true; library.requestedPanel = nil }
        else if library.requestedPanel == "appearance" { appearance = true; library.requestedPanel = nil }
        else if library.requestedPanel == "speech" { speechSettings = true; library.requestedPanel = nil }
    }
    private func locateSpeech() {
        guard reader.speech.playing, let paragraph = reader.speech.spokenParagraph else { return }
        reader.textOffset = reader.speech.spokenRange.location
        reader.position = paragraph
        speechLocationRequest += 1
    }
    private func jump(to index: Int, offset: Int = 0) { reader.selectionParagraph = nil; reader.selectionRange = NSRange(location: 0, length: 0); reader.speech.stop(); reader.textOffset = offset; reader.position = TextContent.clampedPosition(index, count: reader.count); navigation = false }

}

private struct MobileScrollText: UIViewRepresentable {
    let text: String
    let heading: Bool
    let preferences: ReadingPreferences
    let spokenRange: NSRange?
    let highlight: Bool
    let follow: Bool
    let locationRequest: Int
    let marks: [ReadingMark]
    var onRead: ((NSRange) -> Void)? = nil
    var onAI: (() -> Void)? = nil
    var onHighlight: ((HighlightColor) -> Void)? = nil
    let onSelection: (NSRange) -> Void
    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.isScrollEnabled = false; view.isEditable = false; view.isSelectable = true
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = .clear; view.adjustsFontForContentSizeCategory = false; view.delegate = view
        return view
    }
    func updateUIView(_ view: TextView, context: Context) {
        var attributes = MobilePagination.attributes(preferences, heading: heading)
        let font = attributes[.font] as! CTFont
        attributes[.font] = UIFont(name: CTFontCopyPostScriptName(font) as String, size: CTFontGetSize(font)) ?? UIFont.systemFont(ofSize: preferences.fontSize)
        attributes[.foregroundColor] = preferences.theme == .night ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.09, alpha: 1)
        let value = NSMutableAttributedString(string: text, attributes: attributes)
        view.onSelection = onSelection; view.onRead = onRead; view.onAI = onAI; view.onHighlight = onHighlight
        for mark in marks {
            if let range = SpeechTextSegment.localIntersection(NSRange(location: mark.utf16Offset, length: mark.utf16Length), in: NSRange(location: 0, length: value.length)) {
                let color: UIColor = mark.color == .mint ? .systemGreen : mark.color == .rose ? .systemPink : .systemYellow
                value.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.22), range: range)
            }
        }
        let range = spokenRange.flatMap { SpeechTextSegment.localIntersection($0, in: NSRange(location: 0, length: value.length)) }
        if highlight, let range { value.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.3), range: range) }
        if view.attributedText != value {
            let selection = view.selectedRange
            let sameText = view.text == value.string
            view.updating = true
            view.attributedText = value
            if sameText, selection.location != NSNotFound, NSMaxRange(selection) <= value.length { view.selectedRange = selection }
            view.updating = false
        }
        let requested = view.locationRequest != locationRequest
        view.locationRequest = locationRequest
        if let range, (follow || requested), view.lastRange != range || requested {
            view.lastRange = range; view.requestedRange = range
            DispatchQueue.main.async { [weak view] in view?.reveal(range) }
        }
        if range == nil { view.lastRange = nil; view.requestedRange = nil }
        if !follow && !requested { view.requestedRange = nil }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
    final class TextView: UITextView, UITextViewDelegate {
        var onSelection: ((NSRange) -> Void)?
        var onRead: ((NSRange) -> Void)?
        var onAI: (() -> Void)?
        var onHighlight: ((HighlightColor) -> Void)?
        var updating = false
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            var actions = suggestedActions
            if let valid = SpeechTextSegment.sourceSelection(range, in: textView.text ?? ""), let read = onRead {
                actions.insert(UIAction(title: "开始朗读", image: UIImage(systemName: "play.fill")) { _ in read(valid) }, at: 0)
            }
            if let ai = onAI { actions.append(UIAction(title: "询问 AI") { _ in ai() }) }
            if let highlight = onHighlight {
                actions.append(UIMenu(title: "高亮文字", children: HighlightColor.allCases.map { color in
                    UIAction(title: color.title) { _ in highlight(color) }
                }))
            }
            return UIMenu(children: actions)
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating, textView.isFirstResponder else { return }
            onSelection?(textView.selectedRange)
        }
        var locationRequest = 0
        var lastRange: NSRange?
        var requestedRange: NSRange?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, let range = requestedRange {
                DispatchQueue.main.async { [weak self] in self?.reveal(range) }
            }
        }
        func reveal(_ range: NSRange) {
            guard !(isFirstResponder && selectedRange.length > 0), window != nil, requestedRange == range, NSMaxRange(range) <= textStorage.length else { return }
            layoutManager.ensureLayout(for: textContainer)
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            var ancestor = superview
            while let candidate = ancestor {
                if let scroll = candidate as? UIScrollView, scroll.isScrollEnabled {
                    scroll.scrollRectToVisible(convert(rect, to: scroll).insetBy(dx: 0, dy: -28), animated: false)
                    break
                }
                ancestor = candidate.superview
            }
        }
    }
}

private struct MobileSpeechBubble: View {
    @Bindable var speech: MobileSpeech
    @Binding var follow: Bool
    let locate: () -> Void
    let settings: () -> Void
    @State private var expanded = true
    let availableHeight: CGFloat
    @State private var controlHeight: CGFloat = 56
    private var maximumLift: CGFloat { max(0, availableHeight - controlHeight - 32) }
    @State private var lift: CGFloat = 0
    @GestureState private var drag: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private func toggleExpanded() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) { expanded.toggle() }
    }
    var body: some View {
        Group {
            if expanded {
                MobileSpeechBar(speech: speech, follow: $follow, locate: locate, settings: settings, collapse: toggleExpanded)
                    .frame(maxWidth: 350)
                    .transition(.scale(scale: 0.95, anchor: .bottomTrailing).combined(with: .opacity))
            } else {
                Button(action: toggleExpanded) {
                    HStack(spacing: 9) {
                        if speech.preparing { ProgressView().controlSize(.small) }
                        else { Image(systemName: speech.paused ? "pause.fill" : "waveform").foregroundStyle(Color.accentColor) }
                        Text(speech.paused ? "已暂停" : speech.preparing ? "准备中" : "朗读中")
                            .font(.system(size: 13, weight: .medium))
                        Image(systemName: "chevron.up").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 48)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(.primary.opacity(0.08), lineWidth: 0.5) }
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                }.buttonStyle(.plain).accessibilityLabel("展开朗读控制")
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 18)
            .updating($drag) { value, state, _ in state = value.translation.height }
            .onEnded { value in lift = min(0, max(-maximumLift, lift + value.translation.height)) })
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { controlHeight = $0 }
        .offset(y: min(0, max(-maximumLift, lift + drag)))
    }
}

private struct MobileSpeechBar: View {
    @Bindable var speech: MobileSpeech
    @Binding var follow: Bool
    let locate: () -> Void
    let settings: () -> Void
    let collapse: () -> Void
    private var title: String { speech.paused ? "已暂停" : speech.preparing ? "准备朗读" : "正在朗读" }
    private var detail: String { speech.preparing ? speech.preparationStatus : speech.voiceTitle }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.1))
                    if speech.preparing && !speech.paused {
                        ProgressView().controlSize(.small).tint(.accentColor)
                    } else {
                        Image(systemName: "waveform").font(.system(size: 17, weight: .medium)).foregroundStyle(Color.accentColor)
                    }
                }.frame(width: 38, height: 42).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
                Button(action: settings) {
                    Text(String(format: "%g×", speech.preferences.rate))
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                        .padding(.horizontal, 10).frame(minHeight: 44)
                        .background(.primary.opacity(0.04), in: Capsule())
                }.accessibilityLabel("朗读速度与音色设置")
                Button { speech.togglePause() } label: {
                    Image(systemName: speech.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color(uiColor: .systemBackground))
                        .frame(width: 44, height: 44).background(.primary, in: Circle())
                }.accessibilityLabel(speech.paused ? "继续朗读" : "暂停朗读")
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            if let progress = speech.preparationProgress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress).tint(.accentColor)
                    HStack {
                        Text("缓存完成后播放").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        if speech.canPlayImmediately {
                            Button("开始朗读") { speech.playImmediately() }
                                .font(.system(size: 12, weight: .semibold)).frame(minHeight: 32)
                                .accessibilityHint("跳过完整缓存等待，后续可能需要缓冲")
                        }
                    }
                }.padding(.horizontal, 14).padding(.bottom, 8)
            }
            Rectangle().fill(.primary.opacity(0.06)).frame(height: 0.5).padding(.horizontal, 14)
            HStack(spacing: 4) {
                action("定位", icon: "location", active: false, action: locate)
                action("跟随", icon: "location.fill", active: follow) { follow.toggle() }
                action("高亮", icon: "highlighter", active: speech.preferences.highlightSpokenText) { speech.preferences.highlightSpokenText.toggle() }
                Menu {
                    Button("朗读设置", systemImage: "slider.horizontal.3", action: settings)
                    Button(speech.preparing ? "取消准备" : "结束朗读", systemImage: "stop.circle", role: .destructive) { speech.stop() }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium)).frame(width: 44, height: 44)
                }.accessibilityLabel("更多朗读操作")
                Button(action: collapse) {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).frame(width: 44, height: 44)
                }.accessibilityLabel("收起朗读控制")
            }
            .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 3)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground).opacity(0.97), in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.08), radius: 16, y: 5)
        .buttonStyle(.plain)
    }
    private func action(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(active ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title == "定位" ? "回到朗读位置" : title == "跟随" ? "自动跟随" : "文字高亮")
        .accessibilityValue(title == "定位" ? "" : active ? "已开启" : "已关闭")
    }
}

#if DEBUG
// Self-authored layout fixture, no access to the user's books or model inference.
struct MobileSpeechPanelPreview: View {
    @State private var speech = MobileSpeech()
    @State private var follow = true
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                Text("阅读，让文字有了声音。").font(.system(size: 30, weight: .medium))
                Text("阳光穿过窗前的树叶，落在翻开的书页上。我们沿着文字慢慢前行，在故事里看见不同的世界。")
                    .font(.system(size: 27)).lineSpacing(12)
                Spacer()
                Text("19 / 122 · 15%").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(24)
            MobileSpeechBubble(speech: speech, follow: $follow, locate: {}, settings: {}, availableHeight: 700)
                .padding(16).padding(.bottom, 30)
        }
        .task {
            speech.playing = true
            speech.preparing = ProcessInfo.processInfo.environment["READORA_PANEL_STATE"] != "playing"
            speech.preferences.rate = 2
        }
    }
}
#endif

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
    let paged: Bool
    let marks: [ReadingMark]
    let onSelection: (PDFSelection?) -> Void
    @Binding var position: Int
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = paged ? .singlePage : .singlePageContinuous
        view.displayDirection = paged ? .horizontal : .vertical
        view.usePageViewController(paged)
        view.document = document
        context.coordinator.observe(view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document { view.document = document }
        let mode: PDFDisplayMode = paged ? .singlePage : .singlePageContinuous
        if view.displayMode != mode {
            view.usePageViewController(paged); view.displayMode = mode
            view.displayDirection = paged ? .horizontal : .vertical
        }
        if let page = document.page(at: position), view.currentPage !== page { view.go(to: page) }
        if context.coordinator.lastMarks != marks {
            for (page, annotation) in context.coordinator.annotations { page.removeAnnotation(annotation) }
            context.coordinator.annotations = []
            for mark in marks where mark.kind == .highlight {
                guard let page = document.page(at: mark.position) else { continue }
                for rectangle in mark.rectangles ?? [] {
                    let bounds = CGRect(x: rectangle.x, y: rectangle.y, width: rectangle.width, height: rectangle.height).intersection(page.bounds(for: .cropBox))
                    guard !bounds.isNull, !bounds.isEmpty else { continue }
                    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    annotation.color = (mark.color == .mint ? UIColor.systemGreen : mark.color == .rose ? UIColor.systemPink : UIColor.systemYellow).withAlphaComponent(0.35)
                    page.addAnnotation(annotation); context.coordinator.annotations.append((page, annotation))
                }
            }
            context.coordinator.lastMarks = marks
        }
    }
    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) { NotificationCenter.default.removeObserver(coordinator) }
    final class Coordinator: NSObject {
        var parent: MobilePDFView
        var lastMarks: [ReadingMark] = []
        var annotations: [(PDFPage, PDFAnnotation)] = []
        init(_ parent: MobilePDFView) { self.parent = parent }
        func observe(_ view: PDFView) {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: .PDFViewPageChanged, object: view)
            NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)), name: .PDFViewSelectionChanged, object: view)
        }
        @objc func selectionChanged(_ note: Notification) {
            guard let view = note.object as? PDFView else { return }
            let selection = view.currentSelection
            Task { @MainActor [weak self] in self?.parent.onSelection(selection) }
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

struct MobileSpeechSettings: View {
    let speech: MobileSpeech
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("mobileFollowSpeech") private var followSpeech = true
    @State private var draft = SpeechPreferences(maximumRate: 2, cacheBeforePlayback: false)
    @State private var preview = MobileSpeech()
    @State private var draftEngine = MobileSpeechEngine.kokoro
    @State private var draftKokoroVoice = MobileKokoroVoice.female054
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("朗读引擎") {
                    if draftEngine == .kokoro {
                        Picker("普通话音色", selection: $draftKokoroVoice) {
                            ForEach(MobileKokoroVoice.allCases) { Text($0.title).tag($0) }
                        }
                        Text(MobileSpeech.kokoroInstalled ? "Kokoro v1.1 中文模型在手机本机运行，支持中英混读，正文不会发送到服务器。首次准备需要稍候；高亮以实际播放的短句为单位。" : "Kokoro模型尚未准备。请运行项目模型准备脚本并重新安装，。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("多音字纠正 · 本地词典") {
                    Text("每行一个词语，保存后对所有书籍生效。请优先填写完整词语，避免单字覆盖其他读法。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("银行 = yin2 hang2\n行长 = hang2 zhang3\n重庆 = chong2 qing4")
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    TextEditor(text: $draft.pronunciationDictionary).font(.body.monospaced()).frame(minHeight: 120)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityLabel("读音词典，每行词语等于带声调拼音")
                    Button("检查并试听词典") {
                        do {
                            let words = try PronunciationDictionary.parse(draft.pronunciationDictionary).keys.sorted()
                            guard !words.isEmpty else { error = "请先添加一个词语"; return }
                            if speech.playing && !speech.paused { speech.togglePause() }
                            preview.configure(draft, engine: draftEngine, voice: draftKokoroVoice, persistChoice: false)
                            preview.start([words.joined(separator: "，") + "。"], from: 0)
                            error = nil
                        } catch { self.error = error.localizedDescription }
                    }
                }
                Section("朗读跟随") {
                    Toggle("高亮正在朗读的文字", isOn: $draft.highlightSpokenText)
                    Toggle("自动跟随朗读位置", isOn: $followSpeech)
                }
                Section("高速流畅播放") {
                    Toggle("2× / 4× 先完整缓存剩余正文", isOn: $draft.cacheBeforePlayback)
                    Text("默认关闭，优先快速出声，后续可能需要缓冲。打开后先生成全部剩余正文，等待时间随正文增长；生成时请保持应用前台，完成后可锁屏朗读。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("朗读速度") {
                    Text(String(format: "%.2f×", draft.rate)).monospacedDigit()
                    Slider(value: $draft.rate, in: 0.5...max(0.5, min(8, draft.maximumRate)), step: 0.05).accessibilityLabel("朗读速度")
                    Stepper(value: $draft.maximumRate, in: 1...8, step: 0.25) {
                        Text(String(format: "最大速度 %.2f×", draft.maximumRate))
                    }
                    Button("恢复默认上限 2×") { draft.maximumRate = 2 }
                    Text("默认上限2×，可自定义至8×。先正常语速生成，再保音调加速，速度越高越难辨清；不同音色的自然语速有所差异。保存后从当前段落应用，暂停状态保持暂停。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button(preview.playing ? "停止试听" : "试听所选音色", systemImage: preview.playing ? "stop.circle" : "play.circle") {
                        if preview.playing { preview.stop() }
                        else {
                            if speech.playing && !speech.paused { speech.togglePause() }
                            preview.configure(draft, engine: draftEngine, voice: draftKokoroVoice, persistChoice: false)
                            let language = "zh"
                            let text = language.hasPrefix("zh") ? "欢迎使用朗读。翻开一本书，让文字的声音陪伴你的阅读时光。" : "Welcome to Readora. Open a book and enjoy a clear, comfortable reading voice."
                            preview.start([text], from: 0)
                        }
                    }
                    if preview.preparing { Label("正在准备离线声音…", systemImage: "waveform") }
                }
                if let error = error ?? preview.error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("朗读设置")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            do {
                                preview.stop()
                                var saved = draft
                                if draftEngine == .kokoro { saved.voiceIdentifier = "kokoro:\(draftKokoroVoice.rawValue)" }
                                try await store.saveSpeechPreferences(saved)
                                UserDefaults.standard.set(true, forKey: "mobileSpeechMaximumConfigured")
                                speech.configure(saved, engine: draftEngine, voice: draftKokoroVoice); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .onChange(of: draft.maximumRate) { _, maximum in draft.rate = min(draft.rate, maximum) }
            .onChange(of: draftEngine) { _, engine in
                preview.stop()
            }
            .onChange(of: draftKokoroVoice) { _, _ in preview.stop() }
            .onChange(of: draft.voiceIdentifier) { _, _ in preview.stop() }
            .onChange(of: draft.pronunciationDictionary) { _, _ in preview.stop() }
            .onChange(of: draft.rate) { _, _ in preview.stop() }
            .onAppear {
                draft = speech.preferences; draftEngine = speech.engineChoice; draftKokoroVoice = speech.kokoroVoice
            }
            .onDisappear { preview.stop() }
        }
    }
}

private struct MobilePagedReader: View {
    @Bindable var reader: MobileReader
    @Bindable var library: MobileLibrary
    @State private var pages: [MobilePage] = []
    @State private var selection = 0
    @State private var failure: String?
    @State private var paginationID = UUID()
    @State private var paginating = false
    var body: some View {
        GeometryReader { geometry in
            let key = "\(geometry.size.width)-\(geometry.size.height)-\(library.preferences.font)-\(library.preferences.fontSize)-\(library.preferences.boldText == true)-\(library.preferences.lineSpacing)-\(library.preferences.paragraphSpacing)"
            VStack(spacing: 0) {
                if let failure { ContentUnavailableView("无法分页", systemImage: "exclamationmark.triangle", description: Text(failure)) }
                else if pages.isEmpty { ProgressView("正在分页…").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    MobileCurlView(selection: $selection, count: pages.count, paperColor: library.background) { index in
                        guard pages.indices.contains(index) else { return AnyView(library.background) }
                        let page = pages[index]
                        return AnyView(Group {
                            if let image = page.imageIndex, let path = reader.publication?.blocks[image].imagePath {
                                MobileIllustration(book: reader.book, path: path, store: library.store)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
                            } else {
                                MobilePageText(page: page, paragraphs: reader.paragraphs, headings: headingIndices, preferences: library.preferences, marks: reader.marks.filter { $0.kind == .highlight }, spokenParagraph: reader.speech.playing && reader.speech.preferences.highlightSpokenText ? reader.speech.spokenParagraph : nil, spokenRange: reader.speech.spokenRange,
                                    onSelection: { reader.selectText(paragraph: $0, range: $1) },
                                    onRead: { reader.startSpeechFromSelection(paragraph: $0, range: $1) })
                            }
                        }.background(library.background))
                    }
                    .id("\(paginationID)-\(library.preferences.theme)")
                    .allowsHitTesting(!paginating)
                    .accessibilityAction(named: "下一页") { if selection + 1 < pages.count { selection += 1 } }
                    .accessibilityAction(named: "上一页") { if selection > 0 { selection -= 1 } }
                    Group {
                        if paginating { Text("正在重新分页…") }
                        else { Text("\(selection + 1) / \(pages.count) · \(Int(Double(selection + 1) / Double(pages.count) * 100))%") }
                    }
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            .task(id: key) {
                paginating = true
                let paragraphs = reader.paragraphs, preferences = library.preferences
                let headings = headingIndices
                let images = Set(reader.publication?.blocks.indices.filter { reader.publication?.blocks[$0].imagePath != nil } ?? [])
                let width = geometry.size.width - 48, height = geometry.size.height - 70
                let worker = Task.detached(priority: .userInitiated) {
                    try MobilePagination.paginate(paragraphs, headings: headings, images: images, preferences: preferences, width: width, height: height)
                }
                do {
                    let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    try Task.checkCancellation()
                    selection = result.firstIndex { $0.contains(reader.position ?? 0, offset: reader.textOffset) } ?? 0
                    pages = result; reader.pageCount = result.count; reader.pageNumber = selection + 1; paginationID = UUID(); failure = nil; paginating = false
                } catch is CancellationError {} catch { failure = error.localizedDescription; paginating = false }
            }
            .onChange(of: reader.pageRequest) { _, request in
                if let request, pages.indices.contains(request) { selection = request }
                reader.pageRequest = nil
            }
            .onChange(of: selection) { _, index in
                reader.selectionParagraph = nil; reader.selectionRange = NSRange(location: 0, length: 0)
                reader.pageNumber = index + 1
                guard pages.indices.contains(index),
                      !pages[index].contains(reader.position ?? 0, offset: reader.textOffset) else { return }
                reader.textOffset = pages[index].offset
                reader.position = pages[index].position
            }
            .onChange(of: reader.textOffset) { _, _ in alignSelection() }
            .onChange(of: reader.position) { _, _ in alignSelection() }
        }
    }
    private func alignSelection() {
        let position = reader.position ?? 0, offset = reader.textOffset
        if pages.indices.contains(selection), pages[selection].contains(position, offset: offset) { return }
        // Page starts are ordered by paragraph and UTF-16 offset. Avoid scanning
        // a long novel on every spoken word.
        var lower = 0, upper = pages.count
        while lower < upper {
            let middle = (lower + upper) / 2, page = pages[middle]
            if page.position < position || page.position == position && page.offset <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        let index = max(0, lower - 1)
        if pages.indices.contains(index), pages[index].contains(position, offset: offset) { selection = index }
    }
    private var headingIndices: Set<Int> {
        Set(reader.publication?.blocks.indices.filter { reader.publication?.blocks[$0].headingLevel != nil } ?? [])
    }
}

private struct MobilePage: Sendable {
    struct Slice: Sendable { let paragraph: Int; let range: NSRange; let height: Double }
    let slices: [Slice]
    let imageIndex: Int?
    var position: Int { imageIndex ?? slices.first?.paragraph ?? 0 }
    var offset: Int { slices.first?.range.location ?? 0 }
    func contains(_ position: Int, offset: Int) -> Bool {
        imageIndex == position || slices.contains { $0.paragraph == position && NSLocationInRange(offset, $0.range) }
    }
}

private enum MobilePagination {
    nonisolated static func attributes(_ preferences: ReadingPreferences, heading: Bool) -> [NSAttributedString.Key: Any] {
        let size = preferences.fontSize + (heading ? 4 : 0)
        let name: String = switch preferences.font {
        case .songti: heading ? "SongtiSC-Bold" : "SongtiSC-Regular"
        case .pingfang: heading ? "PingFangSC-Semibold" : "PingFangSC-Regular"
        case .serif: "NewYork-Regular"
        case .rounded: "SFProRounded-Regular"
        }
        let base = CTFontCreateWithName(name as CFString, size, nil)
        let font = preferences.boldText == true || heading
            ? CTFontCreateCopyWithSymbolicTraits(base, size, nil, .boldTrait, .boldTrait) ?? base : base
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = preferences.lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: font, .paragraphStyle: paragraph]
    }
    nonisolated static func paginate(_ paragraphs: [String], headings: Set<Int>, images: Set<Int>, preferences: ReadingPreferences, width: Double, height: Double) throws -> [MobilePage] {
        guard width >= 100, height >= 100 else { return [] }
        var pages: [MobilePage] = [], slices: [MobilePage.Slice] = [], used = 0.0
        func flush() {
            if !slices.isEmpty { pages.append(MobilePage(slices: slices, imageIndex: nil)) }
            slices = []; used = 0
        }
        for (index, text) in paragraphs.enumerated() {
            try Task.checkCancellation()
            if images.contains(index) { flush(); pages.append(MobilePage(slices: [], imageIndex: index)); continue }
            let string = text as NSString
            let setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes(preferences, heading: headings.contains(index))))
            var offset = 0
            while offset < string.length {
                try Task.checkCancellation()
                let available = height - used - 4
                if available < preferences.fontSize + preferences.lineSpacing { flush(); continue }
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: available), transform: nil), nil)
                let length = min(CTFrameGetVisibleStringRange(frame).length, string.length - offset)
                if length == 0 {
                    if !slices.isEmpty { flush(); continue }
                    throw ReadingDataError.invalidPreferences
                }
                let measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: offset, length: length), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
                let sliceHeight = min(available, ceil(measured.height) + 2)
                slices.append(.init(paragraph: index, range: NSRange(location: offset, length: length), height: sliceHeight))
                used += sliceHeight + preferences.paragraphSpacing; offset += length
                if offset < string.length { flush() }
            }
        }
        flush(); return pages
    }
}

private struct MobilePageText: UIViewRepresentable {
    let page: MobilePage
    let paragraphs: [String]
    let headings: Set<Int>
    let preferences: ReadingPreferences
    let marks: [ReadingMark]
    let spokenParagraph: Int?
    let spokenRange: NSRange
    let onSelection: (Int, NSRange) -> Void
    let onRead: (Int, NSRange) -> Void
    func makeUIView(context: Context) -> Drawing { Drawing() }
    func updateUIView(_ view: Drawing, context: Context) {
        view.page = page; view.paragraphs = paragraphs; view.headings = headings; view.preferences = preferences
        view.marks = marks
        view.spokenParagraph = spokenParagraph; view.spokenRange = spokenRange
        view.backgroundColor = .clear; view.isOpaque = false
        view.accessibilityLabel = page.slices.map { (paragraphs[$0.paragraph] as NSString).substring(with: $0.range) }.joined(separator: "\n")
        view.isAccessibilityElement = false
        view.configureSelections(onSelection: onSelection, onRead: onRead)
        view.setNeedsDisplay(); view.setNeedsLayout()
    }
    final class Drawing: UIView {
        var page = MobilePage(slices: [], imageIndex: nil)
        var paragraphs: [String] = []
        var headings: Set<Int> = []
        var preferences = ReadingPreferences()
        var marks: [ReadingMark] = []
        var spokenParagraph: Int?
        var spokenRange = NSRange(location: 0, length: 0)
        var selectors: [MobileScrollText.TextView] = []
        func configureSelections(onSelection: @escaping (Int, NSRange) -> Void, onRead: @escaping (Int, NSRange) -> Void) {
            while selectors.count > page.slices.count { selectors.removeLast().removeFromSuperview() }
            while selectors.count < page.slices.count {
                let view = MobileScrollText.TextView()
                view.isEditable = false; view.isSelectable = true; view.isScrollEnabled = false
                view.backgroundColor = .clear; view.textContainerInset = .zero
                view.textContainer.lineFragmentPadding = 0; view.delegate = view
                view.tintColor = .systemBlue
                selectors.append(view); addSubview(view)
            }
            for (index, slice) in page.slices.enumerated() {
                let view = selectors[index]
                let text = (paragraphs[slice.paragraph] as NSString).substring(with: slice.range)
                var attributes = MobilePagination.attributes(preferences, heading: headings.contains(slice.paragraph))
                let font = attributes[.font] as! CTFont
                attributes[.font] = UIFont(name: CTFontCopyPostScriptName(font) as String, size: CTFontGetSize(font)) ?? UIFont.systemFont(ofSize: preferences.fontSize)
                attributes[.foregroundColor] = UIColor.clear
                let value = NSAttributedString(string: text, attributes: attributes)
                if view.attributedText != value {
                    let old = view.selectedRange; let same = view.text == text
                    view.updating = true; view.attributedText = value
                    if same, old.location != NSNotFound, NSMaxRange(old) <= value.length { view.selectedRange = old }
                    view.updating = false
                }
                view.accessibilityLabel = text
                view.onSelection = { range in
                    if let source = SpeechTextSegment.sourceSelection(range, in: text, sourceOffset: slice.range.location) { onSelection(slice.paragraph, source) }
                    else { onSelection(slice.paragraph, NSRange(location: 0, length: 0)) }
                }
                view.onRead = { range in
                    if let source = SpeechTextSegment.sourceSelection(range, in: text, sourceOffset: slice.range.location) { onRead(slice.paragraph, source) }
                }
            }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            var y = 20.0
            for (index, slice) in page.slices.enumerated() where index < selectors.count {
                selectors[index].frame = CGRect(x: 24, y: y, width: max(0, bounds.width - 48), height: slice.height)
                y += slice.height + preferences.paragraphSpacing
            }
        }
        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            var y = 20.0
            for slice in page.slices {
                var attributes = MobilePagination.attributes(preferences, heading: headings.contains(slice.paragraph))
                attributes[.foregroundColor] = preferences.theme == .night ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.09, alpha: 1)
                let text = NSAttributedString(string: (paragraphs[slice.paragraph] as NSString).substring(with: slice.range), attributes: attributes)
                let setter = CTFramesetterCreateWithAttributedString(text)
                context.saveGState()
                context.translateBy(x: 24, y: y + slice.height)
                context.scaleBy(x: 1, y: -1)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 0, y: 0, width: bounds.width - 48, height: slice.height), transform: nil), nil)
                var highlights: [(NSRange, UIColor)] = marks.filter { $0.position == slice.paragraph }.compactMap { mark in
                    guard let range = SpeechTextSegment.localIntersection(NSRange(location: mark.utf16Offset, length: mark.utf16Length), in: slice.range) else { return nil }
                    return (range, mark.color == .mint ? UIColor.systemGreen : mark.color == .rose ? UIColor.systemPink : UIColor.systemYellow)
                }
                if slice.paragraph == spokenParagraph, let range = SpeechTextSegment.localIntersection(spokenRange, in: slice.range) {
                    highlights.append((range, UIColor.systemYellow))
                }
                for (highlight, color) in highlights {
                    let lines = CTFrameGetLines(frame) as! [CTLine]
                    var origins = [CGPoint](repeating: .zero, count: lines.count)
                    if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
                    context.setFillColor(color.withAlphaComponent(0.3).cgColor)
                    for (index, line) in lines.enumerated() {
                        let range = CTLineGetStringRange(line)
                        let overlap = NSIntersectionRange(highlight, NSRange(location: range.location, length: range.length))
                        guard overlap.length > 0 else { continue }
                        let start = CTLineGetOffsetForStringIndex(line, overlap.location, nil)
                        let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(overlap), nil)
                        var ascent: CGFloat = 0, descent: CGFloat = 0
                        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
                        let rect = CGRect(x: origins[index].x + min(start, end), y: origins[index].y - descent - 2,
                                          width: max(2, abs(end - start)), height: ascent + descent + 4)
                        context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 3).cgPath); context.fillPath()
                    }
                }
                CTFrameDraw(frame, context); context.restoreGState()
                y += slice.height + preferences.paragraphSpacing
            }
        }
    }
}

private struct MobileCurlView: UIViewControllerRepresentable {
    @Binding var selection: Int
    let count: Int
    let paperColor: Color
    let content: (Int) -> AnyView
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(
            transitionStyle: UIAccessibility.isReduceMotionEnabled ? .scroll : .pageCurl,
            navigationOrientation: .horizontal)
        // One visible page with UIKit's own translucent paper back. Passing a
        // custom front/back pair can violate the runtime's controller count.
        controller.isDoubleSided = false
        controller.dataSource = context.coordinator; controller.delegate = context.coordinator
        if count > 0 {
            controller.setViewControllers([context.coordinator.page(min(max(0, selection), count - 1))], direction: .forward, animated: false)
        }
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard count > 0, !context.coordinator.turning else { return }
        let target = min(max(0, selection), count - 1)
        let current = controller.viewControllers?.first as? Page
        if current?.index == target { current?.rootView = content(target); return }
        controller.setViewControllers([context.coordinator.page(target)], direction: target > (current?.index ?? 0) ? .forward : .reverse, animated: false)
    }
    static func dismantleUIViewController(_ controller: UIPageViewController, coordinator: Coordinator) {
        coordinator.active = false
        controller.delegate = nil; controller.dataSource = nil
    }
    final class Page: UIHostingController<AnyView> { var index = 0 }
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: MobileCurlView
        var turning = false
        var active = true
        init(_ parent: MobileCurlView) { self.parent = parent }
        func page(_ index: Int) -> Page {
            let page = Page(rootView: parent.content(index))
            page.index = index
            return page
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard active, let page = viewController as? Page, page.index > 0, page.index <= parent.count else { return nil }
            return self.page(page.index - 1)
        }
        func pageViewController(_ controller: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard active, let page = viewController as? Page, page.index + 1 < parent.count else { return nil }
            return self.page(page.index + 1)
        }
        func pageViewController(_ controller: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { turning = true }
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            turning = false
            guard active else { return }
            if completed, let page = controller.viewControllers?.first as? Page, (0..<parent.count).contains(page.index) {
                parent.selection = page.index
            }
        }
    }
}

private struct MobileAppearancePanel: View {
    @Bindable var library: MobileLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var custom = false
    @State private var detent: PresentationDetent = .height(570)
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3.weight(.medium))
                            .frame(width: 42, height: 42).background(.quaternary, in: Circle())
                    }.accessibilityLabel("关闭主题与设置")
                    Text("主题与设置").font(.title3.bold())
                    Spacer()
                }
                HStack(spacing: 12) {
                    HStack(spacing: 0) {
                        Button { library.preferences.fontSize = max(14, library.preferences.fontSize - 2) } label: {
                            Text("小").font(.system(size: 20, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        }.accessibilityLabel("减小字号").disabled(library.preferences.fontSize <= 14)
                        Divider().frame(height: 24)
                        Button { library.preferences.fontSize = min(40, library.preferences.fontSize + 2) } label: {
                            Text("大").font(.system(size: 28, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 48)
                        }.accessibilityLabel("增大字号").disabled(library.preferences.fontSize >= 40)
                    }.background(.quaternary, in: Capsule())
                    Button { library.preferences.layout = library.preferences.layout == .pages ? .scroll : .pages } label: {
                        Image(systemName: library.preferences.layout == .pages ? "book.pages" : "scroll")
                            .font(.title2).frame(width: 48, height: 48)
                    }.accessibilityLabel(library.preferences.layout == .pages ? "左右卷页，点击切换连续滚动" : "连续滚动，点击切换左右卷页")
                    Button { library.preferences.theme = library.preferences.theme == .night ? .paper : .night } label: {
                        Image(systemName: "circle.lefthalf.filled").font(.title2).frame(width: 48, height: 48)
                    }.accessibilityLabel("切换日间与夜间")
                }
                HStack(spacing: 12) {
                    Image(systemName: "sun.min").font(.title3)
                    Slider(value: $library.preferences.brightness, in: 0.35...1).tint(.primary).accessibilityLabel("阅读亮度")
                    Image(systemName: "sun.max.fill").font(.title3)
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Preset.allCases) { preset in
                        Button { preset.apply(to: &library.preferences) } label: {
                            VStack(spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 1) {
                                    Text("大").font(.system(size: 34, weight: preset == .bold ? .bold : .regular, design: preset == .paper ? .serif : .default))
                                    Text("小").font(.system(size: 17))
                                }.accessibilityHidden(true)
                                Text(preset.rawValue).font(.system(size: 15, weight: preset == .bold ? .bold : .regular))
                            }
                            .foregroundStyle(preset == .quiet ? Color.white : Color.black)
                            .frame(maxWidth: .infinity, minHeight: 100)
                            .background(preset.color, in: RoundedRectangle(cornerRadius: 24))
                            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(preset.matches(library.preferences) ? Color.primary : Color.primary.opacity(0.08), lineWidth: preset.matches(library.preferences) ? 2.5 : 1) }
                        }
                        .accessibilityLabel("\(preset.rawValue)主题")
                        .accessibilityAddTraits(preset.matches(library.preferences) ? .isSelected : [])
                    }
                }
                Button {
                    withAnimation { custom.toggle(); detent = custom ? .large : .height(570) }
                } label: {
                    Label("自定义", systemImage: "slider.horizontal.3").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 46).background(.quaternary, in: Capsule())
                }
                if custom {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("字体", selection: $library.preferences.font) {
                            ForEach(ReaderFont.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.menu)
                        Toggle("加粗文字", isOn: Binding(get: { library.preferences.boldText == true }, set: { library.preferences.boldText = $0 }))
                        Text("字号 \(Int(library.preferences.fontSize))")
                        Slider(value: $library.preferences.fontSize, in: 14...40, step: 1).accessibilityLabel("字号")
                        Text("行距 \(Int(library.preferences.lineSpacing))")
                        Slider(value: $library.preferences.lineSpacing, in: 2...18, step: 1).accessibilityLabel("行距")
                        Text("段距 \(Int(library.preferences.paragraphSpacing))")
                        Slider(value: $library.preferences.paragraphSpacing, in: 8...36, step: 1).accessibilityLabel("段距")
                        Picker("翻页方式", selection: $library.preferences.layout) {
                            Text("左右卷页").tag(ReadingLayout.pages)
                            Text("连续滚动").tag(ReadingLayout.scroll)
                        }.pickerStyle(.segmented)
                        Text("亮度仅影响阅读区域。主题和排版自动保存。").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).background(.quaternary, in: RoundedRectangle(cornerRadius: 22))
                }
            }.padding(22)
        }
        .buttonStyle(.plain).foregroundStyle(.primary)
        .presentationDetents([.height(570), .large], selection: $detent)
        .presentationCornerRadius(34)
        .presentationDragIndicator(.hidden)
        .presentationBackground(.regularMaterial)
        .onDisappear { Task { await library.saveAppearance() } }
    }
    private enum Preset: String, CaseIterable, Identifiable {
        case original = "原始", quiet = "安静", paper = "纸张", bold = "粗体", calm = "平静", focus = "专注"
        var id: String { rawValue }
        var color: Color {
            switch self {
            case .original, .bold: .white
            case .quiet: Color(white: 0.25)
            case .paper: Color(white: 0.94)
            case .calm: Color(red: 0.94, green: 0.89, blue: 0.79)
            case .focus: Color(red: 0.91, green: 0.94, blue: 0.86)
            }
        }
        private var theme: ReaderTheme {
            switch self { case .quiet: .night; case .calm: .parchment; case .focus: .sage; default: .paper }
        }
        private var font: ReaderFont { self == .paper || self == .calm ? .songti : .pingfang }
        func apply(to preferences: inout ReadingPreferences) {
            preferences.theme = theme; preferences.font = font; preferences.boldText = self == .bold
            preferences.lineSpacing = self == .focus ? 12 : 8
            preferences.paragraphSpacing = self == .focus ? 28 : 20
        }
        func matches(_ preferences: ReadingPreferences) -> Bool {
            preferences.theme == theme && preferences.font == font && (preferences.boldText == true) == (self == .bold)
                && preferences.lineSpacing == (self == .focus ? 12 : 8)
                && preferences.paragraphSpacing == (self == .focus ? 28 : 20)
        }
    }
}
