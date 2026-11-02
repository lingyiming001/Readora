import AVFoundation
import UIKit
import Observation
import ReadoraCore
import ReadoraKokoroRuntime

enum MobileSpeechEngine: String, CaseIterable {
    case kokoro
    var title: String {
        switch self {
        case .kokoro: "Kokoro 离线"
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
        NeuralSpeechVoice.all.first { $0.id == "kokoro:\(rawValue)" }?.title.replacingOccurrences(of: "Kokoro · ", with: "") ?? "Kokoro \(rawValue)"
    }
}
@MainActor @Observable
final class MobileSpeech: NSObject {
    var playing = false
    var paused = false
    var error: String?
    var preferences = SpeechPreferences(maximumRate: 2, cacheBeforePlayback: false)
    var engineChoice = MobileSpeechEngine(rawValue: UserDefaults.standard.string(forKey: "mobileSpeechEngine") ?? "kokoro") ?? .kokoro
    var kokoroVoice = MobileKokoroVoice(rawValue: UserDefaults.standard.object(forKey: "mobileKokoroVoice") as? Int ?? 56) ?? .female054
    var preparing = false
    var voiceTitle: String {
        switch engineChoice {
        case .kokoro: "Kokoro · " + kokoroVoice.title
        }
    }
    var spokenPreview: String {
        guard let spokenParagraph, texts.indices.contains(spokenParagraph) else { return "让阅读继续" }
        let text = texts[spokenParagraph] as NSString
        guard let range = SpeechTextSegment.range(in: text as String, from: spokenRange.location, maximumLength: 40) else { return "本段朗读即将结束" }
        return text.substring(with: range).replacingOccurrences(of: "\n", with: " ")
    }
    private static var keepAwakeCount = 0
    private static var previousIdleSetting = false
    private var keepsAwakeForPreparation = false
    private func keepAwakeForPreparation(_ enabled: Bool) {
        guard enabled != keepsAwakeForPreparation else { return }
        keepsAwakeForPreparation = enabled
        if enabled {
            if Self.keepAwakeCount == 0 { Self.previousIdleSetting = UIApplication.shared.isIdleTimerDisabled }
            Self.keepAwakeCount += 1
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            Self.keepAwakeCount = max(0, Self.keepAwakeCount - 1)
            if Self.keepAwakeCount == 0 { UIApplication.shared.isIdleTimerDisabled = Self.previousIdleSetting }
        }
    }
    private var preparedAudio: KokoroPreparedAudio?
    private var preparedReader: KokoroPreparedAudioReader?
    private var preparedChunks: [SpeechChunk] = []
    private var preparedIndex = 0
    private var prepareTask: Task<(KokoroPreparedAudio, [SpeechChunk]), Error>?
    private var streamThisSession = false
    var preparationProgress: Double?
    var preparedCount = 0
    var preparationTotal = 0
    var canPlayImmediately: Bool { playing && preparationProgress != nil }
    func playImmediately() {
        guard canPlayImmediately else { return }
        let source = texts, paragraph = index, location = offset
        start(source, from: paragraph, offset: location, streaming: true)
    }
    var preparationStatus: String {
        if let progress = preparationProgress { return preparationTotal > 0 ? "正在缓存 · \(preparedCount)/\(preparationTotal) 段 · \(Int(progress * 100))%" : "正在整理剩余正文…" }
        return bufferedSeconds < 0.1 ? "正在加载声音并生成首段…" : "正在缓冲 · 已备 \(Int(bufferedSeconds)) 秒"
    }
    private var cursor: SpeechChunkCursor?
    private var scheduledChunks: [SpeechChunk] = []
    private var exhausted = false
    private var reserve = SpeechBufferState(rate: 1)
    var underrunCount = 0
    var audioStarted: Bool { reserve.isRunning }
    private var hadPlayback = false
    private var pendingUnderrun = false
    var bufferedSeconds: Double { reserve.seconds(at: ProcessInfo.processInfo.systemUptime) }
    private var corrections: [String: String] = [:]
    private var activeRenderTask: Task<KokoroAudio, Error>?
    private var pumpingToken: UUID?
    private static var modelRoot: URL { Bundle.main.bundleURL.appendingPathComponent("Kokoro", isDirectory: true) }
    static var kokoroInstalled: Bool { KokoroEngine.isInstalled(at: modelRoot) }
    static func installed(for engine: MobileSpeechEngine) -> Bool {
        switch engine {
        case .kokoro: kokoroInstalled
        }
    }
    private var neuralRoot: URL { Self.modelRoot }
    private var neuralSpeaker: Int { kokoroVoice.rawValue }
    func configure(_ input: SpeechPreferences, engine: MobileSpeechEngine? = nil, voice: MobileKokoroVoice? = nil, persistChoice: Bool = true) {
        guard (try? input.validate()) != nil else { error = "朗读速度超出有效范围。"; return }
        var next = input
        let catalogVoice = NeuralSpeechVoice.all.first { $0.id == input.voiceIdentifier }
        let parts = catalogVoice?.id.split(separator: ":")
        let suppliedEngine = engine ?? parts.flatMap { MobileSpeechEngine(rawValue: String($0[0])) }
        let suppliedVoice = voice ?? parts.flatMap { Int($0[1]) }.flatMap(MobileKokoroVoice.init(rawValue:))
        let selectedEngine = suppliedEngine ?? (input.voiceIdentifier != nil && catalogVoice == nil ? .kokoro : engineChoice)
        if selectedEngine == .kokoro { next.voiceIdentifier = "kokoro:\((suppliedVoice ?? kokoroVoice).rawValue)" }
        else if catalogVoice != nil { next.voiceIdentifier = nil }
        let restart = preferences.rate != next.rate || preferences.voiceIdentifier != next.voiceIdentifier || preferences.pronunciationDictionary != next.pronunciationDictionary || preferences.cacheBeforePlayback != next.cacheBeforePlayback || engineChoice != selectedEngine
        engineChoice = selectedEngine
        if let suppliedVoice { kokoroVoice = suppliedVoice }
        if persistChoice {
            UserDefaults.standard.set(engineChoice.rawValue, forKey: "mobileSpeechEngine")
            UserDefaults.standard.set(kokoroVoice.rawValue, forKey: "mobileKokoroVoice")
        }
        preferences = next
        corrections = (try? PronunciationDictionary.parse(next.pronunciationDictionary)) ?? [:]
        guard playing, restart else { return }
        let saved = texts, current = index, currentOffset = spokenRange.location, wasPaused = paused
        start(saved, from: current, offset: currentOffset, paused: wasPaused)
    }
    private var audioSessionActive = false
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var generation = UUID()
    private var offset = 0
    private var texts: [String] = []
    private var index = 0
    var spokenParagraph: Int?
    var spokenRange = NSRange(location: 0, length: 0)
    var onPosition: ((Int, NSRange) -> Void)?
    private func publishPosition(_ range: NSRange) {
        spokenParagraph = index; spokenRange = range
        onPosition?(index, range)
    }
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(interrupted(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    @objc nonisolated private func interrupted(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              value == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor [weak self] in
            self?.pauseForInterruption(); self?.audioSessionActive = false
        }
    }
    @objc nonisolated private func routeChanged(_ notification: Notification) {
        guard let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              value == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        Task { @MainActor [weak self] in self?.pauseForInterruption() }
    }
    private func pauseForInterruption() {
        guard playing, !paused else { return }
        reserve.pause(at: ProcessInfo.processInfo.systemUptime)
        player?.pause()
        paused = true
    }
    func start(_ paragraphs: [String], from position: Int, offset startOffset: Int = 0, paused startPaused: Bool = false, streaming: Bool = false) {
        stop(releaseAudioSession: false)
        streamThisSession = streaming || !preferences.cacheBeforePlayback
        guard paragraphs.indices.contains(position) else { stop(); return }
        error = nil
        texts = paragraphs; index = position; playing = true; paused = startPaused
        offset = SpeechTextSegment.range(in: paragraphs[position], from: startOffset)?.location ?? (paragraphs[position] as NSString).length
        spokenParagraph = position; spokenRange = NSRange(location: offset, length: 0)
        if !startPaused { speakNext() }
    }
    private func speakNext() {
        while index < texts.count, texts[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { index += 1 }
        guard playing, texts.indices.contains(index) else { stop(); return }
        let source = texts[index] as NSString
        if offset >= source.length { index += 1; offset = 0; speakNext(); return }
        beginKokoro()
    }
    /// Kokoro renders short phrases; normal-speed inference retains complete phonemes; playback applies acceleration.
    private var kokoroModelSpeed: Double { min(max(preferences.rate, 0.5), 1) }
    private func beginKokoro() {
        cursor = SpeechChunkCursor(paragraphs: texts, paragraph: index, offset: offset, protectedWords: Array(corrections.keys), continuous: preferences.rate >= 1.75 && !streamThisSession, initialLength: streamThisSession ? 24 : 40, mergeAfterFirst: streamThisSession)
        scheduledChunks = []; exhausted = false; reserve = SpeechBufferState(rate: preferences.rate)
        underrunCount = 0; hadPlayback = false; pendingUnderrun = false
        preparing = true; startProducer()
    }
    private func nextChunk() -> SpeechChunk? {
        if preparedAudio != nil {
            guard preparedChunks.indices.contains(preparedIndex) else { return nil }
            let chunk = preparedChunks[preparedIndex]; preparedIndex += 1; return chunk
        }
        return cursor?.next()
    }
    private func startProducer() {
        guard !streamThisSession, preferences.cacheBeforePlayback, preferences.rate >= 1.75, preparedAudio == nil else { pumpKokoro(); return }
        guard prepareTask == nil else { return }
        let token = generation
        let initialCursor = cursor, paragraphs = self.texts
        let root = self.neuralRoot, speed = Float(self.kokoroModelSpeed), corrections = self.corrections, speaker = self.neuralSpeaker
        preparing = true; preparationProgress = 0
        keepAwakeForPreparation(true)
        let owner = self
        let task = Task.detached(priority: .userInitiated) {
            var walk = initialCursor
            var chunks: [SpeechChunk] = []
            while let chunk = walk?.next() { try Task.checkCancellation(); chunks.append(chunk) }
            guard !chunks.isEmpty else { throw KokoroError.synthesis }
            let source = chunks.map { (paragraphs[$0.paragraph] as NSString).substring(with: $0.range) }
            let total = chunks.count
            await MainActor.run { [weak owner] in
                guard let owner, owner.generation == token, owner.playing else { return }
                owner.preparationTotal = total
            }
            let audio = try await KokoroEngine.shared.prepare(texts: source, speaker: speaker, root: root, speed: speed, corrections: corrections) { completed in
                Task { @MainActor [weak owner] in
                    guard let owner, owner.generation == token, owner.playing, owner.prepareTask != nil else { return }
                    owner.preparedCount = completed
                    owner.preparationProgress = Double(completed) / Double(total)
                }
            }
            return (audio, chunks)
        }
        prepareTask = task
        Task { @MainActor [weak self] in
            do {
                let (audio, chunks) = try await task.value
                guard let self, self.generation == token, self.playing else { return }
                self.prepareTask = nil; self.preparationProgress = nil
                self.keepAwakeForPreparation(false)
                self.preparedReader = try audio.makeReader()
                self.preparedAudio = audio; self.preparedChunks = chunks; self.preparedIndex = 0
                self.pumpKokoro()
                Task { await KokoroEngine.shared.releaseAfterIdle() }
            } catch is CancellationError {}
            catch {
                guard let self, self.generation == token else { return }
                self.error = error.localizedDescription; self.stop()
            }
        }
    }
    private func publish(_ chunk: SpeechChunk) {
        index = chunk.paragraph; offset = chunk.range.location
        publishPosition(chunk.range)
    }
    /// A single producer preserves inference order and bounds the player queue to two chunks.
    private func pumpKokoro() {
        guard playing, pumpingToken != generation else { return }
        let token = generation
        pumpingToken = token
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.pumpingToken == token { self.pumpingToken = nil } }
            while self.playing, self.generation == token, self.reserve.needsMore(at: ProcessInfo.processInfo.systemUptime), !self.exhausted {
                guard let chunk = self.nextChunk() else { self.exhausted = true; break }
                let phrase = (self.texts[chunk.paragraph] as NSString).substring(with: chunk.range)
                let root = self.neuralRoot, speaker = self.neuralSpeaker, speed = Float(self.kokoroModelSpeed), corrections = self.corrections
                let archive = self.preparedReader, archiveIndex = self.preparedIndex - 1
                let started = ProcessInfo.processInfo.systemUptime
                let task = Task.detached(priority: .userInitiated) {
                    if let archive { return try archive.readChunk(archiveIndex) }
                    return try await KokoroEngine.shared.render(text: phrase, speaker: speaker, root: root, speed: speed, corrections: corrections)
                }
                self.activeRenderTask = task
                self.preparing = !self.reserve.isRunning
                do {
                    let audio = try await task.value
                    guard self.playing, self.generation == token else { return }
                    self.activeRenderTask = nil
                    guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1),
                          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
                          let output = buffer.floatChannelData?[0] else { throw KokoroError.synthesis }
                    buffer.frameLength = AVAudioFrameCount(audio.samples.count)
                    audio.samples.withUnsafeBufferPointer { input in if let base = input.baseAddress { output.update(from: base, count: input.count) } }
                    try self.ensureKokoroNode(for: buffer.format)
                    guard let player = self.player else { throw KokoroError.synthesis }
                    self.scheduledChunks.append(chunk)
                    self.reserve.append(audioSeconds: Double(audio.samples.count) / Double(audio.sampleRate), modelSpeed: self.kokoroModelSpeed, generationSeconds: ProcessInfo.processInfo.systemUptime - started)
                    player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.playing, self.generation == token else { return }
                            if self.scheduledChunks.first == chunk {
                                self.scheduledChunks.removeFirst(); self.reserve.completed(at: ProcessInfo.processInfo.systemUptime)
                            }
                            if self.scheduledChunks.isEmpty {
                                self.pendingUnderrun = self.hadPlayback && !self.paused
                                self.player?.pause(); self.preparing = !self.exhausted
                            }
                            else if !self.paused, self.reserve.isRunning, let first = self.scheduledChunks.first { self.publish(first) }
                            self.pumpKokoro()
                        }
                    }
                    self.startWhenReady()
                } catch is CancellationError { return }
                catch {
                    if self.generation == token { self.error = error.localizedDescription; self.stop() }
                    return
                }
            }
            if self.generation == token, self.playing {
                self.startWhenReady()
                if self.exhausted, self.scheduledChunks.isEmpty { self.stop() }
            }
        }
    }
    private func startWhenReady() {
        guard playing, !paused, let engine, let player else { return }
        guard !reserve.isRunning else { preparing = false; return }
        guard reserve.canStart(at: ProcessInfo.processInfo.systemUptime, exhausted: exhausted, immediately: preparedReader != nil || (streamThisSession && (!hadPlayback || reserve.seconds(at: ProcessInfo.processInfo.systemUptime) >= 3))) else { preparing = true; return }
        do {
            if !audioSessionActive {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
                audioSessionActive = true
            }
            if !engine.isRunning { try engine.start() }
            if pendingUnderrun { underrunCount += 1 }
            pendingUnderrun = false; hadPlayback = true
            reserve.resume(at: ProcessInfo.processInfo.systemUptime)
            if let first = scheduledChunks.first { publish(first) }
            player.play(); preparing = false
        } catch { self.error = error.localizedDescription; stop() }
    }
    private func ensureKokoroNode(for format: AVAudioFormat) throws {
        if engine != nil, let existing = player, existing.outputFormat(forBus: 0).isEqual(format) {
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
            pitch.overlap = 16
            engine.attach(pitch)
            engine.connect(node, to: pitch, format: format)
            engine.connect(pitch, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        self.engine = engine; self.player = node
    }
    func togglePause() {
        if paused {
            do {
                paused = false
                if cursor == nil { beginKokoro() } else { startWhenReady(); startProducer() }
            } catch { self.error = error.localizedDescription; paused = true }
        } else { pauseForInterruption() }
    }
    func finish() {
        stop()
        Task { await KokoroEngine.shared.unload() }
    }
    func stop(releaseAudioSession: Bool = true) {
        keepAwakeForPreparation(false)
        prepareTask?.cancel(); prepareTask = nil
        preparedAudio = nil; preparedReader = nil; preparedChunks = []; preparedIndex = 0; preparationProgress = nil
        preparedCount = 0; preparationTotal = 0; streamThisSession = false
        activeRenderTask?.cancel(); activeRenderTask = nil
        let wasPlaying = playing
        cursor = nil; scheduledChunks = []; exhausted = false; pumpingToken = nil; reserve = SpeechBufferState(rate: preferences.rate)
        preparing = false
        generation = UUID(); offset = 0
        player?.stop(); engine?.stop(); player = nil; engine = nil
        playing = false; paused = false; texts = []
        spokenParagraph = nil; spokenRange = NSRange(location: 0, length: 0)
        if wasPlaying { Task { await KokoroEngine.shared.releaseAfterIdle() } }
        if releaseAudioSession, audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

}
