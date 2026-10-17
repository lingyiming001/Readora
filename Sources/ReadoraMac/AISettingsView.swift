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
        VStack(spacing: 0) {
            HStack {
                Button("返回模型列表", systemImage: "chevron.left") { closeEditor() }
                    .buttonStyle(.borderless)
                Spacer()
                if working {
                    ProgressView().controlSize(.small)
                    if !saving { Button("停止") { requestTask?.cancel(); working = false } }
                }
                Button("取消") { closeEditor() }.disabled(saving).keyboardShortcut(.cancelAction)
                Button(isExisting ? "保存更改" : "添加模型") { save() }
                    .buttonStyle(.borderedProminent).disabled(working)
                    .keyboardShortcut(.defaultAction)
            }.controlSize(.regular).padding(.horizontal, 24).padding(.top, 16)
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text(isExisting ? "编辑模型" : "添加模型").font(.system(size: 22, weight: .semibold))
                    Text("连接你的 AI 服务，用于阅读问答与应用操作。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    editorCard("基本信息", icon: "slider.horizontal.3") {
                        field("显示名称", hint: "可选，用于区分不同用途的模型") {
                            TextField("例如：日常阅读、深度思考", text: $name)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("启用模型").font(.callout.weight(.medium))
                                Text("启用后可在 AI 助手中使用").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("启用模型", isOn: $draft.enabled).labelsHidden().toggleStyle(.switch)
                        }
                    }
                    editorCard("服务连接", icon: "network") {
                        field("服务提供商") {
                            Picker("服务提供商", selection: Binding(get: { draft.provider }, set: { provider in
                                draft.provider = provider; draft.baseURL = provider.baseURL
                                draft.model = ""; apiKey = ""; showKey = false; models = []; message = nil
                            })) {
                                ForEach(AIProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                        }
                        field("API 地址", hint: "Chat Completions 兼容接口；请使用账号对应的服务地域。") {
                            TextField("https://服务地址/v1", text: $draft.baseURL)
                                .textContentType(.URL).autocorrectionDisabled()
                        }
                        field("模型 ID") {
                            TextField("填写服务提供商的模型 ID", text: $draft.model).autocorrectionDisabled()
                        }
                        HStack {
                            Button("获取模型列表", systemImage: "arrow.down.circle") { run(.models) }
                            if !models.isEmpty {
                                Menu("选择模型（\(models.count)）") {
                                    ForEach(models, id: \.self) { name in Button(name) { draft.model = name } }
                                }
                            }
                            Spacer()
                            Button("测试连接", systemImage: "bolt.horizontal.circle") { run(.test) }
                        }.controlSize(.regular)
                    }
                    editorCard("访问密钥", icon: "key.horizontal") {
                        HStack(spacing: 10) {
                            Group {
                                if showKey { TextField("输入 API Key", text: $apiKey) }
                                else { SecureField("输入 API Key", text: $apiKey) }
                            }
                            .textFieldStyle(.plain).autocorrectionDisabled()
                            .accessibilityLabel("AI API Key")
                            Button { showKey.toggle() } label: {
                                Image(systemName: showKey ? "eye.slash" : "eye").frame(width: 24, height: 24)
                            }.buttonStyle(.borderless)
                                .help(showKey ? "隐藏 API Key" : "显示 API Key")
                                .accessibilityLabel(showKey ? "隐藏 API Key" : "显示 API Key")
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "lock.shield")
                            Text(hasSavedKey ? "已保存密钥。留空保留，输入新值替换；密钥仅存于系统钥匙串。" : "密钥按服务与地址保存在系统钥匙串中，不写入书库文件。Ollama 本机服务通常可留空。")
                        }.font(.caption).foregroundStyle(.secondary)
                        if hasSavedKey {
                            Button("移除已保存的密钥…", role: .destructive) { removeKey = true }
                                .font(.caption).buttonStyle(.borderless)
                        }
                    }
                    if let message {
                        Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(24).disabled(working)
            }
        }.readoraTheme(model.preferences.theme)
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
    private func closeEditor() {
        guard !saving else { return }
        requestTask?.cancel()
        working = false
        apiKey = ""
        showKey = false
        onCancel()
    }

    private var isExisting: Bool { model.aiModels.profiles.contains { $0.id == profile.id } }

    private func editorCard<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .background(LibraryPalette.surface(model.preferences.theme), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func field<Content: View>(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            content().textFieldStyle(.roundedBorder).controlSize(.large)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(title)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
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
                    .frame(width: 640, height: 680).readoraTheme(model.preferences.theme)
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
