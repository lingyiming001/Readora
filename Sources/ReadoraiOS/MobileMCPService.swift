import SwiftUI
@preconcurrency import Network
import ReadoraCore
import Darwin

@MainActor @Observable
final class MobileMCPService {
    var enabled = UserDefaults.standard.bool(forKey: "mobileMCPEnabled")
    var running = false
    var error: String?
    private(set) var token = ""
    private var listener: NWListener?
    private var starting = false
    private var generation = UUID()
    private var connections: [UUID: NWConnection] = [:]
    private var buffers: [UUID: Data] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var execute: (@Sendable (AIAppCommand) async throws -> String)?
    private var processing = false
    private var window = Date()
    private var requests = 0
    private let queue = DispatchQueue(label: "readora.mobile.mcp")
    static let port: UInt16 = 18543
    var endpoint: String { "http://\(Self.localAddress):\(Self.port)/mcp" }
    var configuration: String {
        let object: [String: Any] = ["mcpServers": ["readora-iphone": ["type": "http", "url": endpoint, "headers": ["Authorization": "Bearer " + token]]]]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
    private static var localAddress: String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0 else { return "127.0.0.1" }
        defer { freeifaddrs(interfaces) }
        var current = interfaces
        while let item = current {
            defer { current = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.pointee.ifa_name) == "en0" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        }
        return "127.0.0.1"
    }
    func start(execute: @escaping @Sendable (AIAppCommand) async throws -> String) async {
        guard listener == nil, !starting, enabled else { return }
        starting = true; defer { starting = false }
        let epoch = generation
        self.execute = execute; error = nil
        do {
            token = try await AICredentialStore.shared.key(account: "readora-mobile-mcp") ?? ""
            if token.isEmpty {
                token = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                try await AICredentialStore.shared.save(token, account: "readora-mobile-mcp")
            }
            guard enabled, generation == epoch else { return }
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.service = NWListener.Service(name: "Readora iPhone", type: "_readora-mcp._tcp")
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == epoch else { return }
                    if case .ready = state { self.running = true }
                    if case .failed(let failure) = state { self.error = failure.localizedDescription; self.stop() }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in Task { @MainActor in self?.accept(connection) } }
            listener.start(queue: queue)
        } catch { self.error = error.localizedDescription; stop() }
    }
    func stop() {
        generation = UUID(); listener?.cancel(); listener = nil; running = false
        for id in Array(connections.keys) { close(id) }
        processing = false
    }
    private func accept(_ connection: NWConnection) {
        guard listener != nil, connections.count < 4 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection; buffers[id] = Data()
        connection.start(queue: queue)
        timeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)); self?.close(id) } catch {}
        }
        receive(id)
    }
    private func receive(_ id: UUID) {
        guard let connection = connections[id] else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                if let data { self.buffers[id, default: Data()].append(data) }
                guard error == nil, let buffer = self.buffers[id] else { self.close(id); return }
                switch ReadoraMCPHTTP.parse(buffer, token: self.token) {
                case .incomplete: if complete { self.close(id) } else { self.receive(id) }
                case .rejected(let status): self.reply(id, status: status)
                case .request(let body): self.dispatch(id, body: body)
                }
            }
        }
    }
    private func dispatch(_ id: UUID, body: Data) {
        if Date().timeIntervalSince(window) > 10 { window = Date(); requests = 0 }
        requests += 1
        guard requests <= 30, !processing, let execute else { reply(id, status: 429); return }
        processing = true
        let epoch = generation
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == epoch { self.processing = false } }
            let response = await ReadoraMCPProtocol.handle(body, execute: execute)
            guard !Task.isCancelled else { return }
            self.reply(id, status: response == nil ? 202 : 200, body: response ?? Data())
        }
    }
    private func reply(_ id: UUID, status: Int, body: Data = Data()) {
        guard let connection = connections[id] else { return }
        let reason = status == 200 ? "OK" : status == 202 ? "Accepted" : "Request Rejected"
        let extra = status == 405 ? "Allow: POST\r\n" : status == 401 ? "WWW-Authenticate: Bearer realm=Readora\r\n" : ""
        var response = Data("HTTP/1.1 \(status) \(reason)\r\n\(extra)Content-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in Task { @MainActor in self?.close(id) } })
    }
    private func close(_ id: UUID) {
        connections.removeValue(forKey: id)?.cancel(); buffers[id] = nil
        tasks.removeValue(forKey: id)?.cancel(); timeouts.removeValue(forKey: id)?.cancel()
    }
}

struct MobileExternalApproval: ViewModifier {
    @Bindable var library: MobileLibrary
    func body(content: Content) -> some View {
        content.overlay {
            if let command = library.externalCommand {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 18) {
                        Label("外部 AI 请求确认", systemImage: "lock.shield").font(.headline)
                        ScrollView { Text(library.confirmationText(command)).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
                        HStack {
                            Button("拒绝", role: .cancel) { library.resolveExternal(false) }
                            Spacer()
                            Button("确认执行", role: .destructive) { library.resolveExternal(true) }
                        }.buttonStyle(.bordered)
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24)).padding(24)
                        .accessibilityAddTraits(.isModal)
                }.zIndex(1000)
            }
        }
    }
}
