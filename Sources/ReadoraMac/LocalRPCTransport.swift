import Foundation
import Network
import ReadoraCore

/// All mutable transport state is confined to queue; request execution never blocks it.
final class LocalRPCTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.readora.mcp")
    private let listener: NWListener
    private let token: String
    private let handler: @Sendable (Data) async -> Data?
    private var peers: [UUID: Peer] = [:]
    private final class Peer: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        var bytes = Data()
        var received = false
        var task: Task<Void, Never>?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    init(port: UInt16, token: String, status: @escaping @Sendable (String) -> Void, handler: @escaping @Sendable (Data) async -> Data?) throws {
        self.token = token; self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: status("已连接 · 127.0.0.1:\(port)")
            case .failed: status("服务启动失败：端口可能被占用，请关闭后重试或修改端口。")
            case .cancelled: status("已关闭")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.peers.count < 8 else { connection.cancel(); return }
            let peer = Peer(connection); self.peers[peer.id] = peer
            connection.start(queue: self.queue)
            self.receive(peer)
            self.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                if !peer.received { self?.close(peer) }
            }
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.async { [self] in
            listener.cancel()
            for peer in Array(peers.values) { close(peer) }
        }
    }
    private func close(_ peer: Peer) {
        peer.task?.cancel(); peer.connection.cancel(); peers.removeValue(forKey: peer.id)
    }
    private func receive(_ peer: Peer) {
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { peer.connection.cancel(); return }
            if let data { peer.bytes.append(data) }
            switch LocalRPCRequest.parse(peer.bytes, token: self.token) {
            case .incomplete:
                if done || error != nil { self.close(peer) } else { self.receive(peer) }
            case .rejected:
                peer.received = true; self.respond(peer, status: "403 Forbidden", body: Data())
            case .body(let body):
                peer.received = true; peer.bytes = Data()
                peer.task = Task { [weak self] in
                    guard let self else { return }
                    let response = await self.handler(body)
                    guard !Task.isCancelled else { return }
                    self.queue.async { self.respond(peer, status: response == nil ? "204 No Content" : "200 OK", body: response ?? Data()) }
                }
            }
        }
    }
    private func respond(_ peer: Peer, status: String, body: Data) {
        guard peers[peer.id] != nil else { return }
        let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        peer.connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.close(peer) })
    }
}
