import SwiftUI
import ReadoraCore

struct MobileSettingsView: View {
    @Bindable var library: MobileLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var speech = MobileSpeech()
    @State private var speechSettings = false
    @State private var deleting: AIModelProfile?
    @State private var editing: AIModelProfile?
    @State private var limit = ImportSettings().maxBookSizeMB
    @State private var importStatus: String?
    var body: some View {
        NavigationStack {
            Form {
                Section("阅读外观") {
                    Picker("翻页方式", selection: $library.preferences.layout) {
                        Text("左右卷页").tag(ReadingLayout.pages)
                        Text("连续滚动").tag(ReadingLayout.scroll)
                    }
                    Picker("主题", selection: $library.preferences.theme) {
                        ForEach(ReaderTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("字体", selection: $library.preferences.font) {
                        ForEach(ReaderFont.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    LabeledContent("字号", value: "\(Int(library.preferences.fontSize))")
                    Slider(value: $library.preferences.fontSize, in: 14...40, step: 1).accessibilityLabel("字号")
                    LabeledContent("行距", value: "\(Int(library.preferences.lineSpacing))")
                    Slider(value: $library.preferences.lineSpacing, in: 2...18, step: 1).accessibilityLabel("行距")
                }
                Section("朗读") {
                    Button("音色、速度与高亮跟随", systemImage: "waveform") { speechSettings = true }
                }
                Section("MCP · 外部 AI 控制") {
                    Toggle("启用手机 MCP", isOn: $library.mcp.enabled)
                    Text("仅在应用前台提供局域网 HTTP 连接，使用独立访问令牌。请在可信网络使用；手机与Mac使用同一套应用操作工具，删除类仍需在手机确认。")
                        .font(.caption).foregroundStyle(.secondary)
                    if library.mcp.running {
                        Text(library.mcp.endpoint).font(.caption.monospaced()).textSelection(.enabled)
                        Button("复制 MCP 连接配置") { UIPasteboard.general.string = library.mcp.configuration }
                    }
                    if let error = library.mcp.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section("AI 模型") {
                    ForEach(library.registry.profiles) { profile in
                        Button { editing = profile } label: {
                            HStack { Text(profile.title); Spacer(); if profile.configuration.enabled { Image(systemName: "checkmark.circle.fill") } }
                        }
                        .contextMenu {
                            Button(profile.configuration.enabled ? "停用" : "启用") {
                                updateModels { next in if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) { next.profiles[index].configuration.enabled.toggle() } }
                            }
                            Button("设为首选") {
                                updateModels { next in if let index = next.profiles.firstIndex(where: { $0.id == profile.id }) { let value = next.profiles.remove(at: index); next.profiles.insert(value, at: 0) } }
                            }
                            Button("删除模型", role: .destructive) { deleting = profile }
                        }
                    }
                    Button("添加模型", systemImage: "plus") {
                        var configuration = AIConfiguration(); configuration.enabled = true
                        editing = AIModelProfile(configuration: configuration)
                    }.disabled(library.registry.profiles.count >= 30)
                    Text("使用第一个启用的模型。支持阅读问答、书库整理、阅读导航和朗读控制；删除操作需要具体确认。").font(.caption).foregroundStyle(.secondary)
                }
                Section("导入大小上限") {
                    TextField("1–2048 MB", value: $limit, format: .number).keyboardType(.numberPad)
                    Button("保存导入上限") {
                        Task {
                            do { try await library.store.saveImportSettings(ImportSettings(maxBookSizeMB: limit)); importStatus = "已保存为 \(limit) MB" }
                            catch { importStatus = error.localizedDescription }
                        }
                    }
                }
                if let importStatus { Text(importStatus).font(.caption).foregroundStyle(.secondary) }
                Section {
                    Text("手机和 Mac 书库独立保存，目前没有自动同步。可通过“文件”、AirDrop 或 iCloud Drive 选择书籍导入。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .modifier(MobileExternalApproval(library: library))
            .onChange(of: library.mcp.enabled) { _, enabled in
                UserDefaults.standard.set(enabled, forKey: "mobileMCPEnabled")
                if enabled { Task { await library.startMCP() } } else { library.mcp.stop(); library.resolveExternal(false) }
            }
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .sheet(isPresented: $speechSettings) { MobileSpeechSettings(speech: speech, store: library.store) }
            .task { if let preferences = try? await library.store.speechPreferences() { speech.configure(preferences) }; if let settings = try? await library.store.importSettings() { limit = settings.maxBookSizeMB } }
            .onDisappear { Task { await library.saveAppearance() } }
            .confirmationDialog("删除模型配置“\(deleting?.title ?? "")”？已保存的书籍保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除模型", role: .destructive) { let id = deleting?.id; deleting = nil; updateModels { next in next.profiles.removeAll { $0.id == id } } }
            }
            .sheet(item: $editing) { profile in MobileModelEditor(profile: profile, library: library) }
        }
    }
    private func updateModels(_ change: (inout AIModelRegistry) -> Void) {
        var next = library.registry; change(&next)
        Task {
            do { try next.validate(); try await library.store.saveAIModelRegistry(next); library.registry = next }
            catch { importStatus = error.localizedDescription }
        }
    }
}

struct MobileModelEditor: View {
    let profile: AIModelProfile
    @Bindable var library: MobileLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var configuration = AIConfiguration()
    @State private var key = ""
    @State private var message: String?
    @State private var saving = false
    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("显示名称（可选）", text: $name)
                    Toggle("启用此模型", isOn: $configuration.enabled)
                }
                Section("服务连接") {
                    Picker("供应商", selection: Binding(get: { configuration.provider }, set: { provider in
                        configuration.provider = provider; configuration.baseURL = provider.baseURL
                        configuration.model = ""; key = ""
                    })) {
                        ForEach(AIProvider.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("API 地址", text: $configuration.baseURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: configuration.baseURL) { _, _ in key = "" }
                    TextField("模型 ID", text: $configuration.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("API Key") {
                    SecureField("输入密钥；留空保留已保存的密钥", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("密钥仅存于本机钥匙串。请使用 HTTPS 云服务；手机的 localhost 不指向你的 Mac。").font(.caption).foregroundStyle(.secondary)
                }
                if let message { Section { Text(message).foregroundStyle(.red) } }
            }.disabled(saving)
            .navigationTitle("模型配置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { key = ""; dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }.disabled(saving)
                }
            }
            .onAppear { name = profile.name; configuration = profile.configuration }
        }.interactiveDismissDisabled(saving)
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            try configuration.validate(requireModel: configuration.enabled)
            var registry = library.registry
            let updated = AIModelProfile(id: profile.id, name: String(name.prefix(100)), configuration: configuration)
            if let i = registry.profiles.firstIndex(where: { $0.id == profile.id }) { registry.profiles[i] = updated }
            else { registry.profiles.append(updated) }
            try registry.validate()
            if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await AICredentialStore.shared.save(key, account: configuration.credentialAccount)
            }
            try await library.store.saveAIModelRegistry(registry)
            library.registry = registry; key = ""; dismiss()
        } catch { message = error.localizedDescription }
    }
}
