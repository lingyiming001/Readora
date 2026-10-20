import AVFoundation
import Observation
import ReadoraCore
import ReadoraKokoroRuntime

enum MobileSpeechEngine: String, CaseIterable {
    case kokoro, melo, system
    var title: String {
        switch self {
        case .kokoro: "Kokoro 离线"
        case .melo: "Melo 离线"
        case .system: "系统朗读"
        }
    }
}
enum MobileKokoroVoice: Int, CaseIterable, Identifiable {
    // Kokoro v1.1-zh speaker table: 0-2 bilingual female, 3-57 Chinese female (zf_*), 58-102 Chinese male (zm_*).
    case bilingualMaple = 0, bilingualSol = 1, bilingualVale = 2
    case female001 = 3, female009 = 11, female021 = 23, female031 = 33, female041 = 43, female054 = 56
    case male001 = 58, male003 = 60, male011 = 68, male021 = 78, male031 = 88, male045 = 102
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .bilingualMaple: "双语 · 枫 Maple"
        case .bilingualSol: "双语 · 晴 Sol"
        case .bilingualVale: "双语 · 谷 Vale"
        case .female001: "女声 · 晓 001"
        case .female009: "女声 · 甜 009"
        case .female021: "女声 · 婉 021"
        case .female031: "女声 · 静 031"
        case .female041: "女声 · 莺 041"
        case .female054: "女声 · 暖 054"
        case .male001: "男声 · 朗 001"
        case .male003: "男声 · 健 003"
        case .male011: "男声 · 岳 011"
        case .male021: "男声 · 川 021"
        case .male031: "男声 · 沉 031"
        case .male045: "男声 · 苍 045"
        }
    }
}
/// MeloTTS-Chinese (myshell-ai) ships exactly one speaker; the enum is per-model so
/// future sherpa-onnx vits models with more speakers just add cases here.
enum MobileMeloVoice: Int, CaseIterable, Identifiable {
    case bilingualZh = 0
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .bilingualZh: "双语 · 泠 Melo"
        }
    }
}

@MainActor @Observable
final class MobileSpeech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var playing = false
    var paused = false
    var error: String?
    var preferences = SpeechPreferences(maximumRate: 2)
    var engineChoice = MobileSpeechEngine(rawValue: UserDefaults.standard.string(forKey: "mobileSpeechEngine") ?? "kokoro") ?? .kokoro
    var kokoroVoice = MobileKokoroVoice(rawValue: UserDefaults.standard.object(forKey: "mobileKokoroVoice") as? Int ?? 56) ?? .female054
    var meloVoice = MobileMeloVoice(rawValue: UserDefaults.standard.object(forKey: "mobileMeloVoice") as? Int ?? 0) ?? .bilingualZh
    var preparing = false
    var voiceTitle: String {
        switch engineChoice {
        case .kokoro: "Kokoro · " + kokoroVoice.title
        case .melo: "Melo · " + meloVoice.title
        case .system: preferences.voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0)?.name } ?? "推荐普通话"
        }
    }
    var spokenPreview: String {
        guard let spokenParagraph, texts.indices.contains(spokenParagraph) else { return "让阅读继续" }
        let text = texts[spokenParagraph] as NSString
        guard let range = SpeechTextSegment.range(in: text as String, from: spokenRange.location, maximumLength: 40) else { return "本段朗读即将结束" }
        return text.substring(with: range).replacingOccurrences(of: "\n", with: " ")
    }
    private var usesRenderedAudio: Bool { engineChoice != .system || preferences.rate > 2 }
    private struct KokoroChunk {
        let range: NSRange
        let nextParagraph: Int
        let nextOffset: Int
        let token: UUID
        let task: Task<KokoroAudio, Error>
    }
    private var scheduleQueue: [KokoroChunk] = []
    /// Chunks already handed to the player node but not yet played back; the head of this
    /// queue is the phrase actually sounding, so highlight follows it instead of the render queue.
    private var scheduledChunks: [KokoroChunk] = []
    private var walkParagraph = 0
    private var walkOffset = 0
    private var pumpingToken: UUID?
    private static var modelRoot: URL { Bundle.main.bundleURL.appendingPathComponent("Kokoro", isDirectory: true) }
    private static var meloRoot: URL { Bundle.main.bundleURL.appendingPathComponent("MeloTTS", isDirectory: true) }
    static var kokoroInstalled: Bool { KokoroEngine.isInstalled(at: modelRoot) }
    static var meloInstalled: Bool { KokoroEngine.isInstalled(at: meloRoot, kind: .melo) }
    static func installed(for engine: MobileSpeechEngine) -> Bool {
        switch engine {
        case .kokoro: kokoroInstalled
        case .melo: meloInstalled
        case .system: true
        }
    }
    private var neuralRoot: URL { engineChoice == .melo ? Self.meloRoot : Self.modelRoot }
    private var neuralKind: SherpaTTSModel { engineChoice == .melo ? .melo : .kokoro }
    private var neuralSpeaker: Int { engineChoice == .melo ? meloVoice.rawValue : kokoroVoice.rawValue }
    func configure(_ preferences: SpeechPreferences, engine: MobileSpeechEngine? = nil, voice: MobileKokoroVoice? = nil, meloVoice: MobileMeloVoice? = nil, persistChoice: Bool = true) {
        guard (try? preferences.validate()) != nil else { error = "朗读速度超出有效范围。"; return }
        let shouldRestart = self.preferences.rate != preferences.rate || self.preferences.voiceIdentifier != preferences.voiceIdentifier || (engine != nil && engine != engineChoice) || (voice != nil && voice != kokoroVoice) || (meloVoice != nil && meloVoice != self.meloVoice)
        if let engine { engineChoice = engine; if persistChoice { UserDefaults.standard.set(engine.rawValue, forKey: "mobileSpeechEngine") } }
        if let voice { kokoroVoice = voice; if persistChoice { UserDefaults.standard.set(voice.rawValue, forKey: "mobileKokoroVoice") } }
        if let meloVoice { self.meloVoice = meloVoice; if persistChoice { UserDefaults.standard.set(meloVoice.rawValue, forKey: "mobileMeloVoice") } }
        self.preferences = preferences
        if let id = self.preferences.voiceIdentifier, !Self.recommendedVoices.contains(where: { $0.identifier == id }) {
            let language = AVSpeechSynthesisVoice(identifier: id)?.language
            self.preferences.voiceIdentifier = Self.recommendedVoices.first { $0.language == language }?.identifier ?? Self.preferredVoice?.identifier
        }
        guard playing, shouldRestart else { return }
        let saved = texts, current = index, currentOffset = spokenRange.location, wasPaused = paused
        start(saved, from: current, offset: currentOffset, paused: wasPaused)
    }
    static var recommendedVoices: [AVSpeechSynthesisVoice] {
        let installed = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
        return Dictionary(grouping: installed, by: \.language).values.flatMap { group in
            let best = group.map { $0.quality.rawValue }.max() ?? 1
            let candidates = group.filter { $0.quality.rawValue == best }.sorted { $0.name < $1.name }
            var names: Set<String> = []
            return Array(candidates.filter { names.insert($0.name).inserted }.prefix(best == AVSpeechSynthesisVoiceQuality.default.rawValue ? 1 : 3))
        }.sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }
    static var preferredVoice: AVSpeechSynthesisVoice? {
        recommendedVoices.first { $0.language == "zh-CN" } ?? recommendedVoices.first { $0.language.hasPrefix("zh") }
    }
    private var selectedVoice: AVSpeechSynthesisVoice?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation = UUID()
    private var offset = 0
    private var texts: [String] = []
    private var index = 0
    private var utteranceID: ObjectIdentifier?
    var spokenParagraph: Int?
    var spokenRange = NSRange(location: 0, length: 0)
    var onPosition: ((Int, NSRange) -> Void)?
    private var utteranceOffset = 0
    private var pendingRange = NSRange(location: 0, length: 0)
    private func publishPosition(_ range: NSRange) {
        spokenParagraph = index; spokenRange = range
        onPosition?(index, range)
    }
    override init() {
        super.init(); synthesizer.delegate = self; synthesizer.usesApplicationAudioSession = true
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    @objc nonisolated private func interrupted(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              value == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor [weak self] in self?.pauseForInterruption() }
    }
    @objc nonisolated private func routeChanged(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              value == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        Task { @MainActor [weak self] in self?.pauseForInterruption() }
    }
    private func pauseForInterruption() {
        guard playing, !paused else { return }
        if usesRenderedAudio { player?.pause() }
        else { _ = synthesizer.pauseSpeaking(at: .immediate) }
        paused = true
    }
    func start(_ paragraphs: [String], from position: Int, offset startOffset: Int = 0, paused startPaused: Bool = false) {
        stop()
        guard paragraphs.indices.contains(position) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            error = nil
            selectedVoice = engineChoice == .system ? preferences.voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) } ?? Self.preferredVoice ?? AVSpeechSynthesisVoice(language: "zh-CN") : nil
            texts = paragraphs; index = position; playing = true; paused = startPaused
            offset = SpeechTextSegment.range(in: paragraphs[position], from: startOffset)?.location ?? (paragraphs[position] as NSString).length
            spokenParagraph = position; spokenRange = NSRange(location: offset, length: 0)
            if !startPaused { speakNext() }
        } catch { self.error = error.localizedDescription }
    }
    private func speakNext() {
        while index < texts.count, texts[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { index += 1 }
        guard playing, texts.indices.contains(index) else { stop(); return }
        let source = texts[index] as NSString
        if offset >= source.length { index += 1; offset = 0; speakNext(); return }
        if engineChoice != .system { beginKokoro(); return }
        let range: NSRange
        if usesRenderedAudio {
            range = SpeechTextSegment.range(in: texts[index], from: offset) ?? NSRange(location: offset, length: source.length - offset)
        } else { range = NSRange(location: offset, length: source.length - offset) }
        utteranceOffset = range.location; pendingRange = range
        let utterance = AVSpeechUtterance(string: source.substring(with: range))
        utterance.rate = preferences.systemRate(defaultRate: AVSpeechUtteranceDefaultSpeechRate,
            minimum: AVSpeechUtteranceMinimumSpeechRate, maximum: AVSpeechUtteranceMaximumSpeechRate)
        utterance.voice = selectedVoice
        utteranceID = ObjectIdentifier(utterance)
        if preferences.rate <= 2 {
            publishPosition(NSRange(location: range.location, length: min(1, range.length)))
            synthesizer.speak(utterance)
        }
        else {
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            let token = generation, nextOffset = NSMaxRange(range)
            let collector = MobilePCMCollector()
            synthesizer.write(utterance) { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength > 0 { collector.append(pcm); return }
                let audio = collector.finish()
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.playing else { return }
                    self.playRendered(audio, nextOffset: nextOffset, token: token)
                }
            }
        }
    }
    /// Kokoro renders short phrases; the model itself speaks faster up to 2x and time pitch fills the rest.
    private var kokoroModelSpeed: Double { min(max(preferences.rate, 0.5), 2) }
    private func beginKokoro() {
        scheduleQueue.forEach { $0.task.cancel() }
        scheduleQueue = []
        walkParagraph = index; walkOffset = offset; scheduledChunks = []
        ensureKokoroQueue()
        guard !scheduleQueue.isEmpty else { stop(); return }
        preparing = true
        pumpKokoro()
    }
    private func ensureKokoroQueue() {
        while scheduleQueue.count < 3 {
            while texts.indices.contains(walkParagraph), texts[walkParagraph].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { walkParagraph += 1; walkOffset = 0 }
            guard texts.indices.contains(walkParagraph) else { return }
            let text = texts[walkParagraph], source = text as NSString
            if walkOffset >= source.length { walkParagraph += 1; walkOffset = 0; continue }
            let range = SpeechTextSegment.phraseRange(in: text, from: walkOffset) ?? NSRange(location: walkOffset, length: source.length - walkOffset)
            let end = NSMaxRange(range)
            let next: (Int, Int) = end >= source.length ? (walkParagraph + 1, 0) : (walkParagraph, end)
            let phrase = source.substring(with: range)
            let speaker = neuralSpeaker
            let kind = neuralKind
            let speed = Float(kokoroModelSpeed)
            let root = neuralRoot
            let token = generation
            let task = Task.detached(priority: .userInitiated) {
                try await KokoroEngine.shared.render(text: phrase, speaker: speaker, root: root, speed: speed, kind: kind)
            }
            scheduleQueue.append(KokoroChunk(range: range, nextParagraph: next.0, nextOffset: next.1, token: token, task: task))
            walkParagraph = next.0; walkOffset = next.1
        }
    }
    /// Keeps the player node continuously scheduled so phrase boundaries are gapless.
    private func pumpKokoro() {
        guard playing, engineChoice != .system else { return }
        let token = generation
        if pumpingToken == token { return }
        pumpingToken = token
        Task { @MainActor in
            while self.playing, self.generation == token, self.scheduledChunks.count < 2 {
                self.ensureKokoroQueue()
                guard !self.scheduleQueue.isEmpty else { break }
                let chunk = self.scheduleQueue.removeFirst()
                do {
                    let audio = try await chunk.task.value
                    try Task.checkCancellation()
                    guard self.playing, self.generation == token,
                          let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1),
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
                          let output = buffer.floatChannelData?[0] else { break }
                    buffer.frameLength = AVAudioFrameCount(audio.samples.count)
                    audio.samples.withUnsafeBufferPointer { input in if let base = input.baseAddress { output.update(from: base, count: input.count) } }
                    self.preparing = false
                    try self.ensureKokoroNode(for: buffer.format)
                    guard let player = self.player else { break }
                    let willStartNow = self.scheduledChunks.isEmpty
                    self.scheduledChunks.append(chunk)
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.playing, self.generation == token else { return }
                            if !self.scheduledChunks.isEmpty { self.scheduledChunks.removeFirst() }
                            self.index = chunk.nextParagraph; self.offset = chunk.nextOffset
                            guard self.texts.indices.contains(chunk.nextParagraph) else { self.stop(); return }
                            if let sounding = self.scheduledChunks.first { self.publishPosition(sounding.range) }
                            else if let upcoming = SpeechTextSegment.phraseRange(in: self.texts[chunk.nextParagraph], from: chunk.nextOffset) { self.publishPosition(upcoming) }
                            else { self.publishPosition(NSRange(location: chunk.nextOffset, length: 0)) }
                            self.pumpKokoro()
                        }
                    }
                    if willStartNow, !self.paused { self.publishPosition(chunk.range) }
                    if !self.paused, !player.isPlaying { player.play() }
                } catch is CancellationError { break }
                catch {
                    if self.generation == token { self.error = error.localizedDescription; self.stop() }
                    break
                }
            }
            if self.pumpingToken == token { self.pumpingToken = nil }
        }
    }
    private func ensureKokoroNode(for format: AVAudioFormat) throws {
        if let current = engine, let existing = player, existing.outputFormat(forBus: 0).isEqual(format) {
            if !current.isRunning { try current.start() }
            return
        }
        engine?.stop()
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        let remainder = preferences.rate / kokoroModelSpeed
        if abs(remainder - 1) > 0.01 {
            let pitch = AVAudioUnitTimePitch()
            pitch.rate = Float(remainder)
            engine.attach(pitch)
            engine.connect(node, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        try engine.start()
        self.engine = engine; self.player = node
    }
    private func playRendered(_ audio: MobilePCMCollector.Batch, nextOffset: Int, token: UUID) {
        guard let first = audio.buffers.first else { error = "此音色无法生成朗读音频，请更换音色。"; stop(); return }
        do {
            let engine: AVAudioEngine, node: AVAudioPlayerNode
            if let current = self.engine, let existing = player, existing.outputFormat(forBus: 0).isEqual(first.format) {
                engine = current; node = existing; node.stop()
            } else {
                self.engine?.stop()
                engine = AVAudioEngine(); node = AVAudioPlayerNode()
                let pitch = AVAudioUnitTimePitch(); pitch.rate = Float(preferences.rate)
                engine.attach(node); engine.attach(pitch)
                engine.connect(node, to: pitch, format: first.format)
                engine.connect(pitch, to: engine.mainMixerNode, format: first.format)
                self.engine = engine; player = node
            }
            for (index, buffer) in audio.buffers.enumerated() {
                if index == audio.buffers.count - 1 {
                    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token, self.playing else { return }
                            self.offset = nextOffset; self.speakNext()
                        }
                    }
                } else { node.scheduleBuffer(buffer) }
            }
            if !engine.isRunning { try engine.start() }
            if !paused { publishPosition(pendingRange); node.play() }
        } catch { self.error = error.localizedDescription; stop() }
    }
    func togglePause() {
        if paused {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                paused = false
                if engineChoice != .system {
                    if let sounding = scheduledChunks.first { publishPosition(sounding.range) }
                    if let player { player.play() }
                    pumpKokoro()
                } else if utteranceID == nil { speakNext() }
                else if usesRenderedAudio {
                    if player != nil { publishPosition(pendingRange); player?.play() }
                } else { _ = synthesizer.continueSpeaking() }
            } catch { self.error = error.localizedDescription; paused = true }
        } else { pauseForInterruption() }
    }
    func finish() {
        stop()
        Task { await KokoroEngine.shared.unload() }
    }
    func stop() {
        let wasPlaying = playing
        scheduleQueue.forEach { $0.task.cancel() }
        scheduleQueue = []; scheduledChunks = []
        preparing = false
        generation = UUID(); offset = 0
        player?.stop(); engine?.stop(); player = nil; engine = nil
        utteranceID = nil; playing = false; paused = false; texts = []
        spokenParagraph = nil; spokenRange = NSRange(location: 0, length: 0)
        synthesizer.stopSpeaking(at: .immediate)
        if wasPlaying { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == id, self.playing, self.engineChoice == .system, self.preferences.rate <= 2 else { return }
            self.publishPosition(NSRange(location: self.utteranceOffset + characterRange.location, length: characterRange.length))
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == id, self.playing, self.engineChoice == .system, self.preferences.rate <= 2 else { return }
            self.index += 1; self.offset = 0; self.speakNext()
        }
    }
}

nonisolated private final class MobilePCMCollector: @unchecked Sendable {
    struct Batch: @unchecked Sendable { let buffers: [AVAudioPCMBuffer] }
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    func append(_ source: AVAudioPCMBuffer) {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else { return }
        copy.frameLength = source.frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in src.indices {
            if let input = src[i].mData, let output = dst[i].mData { memcpy(output, input, Int(src[i].mDataByteSize)) }
        }
        lock.lock(); buffers.append(copy); lock.unlock()
    }
    func finish() -> Batch {
        lock.lock(); defer { lock.unlock() }
        let result = Batch(buffers: buffers); buffers = []; return result
    }
}
