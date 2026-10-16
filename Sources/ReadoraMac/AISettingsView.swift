import SwiftUI
import ReadoraCore

struct AIModelEditor: View {
    let profile: AIModelProfile
    let onSave: (AIModelProfile) async throws -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @Bindable var model: AppModel
    @State private var draft = AIConfiguration()
    @State private var apiKey = ""
    @State private var showKey = false
    @State private var hasSavedKey = false
    @State private var message: String?
    @State private var models: [String] = []
    @State private var working = false
    @State private var removeKey = false
    @State private var saving = false
    @State private var requestTask: Task<Void, Never>?
    var body: some View {
        Form {
            Section("模型名称") {
                TextField("显示名称", text: $name, prompt: Text("例如：日常阅读、翻译模型"))
                Button("返回模型列表") { onCancel() }.disabled(saving)
            }
            Section("阅读 AI") {
                Toggle("启用此模型", isOn: $draft.enabled).disabled(working)
                Text("解释选文、提炼摘要、翻译与阅读问答。只有点击发送才会将面板中预览的原文发给所选服务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("模型连接") {
                Picker("供应商", selection: Binding(get: { draft.provider }, set: { provider in
                    draft.provider = provider; draft.baseURL = provider.baseURL
                    draft.model = ""; apiKey = ""; showKey = false; models = []; message = nil
                })) {
                    ForEach(AIProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(working)
                TextField("API 地址", text: $draft.baseURL, prompt: Text("https://服务地址/v1"))
                    .textContentType(.URL).autocorrectionDisabled().disabled(working)
                Text("使用 Chat Completions 兼容接口。通义预设为北京地域，可按账号地域修改。Ollama 需在本机安装、启动并下载模型。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("模型 ID", text: $draft.model, prompt: Text("填写供应商提供的模型名称"))
                    .autocorrectionDisabled().disabled(working)
                HStack {
                    Button("获取模型列表") { run(.models) }
                    if !models.isEmpty {
                        Menu("选择模型（\(models.count)）") {
                            ForEach(models, id: \.self) { name in Button(name) { draft.model = name } }
                        }
                    }
                    Spacer()
                    Button("测试连接") { run(.test) }
                }.disabled(working)
            }
            Section("API Key") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Group {
                            if showKey {
                                TextField("", text: $apiKey, prompt: Text("输入 API Key"))
                            } else {
                                SecureField("", text: $apiKey, prompt: Text("输入 API Key"))
                            }
                        }.labelsHidden().textFieldStyle(.roundedBorder).controlSize(.large)
                            .frame(minWidth: 240, maxWidth: .infinity, minHeight: 30)
                            .layoutPriority(1).autocorrectionDisabled().disabled(saving)
                            .accessibilityLabel("AI API Key")
                        Button { showKey.toggle() } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }.buttonStyle(.plain).disabled(saving)
                            .help(showKey ? "隐藏 API Key" : "显示 API Key")
                            .accessibilityLabel(showKey ? "隐藏 API Key" : "显示 API Key")
                    }
                    if hasSavedKey { Text("已保存密钥；留空可保留，输入新值可替换。").font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                Text(hasSavedKey ? "此供应商与地址已有密钥。密钥只存于系统钥匙串。" : "按供应商与 API 地址分别保管密钥，不写入书库文件。")
                    .font(.caption).foregroundStyle(.secondary)
                if hasSavedKey { Button("移除此地址的密钥…", role: .destructive) { removeKey = true }.disabled(working) }
            }
            Section {
                HStack {
                    if working { ProgressView().controlSize(.small); Button("取消") { requestTask?.cancel(); working = false }.disabled(saving) }
                    Spacer()
                    Button("保存此模型") { save() }.buttonStyle(.borderedProminent).disabled(working)
                }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
        }.readoraForm(model.preferences.theme)
            .task { draft = profile.configuration; name = profile.name }
            .task(id: draft.credentialAccount) {
                let account = draft.credentialAccount
                do {
                    let present = try await AICredentialStore.shared.key(account: account) != nil
                    if draft.credentialAccount == account { hasSavedKey = present }
                } catch { if draft.credentialAccount == account { hasSavedKey = false; message = error.localizedDescription } }
            }
            .onChange(of: draft.baseURL) { _, _ in apiKey = ""; showKey = false; hasSavedKey = false; models = []; message = nil; requestTask?.cancel(); working = false }
            .onDisappear { requestTask?.cancel(); apiKey = ""; showKey = false; if !saving { working = false } }
            .confirmationDialog("移除此地址的 API Key？", isPresented: $removeKey, titleVisibility: .visible) {
                Button("移除密钥", role: .destructive) {
                    Task {
                        do { try await AICredentialStore.shared.remove(account: draft.credentialAccount); hasSavedKey = false; apiKey = ""; message = "密钥已移除" }
                        catch { message = error.localizedDescription }
                    }
                }
                Button("取消", role: .cancel) {}
            }
    }
    private enum Operation { case models, test }
    private func run(_ operation: Operation) {
        requestTask?.cancel(); working = true; message = nil
        let configuration = draft, enteredKey = apiKey
        requestTask = Task {
            do {
                let key = try await resolvedKey(configuration: configuration, entered: enteredKey)
                let client = AIClient()
                if operation == .models {
                    let available = try await client.models(configuration: configuration, key: key)
                    try Task.checkCancellation(); models = available
                    message = available.isEmpty ? "未返回模型，可手动填写模型 ID。" : "已获取模型列表，选择模型后保存。"
                } else {
                    _ = try await client.complete(configuration: configuration, key: key, context: "连接测试，不含书籍内容。", instruction: "请只回复 OK。")
                    try Task.checkCancellation(); message = "连接成功，模型已返回有效回答。"
                }
            } catch is CancellationError {} catch { if !Task.isCancelled { message = error.localizedDescription } }
            if !Task.isCancelled { working = false }
        }
    }
    private func save() {
        working = true; saving = true; message = nil
        let configuration = draft, enteredKey = apiKey
        requestTask = Task {
            do {
                try configuration.validate(requireModel: configuration.enabled)
                if !enteredKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try await AICredentialStore.shared.save(enteredKey, account: configuration.credentialAccount)
                }
                try await onSave(AIModelProfile(id: profile.id, name: String(name.prefix(100)), configuration: configuration))
                apiKey = ""
                hasSavedKey = try await AICredentialStore.shared.key(account: configuration.credentialAccount) != nil
                message = "模型已保存"
            } catch { message = error.localizedDescription }
            working = false; saving = false
        }
    }
    private func resolvedKey(configuration: AIConfiguration, entered: String) async throws -> String {
        let key = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? try await AICredentialStore.shared.key(account: configuration.credentialAccount) ?? "" : key
    }
}


struct AISettingsView: View {
    @Bindable var model: AppModel
    @State private var editing: AIModelProfile?
    @State private var removing: AIModelProfile?
    @State private var message: String?
    var body: some View {
        Form {
            Section("大模型列表") {
                Text("默认使用列表中第一个已启用的模型。可调整顺序，在助手中也可手动选择；请求失败不会静默切换供应商。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(model.aiModels.profiles.enumerated()), id: \.element.id) { index, profile in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Toggle(profile.title, isOn: Binding(get: {
                                model.aiModels.profiles.first { $0.id == profile.id }?.configuration.enabled ?? false
                            }, set: { value in update { registry in
                                if let i = registry.profiles.firstIndex(where: { $0.id == profile.id }) { registry.profiles[i].configuration.enabled = value }
                            } })).toggleStyle(.switch)
                            if model.aiModels.defaultProfile?.id == profile.id { Text("默认路由").font(.caption2).foregroundStyle(.tint) }
                        }
                        Text(profile.configuration.provider.title + " · " + profile.configuration.model).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("编辑") { editing = profile }
                            Button("上移", systemImage: "arrow.up") { move(profile.id, by: -1) }.disabled(index == 0)
                            Button("下移", systemImage: "arrow.down") { move(profile.id, by: 1) }.disabled(index + 1 == model.aiModels.profiles.count)
                            Spacer()
                            Button("移除…", role: .destructive) { removing = profile }
                        }.font(.caption)
                    }.padding(.vertical, 6)
                }
                if model.aiModels.profiles.isEmpty { Text("还未添加模型。原有模型配置会在升级时自动保留。") }
                Button("添加大模型", systemImage: "plus") {
                    var configuration = AIConfiguration(); configuration.enabled = true
                    editing = AIModelProfile(configuration: configuration)
                }.disabled(model.aiModels.profiles.count >= 30)
            }
            if let message { Section { Text(message).font(.caption).foregroundStyle(.red) } }
        }.readoraForm(model.preferences.theme)
            .sheet(item: $editing) { profile in
                AIModelEditor(profile: profile, onSave: { saved in
                    try await model.updateAIModels { registry in
                        if let i = registry.profiles.firstIndex(where: { $0.id == saved.id }) { registry.profiles[i] = saved }
                        else { registry.profiles.append(saved) }
                    }
                    editing = nil
                }, onCancel: { editing = nil }, model: model)
                    .frame(width: 580, height: 630).readoraTheme(model.preferences.theme)
            }
            .confirmationDialog("移除此模型配置？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("移除模型", role: .destructive) {
                    guard let id = removing?.id else { return }
                    update { $0.profiles.removeAll { $0.id == id } }; removing = nil
                }
                Button("取消", role: .cancel) { removing = nil }
            } message: { Text("同一供应商和地址可能共用密钥，因此此操作保留钥匙串中的密钥。") }
    }
    private func update(_ change: @escaping (inout AIModelRegistry) -> Void) {
        Task { do { try await model.updateAIModels(change) } catch { message = error.localizedDescription } }
    }
    private func move(_ id: UUID, by amount: Int) {
        update { registry in
            if let i = registry.profiles.firstIndex(where: { $0.id == id }), registry.profiles.indices.contains(i + amount) { registry.profiles.swapAt(i, i + amount) }
        }
    }
}

extension AppModel {
    func updateAIModels(_ change: (inout AIModelRegistry) -> Void) async throws {
        let old = aiModels
        var updated = old; change(&updated); try updated.validate()
        aiModels = updated
        do { try await store.saveAIModelRegistry(updated) }
        catch { if aiModels == updated { aiModels = old }; throw error }
    }
}
