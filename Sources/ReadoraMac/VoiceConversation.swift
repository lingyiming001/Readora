import SwiftUI
import ReadoraCore
@preconcurrency import Speech
@preconcurrency import AVFoundation

@MainActor @Observable
final class VoiceConversation: NSObject {
    var listening = false
    var authorizing = false
    var speaking = false
    var transcript = ""
    var error: String?
    var locale = "zh-CN"
    var readReplies = true
    var sendAfterRecording = true
    var onTranscript: ((String) -> Void)?
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    #if os(iOS)
    private let replyPlayer = MobileSpeech()
    #else
    private let replyPlayer = SpeechPlayer()
    #endif
    private var replyMonitor: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finishing: Task<Void, Never>?
    private var generation = UUID()
    override init() { super.init() }
    func start() async {
        stop(); error = nil; transcript = ""; authorizing = true
        let epoch = generation
        let speechStatus = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        guard epoch == generation else { return }
        guard speechStatus == .authorized else { authorizing = false; error = "请在系统设置的隐私与安全性中允许 Readora 使用语音识别。"; return }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard epoch == generation else { return }
        authorizing = false
        guard allowed else { error = "请在系统设置的隐私与安全性中允许 Readora 使用麦克风。"; return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else { error = "当前语言的语音识别暂不可用，请稍后重试或使用文字输入。"; return }
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { self.error = "无法启动录音：" + error.localizedDescription; return }
        #endif
        let audio = AVAudioEngine(), input = audio.inputNode, format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { error = "没有可用的麦克风输入。"; return }
        let bufferRequest = SFSpeechAudioBufferRecognitionRequest()
        bufferRequest.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { bufferRequest.requiresOnDeviceRecognition = true }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in bufferRequest.append(buffer) }
        engine = audio; request = bufferRequest; listening = true
        recognition = recognizer.recognitionTask(with: bufferRequest) { [weak self] result, failure in
            let text = result?.bestTranscription.formattedString, final = result?.isFinal ?? false, failed = failure != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == epoch else { return }
                if let text { self.transcript = String(text.prefix(1200)) }
                if final { self.complete(epoch: epoch) }
                else if failed {
                    // A stopped recognizer may report an error after producing usable text.
                    if !self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.complete(epoch: epoch) }
                    else { self.stop(); self.error = "语音识别未成功，请检查麦克风、语言或网络后重试。" }
                }
            }
        }
        do { audio.prepare(); try audio.start() }
        catch { stop(); self.error = "麦克风启动失败：" + error.localizedDescription; return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(45)); self?.finishRecording() } catch {}
        }
    }
    func finishRecording() {
        guard listening else { return }
        stopMicrophone(); request?.endAudio(); timer?.cancel(); timer = nil
        let epoch = generation
        finishing = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)); self?.complete(epoch: epoch) } catch {}
        }
    }
    private func complete(epoch: UUID) {
        guard epoch == generation else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        if text.isEmpty { error = "没有识别到文字，请重试。" }
        else { onTranscript?(text) }
    }
    private func stopMicrophone() {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil; listening = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
    func stop() {
        generation = UUID(); authorizing = false
        stopMicrophone(); request?.endAudio(); request = nil
        recognition?.cancel(); recognition = nil
        timer?.cancel(); timer = nil; finishing?.cancel(); finishing = nil
        stopReply()
    }
    func speakReply(_ text: String, voice: String?) {
        stopReply(); guard readReplies, !text.isEmpty else { return }
        let preferences = SpeechPreferences(voiceIdentifier: NeuralSpeechVoice.resolvedIdentifier(voice))
        #if os(iOS)
        replyPlayer.configure(preferences, persistChoice: false)
        replyPlayer.start([String(text.prefix(12000))], from: 0)
        #else
        replyPlayer.play([String(text.prefix(12000))], from: 0, rate: preferences) { _, _ in }
        #endif
        speaking = true
        replyMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                #if os(iOS)
                let active = self.replyPlayer.playing
                let failure = self.replyPlayer.error
                #else
                let active = self.replyPlayer.isActive
                let failure = self.replyPlayer.failure
                #endif
                if !active { self.speaking = false; if let failure { self.error = failure }; return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }
    func stopReply() { replyMonitor?.cancel(); replyMonitor = nil; replyPlayer.stop(); speaking = false }
}
