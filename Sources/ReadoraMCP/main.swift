import Foundation
import Darwin
import ReadoraCore

// stdout is reserved for newline-delimited MCP messages; no launch/build logging.
let environment = ProcessInfo.processInfo.environment
let token = environment["READORA_MCP_TOKEN"] ?? ""
let port = UInt16(environment["READORA_MCP_PORT"] ?? "19876") ?? 19876
let sessionConfiguration = URLSessionConfiguration.ephemeral
sessionConfiguration.timeoutIntervalForRequest = 150
sessionConfiguration.timeoutIntervalForResource = 155
sessionConfiguration.connectionProxyDictionary = [:]
final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
let session = URLSession(configuration: sessionConfiguration, delegate: NoRedirect(), delegateQueue: nil)
var initialized = false
var framer = MCPLineFramer()
var inputBuffer = [UInt8](repeating: 0, count: 4096)
while true {
  // Foundation read(upToCount:) can wait for the requested size on a live pipe.
  // POSIX read returns currently available bytes, so requests work before stdin EOF.
  let count = inputBuffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
  if count == 0 { break }
  if count < 0 { if errno == EINTR { continue }; break }
  let chunk = Data(inputBuffer.prefix(count))
  for event in framer.append(chunk) {
    guard case .message(let data) = event else {
        FileHandle.standardOutput.write(ReadoraMCPProtocol.error(id: NSNull(), code: -32600, message: "请求过大") + Data([10])); continue
    }
    var response: Data?
    let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let id = request?["id"] ?? NSNull()
    let method = request?["method"] as? String
    if data.count > ReadoraMCPProtocol.maximumMessageSize {
        response = ReadoraMCPProtocol.error(id: id, code: -32600, message: "请求过大")
    } else if method == "notifications/initialized" { continue }
    else if request?["id"] == nil && method != nil { continue }
    else if !initialized && method != "initialize" {
        response = ReadoraMCPProtocol.error(id: id, code: -32002, message: "请先 initialize")
    } else if token.isEmpty {
        response = ReadoraMCPProtocol.error(id: id, code: -32000, message: "请在Readora设置中启用MCP并复制连接配置")
    } else {
        var http = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/rpc")!)
        http.httpMethod = "POST"; http.httpBody = data
        http.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (body, result) = try await session.data(for: http)
            guard let status = result as? HTTPURLResponse, status.statusCode == 200, body.count <= 262144 else { throw URLError(.badServerResponse) }
            response = body
            if method == "initialize", let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], object["result"] != nil { initialized = true }
        } catch {
            response = ReadoraMCPProtocol.error(id: id, code: -32000, message: "Readora未连接：请打开应用并在设置中启用MCP；检查端口与连接令牌。")
        }
    }
    if let response, !response.isEmpty { FileHandle.standardOutput.write(response + Data([10])) }
  }
}
session.invalidateAndCancel()
