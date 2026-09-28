import Foundation
import XCTest
@testable import IslandNote

final class FlomoClientTests: XCTestCase {
    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testFetchCompletesHandshakeAndRejectsIncompleteMemo() async throws {
        var methods: [String] = []
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://flomoapp.com/mcp")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let body = try requestBody(request)
            let method = try XCTUnwrap(body["method"] as? String)
            methods.append(method)
            switch method {
            case "initialize":
                return .json(["jsonrpc": "2.0", "id": body["id"]!, "result": ["protocolVersion": "2025-11-25"]], headers: ["Mcp-Session-Id": "session-1"])
            case "notifications/initialized":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Mcp-Session-Id"), "session-1")
                return .json([:])
            case "tools/call":
                XCTAssertEqual(request.value(forHTTPHeaderField: "MCP-Protocol-Version"), "2025-11-25")
                let params = try XCTUnwrap(body["params"] as? [String: Any])
                XCTAssertEqual(params["name"] as? String, "memo_batch_get")
                let args = try XCTUnwrap(params["arguments"] as? [String: Any])
                XCTAssertEqual(args["ids"] as? [String], ["memo-1"])
                return .json(["jsonrpc": "2.0", "id": body["id"]!, "result": ["structuredContent": [
                    "truncated": false, "omitted_ids": [String](), "memos": [[
                        "id": "memo-1", "content": "# A", "updated_at": "2026-09-29T00:00:00Z", "content_truncated": false
                    ]]
                ]]])
            default: XCTFail("Unexpected method"); return .json([:])
            }
        }
        let memo = try await client().fetch(id: "memo-1")
        XCTAssertEqual(memo, FlomoMemo(id: "memo-1", content: "# A", updatedAt: "2026-09-29T00:00:00Z"))
        XCTAssertEqual(methods, ["initialize", "notifications/initialized", "tools/call"])
    }

    func testFetchAcceptsNullOmittedIDs() async throws {
        StubProtocol.handler = fixture(payload: [
            "truncated": false, "omitted_ids": NSNull(), "memos": [[
                "id": "memo-1", "content": "Complete", "updated_at": "v1", "content_truncated": false
            ]]
        ])
        let memo = try await client().fetch(id: "memo-1")
        XCTAssertEqual(memo.content, "Complete")
    }

    func testFetchRejectsTruncationAndAttachments() async throws {
        let payloads: [[String: Any]] = [
            ["truncated": true, "omitted_ids": [String](), "memos": [["id": "memo-1", "content": "x", "updated_at": "v", "content_truncated": false]]],
            ["truncated": false, "omitted_ids": [String](), "memos": [[
                "id": "memo-1", "content": "x", "updated_at": "v", "content_truncated": false,
                "files": [["id": "file-1"]]
            ]]]
        ]
        for payload in payloads {
            StubProtocol.handler = fixture(payload: payload)
            do {
                _ = try await client().fetch(id: "memo-1")
                XCTFail("Unsafe memo accepted")
            } catch let error as FlomoClientError {
                XCTAssertTrue(error == .incompleteMemo || error == .attachmentsUnsupported)
            }
        }
    }

    func testSSEAndVersionConflict() async throws {
        StubProtocol.handler = { request in
            let body = try requestBody(request)
            switch body["method"] as? String {
            case "initialize":
                return .json(["jsonrpc": "2.0", "id": body["id"]!, "result": ["protocolVersion": "2025-06-18"]])
            case "notifications/initialized": return .json([:])
            default:
                let response: [String: Any] = ["jsonrpc": "2.0", "id": body["id"]!, "result": [
                    "isError": true, "content": [["type": "text", "text": "server_has_a_newer_version"]]
                ]]
                return .sse(response)
            }
        }
        do {
            try await client().update(id: "memo-1", content: "new", updatedAt: "old")
            XCTFail("Expected conflict")
        } catch let error as FlomoClientError {
            XCTAssertEqual(error, .conflict)
        }
    }

    func testCreateTimeoutHasUnknownOutcomeAndNoRetry() async throws {
        var callCount = 0
        StubProtocol.handler = { request in
            let body = try requestBody(request)
            switch body["method"] as? String {
            case "initialize": return .json(["jsonrpc": "2.0", "id": body["id"]!, "result": ["protocolVersion": "2025-11-25"]])
            case "notifications/initialized": return .json([:])
            default:
                callCount += 1
                throw URLError(.timedOut)
            }
        }
        do {
            _ = try await client().create(content: "New memo")
            XCTFail("Expected uncertain outcome")
        } catch let error as FlomoClientError {
            XCTAssertEqual(error, .unknownWriteOutcome)
        }
        XCTAssertEqual(callCount, 1)
    }

    private func client() -> FlomoClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return FlomoClient(token: "test-token", session: URLSession(configuration: configuration))
    }

    private func fixture(payload: [String: Any]) -> (URLRequest) throws -> StubProtocol.Reply {
        { request in
            let body = try requestBody(request)
            switch body["method"] as? String {
            case "initialize": return .json(["jsonrpc": "2.0", "id": body["id"]!, "result": ["protocolVersion": "2025-11-25"]])
            case "notifications/initialized": return .json([:])
            default: return .json(["jsonrpc": "2.0", "id": body["id"]!, "result": ["structuredContent": payload]])
            }
        }
    }
}

private func requestBody(_ request: URLRequest) throws -> [String: Any] {
    let data: Data
    if let body = request.httpBody {
        data = body
    } else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        var collected = Data()
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            collected.append(bytes, count: count)
        }
        data = collected
    } else {
        throw FlomoClientError.incompleteMemo
    }
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private final class StubProtocol: URLProtocol {
    struct Reply {
        let data: Data
        let contentType: String
        let headers: [String: String]

        static func json(_ object: [String: Any], headers: [String: String] = [:]) -> Reply {
            Reply(data: try! JSONSerialization.data(withJSONObject: object), contentType: "application/json", headers: headers)
        }

        static func sse(_ object: [String: Any]) -> Reply {
            let json = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
            return Reply(data: Data("event: message\ndata: \(json)\n\n".utf8), contentType: "text/event-stream", headers: [:])
        }
    }

    static var handler: ((URLRequest) throws -> Reply)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let reply = try Self.handler!(request)
            var headers = reply.headers
            headers["Content-Type"] = reply.contentType
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
