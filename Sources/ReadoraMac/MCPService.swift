import SwiftUI
import AppKit
import ReadoraCore

@MainActor @Observable
final class MCPService {
    var enabled = false
    var status = "已关闭"
    var port: UInt16 = 19876
    var token = UUID().uuidString + UUID().uuidString
    var pending: AIAppCommand?
    var busy = false
    var recentEvents: [String] = []
    private var transport: LocalRPCTransport?
    private var decision: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    private var generation = UUID()
    private let defaults: UserDefaults?
    init(persistConnection: Bool = true) {
        defaults = persistConnection ? .standard : nil
        if let saved = defaults?.string(forKey: "mcp.connection-token"), saved.count >= 64 { token = saved }
        if let saved = defaults?.object(forKey: "mcp.port") as? Int, (1024...65535).contains(saved) { port = UInt16(saved) }
    }
    func start(model: AppModel) {
        stop()
        enabled = true; status = "正在启动…"
        defaults?.set(token, forKey: "mcp.connection-token"); defaults?.set(Int(port), forKey: "mcp.port")
        let currentGeneration = generation
        do {
            transport = try LocalRPCTransport(port: port, token: token, status: { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    self.status = value
                    if value.hasPrefix("服务启动失败") { self.enabled = false; self.resolve(false) }
                }
            }, handler: { [weak self, weak model] data in
                guard let self, let model else { return ReadoraMCPProtocol.error(id: NSNull(), code: -32000, message: "服务已关闭") }
                return await ReadoraMCPProtocol.handle(data) { command in
                    return try await self.perform(command, model: model, generation: currentGeneration)
                }
            })
        } catch { enabled = false; status = "启动失败：" + error.localizedDescription }
    }
    func stop() {
        generation = UUID(); enabled = false; transport?.stop(); transport = nil
        resolve(false); status = "已关闭"
    }
    func rotateToken(model: AppModel) { token = UUID().uuidString + UUID().uuidString; defaults?.set(token, forKey: "mcp.connection-token"); if enabled { start(model: model) } }
    func resolve(_ allowed: Bool) {
        timeout?.cancel(); timeout = nil
        let continuation = decision; decision = nil; pending = nil
        continuation?.resume(returning: allowed)
    }
    func perform(_ command: AIAppCommand, model: AppModel, generation expected: UUID? = nil) async throws -> String {
        guard enabled, expected == nil || expected == generation else { throw MCPServiceError.unavailable }
        guard !busy else { throw MCPServiceError.busy }
        busy = true; defer { busy = false }
        let bound = model.boundAICommand(command), epoch = generation
        var confirmed = false
        if bound.requiresConfirmation {
            confirmed = await withCheckedContinuation { continuation in
                decision = continuation; pending = bound
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(120)); self?.resolve(false) } catch {}
                }
            }
            guard confirmed else { throw AIAppAgentError.userDeclined }
        }
        try Task.checkCancellation()
        guard enabled, epoch == generation else { throw MCPServiceError.unavailable }
        // UI actions are dispatched through the same validated command executor as the in-app AI.
        let result = try await model.executeAICommand(bound, confirmed: confirmed)
        if bound.action == .importBooks { model.pendingAIImport = false; model.chooseFile() }
        if bound.action == .settings { model.externalSettingsRequest = UUID() }
        recentEvents.insert("\(Date().formatted(date: .omitted, time: .shortened)) · \(bound.action.rawValue)", at: 0)
        recentEvents = Array(recentEvents.prefix(12))
        return result
    }
    var clientConfiguration: String {
        let executable = Bundle.main.bundleURL.pathExtension == "app"
            ? Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ReadoraMCP").path
            : URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("ReadoraMCP").path
        let value: [String: Any] = ["mcpServers": ["readora": ["command": executable, "args": [], "env": ["READORA_MCP_TOKEN": token, "READORA_MCP_PORT": String(port)]]]]
        return (try? String(data: JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)) ?? ""
    }
}
enum MCPServiceError: LocalizedError {
    case unavailable, busy
    var errorDescription: String? { self == .busy ? "Readora正在处理另一个外部操作，请完成确认后重试。" : "Readora MCP服务已关闭或连接已更新。" }
}

struct MCPSettingsView: View {
    @Bindable var model: AppModel
    @State private var portText = "19876"
    @State private var copied = false
    var body: some View {
        Form {
            Section("让其他 AI 操作 Readora") {
                Toggle("启用本机 MCP 服务", isOn: Binding(get: { model.mcp.enabled }, set: { value in
                    if value, let port = UInt16(portText), port >= 1024 { model.mcp.port = port; model.mcp.start(model: model) }
                    else { model.mcp.stop(); if value { model.mcp.status = "请输入1024–65535之间的有效端口。" } }
                }))
                Text(model.mcp.status).font(.caption).foregroundStyle(.secondary)
                TextField("本机端口（1024–65535）", text: $portText).disabled(model.mcp.enabled)
                Text("将配置添加到支持 stdio MCP 的 AI 产品中。Readora 必须保持打开；每次启动默认关闭服务。只有本机可访问，连接令牌等同于操作授权，请勿分享。")
                    .font(.caption).foregroundStyle(.secondary)
                Button(copied ? "已复制连接配置" : "复制 MCP 连接配置") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.mcp.clientConfiguration, forType: .string); copied = true
                }.disabled(!model.mcp.enabled)
                Button("重置连接令牌") { model.mcp.rotateToken(model: model); copied = false }
                Text("支持书库、书架、阅读和应用配置操作。删除、清空和移除操作会在 Readora 内等待确认，120秒未确认自动拒绝。服务不提供系统命令、任意文件访问或 API Key。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.mcp.recentEvents.isEmpty {
                Section("最近外部操作") { ForEach(Array(model.mcp.recentEvents.enumerated()), id: \.offset) { _, event in Text(event).font(.caption) } }
            }
        }.readoraForm(model.preferences.theme).task { portText = String(model.mcp.port) }
    }
}

struct ExternalOperationConfirmation: View {
    @Bindable var model: AppModel
    var body: some View {
        if let command = model.mcp.pending {
            VStack(alignment: .leading, spacing: 12) {
                Label("外部 AI 请求确认", systemImage: "lock.shield").font(.headline)
                Text(model.aiCommandSummary(command)).font(.callout)
                Text("只确认你刚刚要求外部 AI 执行的任务。两分钟未确认将自动拒绝。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("拒绝") { model.mcp.resolve(false) }
                    Spacer()
                    Button("确认执行", role: .destructive) { model.mcp.resolve(true) }.buttonStyle(.borderedProminent)
                }
            }.padding(20).frame(width: 420).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.orange.opacity(0.5))).shadow(radius: 20).padding(24)
        }
    }
}
