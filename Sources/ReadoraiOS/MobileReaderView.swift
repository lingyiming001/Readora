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
                MobilePDFView(document: pdf, paged: library.preferences.layout == .pages, position: Binding(get: { reader.position ?? 0 }, set: { reader.position = $0 }))
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
                                        follow: followSpeech, locationRequest: speechLocationRequest)
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
        .overlay { Color.black.opacity(1 - library.preferences.brightness).allowsHitTesting(false).accessibilityHidden(true) }
        .navigationTitle(reader.book.title).navigationBarTitleDisplayMode(.inline)
        .background(library.background)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("目录与书签", systemImage: "list.bullet") { navigation = true }
                    Button("添加书签", systemImage: "bookmark") { Task { await reader.addBookmark() } }
                    Button("主题与设置", systemImage: "textformat.size") { appearance = true }
                    Button("询问 AI", systemImage: "sparkles") { excerpt = reader.currentText; assistant = true }
                    if reader.pdf == nil {
                        Button("朗读设置 ·速度与音色", systemImage: "slider.horizontal.3") { speechSettings = true }
                        Button(reader.speech.playing ? "停止朗读" : "开始朗读", systemImage: "speaker.wave.2") {
                            if reader.speech.playing { reader.speech.stop() }
                            else { reader.speech.start(reader.paragraphs, from: reader.position ?? 0, offset: reader.textOffset) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("阅读菜单").disabled(!reader.loaded)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if reader.loaded && reader.speech.playing {
                MobileSpeechBar(speech: reader.speech, follow: $followSpeech, locate: locateSpeech, settings: { speechSettings = true })
                    .padding(.horizontal, 14).padding(.bottom, 8)
            } else if reader.loaded && reader.pdf != nil {
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
            if reader.loaded { _ = try? await library.store.updateDocumentInfo(id: reader.book.id, count: reader.count) }
            #if DEBUG
            if reader.loaded, ProcessInfo.processInfo.environment["READORA_SPEECH_SMOKE"] == "1" {
                reader.speech.start(reader.paragraphs, from: reader.position ?? 0, offset: reader.textOffset)
            }
            #endif
        }
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
        .onDisappear { reader.finish(); Task { await reader.saveProgress(); await library.refresh() } }
        .sheet(isPresented: $speechSettings) { MobileSpeechSettings(speech: reader.speech, store: library.store) }
        .onChange(of: reader.textOffset) { _, _ in reader.scheduleSave() }
        .sheet(isPresented: $appearance) { MobileAppearancePanel(library: library) }
        .sheet(isPresented: $assistant) { MobileAssistant(library: library, excerpt: excerpt, currentBookID: reader.book.id) }
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
                            Button(mark.quote.isEmpty ? "位置 \(mark.position + 1)" : mark.quote) { jump(to: mark.position, offset: mark.utf16Offset) }
                                .swipeActions { Button("删除", role: .destructive) { Task { await reader.removeBookmark(mark) } } }
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
    private func locateSpeech() {
        guard reader.speech.playing, let paragraph = reader.speech.spokenParagraph else { return }
        reader.textOffset = reader.speech.spokenRange.location
        reader.position = paragraph
        speechLocationRequest += 1
    }
    private func jump(to index: Int, offset: Int = 0) { reader.speech.stop(); reader.textOffset = offset; reader.position = TextContent.clampedPosition(index, count: reader.count); navigation = false }

}

private struct MobileScrollText: UIViewRepresentable {
    let text: String
    let heading: Bool
    let preferences: ReadingPreferences
    let spokenRange: NSRange?
    let highlight: Bool
    let follow: Bool
    let locationRequest: Int
    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.isScrollEnabled = false; view.isEditable = false; view.isSelectable = true
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.backgroundColor = .clear; view.adjustsFontForContentSizeCategory = false
        return view
    }
    func updateUIView(_ view: TextView, context: Context) {
        var attributes = MobilePagination.attributes(preferences, heading: heading)
        let font = attributes[.font] as! CTFont
        attributes[.font] = UIFont(name: CTFontCopyPostScriptName(font) as String, size: CTFontGetSize(font)) ?? UIFont.systemFont(ofSize: preferences.fontSize)
        attributes[.foregroundColor] = preferences.theme == .night ? UIColor(white: 0.9, alpha: 1) : UIColor(white: 0.09, alpha: 1)
        let value = NSMutableAttributedString(string: text, attributes: attributes)
        let range = spokenRange.flatMap { SpeechTextSegment.localIntersection($0, in: NSRange(location: 0, length: value.length)) }
        if highlight, let range { value.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.3), range: range) }
        if view.attributedText != value { view.attributedText = value }
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
    final class TextView: UITextView {
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
            guard window != nil, requestedRange == range, NSMaxRange(range) <= textStorage.length else { return }
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

private struct MobileSpeechBar: View {
    @Bindable var speech: MobileSpeech
    @Binding var follow: Bool
    let locate: () -> Void
    let settings: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle().fill(speech.paused ? Color.secondary : Color.accentColor).frame(width: 5, height: 5)
                        Text(speech.paused ? "已暂停" : speech.preparing ? "正在准备声音" : "正在朗读")
                        Text("·").foregroundStyle(.tertiary)
                        Text(speech.engineChoice == .system ? "系统音色" : speech.engineChoice.title)
                    }.font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    Text(speech.spokenPreview).font(.subheadline.weight(.medium)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: settings) {
                    Text(String(format: "%.2f×", speech.preferences.rate))
                        .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(.primary)
                        .padding(.horizontal, 10).frame(height: 34)
                        .background(.primary.opacity(0.045), in: Capsule())
                }.accessibilityLabel("朗读速度与音色设置")
                Button { speech.togglePause() } label: {
                    Image(systemName: speech.paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(.background)
                        .frame(width: 44, height: 44).background(.primary, in: Circle())
                }.accessibilityLabel(speech.paused ? "继续朗读" : "暂停朗读")
                Menu {
                    Button("音色与速度", systemImage: "slider.horizontal.3", action: settings)
                    Button("结束朗读", systemImage: "stop.circle", role: .destructive) { speech.stop() }
                } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.medium)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 44)
                }.accessibilityLabel("更多朗读操作")
            }
            Rectangle().fill(.primary.opacity(0.06)).frame(height: 0.5)
            HStack(spacing: 0) {
                action("回到朗读", icon: "location", active: false, action: locate)
                Divider().frame(height: 14)
                action("自动跟随", icon: "location.fill", active: follow) { follow.toggle() }
                Divider().frame(height: 14)
                action("文字高亮", icon: "highlighter", active: speech.preferences.highlightSpokenText) { speech.preferences.highlightSpokenText.toggle() }
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.07), radius: 18, y: 5)
        .buttonStyle(.plain)
    }
    private func action(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 11, weight: .medium))
                if title != "回到朗读" { Circle().fill(active ? Color.accentColor : Color.secondary.opacity(0.3)).frame(width: 4, height: 4) }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .frame(maxWidth: .infinity, minHeight: 32)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(title == "回到朗读" ? "" : active ? "已开启" : "已关闭")
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
    let paged: Bool
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

private struct MobileSpeechSettings: View {
    let speech: MobileSpeech
    let store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SpeechPreferences(maximumRate: 2)
    @State private var preview = MobileSpeech()
    @State private var draftEngine = MobileSpeechEngine.kokoro
    @State private var draftKokoroVoice = MobileKokoroVoice.female054
    @State private var draftMeloVoice = MobileMeloVoice.bilingualZh
    @State private var language = "zh-CN"
    @State private var error: String?
    private var allVoices: [AVSpeechSynthesisVoice] { MobileSpeech.recommendedVoices }
    private var languages: [String] {
        Set(allVoices.map(\.language)).sorted {
            if $0.hasPrefix("zh") != $1.hasPrefix("zh") { return $0.hasPrefix("zh") }
            return languageName($0) < languageName($1)
        }
    }
    private var voices: [AVSpeechSynthesisVoice] { allVoices.filter { $0.language == language } }
    private func languageName(_ code: String) -> String {
        Locale(identifier: "zh_CN").localizedString(forIdentifier: code) ?? code
    }
    private func detail(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality = voice.quality == .premium ? "优质版" : voice.quality == .enhanced ? "增强版" : "标准版（未安装高质量版）"
        let gender = voice.gender == .female ? "女声" : voice.gender == .male ? "男声" : ""
        return [languageName(voice.language), gender, quality].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("朗读引擎") {
                    Picker("引擎", selection: $draftEngine) {
                        ForEach(MobileSpeechEngine.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    if draftEngine == .kokoro {
                        Picker("普通话音色", selection: $draftKokoroVoice) {
                            ForEach(MobileKokoroVoice.allCases) { Text($0.title).tag($0) }
                        }
                        Text(MobileSpeech.kokoroInstalled ? "Kokoro v1.1 中文模型在手机本机运行，支持中英混读，正文不会发送到服务器。首次准备需要稍候；高亮以实际播放的短句为单位。" : "Kokoro模型尚未准备。请运行项目模型准备脚本并重新安装，或选择其他引擎。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if draftEngine == .melo {
                        Picker("Melo 音色", selection: $draftMeloVoice) {
                            ForEach(MobileMeloVoice.allCases) { Text($0.title).tag($0) }
                        }
                        Text(MobileSpeech.meloInstalled ? "MeloTTS 中文模型（sherpa-onnx vits-melo-tts-zh_en）本机运行，中英混读、采样率 44.1kHz。官方中文模型仅提供一个说话人，所以 Melo 引擎目前是一个音色；多音色可选 Kokoro 引擎。" : "MeloTTS 模型尚未准备。请运行 scripts/prepare-melotts.py 并重新安装，或选择其他引擎。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("朗读速度") {
                    Text(String(format: "%.2f×", draft.rate)).monospacedDigit()
                    Slider(value: $draft.rate, in: 0.5...max(0.5, min(8, draft.maximumRate)), step: 0.05).accessibilityLabel("朗读速度")
                    Stepper(value: $draft.maximumRate, in: 1...8, step: 0.25) {
                        Text(String(format: "最大速度 %.2f×", draft.maximumRate))
                    }
                    Button("恢复默认上限 2×") { draft.maximumRate = 2 }
                    Text("默认上限2×，可自定义至8×。超过2×采用保音调加速，速度越高越难辨清；不同音色的自然语速有所差异。保存后从当前段落应用，暂停状态保持暂停。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draftEngine == .system {
                Section("精选音色") {
                    Picker("语言与地区", selection: $language) {
                        ForEach(languages, id: \.self) { Text(languageName($0)).tag($0) }
                    }
                    Button {
                        draft.voiceIdentifier = nil
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("推荐普通话")
                                Text(MobileSpeech.preferredVoice.map { $0.name + " · " + detail($0) } ?? "系统默认中文音色")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if draft.voiceIdentifier == nil { Image(systemName: "checkmark") }
                        }
                    }.foregroundStyle(.primary)
                    ForEach(voices, id: \.identifier) { voice in
                        Button { draft.voiceIdentifier = voice.identifier } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(voice.name)
                                    Text(detail(voice)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if draft.voiceIdentifier == voice.identifier { Image(systemName: "checkmark") }
                            }
                        }.foregroundStyle(.primary)
                    }
                    Text("试听会暂停正在朗读的内容，可返回阅读页继续。每个地区只保留已安装音色中最高质量等级的最多3款，没有高质量版时仅留1款标准备用音色，并去除趣味音效；音质等级由系统提供。若只显示标准版，可到iPhone设置 → 辅助功能 → 朗读内容（或阅读与朗读）→ 声音，下载增强版或优质版后重新打开本页。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                Section {
                    Button(preview.playing ? "停止试听" : "试听所选音色", systemImage: preview.playing ? "stop.circle" : "play.circle") {
                        if preview.playing { preview.stop() }
                        else {
                            if speech.playing && !speech.paused { speech.togglePause() }
                            preview.configure(draft, engine: draftEngine, voice: draftKokoroVoice, meloVoice: draftMeloVoice, persistChoice: false)
                            let language = draftEngine != .system ? "zh" : draft.voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0)?.language } ?? "zh"
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
                                try await store.saveSpeechPreferences(draft)
                                UserDefaults.standard.set(true, forKey: "mobileSpeechMaximumConfigured")
                                speech.configure(draft, engine: draftEngine, voice: draftKokoroVoice, meloVoice: draftMeloVoice); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            .onChange(of: draft.maximumRate) { _, maximum in draft.rate = min(draft.rate, maximum) }
            .onChange(of: draftEngine) { _, _ in preview.stop() }
            .onChange(of: draftKokoroVoice) { _, _ in preview.stop() }
            .onChange(of: draftMeloVoice) { _, _ in preview.stop() }
            .onChange(of: draft.voiceIdentifier) { _, _ in preview.stop() }
            .onChange(of: draft.rate) { _, _ in preview.stop() }
            .onAppear {
                draft = speech.preferences; draftEngine = speech.engineChoice; draftKokoroVoice = speech.kokoroVoice; draftMeloVoice = speech.meloVoice
                if let voice = draft.voiceIdentifier.flatMap({ AVSpeechSynthesisVoice(identifier: $0) }) { language = voice.language }
                else { language = MobileSpeech.preferredVoice?.language ?? languages.first ?? "zh-CN" }
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
                                MobilePageText(page: page, paragraphs: reader.paragraphs, headings: headingIndices, preferences: library.preferences, spokenParagraph: reader.speech.playing && reader.speech.preferences.highlightSpokenText ? reader.speech.spokenParagraph : nil, spokenRange: reader.speech.spokenRange)
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
                    pages = result; paginationID = UUID(); failure = nil; paginating = false
                } catch is CancellationError {} catch { failure = error.localizedDescription; paginating = false }
            }
            .onChange(of: selection) { _, index in
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
    let spokenParagraph: Int?
    let spokenRange: NSRange
    func makeUIView(context: Context) -> Drawing { Drawing() }
    func updateUIView(_ view: Drawing, context: Context) {
        view.page = page; view.paragraphs = paragraphs; view.headings = headings; view.preferences = preferences
        view.spokenParagraph = spokenParagraph; view.spokenRange = spokenRange
        view.backgroundColor = .clear; view.isOpaque = false
        view.accessibilityLabel = page.slices.map { (paragraphs[$0.paragraph] as NSString).substring(with: $0.range) }.joined(separator: "\n")
        view.isAccessibilityElement = true; view.setNeedsDisplay()
    }
    final class Drawing: UIView {
        var page = MobilePage(slices: [], imageIndex: nil)
        var paragraphs: [String] = []
        var headings: Set<Int> = []
        var preferences = ReadingPreferences()
        var spokenParagraph: Int?
        var spokenRange = NSRange(location: 0, length: 0)
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
                if slice.paragraph == spokenParagraph,
                   let highlight = SpeechTextSegment.localIntersection(spokenRange, in: slice.range) {
                    let lines = CTFrameGetLines(frame) as! [CTLine]
                    var origins = [CGPoint](repeating: .zero, count: lines.count)
                    if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
                    context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.3).cgColor)
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
