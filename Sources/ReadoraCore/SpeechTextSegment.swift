import Foundation

public enum SpeechTextSegment {
    /// Returns UTF-16 offsets while keeping emoji and combining characters intact.
    public static func range(in text: String, from offset: Int, maximumLength: Int = 180) -> NSRange? {
        let source = text as NSString
        guard offset < source.length, maximumLength > 0 else { return nil }
        let start = source.rangeOfComposedCharacterSequence(at: max(0, offset)).location
        return source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(maximumLength, source.length - start)))
    }
}
