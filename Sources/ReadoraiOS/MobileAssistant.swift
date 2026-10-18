import SwiftUI
import ReadoraCore

struct MobileAssistant: View {
    @Bindable var library: MobileLibrary
    let excerpt: String
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer = ""
    @State private var history: [AIChatMessage] = []
    @State private var working = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if library.registry.defaultProfile == nil {
                            ContentUnavailableView("先添加 AI 模型", systemImage: "sparkles", description: Text("在书库菜单的设置中配置服务、模型与 API Key。"))
                        } else if answer.isEmpty && !working {
                            Text(excerpt.isEmpty ? "想了解什么？" : "可以解释、总结或翻译当前段落。")
                                .foregroundStyle(.secondary).padding(.vertical, 30)
                        } else { Text(answer).textSelection(.enabled) }
                        if let error { Text(error).foregroundStyle(.red) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                VStack(alignment: .leading, spacing: 12) {
                    TextField("输入问题…", text: $question, axis: .vertical).lineLimit(3...6).disabled(working)
                    HStack {
                        if !excerpt.isEmpty {
                            Button("解释") { question = "解释当前引用" }
                            Button("摘要") { question = "概括当前引用" }
                        }
                        Spacer()
                        if working {
                            ProgressView()
                            Button("停止") { task?.cancel(); working = false }
                        } else {
                            Button("发送", systemImage: "arrow.up.circle.fill") { send() }
                                .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || library.registry.defaultProfile == nil)
                        }
                    }
                    Text(excerpt.isEmpty ? "发送问题与最近对话给所选服务" : "发送当前段落、问题与最近对话给所选服务")
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(16).background(.regularMaterial)
            }
            .navigationTitle("AI 助手").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { task?.cancel(); dismiss() } } }
            .onChange(of: question) { _, value in if value.count > 1200 { question = String(value.prefix(1200)) } }
            .onDisappear { task?.cancel() }
        }
    }
    private func send() {
        guard let profile = library.registry.defaultProfile else { return }
        task?.cancel(); working = true; error = nil; answer = ""
        let prompt = question
        task = Task {
            do {
                let key = try await AICredentialStore.shared.key(account: profile.configuration.credentialAccount) ?? ""
                let reply = try await AIClient().chat(configuration: profile.configuration, key: key, history: history, question: prompt, excerpt: String(excerpt.prefix(6000)))
                try Task.checkCancellation()
                answer = reply; history = AIConversation.appending(history, question: prompt, answer: reply); question = ""
            } catch is CancellationError {} catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { working = false }
        }
    }
}
