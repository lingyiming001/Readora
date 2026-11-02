import Foundation

public enum ReaderTheme: String, Codable, CaseIterable, Sendable {
    case paper, parchment, sage, night
    public var title: String { switch self { case .paper: "纸白"; case .parchment: "暖砂"; case .sage: "浅绿"; case .night: "夜间" } }
}
public enum ReaderFont: String, Codable, CaseIterable, Sendable {
    case songti, pingfang, serif, rounded
    public var title: String { switch self { case .songti: "宋体"; case .pingfang: "苹方"; case .serif: "系统衬线"; case .rounded: "圆体" } }
}
public enum ReadingLayout: String, Codable, CaseIterable, Sendable {
    case scroll, pages
    public var title: String { self == .scroll ? "连续滚动" : "分页阅读" }
}
public struct ReadingPreferences: Codable, Equatable, Sendable {
    public var theme: ReaderTheme = .paper
    public var font: ReaderFont = .pingfang
    public var layout: ReadingLayout = .pages
    public var boldText: Bool? = nil
    public var fontSize: Double = 26
    public var lineSpacing: Double = 8
    public var paragraphSpacing: Double = 20
    public var contentWidth: Double = 960
    public var brightness: Double = 1
    public var animateTransitions: Bool = true
    public init() {}
    public func validate() throws {
        guard (14...40).contains(fontSize), (2...18).contains(lineSpacing),
              (8...36).contains(paragraphSpacing), (480...1400).contains(contentWidth),
              (0.35...1).contains(brightness) else { throw ReadingDataError.invalidPreferences }
    }
}
public struct SpeechPreferences: Codable, Equatable, Sendable {
    public var rate: Double
    public var maximumRate: Double
    public var voiceIdentifier: String?
    public var highlightSpokenText: Bool = true
    public var pronunciationDictionary: String = ""
    public var cacheBeforePlayback: Bool = true
    public init(rate: Double = 1, maximumRate: Double = 2, voiceIdentifier: String? = nil, highlightSpokenText: Bool = true, pronunciationDictionary: String = "", cacheBeforePlayback: Bool = true) {
        self.cacheBeforePlayback = cacheBeforePlayback
        self.pronunciationDictionary = pronunciationDictionary
        self.voiceIdentifier = voiceIdentifier; self.highlightSpokenText = highlightSpokenText
        self.maximumRate = maximumRate
        self.rate = min(rate, maximumRate)
    }
    private enum CodingKeys: String, CodingKey { case rate, maximumRate, voiceIdentifier, highlightSpokenText, pronunciationDictionary, cacheBeforePlayback }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        cacheBeforePlayback = try values.decodeIfPresent(Bool.self, forKey: .cacheBeforePlayback) ?? true
        pronunciationDictionary = try values.decodeIfPresent(String.self, forKey: .pronunciationDictionary) ?? ""
        rate = try values.decode(Double.self, forKey: .rate)
        maximumRate = try values.decode(Double.self, forKey: .maximumRate)
        voiceIdentifier = try values.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        highlightSpokenText = try values.decodeIfPresent(Bool.self, forKey: .highlightSpokenText) ?? true
    }
    public func validate() throws {
        _ = try PronunciationDictionary.parse(pronunciationDictionary)
        guard rate.isFinite, maximumRate.isFinite, (0.5...8).contains(maximumRate),
              (0.5...maximumRate).contains(rate) else { throw ReadingDataError.invalidPreferences }
    }
    public func capped(to maximum: Double) -> Self { Self(rate: rate, maximumRate: maximum, voiceIdentifier: voiceIdentifier, highlightSpokenText: highlightSpokenText, pronunciationDictionary: pronunciationDictionary, cacheBeforePlayback: cacheBeforePlayback) }
    public func systemRate(defaultRate: Float, minimum: Float, maximum: Float) -> Float {
        guard rate.isFinite, maximumRate.isFinite else { return defaultRate }
        return min(maximum, max(minimum, defaultRate * Float(min(rate, maximumRate))))
    }
}
public enum ReadingDataError: LocalizedError {
    case invalidPreferences, invalidMark
    public var errorDescription: String? {
        switch self {
        case .invalidPreferences: "阅读或朗读设置超出有效范围。"
        case .invalidMark: "书签或高亮位置无效，请重新选择。"
        }
    }
}

/// Stable engine-qualified identifiers shared by both platform settings.
public struct NeuralSpeechVoice: Identifiable, Sendable {
    public let id: String
    public let title: String
    public static let defaultIdentifier = "kokoro:56"
    /// Migrate removed system/model IDs without losing speed or reading position.
    public static func resolvedIdentifier(_ identifier: String?) -> String {
        all.contains { $0.id == identifier } ? identifier! : defaultIdentifier
    }
    public static let all: [Self] = [
        .init(id: "kokoro:0", title: "Kokoro · 双语 枫 Maple"),
        .init(id: "kokoro:1", title: "Kokoro · 双语 晴 Sol"),
        .init(id: "kokoro:2", title: "Kokoro · 双语 谷 Vale"),
        .init(id: "kokoro:3", title: "Kokoro · 女声 晓 001"),
        .init(id: "kokoro:11", title: "Kokoro · 女声 甜 009"),
        .init(id: "kokoro:23", title: "Kokoro · 女声 婉 021"),
        .init(id: "kokoro:33", title: "Kokoro · 女声 静 031"),
        .init(id: "kokoro:43", title: "Kokoro · 女声 莺 041"),
        .init(id: "kokoro:56", title: "Kokoro · 女声 暖 054"),
        .init(id: "kokoro:58", title: "Kokoro · 男声 朗 001"),
        .init(id: "kokoro:60", title: "Kokoro · 男声 健 003"),
        .init(id: "kokoro:68", title: "Kokoro · 男声 岳 011"),
        .init(id: "kokoro:78", title: "Kokoro · 男声 川 021"),
        .init(id: "kokoro:88", title: "Kokoro · 男声 沉 031"),
        .init(id: "kokoro:102", title: "Kokoro · 男声 苍 045"),
    ]
}

/// A local word dictionary: tone-number pinyin is converted to this model's phonemes.
public enum PronunciationDictionary {
    public static func parse(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let value = line.trimmingCharacters(in: .whitespaces)
            if value.isEmpty { continue }
            let parts = value.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 12,
                  parts[0].unicodeScalars.allSatisfy({ (0x3400...0x9FFF).contains($0.value) }),
                  result[parts[0]] == nil else { throw PronunciationError.invalidEntry(String(line)) }
            let syllables = parts[1].lowercased().replacingOccurrences(of: "’", with: " ").replacingOccurrences(of: "'", with: " ")
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard syllables.count == parts[0].count else { throw PronunciationError.invalidEntry(String(line)) }
            result[parts[0]] = try syllables.map(phonemes).joined(separator: " ")
        }
        guard result.count <= 300 else { throw PronunciationError.tooManyEntries }
        return result
    }
    public static func phonemes(_ input: String) throws -> String {
        var syllable = input.lowercased().replacingOccurrences(of: "u:", with: "v")
        var tone: Int?
        if let last = syllable.last, let value = Int(String(last)) {
            guard (1...5).contains(value) else { throw PronunciationError.invalidEntry(input) }
            tone = value; syllable.removeLast()
        }
        var letters = ""
        for scalar in syllable.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x304, 0x301, 0x30C, 0x300:
                let value = [0x304: 1, 0x301: 2, 0x30C: 3, 0x300: 4][Int(scalar.value)]!
                guard tone == nil || tone == value else { throw PronunciationError.invalidEntry(input) }
                tone = value
            case 0x308:
                guard letters.last == "u" else { throw PronunciationError.invalidEntry(input) }
                letters.removeLast(); letters += "v"
            case 97...122: letters.unicodeScalars.append(scalar)
            default: throw PronunciationError.invalidEntry(input)
            }
        }
        let zero: [String: String] = ["yi":"i", "ya":"ia", "yao":"iao", "ye":"ie", "you":"iu", "yan":"ian", "yin":"in", "yang":"iang", "ying":"ing", "yong":"iong", "yu":"v", "yue":"ve", "yuan":"van", "yun":"vn", "wu":"u", "wa":"ua", "wo":"uo", "wai":"uai", "wei":"ui", "wan":"uan", "wen":"un", "wang":"uang", "weng":"ueng"]
        if let value = zero[letters] { letters = value }
        let initials = ["zh":"ㄓ", "ch":"ㄔ", "sh":"ㄕ", "b":"ㄅ", "p":"ㄆ", "m":"ㄇ", "f":"ㄈ", "d":"ㄉ", "t":"ㄊ", "n":"ㄋ", "l":"ㄌ", "g":"ㄍ", "k":"ㄎ", "h":"ㄏ", "j":"ㄐ", "q":"ㄑ", "x":"ㄒ", "r":"ㄖ", "z":"ㄗ", "c":"ㄘ", "s":"ㄙ"]
        let initial = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s"].first { letters.hasPrefix($0) }
        if let initial { letters.removeFirst(initial.count) }
        if let initial, ["j", "q", "x"].contains(initial), letters.hasPrefix("u") { letters = "v" + letters.dropFirst() }
        let finals = ["a":"ㄚ", "o":"ㄛ", "e":"ㄜ", "ai":"ㄞ", "ei":"ㄟ", "ao":"ㄠ", "ou":"ㄡ", "an":"ㄢ", "en":"ㄣ", "ang":"ㄤ", "eng":"ㄥ", "er":"ㄦ", "i":"ㄧ", "u":"ㄨ", "v":"ㄩ", "ia":"压", "ie":"ㄝ", "iao":"要", "iu":"又", "iou":"又", "ian":"言", "in":"阴", "iang":"阳", "ing":"应", "iong":"用", "ua":"穵", "uo":"我", "uai":"外", "ui":"为", "uei":"为", "uan":"万", "un":"文", "uen":"文", "uang":"王", "ueng":"瓮", "ve":"月", "van":"元", "vn":"云", "ong":"中"]
        let final: String?
        if letters == "i", let initial, ["zh", "ch", "sh", "r"].contains(initial) { final = "十" }
        else if letters == "i", let initial, ["z", "c", "s"].contains(initial) { final = "ㄭ" }
        else { final = finals[letters] }
        guard let final else { throw PronunciationError.invalidEntry(input) }
        return ([initial.flatMap { initials[$0] }, final, String(tone ?? 5)].compactMap { $0 }).joined(separator: " ")
    }
}
public enum PronunciationError: LocalizedError {
    case invalidEntry(String), tooManyEntries
    public var errorDescription: String? {
        switch self {
        case .invalidEntry(let line): "读音格式有误：\(line)。每行填写「词语 = 带声调拼音」，例如：银行 = yin2 hang2。"
        case .tooManyEntries: "读音词典最多保存 300 个词语。"
        }
    }
}
