import Foundation

public struct AIModelProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var configuration: AIConfiguration
    public init(id: UUID = UUID(), name: String = "", configuration: AIConfiguration = AIConfiguration()) {
        self.id = id; self.name = name; self.configuration = configuration
    }
    public var title: String { name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? configuration.provider.title + " · " + configuration.model : name }
}
public struct AIModelRegistry: Codable, Equatable, Sendable {
    public var profiles: [AIModelProfile]
    public init(profiles: [AIModelProfile] = []) { self.profiles = profiles }
    public var enabled: [AIModelProfile] { profiles.filter { $0.configuration.enabled } }
    public var defaultProfile: AIModelProfile? { enabled.first }
    public func route(_ id: UUID? = nil) -> AIModelProfile? {
        if let id { return enabled.first { $0.id == id } }
        return defaultProfile
    }
    public func validate() throws {
        guard profiles.count <= 30, Set(profiles.map(\.id)).count == profiles.count,
              profiles.allSatisfy({ $0.name.count <= 100 }) else { throw AIError.invalidModelRegistry }
        for profile in profiles { try profile.configuration.validate(requireModel: profile.configuration.enabled) }
    }
}
