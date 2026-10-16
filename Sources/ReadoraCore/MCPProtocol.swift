import Foundation

/// Stateless JSON-RPC endpoint, transported by the bundled stdio bridge.
public enum ReadoraMCPProtocol {
    public static let version = "2025-06-18"
    public static let maximumMessageSize = 65_536
    public static func handle(_ data: Data, execute: @Sendable (AIAppCommand) async throws -> String) async -> Data? {
        guard data.count <= maximumMessageSize else { return error(id: NSNull(), code: -32600, message: "请求过大") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["jsonrpc"] as? String == "2.0", let method = object["method"] as? String else {
            return error(id: NSNull(), code: -32700, message: "无效 JSON-RPC 请求")
        }
        guard let id = object["id"] else { return nil }
        guard id is String || (id is NSNumber && CFGetTypeID(id as CFTypeRef) != CFBooleanGetTypeID()) else {
            return error(id: NSNull(), code: -32600, message: "无效请求 ID")
        }
        let params = object["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? version
            let supported = ["2024-11-05", "2025-03-26", version]
            return result(id: id, value: ["protocolVersion": supported.contains(requested) ? requested : version,
                "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "Readora", "version": "0.6.0"],
                "instructions": "操作用户本机Readora。先查询书籍/书架ID；仅按用户明确要求操作。删除类必须在Readora中确认；不要重复提交等待确认的操作。"])
        case "ping": return result(id: id, value: [:])
        case "tools/list":
            let function = AIAppCommand.tool["function"] as! [String: Any]
            return result(id: id, value: ["tools": [["name": "readora", "description": function["description"]!, "inputSchema": function["parameters"]!]]])
        case "tools/call":
            guard params["name"] as? String == "readora", let arguments = params["arguments"] as? [String: Any], arguments["ids"] == nil,
                  let encoded = try? JSONSerialization.data(withJSONObject: arguments), let source = String(data: encoded, encoding: .utf8),
                  let command = try? AIAppCommand.parse(source) else {
                return error(id: id, code: -32602, message: "工具或参数无效")
            }
            do {
                let text = try await execute(command)
                return result(id: id, value: ["content": [["type": "text", "text": String(text.prefix(24000))]], "isError": false])
            } catch {
                return result(id: id, value: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default: return error(id: id, code: -32601, message: "方法不存在")
        }
    }
    public static func error(id: Any, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }
    private static func result(id: Any, value: [String: Any]) -> Data { encode(["jsonrpc": "2.0", "id": id, "result": value]) }
    private static func encode(_ value: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data() }
}
import CoreFoundation
