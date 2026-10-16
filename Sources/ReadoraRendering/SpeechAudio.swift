import AVFoundation

public enum SpeechAudio {
    /// Time stretching extends system speech beyond the utterance rate ceiling.
    public static func timePitch(rate: Double) -> AVAudioUnitTimePitch {
        let effect = AVAudioUnitTimePitch()
        effect.rate = Float(rate.isFinite ? min(8, max(0.5, rate)) : 1)
        effect.pitch = 0
        return effect
    }
}
