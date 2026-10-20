import Foundation

public enum SpeechTextSegment {
    /// Bounded phrase chunks keep neural speech responsive while preserving punctuation and composed characters.
    public static func phraseRange(in text: String, from offset: Int, maximumLength: Int = 80) -> NSRange? {
        guard let range = range(in: text, from: offset, maximumLength: maximumLength) else { return nil }
        let source = text as NSString
        let chunk = source.substring(with: range)
        var length = 0
        for character in chunk {
            length += String(character).utf16.count
            if length >= 12, "。！？!?；;，,\n".contains(character) { return NSRange(location: range.location, length: length) }
        }
        return range
    }
    /// Intersect a spoken UTF-16 range with a rendered slice, returning slice-local offsets.
    public static func localIntersection(_ spoken: NSRange, in slice: NSRange) -> NSRange? {
        guard spoken.location >= 0, spoken.length > 0, spoken.location != NSNotFound,
              slice.location >= 0, slice.length > 0, slice.location != NSNotFound,
              spoken.location <= Int.max - spoken.length, slice.location <= Int.max - slice.length else { return nil }
        let start = max(spoken.location, slice.location)
        let end = min(spoken.location + spoken.length, slice.location + slice.length)
        guard end > start else { return nil }
        return NSRange(location: start - slice.location, length: end - start)
    }
    /// Returns UTF-16 offsets while keeping emoji and combining characters intact.
    public static func range(in text: String, from offset: Int, maximumLength: Int = 180) -> NSRange? {
        let source = text as NSString
        guard offset < source.length, maximumLength > 0 else { return nil }
        let start = source.rangeOfComposedCharacterSequence(at: max(0, offset)).location
        return source.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: min(maximumLength, source.length - start)))
    }
}
