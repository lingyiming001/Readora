import Foundation

public struct MCPLineFramer {
    public enum Event: Equatable { case message(Data), oversized }
    private var buffer = Data()
    private var discarding = false
    public init() {}
    public mutating func append(_ bytes: Data) -> [Event] {
        var events: [Event] = []
        for byte in bytes {
            if byte == 10 {
                if discarding { events.append(.oversized) }
                else if !buffer.isEmpty { events.append(.message(buffer)) }
                buffer.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if buffer.count >= ReadoraMCPProtocol.maximumMessageSize { buffer.removeAll(keepingCapacity: true); discarding = true }
                else { buffer.append(byte) }
            }
        }
        return events
    }
}
