import Foundation

/// Read-only RPC client. Never creates an agent session or sends a prompt.
final class QuotaRPC: @unchecked Sendable {
    enum Framing { case lines, contentLength }
    private let process: ProcessSession
    private let framing: Framing
    private var sequence = 0
    init(binary: String, arguments: [String], environment: [String: String], framing: Framing) throws {
        process = try ProcessSession(executable: binary, arguments: arguments, environment: environment)
        self.framing = framing
    }
    func close() { process.close() }
    private func send(_ data: Data) throws {
        if framing == .contentLength { try process.send(Data("Content-Length: \(data.count)\r\n\r\n".utf8) + data) }
        else { try process.send(data + Data([10])) }
    }
    func request(_ method: String, params: String = "{}", timeout: TimeInterval = 15) async throws -> Data {
        sequence += 1; let id = sequence
        try send(Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":\(params)}".utf8))
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = max(0, deadline.timeIntervalSinceNow)
            let data = try await framing == .lines ? process.nextLine(timeout: remaining) : process.nextFramedMessage(timeout: remaining)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ErrorKind.malformed }
            // Refuse reverse RPCs (filesystem, tools, permission requests); this client only reads quotas.
            if object["method"] != nil, let requestID = object["id"] {
                try send(JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID, "error": ["code": -32601, "message": "Read-only quota client"]]))
                continue
            }
            guard object["id"] as? Int == id else { continue }
            if let error = object["error"] as? [String: Any] {
                let text = String(describing: error).lowercased() // Used only to classify, never logged.
                if error["code"] as? Int == -32601 { throw ErrorKind.quotaUnavailable }
                if text.contains("429") || text.contains("rate limit") { throw ErrorKind.rateLimited }
                if text.contains("auth") || text.contains("login") || text.contains("401") { throw ErrorKind.needsLogin }
                if text.contains("403") { throw ErrorKind.policy }
                throw ErrorKind.server
            }
            guard let result = object["result"], JSONSerialization.isValidJSONObject(result) else { throw ErrorKind.malformed }
            return try JSONSerialization.data(withJSONObject: result)
        }
    }
}

public enum QuotaDate {
    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withFullDate]; return formatter.date(from: value)
    }
}
