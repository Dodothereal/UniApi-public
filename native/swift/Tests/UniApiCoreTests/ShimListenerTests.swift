import XCTest
import Network
@testable import UniApiCore

private struct ShimListenerFixtureHTTP: ShimTransport {
    let delay: UInt64
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        try await Task.sleep(nanoseconds: delay)
        let json: JSONValue = ["choices": [["message": ["content": "fixture response"], "finish_reason": "stop"]]]
        let bytes = try json.encoded()
        return .init(status: 200, chunks: AsyncThrowingStream { $0.yield(bytes); $0.finish() })
    }
}

final class ShimListenerTests: XCTestCase {
    private func fixture(port: Int = 0, readTimeout: Double = 120, delay: UInt64 = 0) throws -> (URL, NativeShimServer) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shim-listener-" + UUID().uuidString), paths = NativePaths(root: root, home: root)
        let provider: JSONValue = ["id": "fixture", "base_url": "https://must-not-be-called.invalid/v1", "api_key": "fixture-key", "proxy": ["format": "openai", "model": "fixture"]]
        try NativeFile.writeAtomic(try JSONValue.object(["providers": [provider]]).encoded(), to: paths.providers)
        let deps = ShimDependencies(transport: ShimListenerFixtureHTTP(delay: delay), retryBackoff: [], heartbeatSeconds: 0)
        return (root, try NativeShimServer(paths: paths, port: port, dependencies: deps, readTimeout: readTimeout))
    }
    func testDoubleStartRefusedAndShutdownThenRestartUsesFreshListener() async throws {
        let (root, server) = try fixture(); defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        try await server.start(); let first = try XCTUnwrap(server.listeningPort); XCTAssertNotEqual(first, 8823)
        do { try await server.start(); XCTFail("Second start replaced an active listener") } catch { XCTAssertTrue(error.localizedDescription.contains("already")) }
        XCTAssertEqual(server.listeningPort, first)
        await server.shutdown(); XCTAssertNil(server.listeningPort)
        try await server.start(); XCTAssertNotNil(server.listeningPort); await server.shutdown()
    }
    func testFailedBindClearsOnlyItsOwnListenerAndCanRetry() async throws {
        let (root, owner) = try fixture(); defer { owner.stop(); try? FileManager.default.removeItem(at: root) }
        try await owner.start(); let port = try XCTUnwrap(owner.listeningPort)
        let (secondRoot, contender) = try fixture(port: port); defer { contender.stop(); try? FileManager.default.removeItem(at: secondRoot) }
        do { try await contender.start(); XCTFail("Occupied fixture port was replaced") } catch {}
        XCTAssertNil(contender.listeningPort); XCTAssertEqual(owner.listeningPort, port)
        await owner.shutdown(); try await contender.start(); XCTAssertEqual(contender.listeningPort, port); await contender.shutdown()
    }
    func testStalledHeadersExpireAndDeadlineDoesNotApplyToResponseStreaming() async throws {
        let (root, server) = try fixture(readTimeout: 0.1); defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        try await server.start(); let port = try XCTUnwrap(server.listeningPort)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        connection.start(queue: DispatchQueue(label: "shim-fixture-client")); defer { connection.cancel() }
        for _ in 0..<100 where server.activeConnections == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertGreaterThan(server.activeConnections, 0)
        for _ in 0..<100 where server.activeConnections != 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(server.activeConnections, 0); await server.shutdown()
        let (responseRoot, responding) = try fixture(readTimeout: 1, delay: 1_200_000_000); defer { responding.stop(); try? FileManager.default.removeItem(at: responseRoot) }
        try await responding.start(); let responsePort = try XCTUnwrap(responding.listeningPort)
        let payload: JSONValue = ["model": "fixture", "messages": [["role": "user", "content": "fixture"]], "max_tokens": 8, "stream": false]
        let http = ShimURLSessionTransport()
        let reply = try await http.open(.init(url: URL(string: "http://127.0.0.1:\(responsePort)/fixture/v1/messages")!, headers: ["Content-Type": "application/json"], body: try payload.encoded(), timeout: 3))
        let body = try await reply.body(); XCTAssertEqual(reply.status, 200); XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("fixture response")); await responding.shutdown()
    }
}
