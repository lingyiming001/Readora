import Foundation

public enum LocalRPCRequest {
    public enum ParseResult: Equatable { case incomplete, rejected, body(Data) }
    /// One bounded POST per connection. Browser origins and ambiguous framing are rejected.
    public static func parse(_ data: Data, token: String) -> ParseResult {
        guard data.count <= ReadoraMCPProtocol.maximumMessageSize + 8192 else { return .rejected }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return data.count > 8192 ? .rejected : .incomplete }
        guard boundary.lowerBound <= 8192, let header = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return .rejected }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "POST /rpc HTTP/1.1" else { return .rejected }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .rejected }
            let key = String(line[..<colon]).lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard fields[key] == nil else { return .rejected }
            fields[key] = value
        }
        guard fields["origin"] == nil, fields["transfer-encoding"] == nil,
              !token.isEmpty, fields["authorization"] == "Bearer " + token,
              fields["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let length = fields["content-length"].flatMap(Int.init), (1...ReadoraMCPProtocol.maximumMessageSize).contains(length) else { return .rejected }
        let count = data.count - boundary.upperBound
        guard count <= length else { return .rejected }
        return count == length ? .body(Data(data[boundary.upperBound...])) : .incomplete
    }
}
