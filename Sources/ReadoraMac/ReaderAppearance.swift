import SwiftUI
import ReadoraCore
import ReadoraRendering
import AVFoundation

extension AppModel {
    func preferenceBinding<Value>(_ key: WritableKeyPath<ReadingPreferences, Value>) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: key] }, set: { value in
            var preferences = self.preferences; preferences[keyPath: key] = value; self.changePreferences(preferences)
        })
    }
}

struct ReaderAppearanceControls: View {
    @Bindable var model: AppModel
    var body: some View {
        Section("阅读外观") {
            HStack(spacing: 10) {
                ForEach(ReaderTheme.allCases, id: \.self) { theme in
                    Button { var p = model.preferences; p.theme = theme; model.changePreferences(p) } label: {
                        VStack(spacing: 6) {
                            Text("文").font(.system(size: 20, design: .serif))
                                .foregroundStyle(Color(nsColor: ReaderTypography.textColor(theme)))
                                .frame(width: 52, height: 42)
                                .background(Color(nsColor: ReaderTypography.background(theme)))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(model.preferences.theme == theme ? Color.accentColor : .secondary.opacity(0.15), lineWidth: model.preferences.theme == theme ? 2 : 1))
                            Text(theme.title).font(.caption)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("\(theme.title)主题")
                }
            }.padding(.vertical, 6)
            Picker("阅读方式", selection: model.preferenceBinding(\.layout)) {
                ForEach(ReadingLayout.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Picker("字体", selection: model.preferenceBinding(\.font)) {
                ForEach(ReaderFont.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                Text("字号")
                Slider(value: model.preferenceBinding(\.fontSize), in: 14...40, step: 1)
                Text("\(Int(model.preferences.fontSize))").monospacedDigit().frame(width: 28)
            }
            HStack { Text("行距"); Slider(value: model.preferenceBinding(\.lineSpacing), in: 2...18, step: 1) }
            HStack { Text("段距"); Slider(value: model.preferenceBinding(\.paragraphSpacing), in: 8...36, step: 1) }
            HStack { Text("页宽"); Slider(value: model.preferenceBinding(\.contentWidth), in: 480...1400, step: 20) }
            HStack {
                Image(systemName: "sun.min")
                Slider(value: model.preferenceBinding(\.brightness), in: 0.35...1)
                    .accessibilityLabel("阅读页面亮度")
                Image(systemName: "sun.max")
            }
            Text("亮度仅调整阅读页面，不改变系统屏幕亮度。PDF 保留原始页面颜色。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("翻页过渡动画", isOn: model.preferenceBinding(\.animateTransitions))
            Button("恢复阅读默认设置") { model.changePreferences(ReadingPreferences()) }
        }
    }
}

struct ReaderAppearancePanel: View {
    let model: AppModel
    var body: some View {
        Form { ReaderAppearanceControls(model: model) }
            .readoraForm(model.preferences.theme).frame(width: 360, height: 520)
            .readoraTheme(model.preferences.theme)
    }
}

struct SpeechSettingsView: View {
    @Bindable var model: AppModel
    @State private var rate = 1.0
    @State private var maximum = 8.0
    @State private var voice = ""
    @State private var voiceLanguage = "zh"
    @State private var highlight = true
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var preview = SpeechPlayer()
    @State private var message: String?
    var body: some View {
        Form {
            Section("朗读声音") {
                Picker("语言", selection: $voiceLanguage) {
                    Text("中文").tag("zh"); Text("英语").tag("en"); Text("全部语言").tag("all")
                }
                Picker("音色", selection: $voice) {
                    Text("自动 · 跟随书籍语言").tag("")
                    ForEach(filteredVoices, id: \.identifier) { item in
                        Text("\(item.name) · \(Locale(identifier: "zh-Hans").localizedString(forIdentifier: item.language) ?? item.language)").tag(item.identifier)
                    }
                }
                HStack {
                    Button(preview.isActive ? "停止试听" : "试听音色", systemImage: preview.isActive ? "stop.fill" : "speaker.wave.2") {
                        if preview.isActive { preview.stop() }
                        else { preview.play(["你好，欢迎来到 Readora。让每一页，从容展开。Hello, enjoy your reading."], from: 0, rate: draft) { _, _ in } }
                    }
                    Spacer()
                    Button("刷新音色") { loadVoices() }
                }
                if let failure = preview.failure { Text(failure).font(.caption).foregroundStyle(.red) }
                Text("显示本机已安装的系统音色。可在 macOS 系统设置的辅助功能中添加更多声音，再刷新此列表。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("更自然的开源音色") {
                Text("中文长文可试听 Qwen3-TTS、CosyVoice；轻量方案可了解 Kokoro。以下模型尚未内置到本机音色列表，需要单独部署推理服务。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Link("Qwen3-TTS", destination: URL(string: "https://github.com/QwenLM/Qwen3-TTS")!)
                    Link("CosyVoice", destination: URL(string: "https://github.com/FunAudioLLM/CosyVoice")!)
                    Link("Kokoro 中文", destination: URL(string: "https://huggingface.co/hexgrad/Kokoro-82M-v1.1-zh")!)
                }
            }
            Section("朗读速度") {
                HStack { Text("当前速度"); Spacer(); Text(String(format: "%.2f×", rate)).monospacedDigit() }
                Slider(value: $rate, in: 0.5...max(0.55, maximum), step: 0.05)
                    .disabled(maximum == 0.5).accessibilityLabel("当前朗读速度")
                HStack(spacing: 6) {
                    ForEach([0.5, 1, 1.5, 2, 3, 4, 6, 8], id: \.self) { value in
                        Button("\(value.formatted())×") { rate = min(value, maximum) }
                            .buttonStyle(.bordered).tint(rate == value ? .accentColor : .secondary)
                            .disabled(value > maximum).accessibilityLabel("\(value.formatted())倍速")
                    }
                }
                HStack { Text("最高速度"); Spacer(); Text(String(format: "%.2f×", maximum)).monospacedDigit() }
                Slider(value: $maximum, in: 0.5...8, step: 0.05).accessibilityLabel("最高朗读速度")
                    .onChange(of: maximum) { _, value in rate = min(rate, value); message = nil }
                Text("支持 0.5–8 倍速。超过 2 倍使用保持音调的音频加速；不同音色的自然语速有所差异。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("阅读时") {
                Toggle("高亮正在朗读的位置", isOn: $highlight)
                Text("选中文字后点击朗读，会从选区起点继续读；播放中选中文字会跳到该处。也可右键选择「从这里开始朗读」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("恢复默认值") { rate = 1; maximum = 8; voice = ""; highlight = true; message = nil }
                    Spacer()
                    Button("保存朗读设置") {
                        preview.stop()
                        Task { message = await model.saveSpeechPreferences(draft) ? "设置已保存" : "保存失败，请重试" }
                    }.buttonStyle(.borderedProminent)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }.readoraForm(model.preferences.theme)
            .task {
                rate = model.speechPreferences.rate; maximum = model.speechPreferences.maximumRate
                voice = model.speechPreferences.voiceIdentifier ?? ""
                if let selected = AVSpeechSynthesisVoice(identifier: voice), !selected.language.hasPrefix("zh") { voiceLanguage = selected.language.hasPrefix("en") ? "en" : "all" }
                highlight = model.speechPreferences.highlightSpokenText
                loadVoices()
            }
            .onDisappear { preview.stop() }
            .onChange(of: rate) { _, _ in message = nil }
            .onChange(of: voice) { _, _ in message = nil; preview.stop() }
            .onChange(of: highlight) { _, _ in message = nil }
    }
    private var draft: SpeechPreferences {
        SpeechPreferences(rate: min(rate, maximum), maximumRate: maximum, voiceIdentifier: voice.isEmpty ? nil : voice, highlightSpokenText: highlight)
    }
    private var filteredVoices: [AVSpeechSynthesisVoice] {
        voices.filter { voiceLanguage == "all" || $0.language.hasPrefix(voiceLanguage) || $0.identifier == voice }
    }
    private func loadVoices() {
        voices = AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.language.hasPrefix("zh") != $1.language.hasPrefix("zh") { return $0.language.hasPrefix("zh") }
            return ($0.language + $0.name).localizedStandardCompare($1.language + $1.name) == .orderedAscending
        }
        if !voice.isEmpty, !voices.contains(where: { $0.identifier == voice }) { voice = "" }
    }
}

struct ApplicationThemeSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section("应用主题") {
                Text("选择你喜欢的阅读氛围").font(.headline)
                Text("主题同时应用于书库、阅读页面与设置面板，选择后自动保存。")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    ForEach(ReaderTheme.allCases, id: \.self) { theme in
                        Button {
                            var preferences = model.preferences; preferences.theme = theme
                            model.changePreferences(preferences)
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: theme == .night ? "moon.stars" : "sun.max").font(.title2)
                                Text("文 Aa").font(.system(size: 24, design: .serif))
                                Text(theme.title).font(.caption.weight(.medium))
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                .foregroundStyle(Color(nsColor: ReaderTypography.textColor(theme)))
                                .background(Color(nsColor: ReaderTypography.background(theme)), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.preferences.theme == theme ? Color.accentColor : .secondary.opacity(0.2), lineWidth: model.preferences.theme == theme ? 2 : 1))
                        }.buttonStyle(.plain).accessibilityLabel("应用\(theme.title)主题")
                    }
                }.padding(.vertical, 12)
            }
        }.readoraForm(model.preferences.theme)
    }
}
