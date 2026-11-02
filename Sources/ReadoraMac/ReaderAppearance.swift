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
    @State private var maximum = 2.0
    @State private var voice = ""
    @State private var dictionary = ""
    @State private var cacheBeforePlayback = false
    @State private var highlight = true
    @State private var preview = SpeechPlayer()
    @State private var message: String?
    var body: some View {
        Form {
            Section("朗读声音") {
                Picker("音色", selection: $voice) {
                    ForEach(NeuralSpeechVoice.all) { item in Text(item.title).tag(item.id) }
                }
                HStack {
                    Button(preview.isActive ? "停止试听" : "试听音色", systemImage: preview.isActive ? "stop.fill" : "speaker.wave.2") {
                        if preview.isActive { preview.stop() }
                        else {
                            if model.speech.isPlaying { model.speech.togglePause() }
                            preview.play(["你好，欢迎来到 Readora。让每一页，从容展开。Hello, enjoy your reading."], from: 0, rate: draft) { _, _ in }
                        }
                    }
                    Spacer()
                }
                if preview.preparing { Label("正在准备离线声音…", systemImage: "hourglass").font(.caption) }
                if let failure = preview.failure { Text(failure).font(.caption).foregroundStyle(.red) }
                Text("已内置离线音色，选择后可直接试听。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("离线模型") {
                Text("轻量 Kokoro 支持中文和英文混读，完全在本机运行。可用读音词典纠正多音字，不会修改书籍原文。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("多音字纠正 · 本地词典") {
                Text("每行填写一个词语及声调拼音，保存后对所有书籍生效。优先填写完整词语，避免单字覆盖其他读法。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("银行 = yin2 hang2\n行长 = hang2 zhang3\n重庆 = chong2 qing4")
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                TextEditor(text: $dictionary).font(.body.monospaced()).frame(minHeight: 100)
                    .accessibilityLabel("读音词典，每行词语等于带声调拼音")
                Button("检查并试听词典") {
                    do {
                        let words = try PronunciationDictionary.parse(dictionary).keys.sorted()
                        guard !words.isEmpty else { message = "请先添加一个词语"; return }
                        if model.speech.isPlaying { model.speech.togglePause() }
                        preview.play([words.joined(separator: "，") + "。"], from: 0, rate: draft) { _, _ in }
                        message = "格式正确，共 \(words.count) 个词语；点击保存后生效"
                    } catch { message = error.localizedDescription }
                }
            }
            Section("高速流畅播放") {
                Toggle("2× / 4× 先完整缓存剩余正文", isOn: $cacheBeforePlayback)
                Text("首次需等待音频全部生成；完成后从本地音频连续播放，不会因为模型生成跟不上而停顿。缓存保存在本机，停止可取消生成。")
                    .font(.caption).foregroundStyle(.secondary)
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
                Text("支持 0.5–8 倍速。正常语速生成完整音频后再保音调加速；不同音色的自然语速有所差异。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("阅读时") {
                Toggle("高亮正在朗读的位置", isOn: $highlight)
                Text("选中文字后点击朗读，会从选区起点继续读；播放中选中文字会跳到该处。也可右键选择「从这里开始朗读」。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("恢复默认值") { rate = 1; maximum = 2; voice = NeuralSpeechVoice.defaultIdentifier; highlight = true; cacheBeforePlayback = true; message = nil }
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
                voice = NeuralSpeechVoice.resolvedIdentifier(model.speechPreferences.voiceIdentifier)
                cacheBeforePlayback = model.speechPreferences.cacheBeforePlayback
                dictionary = model.speechPreferences.pronunciationDictionary
                highlight = model.speechPreferences.highlightSpokenText
            }
            .onDisappear { preview.stop() }
            .onChange(of: rate) { _, _ in message = nil }
            .onChange(of: voice) { _, _ in message = nil; preview.stop() }
            .onChange(of: dictionary) { _, _ in message = nil; preview.stop() }
            .onChange(of: highlight) { _, _ in message = nil }
    }
    private var draft: SpeechPreferences {
        SpeechPreferences(rate: min(rate, maximum), maximumRate: maximum, voiceIdentifier: voice.isEmpty ? nil : voice, highlightSpokenText: highlight, pronunciationDictionary: dictionary, cacheBeforePlayback: cacheBeforePlayback)
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
