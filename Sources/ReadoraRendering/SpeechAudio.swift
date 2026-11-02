import AVFoundation

public enum SpeechAudio {
    /// Preserve synthesis articulation, then accelerate the complete audio.
    public static func timePitch(rate: Double) -> AVAudioUnitTimePitch {
        let effect = AVAudioUnitTimePitch()
        effect.rate = Float(rate.isFinite ? min(8, max(0.5, rate)) : 1)
        effect.pitch = 0
        effect.overlap = 16
        return effect
    }
}
