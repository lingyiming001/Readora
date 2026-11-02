import Foundation
import NaturalLanguage

public enum SpeechTextSegment {
    /// Convert a native selection in a visible slice back to the book's UTF-16 source offsets.
    public static func sourceSelection(_ local: NSRange, in slice: String, sourceOffset: Int = 0) -> NSRange? {
        let text = slice as NSString
        guard local.location != NSNotFound, local.location >= 0, local.length > 0,
              local.location < text.length, local.length <= text.length - local.location,
              sourceOffset >= 0, sourceOffset <= Int.max - text.length else { return nil }
        let range = text.rangeOfComposedCharacterSequences(for: local)
        return NSRange(location: sourceOffset + range.location, length: range.length)
    }
    /// Bounded phrase chunks keep neural speech responsive while preserving punctuation and composed characters.
    public static func phraseRange(in text: String, from offset: Int, maximumLength: Int = 80, protectedWords: [String] = []) -> NSRange? {
        guard let range = range(in: text, from: offset, maximumLength: maximumLength) else { return nil }
        let source = text as NSString
        let characters = Array(source.substring(with: range))
        var length = 0
        var boundary: Int?
        var hasContent = false
        for (index, character) in characters.enumerated() {
            length += String(character).utf16.count
            hasContent = hasContent || character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            if hasContent && ("。！？!?；;\n".contains(character) || (character == "." && (range.location + length == source.length || source.substring(from: range.location + length).first?.isWhitespace == true) && !isAbbreviation(source, endingAt: range.location + length))) {
                boundary = length
                // Keep closing quotes with the sentence they belong to.
                for next in characters.dropFirst(index + 1) {
                    guard "”’」』）)]\"".contains(next) else { break }
                    boundary! += String(next).utf16.count
                }
                break
            }
            if length >= min(32, max(12, maximumLength / 2)), "，,：:".contains(character) { boundary = length; break }
        }
        if boundary == nil, NSMaxRange(range) < source.length,
           let split = characters.indices.last(where: { characters[$0].isWhitespace }), split > characters.count / 2 {
            boundary = characters.prefix(split + 1).reduce(0) { $0 + String($1).utf16.count }
        }
        var end = range.location + (boundary ?? range.length)
        if boundary == nil, end < source.length {
            let tokenizer = NLTokenizer(unit: .word)
            // A bounded context avoids tokenizing an entire long chapter per chunk.
            let windowStart = max(range.location, end - 24)
            let windowRange = source.rangeOfComposedCharacterSequences(for: NSRange(location: windowStart, length: min(source.length - windowStart, end - windowStart + 24)))
            let context = source.substring(with: windowRange)
            tokenizer.string = context
            let token = tokenizer.tokenRange(at: String.Index(utf16Offset: end - windowRange.location, in: context))
            let word = NSRange(token, in: context)
            let start = windowRange.location + word.location
            if start > range.location + range.length / 2, start < end, windowRange.location + NSMaxRange(word) > end { end = start }
        }
        if boundary != nil {
            for _ in 0..<8 where end < source.length {
                let closing = source.rangeOfComposedCharacterSequence(at: end)
                guard "”’」』）)]\"。！？!?".contains(source.substring(with: closing)) else { break }
                end = NSMaxRange(closing)
            }
        }
        // Do not split a dictionary entry across inference chunks.
        for word in protectedWords where !word.isEmpty {
            let wordLength = (word as NSString).length
            let start = max(range.location, end - wordLength + 1)
            let window = NSRange(location: start, length: min(source.length - start, end - start + wordLength))
            var search = window
            while search.length > 0 {
                let match = source.range(of: word, range: search)
                guard match.location != NSNotFound else { break }
                if match.location < end, NSMaxRange(match) > end { end = NSMaxRange(match) }
                let next = NSMaxRange(match)
                search = NSRange(location: next, length: max(0, NSMaxRange(window) - next))
            }
        }
        return NSRange(location: range.location, length: end - range.location)
    }
    private static func isAbbreviation(_ source: NSString, endingAt offset: Int) -> Bool {
        let window = source.rangeOfComposedCharacterSequences(for: NSRange(location: max(0, offset - 24), length: min(offset, 24)))
        let prefix = source.substring(with: window)
        let word = String(prefix.split(whereSeparator: { $0.isWhitespace || "（(\"“".contains($0) }).last ?? "").lowercased()
        if ["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.", "e.g.", "i.e.", "vs."].contains(word) { return true }
        let initials = word.split(separator: ".")
        return initials.count > 1 && initials.allSatisfy { $0.count == 1 && $0.allSatisfy(\.isLetter) }
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

/// Inference walks ahead independently of the paragraph currently audible.
public struct SpeechChunk: Equatable, Sendable {
    public let paragraph: Int
    public let range: NSRange
}
public struct SpeechChunkCursor: Sendable {
    private let paragraphs: [String]
    private let protectedWords: [String]
    private var paragraph: Int
    private var offset: Int
    private var first = true
    private let continuous: Bool
    private let mergeAfterFirst: Bool
    private let initialLength: Int
    public init(paragraphs: [String], paragraph: Int, offset: Int, protectedWords: [String] = [], continuous: Bool = false, initialLength: Int = 40, mergeAfterFirst: Bool = false) {
        self.paragraphs = paragraphs; self.paragraph = max(0, paragraph); self.offset = max(0, offset)
        self.protectedWords = protectedWords.sorted(); self.continuous = continuous
        self.initialLength = min(80, max(12, initialLength))
        self.mergeAfterFirst = mergeAfterFirst
    }
    public mutating func next() -> SpeechChunk? {
        while paragraphs.indices.contains(paragraph) {
            let text = paragraphs[paragraph] as NSString
            guard offset < text.length else { paragraph += 1; offset = 0; continue }
            let tail = text.substring(from: offset)
            guard tail.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
                paragraph += 1; offset = 0; continue
            }
            guard var range = SpeechTextSegment.phraseRange(in: text as String, from: offset, maximumLength: first && !continuous ? initialLength : 80, protectedWords: protectedWords) else {
                paragraph += 1; offset = 0; continue
            }
            if continuous || (!first && mergeAfterFirst) {
                // Preserve punctuation inside a single utterance, amortizing short-sentence inference.
                for _ in 0..<3 {
                    guard range.length < 64, NSMaxRange(range) < text.length,
                          let next = SpeechTextSegment.phraseRange(in: text as String, from: NSMaxRange(range), maximumLength: max(12, 96 - range.length), protectedWords: protectedWords),
                          NSMaxRange(next) - range.location <= 108 else { break }
                    range.length = NSMaxRange(next) - range.location
                }
            }
            let chunk = SpeechChunk(paragraph: paragraph, range: range)
            offset = NSMaxRange(range); first = false
            return chunk
        }
        return nil
    }
}

/// Measures reserve in seconds at the requested playback rate, not in arbitrary chunk counts.
public struct SpeechBufferState: Sendable {
    public let rate: Double
    private var durations: [Double] = []
    private var headElapsed: Double = 0
    private var runningSince: Double?
    private var generationRatio: Double = 0
    private var modelSpeed: Double = 1
    public var isRunning: Bool { runningSince != nil }
    public var count: Int { durations.count }
    public init(rate: Double) { self.rate = rate.isFinite ? min(8, max(0.5, rate)) : 1 }
    public var startupSeconds: Double {
        let base: Double = rate >= 3 ? 12 : (rate >= 1.75 ? 6 : 1)
        return min(40, base + max(0, generationRatio - 0.7) * (rate >= 3 ? 24 : 12))
    }
    public var targetSeconds: Double { max(6, startupSeconds * 2) }
    public func seconds(at now: Double) -> Double {
        max(0, durations.reduce(0, +) - headElapsed - (runningSince.map { max(0, now - $0) } ?? 0))
    }
    public func needsMore(at now: Double) -> Bool {
        count < 64 && seconds(at: now) < targetSeconds && durations.reduce(0, +) * max(0.5, rate / modelSpeed) < 120
    }
    public func canStart(at now: Double, exhausted: Bool, immediately: Bool = false) -> Bool {
        count > 0 && (immediately || seconds(at: now) >= startupSeconds || exhausted || !needsMore(at: now))
    }
    public mutating func append(audioSeconds: Double, modelSpeed: Double, generationSeconds: Double) {
        self.modelSpeed = modelSpeed
        let duration = audioSeconds / max(0.5, rate / modelSpeed)
        durations.append(duration)
        if generationSeconds > 0.005, duration > 0 {
            let ratio = min(5, generationSeconds / duration)
            generationRatio = generationRatio == 0 ? ratio : generationRatio * 0.8 + ratio * 0.2
        }
    }
    public mutating func resume(at now: Double) { if !durations.isEmpty, runningSince == nil { runningSince = now } }
    public mutating func pause(at now: Double) {
        if let start = runningSince { headElapsed += max(0, now - start) }
        runningSince = nil
    }
    public mutating func completed(at now: Double) {
        if !durations.isEmpty { durations.removeFirst() }
        headElapsed = 0
        if runningSince != nil { runningSince = durations.isEmpty ? nil : now }
    }
}
