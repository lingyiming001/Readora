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
    public init(rate: Double = 1, maximumRate: Double = 8, voiceIdentifier: String? = nil, highlightSpokenText: Bool = true) {
        self.voiceIdentifier = voiceIdentifier; self.highlightSpokenText = highlightSpokenText
        self.maximumRate = maximumRate
        self.rate = min(rate, maximumRate)
    }
    private enum CodingKeys: String, CodingKey { case rate, maximumRate, voiceIdentifier, highlightSpokenText }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rate = try values.decode(Double.self, forKey: .rate)
        maximumRate = try values.decode(Double.self, forKey: .maximumRate)
        voiceIdentifier = try values.decodeIfPresent(String.self, forKey: .voiceIdentifier)
        highlightSpokenText = try values.decodeIfPresent(Bool.self, forKey: .highlightSpokenText) ?? true
    }
    public func validate() throws {
        guard rate.isFinite, maximumRate.isFinite, (0.5...8).contains(maximumRate),
              (0.5...maximumRate).contains(rate) else { throw ReadingDataError.invalidPreferences }
    }
    public func capped(to maximum: Double) -> Self { Self(rate: rate, maximumRate: maximum, voiceIdentifier: voiceIdentifier, highlightSpokenText: highlightSpokenText) }
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
