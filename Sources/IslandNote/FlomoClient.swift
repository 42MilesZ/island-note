import Foundation

struct FlomoMemo: Codable, Equatable {
    let id: String
    let content: String
    let updatedAt: String
}

protocol FlomoServing {
    func fetch(id: String) async throws -> FlomoMemo
    func create(content: String) async throws -> String
    func update(id: String, content: String, updatedAt: String) async throws
}

enum FlomoClientError: LocalizedError, Equatable {
    case authentication
    case rateLimited
    case conflict
    case unavailable
    case incompleteMemo
    case attachmentsUnsupported
    case unknownWriteOutcome

    var errorDescription: String? {
        switch self {
        case .authentication: return "Flomo authorization failed. Check the token in Island Note settings."
        case .rateLimited: return "Flomo is limiting requests. Try again later."
        case .conflict: return "The Flomo memo changed elsewhere. Review it before syncing again."
        case .unavailable: return "Flomo is unavailable. Try again later."
        case .incompleteMemo: return "Flomo returned an incomplete memo. Sync has stopped to protect its content."
        case .attachmentsUnsupported: return "This Flomo memo has attachments that Island Note cannot preserve. Sync has stopped."
        case .unknownWriteOutcome: return "Flomo may have saved the change, but its response was lost. Check Flomo before trying again."
        }
    }
}

/// A small MCP client scoped to the three memo operations used by Island Note.
/// Every operation opens its own session; no failed write is retried automatically.
final class FlomoClient: FlomoServing {
    private static let endpoint = URL(string: "https://flomoapp.com/mcp")!
    private static let offeredVersion = "2025-11-25"
    private static let supportedVersions: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26"]

    private let token: String
    private let session: URLSession
    private let redirectBlocker = RedirectBlocker()

    init(token: String, session: URLSession = .shared) {
        self.token = token
        self.session = session
    }

    func fetch(id: String) async throws -> FlomoMemo {
        let result = try await call("memo_batch_get", arguments: ["ids": [id]], isWrite: false)
        guard result["truncated"] as? Bool == false,
              (result["omitted_ids"] is NSNull || (result["omitted_ids"] as? [String])?.isEmpty == true),
              let memos = result["memos"] as? [[String: Any]],
              let memo = memos.first(where: { $0["id"] as? String == id }),
              memo["content_truncated"] as? Bool == false,
              let content = memo["content"] as? String,
              let updatedAt = memo["updated_at"] as? String, !updatedAt.isEmpty
        else { throw FlomoClientError.incompleteMemo }

        if hasAttachments(memo) { throw FlomoClientError.attachmentsUnsupported }
        return FlomoMemo(id: id, content: content, updatedAt: updatedAt)
    }

    func create(content: String) async throws -> String {
        let result = try await call("memo_create", arguments: ["content": content, "format": "markdown"], isWrite: true)
        let memo = result["memo"] as? [String: Any]
        guard let id = (result["id"] as? String) ?? (memo?["id"] as? String), !id.isEmpty else {
            throw FlomoClientError.unknownWriteOutcome
        }
        return id
    }

    func update(id: String, content: String, updatedAt: String) async throws {
        _ = try await call("memo_update", arguments: [
            "id": id, "content": content, "format": "markdown", "local_updated_at": updatedAt
        ], isWrite: true)
    }

    private func hasAttachments(_ memo: [String: Any]) -> Bool {
        for key in ["files", "attachments", "images", "voices"] {
            if let items = memo[key] as? [Any], !items.isEmpty { return true }
        }
        return memo["has_image"] as? Bool == true || memo["has_voice"] as? Bool == true
    }

    private func call(_ name: String, arguments: [String: Any], isWrite: Bool) async throws -> [String: Any] {
        let context = try await initialize()
        let id = UUID().uuidString
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ]
        let response: [String: Any]
        do {
            response = try await post(envelope, id: id, context: context)
        } catch let error as FlomoClientError {
            switch error {
            case .unavailable where isWrite: throw FlomoClientError.unknownWriteOutcome
            case .incompleteMemo where isWrite: throw FlomoClientError.unknownWriteOutcome
            default: throw error
            }
        } catch {
            throw isWrite ? FlomoClientError.unknownWriteOutcome : FlomoClientError.unavailable
        }

        guard let result = response["result"] as? [String: Any] else {
            throw isWrite ? FlomoClientError.unknownWriteOutcome : FlomoClientError.incompleteMemo
        }
        if result["isError"] as? Bool == true {
            throw classifyToolError(result)
        }
        do {
            return try payload(from: result)
        } catch {
            throw isWrite ? FlomoClientError.unknownWriteOutcome : FlomoClientError.incompleteMemo
        }
    }

    private struct Context {
        let version: String
        let sessionID: String?
    }

    private func initialize() async throws -> Context {
        guard !token.isEmpty else { throw FlomoClientError.authentication }
        let id = UUID().uuidString
        let envelope: [String: Any] = [
            "jsonrpc": "2.0", "id": id, "method": "initialize",
            "params": [
                "protocolVersion": Self.offeredVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Island Note", "version": "1.0"]
            ]
        ]
        let (body, http) = try await send(envelope, context: nil)
        let response = try parseRPC(body, contentType: http.value(forHTTPHeaderField: "Content-Type"), id: id)
        if let error = response["error"] as? [String: Any] { throw classifyRPCError(error) }
        guard let result = response["result"] as? [String: Any],
              let version = result["protocolVersion"] as? String,
              Self.supportedVersions.contains(version) else { throw FlomoClientError.unavailable }

        let context = Context(version: version, sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id"))
        let notification: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        _ = try await send(notification, context: context)
        return context
    }

    private func post(_ envelope: [String: Any], id: String, context: Context) async throws -> [String: Any] {
        let (body, http) = try await send(envelope, context: context)
        let response = try parseRPC(body, contentType: http.value(forHTTPHeaderField: "Content-Type"), id: id)
        if let error = response["error"] as? [String: Any] { throw classifyRPCError(error) }
        return response
    }

    private func send(_ envelope: [String: Any], context: Context?) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let context {
            request.setValue(context.version, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionID = context.sessionID {
                request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            }
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: envelope)
            let (data, response) = try await session.data(for: request, delegate: redirectBlocker)
            guard let http = response as? HTTPURLResponse,
                  http.url?.scheme == "https", http.url?.host == Self.endpoint.host,
                  http.url?.path == Self.endpoint.path else { throw FlomoClientError.unavailable }
            switch http.statusCode {
            case 200..<300: return (data, http)
            case 401, 403: throw FlomoClientError.authentication
            case 409, 412: throw FlomoClientError.conflict
            case 429: throw FlomoClientError.rateLimited
            default: throw FlomoClientError.unavailable
            }
        } catch let error as FlomoClientError {
            throw error
        } catch {
            throw FlomoClientError.unavailable
        }
    }

    private func parseRPC(_ data: Data, contentType: String?, id: String) throws -> [String: Any] {
        let messages: [[String: Any]]
        if contentType?.lowercased().contains("text/event-stream") == true {
            guard let stream = String(data: data, encoding: .utf8) else { throw FlomoClientError.incompleteMemo }
            messages = stream.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n\n")
                .compactMap { event in
                    let payload = event.split(separator: "\n")
                        .filter { $0.hasPrefix("data:") }
                        .map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
                        .joined(separator: "\n")
                    guard let json = payload.data(using: .utf8) else { return nil }
                    return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
                }
        } else {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw FlomoClientError.incompleteMemo
            }
            messages = [object]
        }
        guard let matched = messages.first(where: { $0["id"] as? String == id && $0["jsonrpc"] as? String == "2.0" }) else {
            throw FlomoClientError.incompleteMemo
        }
        return matched
    }

    private func payload(from result: [String: Any]) throws -> [String: Any] {
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        guard let blocks = result["content"] as? [[String: Any]],
              let block = blocks.first(where: { $0["type"] as? String == "text" }),
              let text = block["text"] as? String,
              let data = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FlomoClientError.incompleteMemo }
        return payload
    }

    private func classifyRPCError(_ error: [String: Any]) -> FlomoClientError {
        let message = error["message"] as? String ?? ""
        return classify(message)
    }

    private func classifyToolError(_ result: [String: Any]) -> FlomoClientError {
        let messages = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return classify(messages.joined(separator: " "))
    }

    private func classify(_ message: String) -> FlomoClientError {
        let lower = message.lowercased()
        if lower.contains("server_has_a_newer_version") || lower.contains("conflict") || lower.contains("version_conflict") {
            return .conflict
        }
        if lower.contains("unauthorized") || lower.contains("forbidden") || lower.contains("invalid_token") { return .authentication }
        if lower.contains("rate_limit") || lower.contains("too many requests") { return .rateLimited }
        return .unavailable
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
