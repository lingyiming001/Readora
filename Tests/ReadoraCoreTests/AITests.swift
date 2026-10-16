import XCTest
import ReadoraCore

final class AITests: XCTestCase {
    func testEndpointValidationAndCredentialIsolation() throws {
        var configuration = AIConfiguration()
        configuration.model = "test-model"
        configuration.baseURL = "https://example.com/v1/chat/completions/"
        XCTAssertEqual(try configuration.endpoint("chat/completions").absoluteString, "https://example.com/v1/chat/completions")
        let account = configuration.credentialAccount
        configuration.baseURL = "https://example.com/v1"
        configuration.model = "another-model"
        XCTAssertEqual(configuration.credentialAccount, account)
        configuration.baseURL = "https://other.example.com/v1"
        XCTAssertNotEqual(configuration.credentialAccount, account)
        for endpoint in ["http://remote.example/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "file:///tmp/api", "https://example.com/v1#fragment"] {
            configuration.baseURL = endpoint
            XCTAssertThrowsError(try configuration.validate())
        }
        configuration.baseURL = "http://127.0.0.1:11434/v1"
        try configuration.validate()
        XCTAssertTrue(configuration.allowsEmptyKey)
        configuration.model = ""
        XCTAssertThrowsError(try configuration.validate())
        XCTAssertNoThrow(try configuration.validate(requireModel: false))
    }
    func testRequestBoundsExcerptAndKeepsKeyOutOfBodyAndConfiguration() throws {
        var configuration = AIConfiguration(); configuration.model = "test-model"
        let request = try AIClient.request(configuration: configuration, key: "test-secret", context: String(repeating: "文", count: 7000), instruction: "总结")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
        let data = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: String]])
        let content = try XCTUnwrap(messages.last?["content"])
        XCTAssertEqual(content.filter { $0 == "文" }.count, 6000 + 1) // excerpt label includes 原文
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("test-secret"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self).contains("test-secret"))
        XCTAssertEqual(object["max_completion_tokens"] as? Int, 1800)
        XCTAssertThrowsError(try AIClient.request(configuration: configuration, key: "", context: "正文", instruction: "总结"))
        XCTAssertThrowsError(try AIClient.request(configuration: configuration, key: "secret\nInjected", context: "正文", instruction: "总结"))
        XCTAssertThrowsError(try AIClient.request(configuration: configuration, key: "test", context: "  ", instruction: "总结"))
        configuration.provider = .ollama; configuration.baseURL = AIProvider.ollama.baseURL
        let local = try AIClient.request(configuration: configuration, key: "", context: "正文", instruction: "解释")
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"))
        let localBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(local.httpBody)) as? [String: Any])
        XCTAssertEqual(localBody["max_tokens"] as? Int, 1800)
    }
    func testResponseParsingAndTruncationNotice() throws {
        let valid = Data(#"{"choices":[{"message":{"content":"回答"},"finish_reason":"stop"}]}"#.utf8)
        XCTAssertEqual(try AIClient.answer(from: valid), "回答")
        let truncated = Data(#"{"choices":[{"message":{"content":"部分回答"},"finish_reason":"length"}]}"#.utf8)
        XCTAssertTrue(try AIClient.answer(from: truncated).contains("输出上限"))
        for text in ["not-json", #"{"choices":[]}"#, #"{"choices":[{"message":{"content":null}}]}"#, #"{"choices":[{"message":{"content":" "}}]}"#] {
            XCTAssertThrowsError(try AIClient.answer(from: Data(text.utf8)))
        }
        XCTAssertFalse(AIError.http(401).localizedDescription.contains("test-secret"))
    }
    func testAIConfigurationPersistsWithoutSecretsAndInvalidSaveDoesNotOverwrite() async throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent(".agents/test/ai/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let defaults = try await store.aiConfiguration()
        XCTAssertFalse(defaults.enabled)
        var configuration = AIConfiguration(); configuration.enabled = true
        configuration.provider = .ollama; configuration.baseURL = AIProvider.ollama.baseURL; configuration.model = "local-model"
        try await store.saveAIConfiguration(configuration)
        let restored = try await LibraryStore(root: root).aiConfiguration()
        XCTAssertEqual(restored, configuration)
        var invalid = configuration; invalid.model = ""
        do { try await store.saveAIConfiguration(invalid); XCTFail("invalid model saved") } catch {}
        let preserved = try await store.aiConfiguration()
        XCTAssertEqual(preserved, configuration)
        let json = try String(contentsOf: root.appendingPathComponent("ai-configuration.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("apiKey")); XCTAssertFalse(json.contains("Authorization"))
    }
    func testMockTransportSuccessModelsHTTPFailureAndOversizedResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AIStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = AIClient(session: session)
        var settings = AIConfiguration(); settings.model = "mock-model"
        settings.baseURL = "https://success.invalid/v1"
        let reply = try await client.complete(configuration: settings, key: "dummy", context: "仅测试材料", instruction: "解释")
        XCTAssertEqual(reply, "测试回答")
        let models = try await client.models(configuration: settings, key: "dummy")
        XCTAssertEqual(models, ["a", "b"])
        settings.baseURL = "https://denied.invalid/v1"
        do { _ = try await client.complete(configuration: settings, key: "dummy", context: "测试", instruction: "解释"); XCTFail("401 accepted") }
        catch { XCTAssertEqual(error as? AIError, .http(401)) }
        settings.baseURL = "https://oversized.invalid/v1"
        do { _ = try await client.complete(configuration: settings, key: "dummy", context: "测试", instruction: "解释"); XCTFail("large response accepted") }
        catch { XCTAssertEqual(error as? AIError, .oversizedResponse) }
    }
}
private final class AIStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let denied = url.host == "denied.invalid", large = url.host == "oversized.invalid"
        let text = url.path.hasSuffix("/models") ? #"{"data":[{"id":"b"},{"id":"a"},{"id":"b"}]}"# : #"{"choices":[{"message":{"content":"测试回答"},"finish_reason":"stop"}]}"#
        let headers = large ? ["Content-Length": "2000000"] : ["Content-Type": "application/json"]
        let response = HTTPURLResponse(url: url, statusCode: denied ? 401 : 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
