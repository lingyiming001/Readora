import SwiftUI
import AppKit
import ReadoraCore

struct AIReadingAssistant: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var voice = VoiceConversation()
    @State private var history: [AIChatMessage] = []
    @State private var context = ""
    @State private var showVoice = false
    @State private var question = ""
    @State private var answer = ""
    @State private var message: String?
    @State private var working = false
    @State private var routeID: UUID?
    @State private var usedModel = ""
    @State private var pending: AIAppCommand?
    @State private var decision: CheckedContinuation<Bool, Never>?
    @State private var requestTask: Task<Void, Never>?
    private var route: AIModelProfile? { model.aiModels.route(routeID) }
    private var canSend: Bool {
        route != nil && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(spacing: 0) {
                HStack {
                    Label("AI 助手", systemImage: "sparkles").font(.title2.weight(.semibold))
                    Spacer()
                    Button("语音", systemImage: "mic") { showVoice.toggle() }.disabled(working)
                    Button("AI 设置…") { model.settingsSection = .ai; openSettings() }
                    Button("完成") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                DisclosureGroup(route.map { "模型 · " + $0.title } ?? "选择模型") {
                    Picker("使用模型", selection: $routeID) {
                        Text("自动选择").tag(Optional<UUID>.none)
                        ForEach(model.aiModels.enabled) { profile in Text(profile.title).tag(Optional(profile.id)) }
                    }.disabled(working)
                }
                if route == nil {
                    Text("请在 AI 设置中添加并启用模型。").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(context.isEmpty ? "添加引用原文" : "引用原文 · \(context.count)字") {
                    HStack {
                        Button("当前段落") { context = model.currentAIParagraph }.disabled(model.currentAIParagraph.isEmpty || working)
                        Button("清除引用") { context = "" }.disabled(working)
                    }
                    TextEditor(text: $context).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8)
                        .frame(height: 85)
                        .accessibilityLabel("发送给AI的引用原文").disabled(working)
                        .onChange(of: context) { _, value in if value.count > 6000 { context = String(value.prefix(6000)) } }
                }
                if !answer.isEmpty {
                    Text(answer).font(.system(size: 15)).lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else if !working {
                    VStack(spacing: 10) {
                        Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(.secondary)
                        Text("想了解什么，或想做什么？").font(.headline)
                        Text("直接提问，或让我调整阅读与书库。").font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                if showVoice {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("语音聊天", systemImage: "waveform").font(.headline)
                            Spacer()
                            Picker("识别语言", selection: $voice.locale) {
                                Text("中文").tag("zh-CN"); Text("English").tag("en-US")
                            }.frame(width: 180).disabled(voice.listening || voice.authorizing)
                        }
                        HStack {
                            if voice.listening {
                                Button("结束录音并识别", systemImage: "stop.circle.fill") { voice.finishRecording() }
                            } else {
                                Button(voice.authorizing ? "等待麦克风授权…" : "开始说话", systemImage: "mic.fill") {
                                    model.speech.stop()
                                    Task { await voice.start() }
                                }.disabled(working || voice.authorizing || route == nil)
                            }
                            if voice.speaking { Button("打断回答") { voice.stopReply() } }
                            Spacer()
                            Button("新对话") { cancel(); voice.stop(); history = []; answer = ""; question = "" }
                        }
                        Toggle("识别完成后自动发送", isOn: $voice.sendAfterRecording).disabled(working)
                        Toggle("朗读 AI 回答", isOn: $voice.readReplies)
                        Text("点击开始才使用麦克风，每次最多45秒；优先使用设备端识别，不支持时可能使用 Apple 语音服务。识别后的文字和当前引用发给所选大模型，对话仅在本次面板中保留。AI 会根据你的话回答或操作应用。")
                            .font(.caption).foregroundStyle(.secondary)
                        if voice.listening { Text(voice.transcript.isEmpty ? "正在聆听…" : voice.transcript).font(.callout).textSelection(.enabled) }
                        if let error = voice.error { Text(error).font(.caption).foregroundStyle(.red) }
                    }.padding(14).background(LibraryPalette.surface(model.preferences.theme), in: RoundedRectangle(cornerRadius: 10))
                }
                if let pending {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("确认执行此操作？").font(.headline)
                        Text(model.aiCommandSummary(pending)).font(.caption).textSelection(.enabled)
                        HStack {
                            Button("确认执行", role: .destructive) { resolve(true) }
                            Button("拒绝") { resolve(false) }
                        }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                if let message { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }

                    }.padding(20)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                composer
        }.frame(width: 680, height: 650).readoraTheme(model.preferences.theme)
            .overlay(alignment: .topTrailing) { ExternalOperationConfirmation(model: model) }
            .task {
                context = model.aiContext
                voice.onTranscript = { text in
                    question = text
                    if voice.sendAfterRecording && !working { send() }
                }
            }
            .onChange(of: showVoice) { _, shown in if !shown { voice.stop() } }
            .onChange(of: route?.id) { _, _ in history = [] }
            .onChange(of: voice.readReplies) { _, enabled in if !enabled { voice.stopReply() } }
            .onChange(of: model.aiSettingsRequest) { _, _ in openSettings() }
            .onDisappear { cancel(); voice.stop(); voice.onTranscript = nil }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("输入问题或告诉我想做什么…", text: $question, axis: .vertical)
                    .font(.system(size: 15)).textFieldStyle(.plain)
                    .lineLimit(3...6).frame(minHeight: 66, alignment: .topLeading)
                    .disabled(working)
                    .accessibilityLabel("AI消息输入框")
                    .onChange(of: question) { _, value in
                        if value.count > 1200 { question = String(value.prefix(1200)) }
                    }
                HStack(spacing: 10) {
                    if !context.isEmpty {
                        Button("解释") { question = "解释这段原文" }
                        Button("摘要") { question = "概括这段原文" }
                        Button("翻译") { question = "翻译这段原文，中文译成英文，其他语言译成中文" }
                    }
                    Spacer()
                    if working {
                        ProgressView().controlSize(.small)
                        Button("停止") { cancel() }
                    } else {
                        Button { send() } label: {
                            Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.borderedProminent).clipShape(Circle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityLabel("发送")
                        .help("发送（⌘Return）")
                        .disabled(!canSend || voice.listening || voice.authorizing)
                    }
                }.buttonStyle(.borderless).disabled(working && pending != nil)
            }
            .padding(16)
            .background(LibraryPalette.surface(model.preferences.theme), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            HStack {
                Text("自动执行应用操作 · 删除前确认").font(.caption2).foregroundStyle(.secondary)
                    .help("发送问题、引用和最近对话，必要时查询书库信息。")
                Spacer()
                if !answer.isEmpty {
                    Button("复制回复") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    }
                }
                Button("清空对话") {
                    cancel(); history = []; answer = ""; question = ""; message = nil
                }
            }.font(.caption).buttonStyle(.borderless)
        }.padding(20)
    }
    private func resolve(_ allowed: Bool) {
        let continuation = decision; decision = nil; pending = nil
        continuation?.resume(returning: allowed)
    }
    private func cancel() { voice.stop(); requestTask?.cancel(); resolve(false); working = false }
    private func send() {
        guard let profile = route else { return }
        cancel(); message = nil; answer = ""; working = true; usedModel = profile.title
        let configuration = profile.configuration, excerpt = context, taskQuestion = question
        requestTask = Task {
            do {
                let key = try await AICredentialStore.shared.key(account: configuration.credentialAccount) ?? ""
                let result: String
                result = try await AIAppAgent.run(client: AIClient(), configuration: configuration, key: key, question: taskQuestion, excerpt: excerpt, history: history, perform: { command in
                    let bound = model.boundAICommand(command)
                    if bound.requiresConfirmation {
                        try Task.checkCancellation()
                        let allowed = await withCheckedContinuation { continuation in decision = continuation; pending = bound }
                        try Task.checkCancellation()
                        guard allowed else { throw AIAppAgentError.userDeclined }
                        return try await model.executeAICommand(bound, confirmed: true)
                    }
                    return try await model.executeAICommand(bound)
                }, progress: { _ in })
                try Task.checkCancellation(); answer = result
                history = AIConversation.appending(history, question: taskQuestion, answer: result)
                question = ""
                if showVoice {
                    model.speech.stop()
                    voice.speakReply(result, voice: model.speechPreferences.voiceIdentifier)
                }
            } catch is CancellationError {} catch { if !Task.isCancelled { message = error.localizedDescription } }
            if !Task.isCancelled { working = false }
        }
    }
}

extension AppModel {
    var currentAIParagraph: String {
        if paragraphs.indices.contains(position) { return String(paragraphs[position].prefix(6000)) }
        if let page = pdf?.page(at: position), let text = page.string { return String(text.prefix(6000)) }
        return ""
    }
    func presentAI(index: Int? = nil, range: NSRange? = nil) {
        if let index, let range, paragraphs.indices.contains(index) {
            let source = paragraphs[index] as NSString
            if range.location >= 0, range.location <= source.length {
                let count = min(range.length, source.length - range.location)
                aiContext = String(source.substring(with: NSRange(location: range.location, length: count)).prefix(6000))
            }
        } else { aiContext = selectedAIText.isEmpty ? currentAIParagraph : selectedAIText }
        showAIAssistant = true
    }
}
