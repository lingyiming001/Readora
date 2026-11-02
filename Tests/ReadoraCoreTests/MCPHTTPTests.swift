import XCTest
import ReadoraCore

final class MCPHTTPTests: XCTestCase {
    private let token = "test-bearer-token"
    private func request(_ body: String = "{}", extra: String = "", authorization: String? = nil) -> Data {
        Data(("POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nAuthorization: Bearer \(authorization ?? token)\r\nContent-Length: \(body.utf8.count)\r\n" + extra + "\r\n" + body).utf8)
    }
    func testBoundedAuthenticatedHTTPAndPartialPackets() {
        let data = request()
        XCTAssertEqual(ReadoraMCPHTTP.parse(data, token: token), .request(Data("{}".utf8)))
        XCTAssertEqual(ReadoraMCPHTTP.parse(Data(data.dropLast()), token: token), .incomplete)
        XCTAssertEqual(ReadoraMCPHTTP.parse(request(authorization: "wrong"), token: token), .rejected(401))
        XCTAssertEqual(ReadoraMCPHTTP.parse(request(extra: "Origin: https://untrusted.example\r\n"), token: token), .rejected(403))
        XCTAssertEqual(ReadoraMCPHTTP.parse(request(extra: "Transfer-Encoding: chunked\r\n"), token: token), .rejected(400))
        XCTAssertEqual(ReadoraMCPHTTP.parse(request(extra: "Content-Length: 2\r\n"), token: token), .rejected(400))
        XCTAssertEqual(ReadoraMCPHTTP.parse(Data(repeating: 65, count: 8193), token: token), .rejected(431))
        XCTAssertEqual(ReadoraMCPHTTP.parse(request(String(repeating: "x", count: 65537)), token: token), .rejected(413))
        XCTAssertEqual(ReadoraMCPHTTP.parse(data + Data("extra".utf8), token: token), .rejected(400))
    }
    func testHTTPEnvelopeDispatchesTheSameMCPToolProtocol() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"readora","arguments":{"action":"state"}}}"#
        guard case .request(let payload) = ReadoraMCPHTTP.parse(request(body), token: token) else { return XCTFail("valid envelope rejected") }
        let response = await ReadoraMCPProtocol.handle(payload) { command in
            guard command.action == .state else { throw AIError.invalidResponse }
            return "mobile-state"
        }
        let data = try XCTUnwrap(response)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(decoded["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("mobile-state"))
    }
}
