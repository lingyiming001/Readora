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
    @State private var action = AIReadingAction.explain
    @State private var question = ""
    @State private var answer = ""
    @State private var message: String?
    @State private var working = false
    @State private var routeID: UUID?
    @State private var usedModel = ""
    @State private var operations: [String] = []
    @State private var pending: AIAppCommand?
    @State private var decision: CheckedContinuation<Bool, Never>?
    @State private var requestTask: Task<Void, Never>?
    private var route: AIModelProfile? { model.aiModels.route(routeID) }
    private var asksQuestion: Bool { action == .question || action == .operate }
    private var canSend: Bool {
        route != nil && (asksQuestion ? !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("AI 阅读与应用助手", systemImage: "sparkles").font(.title2.weight(.semibold))
                    Spacer()
                    Button("语音聊天", systemImage: "mic") { action = .question }.disabled(working)
                    Button("AI 设置…") { model.settingsSection = .ai; openSettings() }
                    Button("完成") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                }
                Picker("使用模型", selection: $routeID) {
                    Text("自动 · 第一个已启用模型").tag(Optional<UUID>.none)
                    ForEach(model.aiModels.enabled) { profile in Text(profile.title).tag(Optional(profile.id)) }
                }.disabled(working)
                Text(route.map { "当前路由：" + $0.title + " · " + $0.configuration.baseURL } ?? "没有已启用的模型，请前往AI设置添加。")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Text("原文预览（可留空进行自由问答）").font(.headline)
                    Spacer()
                    Button("当前段落") { context = model.currentAIParagraph }.disabled(model.currentAIParagraph.isEmpty || working)
                }
                TextEditor(text: $context).font(.system(size: 14)).scrollContentBackground(.hidden).padding(8)
                    .frame(height: 85).background(LibraryPalette.surface(model.preferences.theme), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("发送给AI的引用原文").disabled(working)
                    .onChange(of: context) { _, value in if value.count > 6000 { context = String(value.prefix(6000)) } }
                Picker("任务", selection: $action) {
                    ForEach(AIReadingAction.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).disabled(working)
                if asksQuestion {
                    TextField(action == .operate ? "例如：切换夜间主题，把字号设为28" : "例如：serendipity是什么意思？翻译成英文…", text: $question, axis: .vertical)
                        .lineLimit(2...3).textFieldStyle(.roundedBorder).disabled(working)
                        .onChange(of: question) { _, value in if value.count > 1200 { question = String(value.prefix(1200)) } }
                }
                if action == .question {
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
                        Text("点击开始才使用麦克风，每次最多45秒；优先使用设备端识别，不支持时可能使用 Apple 语音服务。识别后的文字和当前引用发给所选大模型，对话仅在本次面板中保留。语音问答不会执行应用操作。")
                            .font(.caption).foregroundStyle(.secondary)
                        if voice.listening { Text(voice.transcript.isEmpty ? "正在聆听…" : voice.transcript).font(.callout).textSelection(.enabled) }
                        if let error = voice.error { Text(error).font(.caption).foregroundStyle(.red) }
                        if !history.isEmpty {
                            DisclosureGroup("本次对话（\(history.count / 2)轮）") {
                                ForEach(Array(history.enumerated()), id: \.offset) { _, turn in
                                    Text((turn.role == "user" ? "你：" : "AI：") + (turn.content ?? "")).font(.caption).textSelection(.enabled)
                                }
                            }
                        }
                    }.padding(14).background(LibraryPalette.surface(model.preferences.theme), in: RoundedRectangle(cornerRadius: 10))
                }
                Text(action == .operate ? "点击执行后，模型可获取书名、阅读状态、书架、标记摘录及执行结果，并按你的要求操作Readora。引用原文不构成操作授权；清除/移除需确认。" : (action == .question ? "发送或语音自动发送时，会提交当前问题、预览原文和最近对话。回答可能有误，请结合原文判断。" : "点击发送才提交预览原文（最多6000字）和问题。回答可能有误，请结合原文判断。"))
                    .font(.caption).foregroundStyle(.secondary)
                if action == .operate {
                    DisclosureGroup("可操作的应用功能") {
                        Text("书库搜索/筛选/排序/网格列表、打开书籍、收藏/已读/回收站还原、书架创建/重命名/删除和归属、翻页和定位、目录/书签/高亮、主题/字体/字号/亮度/行段距、朗读/暂停/音色/速度/跟随、导入上限、模型配置复制/启停/排序和设置入口。导入文件由你在系统选择器中选择；模型不读取密钥，也不执行系统命令。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if working {
                        ProgressView().controlSize(.small)
                        Text("处理中…").font(.caption)
                        Button("停止") { cancel() }
                    } else {
                        Button(action == .operate ? "执行应用任务" : "发送", systemImage: "arrow.up.circle.fill") { send() }
                            .buttonStyle(.borderedProminent).disabled(!canSend || voice.listening || voice.authorizing)
                    }
                    Spacer()
                    if !answer.isEmpty {
                        Button("复制回答") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(answer, forType: .string) }
                    }
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
                if !usedModel.isEmpty { Text("本次模型：" + usedModel).font(.caption2).foregroundStyle(.secondary) }
                if !operations.isEmpty {
                    DisclosureGroup("应用操作记录（\(operations.count)）") {
                        ForEach(Array(operations.enumerated()), id: \.offset) { _, item in Text(item).font(.caption).textSelection(.enabled) }
                    }
                }
                Text(answer.isEmpty ? "回答将在这里显示。" : answer).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                    .foregroundStyle(answer.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading).padding(16)
                    .background(LibraryPalette.surface(model.preferences.theme), in: RoundedRectangle(cornerRadius: 10))
            }.padding(24)
        }.frame(width: 720, height: 730).readoraTheme(model.preferences.theme)
            .overlay(alignment: .topTrailing) { ExternalOperationConfirmation(model: model) }
            .task {
                context = model.aiContext
                voice.onTranscript = { text in
                    question = text
                    if voice.sendAfterRecording && action == .question && !working { send() }
                }
            }
            .onChange(of: action) { _, _ in voice.stop() }
            .onChange(of: route?.id) { _, _ in history = [] }
            .onChange(of: voice.readReplies) { _, enabled in if !enabled { voice.stopReply() } }
            .onChange(of: model.aiSettingsRequest) { _, _ in openSettings() }
            .onDisappear { cancel(); voice.stop(); voice.onTranscript = nil }
    }
    private func resolve(_ allowed: Bool) {
        let continuation = decision; decision = nil; pending = nil
        continuation?.resume(returning: allowed)
    }
    private func cancel() { voice.stop(); requestTask?.cancel(); resolve(false); working = false }
    private func send() {
        guard let profile = route else { return }
        cancel(); message = nil; answer = ""; operations = []; working = true; usedModel = profile.title
        let configuration = profile.configuration, excerpt = context, taskAction = action, taskQuestion = question
        requestTask = Task {
            do {
                let key = try await AICredentialStore.shared.key(account: configuration.credentialAccount) ?? ""
                let result: String
                if taskAction == .operate {
                    result = try await AIAppAgent.run(client: AIClient(), configuration: configuration, key: key, question: taskQuestion, excerpt: excerpt, perform: { command in
                        let bound = model.boundAICommand(command)
                        if bound.requiresConfirmation {
                            try Task.checkCancellation()
                            let allowed = await withCheckedContinuation { continuation in decision = continuation; pending = bound }
                            try Task.checkCancellation()
                            guard allowed else { throw AIAppAgentError.userDeclined }
                            return try await model.executeAICommand(bound, confirmed: true)
                        }
                        return try await model.executeAICommand(bound)
                    }, progress: { event in operations.append(event) })
                } else if taskAction == .question {
                    result = try await AIClient().chat(configuration: configuration, key: key, history: history, question: taskQuestion, excerpt: excerpt)
                } else {
                    let instruction = taskAction.instruction + (taskAction == .question ? "\n读者问题：" + taskQuestion : "")
                    result = try await AIClient().complete(configuration: configuration, key: key,
                        context: excerpt.isEmpty ? "未提供引用原文，请直接回答用户问题。" : excerpt, instruction: instruction)
                }
                try Task.checkCancellation(); answer = result
                if taskAction == .question {
                    history = AIConversation.appending(history, question: taskQuestion, answer: result)
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
