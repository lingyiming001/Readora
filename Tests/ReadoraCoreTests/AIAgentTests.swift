import XCTest
import ReadoraCore

final class AIAgentTests: XCTestCase {
    private func directory() throws -> URL {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent(".agents/test/ai-agent/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testDefaultRouteIsFirstEnabledAndManualRouteDoesNotSilentlyFallback() throws {
        var first = AIConfiguration(); first.model = "first"; first.enabled = false
        var second = first; second.model = "second"; second.enabled = true
        let a = AIModelProfile(configuration: first), b = AIModelProfile(configuration: second)
        var registry = AIModelRegistry(profiles: [a, b])
        XCTAssertEqual(registry.defaultProfile?.id, b.id)
        XCTAssertNil(registry.route(a.id)); XCTAssertNil(registry.route(UUID()))
        registry.profiles[0].configuration.enabled = true
        XCTAssertEqual(registry.defaultProfile?.id, a.id)
        registry.profiles.swapAt(0, 1)
        XCTAssertEqual(registry.defaultProfile?.id, b.id)
        XCTAssertEqual(registry.route(a.id)?.id, a.id)
        XCTAssertEqual(a.configuration.credentialAccount, b.configuration.credentialAccount)
        registry.profiles = [a, a]
        XCTAssertThrowsError(try registry.validate())
    }
    func testRegistryMigratesLegacyOnceAndPersistsOrderAndDisabledFlags() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        var legacy = AIConfiguration(); legacy.enabled = true; legacy.model = "old-model"
        try await store.saveAIConfiguration(legacy)
        var registry = try await store.aiModelRegistry()
        XCTAssertEqual(registry.profiles.count, 1)
        XCTAssertEqual(registry.defaultProfile?.configuration, legacy)
        let id = registry.profiles[0].id
        let reopened = try await LibraryStore(root: root).aiModelRegistry()
        XCTAssertEqual(reopened.profiles.first?.id, id)
        var other = legacy; other.model = "new-model"
        registry.profiles.insert(AIModelProfile(name: "新路由", configuration: other), at: 0)
        registry.profiles[1].configuration.enabled = false
        try await store.saveAIModelRegistry(registry)
        let restored = try await LibraryStore(root: root).aiModelRegistry()
        XCTAssertEqual(restored, registry)
        try await store.saveAIModelRegistry(AIModelRegistry())
        let cleared = try await LibraryStore(root: root).aiModelRegistry()
        XCTAssertTrue(cleared.profiles.isEmpty)
    }
    func testCommandConfirmationCannotBeOverriddenByModelArguments() throws {
        for action in ["delete_book", "empty_trash", "delete_shelf", "delete_model", "remove_mark", "clear_history"] {
            let command = try AIAppCommand.parse("{\"action\":\"\(action)\",\"confirmed\":true}")
            XCTAssertTrue(command.requiresConfirmation)
        }
        XCTAssertFalse(AIAppCommand(action: .createShelf, text: "书架").requiresConfirmation)
        XCTAssertFalse(AIAppCommand(action: .readingPreference, target: "theme", text: "night").requiresConfirmation)
        XCTAssertThrowsError(try AIAppCommand.parse(#"{"action":"shell","text":"anything"}"#))
        XCTAssertThrowsError(try AIAppCommand.parse(String(repeating: "x", count: 17000)))
    }
    func testToolResponseRetainsReasoningAndRejectsUnknownTools() throws {
        let valid = Data(#"{"choices":[{"message":{"role":"assistant","content":null,"reasoning_content":"reasoning","tool_calls":[{"id":"c1","type":"function","function":{"name":"readora","arguments":"{\"action\":\"state\"}"}}]}}]}"#.utf8)
        let turn = try AIChatTurn.parse(valid)
        XCTAssertEqual(turn.calls.count, 1)
        XCTAssertEqual(turn.message.reasoning_content, "reasoning")
        XCTAssertEqual(try AIAppCommand.parse(turn.calls[0].function.arguments).action, .state)
        let invalid = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "readora", with: "shell")
        XCTAssertThrowsError(try AIChatTurn.parse(Data(invalid.utf8)))
    }
    @MainActor
    func testAgentExecutesToolAndReturnsAnswerAfterToolResult() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AgentStubProtocol.self]
        let client = AIClient(session: URLSession(configuration: configuration))
        var settings = AIConfiguration(); settings.model = "mock"; settings.baseURL = "https://agent.invalid/v1"
        var performed: [AIAppAction] = [], events: [String] = []
        let result = try await AIAppAgent.run(client: client, configuration: settings, key: "dummy", question: "添加一个书架", excerpt: "", perform: { command in
            performed.append(command.action); return "已创建书架"
        }, progress: { events.append($0) })
        XCTAssertEqual(performed, [.createShelf]); XCTAssertEqual(result, "任务完成")
        XCTAssertEqual(events.count, 2)
    }
    @MainActor
    func testAgentStopsWhenUserDeclinesInsteadOfRetrying() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [AgentStubProtocol.self]
        let client = AIClient(session: URLSession(configuration: configuration))
        var settings = AIConfiguration(); settings.model = "mock"; settings.baseURL = "https://agent.invalid/v1"
        var calls = 0
        do {
            _ = try await AIAppAgent.run(client: client, configuration: settings, key: "dummy", question: "测试拒绝", excerpt: "", perform: { _ in
                calls += 1; throw AIAppAgentError.userDeclined
            }, progress: { _ in })
            XCTFail("denial ignored")
        } catch { XCTAssertTrue(error is AIAppAgentError) }
        XCTAssertEqual(calls, 1)
    }
    func testDeletionRefusesRestoredBooksAndPreservesSource() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.txt"); try Data("测试正文".utf8).write(to: source)
        let store = LibraryStore(root: root.appendingPathComponent("Library"))
        let imported = try await store.importFile(source), book = try XCTUnwrap(imported.first)
        _ = try await store.changeBook(id: book.id, change: .trash(true))
        _ = try await store.changeBook(id: book.id, change: .trash(false))
        do { _ = try await store.deleteTrashedBooks(ids: [book.id]); XCTFail("restored book removed") } catch {}
        let retained = try await store.load(); XCTAssertEqual(retained.count, 1)
        _ = try await store.changeBook(id: book.id, change: .trash(true))
        let removed = try await store.deleteTrashedBooks(ids: [book.id]); XCTAssertTrue(removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let internalURL = await store.fileURL(for: book)
        XCTAssertFalse(FileManager.default.fileExists(atPath: internalURL.path))
    }
    func testInterruptedDeletionRecoversBeforeLibraryLoad() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.txt"); try Data("恢复测试正文".utf8).write(to: source)
        let library = root.appendingPathComponent("Library"), store = LibraryStore(root: library)
        let imported = try await store.importFile(source), book = try XCTUnwrap(imported.first)
        _ = try await store.changeBook(id: book.id, change: .trash(true))
        let libraryData = try Data(contentsOf: library.appendingPathComponent("library.json"))
        let staging = library.appendingPathComponent(".deletion-test"), temporary = UUID().uuidString
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let journal: [String: Any] = ["entries": [["original": book.filename, "temporary": temporary]], "backups": ["library.json": libraryData.base64EncodedString()]]
        try JSONSerialization.data(withJSONObject: journal).write(to: staging.appendingPathComponent("journal.json"))
        try FileManager.default.moveItem(at: library.appendingPathComponent(book.filename), to: staging.appendingPathComponent(temporary))
        try Data("[]".utf8).write(to: library.appendingPathComponent("library.json"))
        let recovered = try await LibraryStore(root: library).load()
        XCTAssertEqual(recovered.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent(book.filename).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
}

private final class AgentStubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let messages = object?["messages"] as? [[String: Any]]
        let complete = messages?.last?["role"] as? String == "tool"
        let body = complete ? #"{"choices":[{"message":{"role":"assistant","content":"任务完成"}}]}"# : #"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call1","type":"function","function":{"name":"readora","arguments":"{\"action\":\"create_shelf\",\"text\":\"AI书架\"}"}}]}}]}"#
        guard let url = request.url else { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
