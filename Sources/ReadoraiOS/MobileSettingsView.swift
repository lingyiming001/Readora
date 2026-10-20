import SwiftUI
import ReadoraCore

struct MobileSettingsView: View {
    @Bindable var library: MobileLibrary
    @Environment(\.dismiss) private var dismiss
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
                Section("AI 模型") {
                    ForEach(library.registry.profiles) { profile in
                        Button { editing = profile } label: {
                            HStack { Text(profile.title); Spacer(); if profile.configuration.enabled { Image(systemName: "checkmark.circle.fill") } }
                        }
                    }
                    Button("添加模型", systemImage: "plus") {
                        var configuration = AIConfiguration(); configuration.enabled = true
                        editing = AIModelProfile(configuration: configuration)
                    }.disabled(library.registry.profiles.count >= 30)
                    Text("使用第一个启用的模型。手机端提供阅读问答；不执行 Mac 应用操作。").font(.caption).foregroundStyle(.secondary)
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
            .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { if let settings = try? await library.store.importSettings() { limit = settings.maxBookSizeMB } }
            .onDisappear { Task { await library.saveAppearance() } }
            .sheet(item: $editing) { profile in MobileModelEditor(profile: profile, library: library) }
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
