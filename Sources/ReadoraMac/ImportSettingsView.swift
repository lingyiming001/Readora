import SwiftUI
import ReadoraCore

struct ImportLimitsSettings: View {
    @Bindable var model: AppModel
    @State private var limitText = String(ImportSettings.defaultMaxBookSizeMB)
    @State private var isSaving = false
    @State private var message: String?
    private var limit: Int? { Int(limitText.trimmingCharacters(in: .whitespaces)) }
    private var valid: Bool { limit.map { ImportSettings.allowedRange.contains($0) } ?? false }
    var body: some View {
        Form {
            Section("书籍导入") {
                HStack {
                    Text("单本书籍大小上限")
                    Spacer()
                    TextField("大小", text: $limitText)
                        .multilineTextAlignment(.trailing).frame(width: 90)
                        .accessibilityLabel("单本书籍大小上限，单位 MB")
                    Text("MB").foregroundStyle(.secondary)
                }
                Text("默认 200 MB，可设置为 1–2048 MB。新设置对后续导入生效，不影响已导入的书籍。")
                    .font(.caption).foregroundStyle(.secondary)
                if !valid { Text("请输入 1–2048 之间的整数。").foregroundStyle(.red).font(.caption) }
                HStack {
                    Button("恢复默认值") { limitText = String(ImportSettings.defaultMaxBookSizeMB); message = nil }
                    Spacer()
                    Button(isSaving ? "正在保存…" : "保存设置") {
                        guard let limit, valid else { return }
                        isSaving = true
                        Task {
                            let saved = await model.saveImportSettings(ImportSettings(maxBookSizeMB: limit))
                            message = saved ? "设置已保存" : "保存失败，请重试"
                            isSaving = false
                        }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!valid || isSaving)
                }
                if let message { Text(message).font(.caption).accessibilityLabel(message) }
            }
        }.readoraForm(model.preferences.theme)
            .task {
                await model.loadImportSettings()
                limitText = String(model.importSettings.maxBookSizeMB)
            }
            .onChange(of: limitText) { _, _ in message = nil }
    }
}

struct ImportSettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        TabView(selection: $model.settingsSection) {
            ApplicationThemeSettings(model: model).tag(SettingsSection.appearance).tabItem { Label("外观", systemImage: "circle.lefthalf.filled") }
            ImportLimitsSettings(model: model).tag(SettingsSection.importing).tabItem { Label("导入", systemImage: "square.and.arrow.down") }
            Form { ReaderAppearanceControls(model: model) }.readoraForm(model.preferences.theme)
                .tag(SettingsSection.reading).tabItem { Label("阅读", systemImage: "textformat") }
            SpeechSettingsView(model: model).tag(SettingsSection.speech).tabItem { Label("朗读", systemImage: "waveform") }
            AISettingsView(model: model).tag(SettingsSection.ai).tabItem { Label("AI", systemImage: "sparkles") }
            MCPSettingsView(model: model).tag(SettingsSection.mcp).tabItem { Label("MCP", systemImage: "point.3.connected.trianglepath.dotted") }
        }.frame(width: 640, height: 660)
        .overlay(alignment: .topTrailing) { ExternalOperationConfirmation(model: model) }
        .readoraTheme(model.preferences.theme)
    }
}
