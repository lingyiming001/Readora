import AVFoundation
import Observation

@MainActor @Observable
final class MobileSpeech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    var playing = false
    var paused = false
    var error: String?
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    private var texts: [String] = []
    private var index = 0
    private var utteranceID: ObjectIdentifier?
    var onParagraph: ((Int) -> Void)?
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
        _ = synthesizer.pauseSpeaking(at: .immediate); paused = true
    }
    func start(_ paragraphs: [String], from position: Int) {
        stop()
        guard paragraphs.indices.contains(position) else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            texts = paragraphs; index = position; playing = true
            speakNext()
        } catch { self.error = error.localizedDescription }
    }
    private func speakNext() {
        while index < texts.count, texts[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { index += 1 }
        guard playing, texts.indices.contains(index) else { stop(); return }
        onParagraph?(index)
        let utterance = AVSpeechUtterance(string: texts[index])
        utterance.rate = rate
        utteranceID = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }
    func togglePause() {
        if paused {
            do { try AVAudioSession.sharedInstance().setActive(true); _ = synthesizer.continueSpeaking(); paused = false }
            catch { self.error = error.localizedDescription }
        }
        else { _ = synthesizer.pauseSpeaking(at: .word); paused = true }
    }
    func stop() {
        utteranceID = nil; playing = false; paused = false; texts = []
        synthesizer.stopSpeaking(at: .immediate)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.utteranceID == id, self.playing else { return }
            self.index += 1; self.speakNext()
        }
    }
}
