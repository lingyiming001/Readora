import Foundation

public struct ImportSettings: Codable, Equatable, Sendable {
    public static let defaultMaxBookSizeMB = 200
    public static let allowedRange = 1...2048
    public static let bytesPerMB = 1024 * 1024
    public var maxBookSizeMB: Int

    public init(maxBookSizeMB: Int = Self.defaultMaxBookSizeMB) {
        self.maxBookSizeMB = maxBookSizeMB
    }
    public var isValid: Bool { Self.allowedRange.contains(maxBookSizeMB) }
    public var maxBookSizeBytes: Int64 { isValid ? Int64(maxBookSizeMB) * Int64(Self.bytesPerMB) : 0 }
    public func validate() throws {
        guard isValid else { throw ImportSettingsError.invalidLimit }
    }
    public func validateFileSize(_ size: Int64) throws {
        try validate()
        guard size >= 0, size <= maxBookSizeBytes else { throw LibraryError.tooLarge(limitMB: maxBookSizeMB) }
    }
}

public enum ImportSettingsError: LocalizedError {
    case invalidLimit
    public var errorDescription: String? { "书籍大小上限须为 1–2048 MB 的整数。" }
}
