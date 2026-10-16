import XCTest
import ReadoraCore
@testable import ReadoraMac

@MainActor
final class MCPServiceTests: XCTestCase {
    func testExternalDeletionWaitsForRealDecisionAndStopRevokesRequest() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent(".agents/test/mcp-service/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(libraryRoot: root)
        await model.load()
        _ = try await model.executeAICommand(.init(action: .createShelf, text: "待确认书架"))
        let shelf = try XCTUnwrap(model.collections.first)
        let service = MCPService(persistConnection: false)
        service.enabled = true
        let command = AIAppCommand(action: .deleteShelf, id: shelf.id)
        let denied = Task { try await service.perform(command, model: model) }
        for _ in 0..<100 where service.pending == nil { await Task.yield() }
        XCTAssertEqual(service.pending?.id, shelf.id)
        XCTAssertEqual(model.collections.count, 1)
        do { _ = try await service.perform(.init(action: .state), model: model); XCTFail("并发请求未被阻止") } catch {}
        service.resolve(false)
        do { _ = try await denied.value; XCTFail("拒绝仍执行") } catch {}
        XCTAssertEqual(model.collections.count, 1)
        let revoked = Task { try await service.perform(command, model: model) }
        for _ in 0..<100 where service.pending == nil { await Task.yield() }
        service.stop()
        do { _ = try await revoked.value; XCTFail("关闭服务仍执行") } catch {}
        XCTAssertEqual(model.collections.count, 1)
        service.enabled = true
        let accepted = Task { try await service.perform(command, model: model) }
        for _ in 0..<100 where service.pending == nil { await Task.yield() }
        service.resolve(true)
        _ = try await accepted.value
        XCTAssertTrue(model.collections.isEmpty)
        service.stop()
    }
    func testRealLoopbackTransportAuthenticatesAndRoutesRPC() async throws {
        let ready = expectation(description: "本机RPC监听启动")
        let port = UInt16.random(in: 40000...59000)
        let transport = try LocalRPCTransport(port: port, token: "isolated-test-token", status: { status in
            if status.hasPrefix("已连接") { ready.fulfill() }
        }, handler: { data in
            await ReadoraMCPProtocol.handle(data) { command in "隔离测试：" + command.action.rawValue }
        })
        defer { transport.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/rpc")!)
        request.timeoutInterval = 5; request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"readora\",\"arguments\":{\"action\":\"state\"}}}".utf8)
        let (_, denied) = try await session.data(for: request)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
        request.setValue("Bearer isolated-test-token", forHTTPHeaderField: "Authorization")
        let (data, allowed) = try await session.data(for: request)
        XCTAssertEqual((allowed as? HTTPURLResponse)?.statusCode, 200)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let content = try XCTUnwrap((object["result"] as? [String: Any])?["content"] as? [[String: String]])
        XCTAssertEqual(content.first?["text"], "隔离测试：state")
        request.setValue("https://example.com", forHTTPHeaderField: "Origin")
        let (_, browser) = try await session.data(for: request)
        XCTAssertEqual((browser as? HTTPURLResponse)?.statusCode, 403)
    }
}
