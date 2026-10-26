import XCTest
@testable import UniApiCore

private struct ResponseClosureUpstream: ShimTransport {
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        guard request.url.host == "never-called.invalid", request.method == "POST" else { throw NativeFailure("Private streaming fixture route changed") }
        let chunks = [
            "data: {\"choices\":[{\"delta\":{\"content\":\"first \"},\"finish_reason\":null}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"second\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        ]
        return .init(status: 200, headers: ["content-type":"text/event-stream"], chunks: AsyncThrowingStream { continuation in
            for part in chunks { continuation.yield(Data(part.utf8)) }; continuation.finish()
        })
    }
}

final class ShimResponseClosureTests: XCTestCase {
    private func fixture() throws -> (URL, NativeShimServer) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shim-response-closure-" + UUID().uuidString)
        let paths = NativePaths(root: root, home: root.appendingPathComponent("private-home"))
        let provider: JSONValue = ["id":"fixture", "base_url":"https://never-called.invalid/v1", "api_key":"fixture-key", "proxy":["format":"openai", "model":"fixture"]]
        try NativeFile.writeAtomic(try JSONValue.object(["providers":[provider]]).encoded(), to: paths.providers)
        let dependencies = ShimDependencies(transport: ResponseClosureUpstream(), retryBackoff: [], heartbeatSeconds: 0)
        return (root, try NativeShimServer(paths: paths, port: 0, dependencies: dependencies, readTimeout: 2))
    }
    private func retired(_ server: NativeShimServer) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while server.activeConnections != 0 || server.activeRequests != 0 {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFailure("Private shim failed to retire its completed response") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(server.activeConnections, 0); XCTAssertEqual(server.activeRequests, 0)
        XCTAssertNotNil(server.listeningPort, "Closure must precede explicit listener shutdown")
    }
    func testRealHealthReplyReachesStrictLegacyProbeEOFAndRetiresBeforeShutdown() async throws {
        let (root, server) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        try await server.start(); let port = try XCTUnwrap(server.listeningPort)
        XCTAssertNotEqual(port, 8823); XCTAssertNotEqual(port, 8780)
        // get() uses the unmodified production socket exchange, not URLSession
        // framing completion. It sends no SHUT_WR and requires actual EOF.
        let value = try await NativeLegacyHTTPProbe.get(port: UInt16(port), path: "/healthz", timeout: 2)
        XCTAssertEqual(value["ok"], true); XCTAssertEqual(value["runtime"], "swift"); XCTAssertEqual(value["service"], "uniapi-shim")
        try await retired(server); await server.shutdown()
        } catch { await server.shutdown(); throw error }
    }
    func testRealGatewayMultipleStreamingChunksReachEOFAndRetireBeforeShutdown() async throws {
        let (root, server) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        do {
        try await server.start(); let port = try XCTUnwrap(server.listeningPort)
        XCTAssertNotEqual(port, 8823); XCTAssertNotEqual(port, 8780)
        let body = try JSONValue.object(["model":"fixture", "stream":true, "max_tokens":8, "messages":[["role":"user", "content":"private fixture"]]]).encoded()
        let header = "POST /fixture/v1/messages HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        let exchange = try await NativeLegacyHTTPProbe.socketExchange(port: UInt16(port), request: Data(header.utf8) + body, timeout: 2)
        XCTAssertTrue(exchange.reachedEOF)
        let text = String(decoding: try NativeLegacyHTTPProbe.body(exchange.data), as: UTF8.self)
        XCTAssertTrue(text.contains("message_start")); XCTAssertTrue(text.contains("first ")); XCTAssertTrue(text.contains("second")); XCTAssertTrue(text.contains("message_stop"))
        try await retired(server); await server.shutdown()
        } catch { await server.shutdown(); throw error }
    }
}
