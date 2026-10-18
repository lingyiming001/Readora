import Foundation
import AVFoundation
import Observation
import ReadoraCore
import ReadoraRendering

@MainActor
@Observable
final class SpeechPlayer: NSObject, AVSpeechSynthesizerDelegate {
    var isActive = false
    var isPlaying = false
    var index = 0
    var spokenRange = NSRange(location: 0, length: 0)
    var failure: String?
    private var synthesizer = AVSpeechSynthesizer()
    private var paragraphs: [String] = []
    private var language: String?
    private var rate = SpeechPreferences()
    private var pendingStart = false
    private var offset = 0
    private var utteranceOffset = 0
    private var generation = UUID()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var onPosition: ((Int, Int) -> Void)?
    override init() { super.init(); synthesizer.delegate = self }
    func play(_ paragraphs: [String], from index: Int, offset: Int = 0, language: String? = nil, rate: SpeechPreferences = SpeechPreferences(), startPaused: Bool = false, onPosition: @escaping (Int, Int) -> Void) {
        stop()
        guard paragraphs.indices.contains(index) else { return }
        self.paragraphs = paragraphs; self.index = index; self.onPosition = onPosition; self.language = language
        self.offset = SpeechTextSegment.range(in: paragraphs[index], from: max(0, offset))?.location ?? (paragraphs[index] as NSString).length
        self.rate = rate; pendingStart = startPaused; failure = nil
        isActive = true; isPlaying = !startPaused
        if !startPaused { speakCurrent() }
    }
    func stop() {
        generation = UUID()
        synthesizer.delegate = nil; synthesizer.stopSpeaking(at: .immediate)
        synthesizer = AVSpeechSynthesizer(); synthesizer.delegate = self
        player?.stop(); engine?.stop(); player = nil; engine = nil
        isActive = false; isPlaying = false; pendingStart = false; onPosition = nil; paragraphs = []
        spokenRange = NSRange(location: 0, length: 0)
    }
    func configure(_ preferences: SpeechPreferences) {
        let restart = preferences.rate != rate.rate || preferences.voiceIdentifier != rate.voiceIdentifier
        rate = preferences
        guard restart, isActive, let onPosition else { return }
        play(paragraphs, from: index, offset: spokenRange.location, language: language, rate: rate, startPaused: !isPlaying, onPosition: onPosition)
    }
    func togglePause() {
        if pendingStart { pendingStart = false; isPlaying = true; speakCurrent(); return }
        if rate.rate > 2 {
            isPlaying.toggle()
            if isPlaying { player?.play() } else { player?.pause() }
        } else if isPlaying {
            if synthesizer.pauseSpeaking(at: .immediate) { isPlaying = false }
        } else if synthesizer.continueSpeaking() { isPlaying = true }
    }
    private func speakCurrent() {
        guard isActive, paragraphs.indices.contains(index) else { stop(); return }
        let source = paragraphs[index] as NSString
        guard offset < source.length else { nextParagraph(); return }
        utteranceOffset = offset
        onPosition?(index, offset)
        let length: Int
        if rate.rate > 2 {
            // Bounded chunks avoid rendering an entire large chapter before playback.
            length = SpeechTextSegment.range(in: paragraphs[index], from: offset)?.length ?? 0
        } else { length = source.length - offset }
        let utterance = AVSpeechUtterance(string: source.substring(with: NSRange(location: offset, length: length)))
        utterance.voice = rate.voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
            ?? AVSpeechSynthesisVoice(language: language ?? "zh-CN")
        if rate.rate <= 2 {
            utterance.rate = rate.systemRate(defaultRate: AVSpeechUtteranceDefaultSpeechRate, minimum: AVSpeechUtteranceMinimumSpeechRate, maximum: AVSpeechUtteranceMaximumSpeechRate)
            synthesizer.speak(utterance)
        } else {
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate
            spokenRange = NSRange(location: offset, length: length)
            let token = generation, nextOffset = offset + length
            let collector = SpeechPCMCollector()
            synthesizer.write(utterance) { [weak self] buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength > 0 { collector.append(pcm); return }
                let audio = collector.finish()
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.isActive else { return }
                    self.playRendered(audio, nextOffset: nextOffset, token: token)
                }
            }
        }
    }
    private func playRendered(_ audio: SpeechPCMCollector.Batch, nextOffset: Int, token: UUID) {
        guard let first = audio.buffers.first else {
            failure = "此音色未生成音频，请在设置中更换已安装的系统音色。"; stop(); return
        }
        do {
            let engine: AVAudioEngine, node: AVAudioPlayerNode
            if let existingEngine = self.engine, let existingNode = player,
               existingNode.outputFormat(forBus: 0).isEqual(first.format) {
                engine = existingEngine; node = existingNode; node.stop()
            } else {
                self.engine?.stop()
                engine = AVAudioEngine(); node = AVAudioPlayerNode()
                let pitch = SpeechAudio.timePitch(rate: rate.rate)
                engine.attach(node); engine.attach(pitch)
                engine.connect(node, to: pitch, format: first.format)
                engine.connect(pitch, to: engine.mainMixerNode, format: first.format)
                self.engine = engine; player = node
            }
            for (index, buffer) in audio.buffers.enumerated() {
                if index == audio.buffers.count - 1 {
                    node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == token, self.isActive else { return }
                            self.offset = nextOffset
                            self.speakCurrent()
                        }
                    }
                } else { node.scheduleBuffer(buffer) }
            }
            if !engine.isRunning { try engine.start() }
            if isPlaying { node.play() }
        } catch {
            failure = "无法播放朗读音频：\(error.localizedDescription)"; stop()
        }
    }
    private func nextParagraph() {
        index += 1; offset = 0
        if index < paragraphs.count { speakCurrent() } else { stop() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let senderID = ObjectIdentifier(synthesizer)
        Task { @MainActor [weak self] in
            guard let self, senderID == ObjectIdentifier(self.synthesizer), self.isActive, self.rate.rate <= 2 else { return }
            self.spokenRange = NSRange(location: self.utteranceOffset + characterRange.location, length: characterRange.length)
            self.onPosition?(self.index, self.spokenRange.location)
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let senderID = ObjectIdentifier(synthesizer)
        Task { @MainActor [weak self] in
            guard let self, senderID == ObjectIdentifier(self.synthesizer), self.isActive, self.rate.rate <= 2 else { return }
            self.nextParagraph()
        }
    }
}

/// The synthesis callback may run off the main actor. Buffers are copied before
/// returning to AVFoundation, then transferred once and retained by the player.
nonisolated private final class SpeechPCMCollector: @unchecked Sendable {
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
