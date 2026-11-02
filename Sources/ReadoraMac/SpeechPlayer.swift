import Foundation
import AVFoundation
import Observation
import ReadoraCore
import ReadoraRendering
import ReadoraKokoroRuntime

@MainActor
@Observable
final class SpeechPlayer: NSObject {
    var isActive = false
    var isPlaying = false
    var preparing = false
    var index = 0
    var spokenRange = NSRange(location: 0, length: 0)
    var failure: String?
    private var paragraphs: [String] = []
    private var language: String?
    private var rate = SpeechPreferences()
    private var preparedAudio: KokoroPreparedAudio?
    private var preparedReader: KokoroPreparedAudioReader?
    private var preparedChunks: [SpeechChunk] = []
    private var preparedIndex = 0
    private var prepareTask: Task<(KokoroPreparedAudio, [SpeechChunk]), Error>?
    var preparationProgress: Double?
    var preparationStatus: String {
        if let progress = preparationProgress { return "正在缓存剩余正文 · \(Int(progress * 100))%" }
        return "正在缓冲 · 已备 \(Int(bufferedSeconds)) 秒"
    }
    private var cursor: SpeechChunkCursor?
    private var exhausted = false
    private var reserve = SpeechBufferState(rate: 1)
    var underrunCount = 0
    var audioStarted: Bool { reserve.isRunning }
    private var hadPlayback = false
    private var pendingUnderrun = false
    var bufferedSeconds: Double { reserve.seconds(at: ProcessInfo.processInfo.systemUptime) }
    private var scheduled: [SpeechChunk] = []
    private var generation = UUID()
    private var pumpingToken: UUID?
    private var renderTask: Task<KokoroAudio, Error>?
    private var corrections: [String: String] = [:]
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var onPosition: ((Int, Int) -> Void)?
    private var modelSpeed: Double { min(max(rate.rate, 0.5), 1) }
    private var root: URL {
        var root = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Kokoro")
        #if DEBUG
        if !KokoroEngine.isInstalled(at: root) {
            root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/iOS/Kokoro")
        }
        #endif
        return root
    }
    override init() { super.init() }
    func play(_ paragraphs: [String], from index: Int, offset: Int = 0, language: String? = nil, rate: SpeechPreferences = SpeechPreferences(), startPaused: Bool = false, onPosition: @escaping (Int, Int) -> Void) {
        stop()
        guard paragraphs.indices.contains(index) else { return }
        do { try rate.validate(); corrections = try PronunciationDictionary.parse(rate.pronunciationDictionary) }
        catch { failure = error.localizedDescription; return }
        self.paragraphs = paragraphs; self.index = index; self.language = language; self.onPosition = onPosition
        self.rate = rate; self.rate.voiceIdentifier = NeuralSpeechVoice.resolvedIdentifier(rate.voiceIdentifier)
        let start = SpeechTextSegment.range(in: paragraphs[index], from: max(0, offset))?.location ?? (paragraphs[index] as NSString).length
        spokenRange = NSRange(location: start, length: 0)
        cursor = SpeechChunkCursor(paragraphs: paragraphs, paragraph: index, offset: start, protectedWords: Array(corrections.keys), continuous: rate.rate >= 1.75)
        reserve = SpeechBufferState(rate: rate.rate)
        underrunCount = 0; hadPlayback = false; pendingUnderrun = false
        exhausted = false; failure = nil; isActive = true; isPlaying = !startPaused
        if !startPaused { startProducer() }
    }
    func stop() {
        prepareTask?.cancel(); prepareTask = nil
        preparedAudio = nil; preparedReader = nil; preparedChunks = []; preparedIndex = 0; preparationProgress = nil
        let wasActive = isActive
        generation = UUID(); renderTask?.cancel(); renderTask = nil; pumpingToken = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil
        scheduled = []; cursor = nil; exhausted = false; reserve = SpeechBufferState(rate: rate.rate)
        isActive = false; isPlaying = false; preparing = false; onPosition = nil; paragraphs = []
        spokenRange = NSRange(location: 0, length: 0)
        if wasActive { Task { await KokoroEngine.shared.releaseAfterIdle() } }
    }
    func configure(_ preferences: SpeechPreferences) {
        let restart = preferences.rate != rate.rate || preferences.voiceIdentifier != rate.voiceIdentifier || preferences.pronunciationDictionary != rate.pronunciationDictionary || preferences.cacheBeforePlayback != rate.cacheBeforePlayback
        guard (try? preferences.validate()) != nil else { failure = "朗读设置格式有误，请检查读音词典。"; return }
        rate = preferences; rate.voiceIdentifier = NeuralSpeechVoice.resolvedIdentifier(preferences.voiceIdentifier)
        guard restart, isActive, let onPosition else { return }
        play(paragraphs, from: index, offset: spokenRange.location, language: language, rate: rate, startPaused: !isPlaying, onPosition: onPosition)
    }
    func togglePause() {
        guard isActive else { return }
        isPlaying.toggle()
        if isPlaying {
            startWhenReady(); startProducer()
        } else { reserve.pause(at: ProcessInfo.processInfo.systemUptime); player?.pause() }
    }
    private func nextChunk() -> SpeechChunk? {
        if preparedAudio != nil {
            guard preparedChunks.indices.contains(preparedIndex) else { return nil }
            let chunk = preparedChunks[preparedIndex]; preparedIndex += 1; return chunk
        }
        return cursor?.next()
    }
    private func startProducer() {
        guard rate.cacheBeforePlayback, rate.rate >= 1.75, preparedAudio == nil else { pump(); return }
        guard prepareTask == nil else { return }
        let token = generation
        let initialCursor = cursor, paragraphs = self.paragraphs
        let root = self.root, speed = Float(self.modelSpeed), corrections = self.corrections, speaker = Int((self.rate.voiceIdentifier ?? NeuralSpeechVoice.defaultIdentifier).split(separator: ":").last ?? "56") ?? 56
        preparing = true; preparationProgress = 0
        let owner = self
        let task = Task.detached(priority: .userInitiated) {
            var walk = initialCursor
            var chunks: [SpeechChunk] = []
            while let chunk = walk?.next() { try Task.checkCancellation(); chunks.append(chunk) }
            guard !chunks.isEmpty else { throw KokoroError.synthesis }
            let source = chunks.map { (paragraphs[$0.paragraph] as NSString).substring(with: $0.range) }
            let total = chunks.count
            let audio = try await KokoroEngine.shared.prepare(texts: source, speaker: speaker, root: root, speed: speed, corrections: corrections) { completed in
                Task { @MainActor [weak owner] in
                    guard let owner, owner.generation == token, owner.isActive, owner.prepareTask != nil else { return }
                    owner.preparationProgress = Double(completed) / Double(total)
                }
            }
            return (audio, chunks)
        }
        prepareTask = task
        Task { @MainActor [weak self] in
            do {
                let (audio, chunks) = try await task.value
                guard let self, self.generation == token, self.isActive else { return }
                self.prepareTask = nil; self.preparationProgress = nil
                self.preparedReader = try audio.makeReader()
                self.preparedAudio = audio; self.preparedChunks = chunks; self.preparedIndex = 0
                self.pump()
                Task { await KokoroEngine.shared.releaseAfterIdle() }
            } catch is CancellationError {}
            catch {
                guard let self, self.generation == token else { return }
                self.failure = error.localizedDescription; self.stop()
            }
        }
    }
    private func publish(_ chunk: SpeechChunk) {
        index = chunk.paragraph; spokenRange = chunk.range
        onPosition?(index, chunk.range.location)
    }
    /// Exactly one inference in flight; schedule the next buffer while the current one sounds.
    private func pump() {
        guard isActive, pumpingToken != generation else { return }
        let token = generation
        pumpingToken = token
        Task { @MainActor in
            defer { if pumpingToken == token { pumpingToken = nil } }
            while isActive, generation == token, reserve.needsMore(at: ProcessInfo.processInfo.systemUptime), !exhausted {
                guard let chunk = nextChunk() else { exhausted = true; break }
                let text = (paragraphs[chunk.paragraph] as NSString).substring(with: chunk.range)
                let root = root, speed = Float(modelSpeed), corrections = corrections
                let speaker = Int((rate.voiceIdentifier ?? NeuralSpeechVoice.defaultIdentifier).split(separator: ":").last ?? "56") ?? 56
                let archive = preparedReader, archiveIndex = preparedIndex - 1
                let started = ProcessInfo.processInfo.systemUptime
                let task = Task.detached(priority: .userInitiated) {
                    if let archive { return try archive.readChunk(archiveIndex) }
                    return try await KokoroEngine.shared.render(text: text, speaker: speaker, root: root, speed: speed, corrections: corrections)
                }
                renderTask = task; preparing = !reserve.isRunning
                do {
                    let audio = try await task.value
                    guard isActive, generation == token else { return }
                    renderTask = nil
                    try schedule(audio, chunk: chunk, token: token, generationSeconds: ProcessInfo.processInfo.systemUptime - started)
                } catch is CancellationError { return }
                catch {
                    guard generation == token else { return }
                    failure = error.localizedDescription; stop(); return
                }
            }
            if generation == token, isActive {
                startWhenReady()
                if exhausted, scheduled.isEmpty { stop() }
            }
        }
    }
    private func schedule(_ audio: KokoroAudio, chunk: SpeechChunk, token: UUID, generationSeconds: Double) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(audio.sampleRate), channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audio.samples.count)),
              let output = buffer.floatChannelData?[0] else { throw KokoroError.synthesis }
        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { if let base = $0.baseAddress { output.update(from: base, count: $0.count) } }
        if engine == nil {
            let engine = AVAudioEngine(), node = AVAudioPlayerNode()
            engine.attach(node)
            let remainder = rate.rate / modelSpeed
            if abs(remainder - 1) > 0.01 {
                let pitch = SpeechAudio.timePitch(rate: remainder)
                engine.attach(pitch); engine.connect(node, to: pitch, format: format)
                engine.connect(pitch, to: engine.mainMixerNode, format: format)
            } else { engine.connect(node, to: engine.mainMixerNode, format: format) }
            self.engine = engine; self.player = node
        }
        guard let player else { throw KokoroError.synthesis }
        scheduled.append(chunk)
        reserve.append(audioSeconds: Double(audio.samples.count) / Double(audio.sampleRate), modelSpeed: modelSpeed, generationSeconds: generationSeconds)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isActive, self.generation == token else { return }
                if self.scheduled.first == chunk {
                    self.scheduled.removeFirst(); self.reserve.completed(at: ProcessInfo.processInfo.systemUptime)
                }
                if self.scheduled.isEmpty {
                    self.pendingUnderrun = self.hadPlayback && self.isPlaying
                    self.player?.pause(); self.preparing = !self.exhausted
                }
                else if self.isPlaying, self.reserve.isRunning, let first = self.scheduled.first { self.publish(first) }
                self.pump()
            }
        }
        startWhenReady()
    }
    private func startWhenReady() {
        guard isPlaying, let engine, let player else { return }
        guard !reserve.isRunning else { preparing = false; return }
        guard reserve.canStart(at: ProcessInfo.processInfo.systemUptime, exhausted: exhausted, immediately: preparedReader != nil) else { preparing = true; return }
        do {
            if !engine.isRunning { try engine.start() }
            if pendingUnderrun { underrunCount += 1 }
            pendingUnderrun = false; hadPlayback = true
            reserve.resume(at: ProcessInfo.processInfo.systemUptime)
            if let first = scheduled.first { publish(first) }
            player.play(); preparing = false
        } catch { failure = error.localizedDescription; stop() }
    }
}
