import XCTest
import Network
@testable import UniApiCore

private final class ShimActivitySignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false, waiters: [CheckedContinuation<Void, Never>] = []
    init(signalled: Bool = false) { self.signalled = signalled }
    var isSignalled: Bool { lock.withLock { signalled } }
    func wait() async { await withCheckedContinuation { continuation in let ready = lock.withLock { if signalled { return true }; waiters.append(continuation); return false }; if ready { continuation.resume() } } }
    func signal() { let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in signalled = true; let result = waiters; waiters.removeAll(); return result }; pending.forEach { $0.resume() } }
}

/// Header delivery, body delivery and cancellation acknowledgement are separate
/// gates: finishing the async stream must not stand in for transport cleanup.
private final class ShimActivityTransport: ShimTransport, @unchecked Sendable {
    let opened = ShimActivitySignal(), cancelled = ShimActivitySignal(), drained = ShimActivitySignal()
    let headers: ShimActivitySignal
    let status: Int
    private let stream: AsyncThrowingStream<Data, Error>, continuation: AsyncThrowingStream<Data, Error>.Continuation
    init(holdHeaders: Bool = false, status: Int = 200) {
        headers = ShimActivitySignal(signalled: !holdHeaders); self.status = status
        let pair = AsyncThrowingStream<Data, Error>.makeStream(); stream = pair.stream; continuation = pair.continuation
    }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        opened.signal()
        return try await withTaskCancellationHandler(operation: {
            await headers.wait()
            if Task.isCancelled { await drained.wait(); throw CancellationError() }
            return .init(status: status, chunks: stream, cancel: { self.cancel() }, waitForCompletion: { await self.drained.wait() })
        }, onCancel: { self.cancel(); self.headers.signal() })
    }
    func yield(_ bytes: Data) { continuation.yield(bytes) }
    func finish() { continuation.finish() }
    func cancel() { continuation.finish(throwing: CancellationError()); cancelled.signal() }
    func closeFixture() { cancel(); headers.signal(); drained.signal() }
}
private actor ShimActivityQueue: ShimTransport {
    var entries: [ShimActivityTransport]
    init(_ entries: [ShimActivityTransport]) { self.entries = entries }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream { try await entries.removeFirst().open(request) }
}

final class ShimActivityTests: XCTestCase {
    private func fixture(_ transport: any ShimTransport) throws -> (URL, NativePaths, NativeShimGateway) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shim-activity-" + UUID().uuidString)
        let paths = NativePaths(root: root, home: root.appendingPathComponent("private-home"))
        let row: JSONValue = ["id": "fixture", "base_url": "https://never-called.invalid/v1", "api_key": "fixture-key", "proxy": ["format": "openai", "model": "fixture"]]
        try NativeFile.writeAtomic(try JSONValue.object(["providers": [row]]).encoded(), to: paths.providers)
        return (root, paths, NativeShimGateway(providers: NativeProviderStore(paths: paths), dependencies: .init(transport: transport, retryBackoff: [], heartbeatSeconds: 0)))
    }
    private func request(stream: Bool = true) throws -> ShimClientRequest {
        let body: JSONValue = ["model": "fixture", "stream": .bool(stream), "messages": [["role": "user", "content": "fixture"]]]
        return .init(method: "POST", path: "/fixture/v1/messages", headers: ["host": "localhost"], body: try body.encoded())
    }
    private func count(_ gateway: NativeShimGateway, path: String = "/healthz", expected: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let reply = try await gateway.handle(.init(method: "GET", path: path, headers: ["host": "localhost"]))
        let body = try JSONValue.decode(await reply.body())
        XCTAssertEqual(body["activeRequests"], .number(Double(expected)), file: file, line: line)
        XCTAssertEqual(body["service"], "uniapi-shim", file: file, line: line)
    }
    func testHealthProbesExcludedButPostAndUnconsumedErrorCounted() async throws {
        let http = ShimActivityTransport(), (root, _, gateway) = try fixture(http)
        defer { http.closeFixture(); try? FileManager.default.removeItem(at: root) }
        try await count(gateway, expected: 0)
        try await count(gateway, path: "/health?probe=fixture", expected: 0)
        let error = try await gateway.handle(.init(method: "POST", path: "/healthz", headers: ["host": "localhost"]))
        XCTAssertEqual(error.status, 404)
        try await count(gateway, expected: 1)
        _ = try await error.body()
        try await count(gateway, expected: 0)
        error.cancel(); error.cancel()
        try await count(gateway, expected: 0)
    }
    func testPendingHeadersCancellationStaysBusyUntilTransportAcknowledges() async throws {
        let http = ShimActivityTransport(holdHeaders: true), (root, _, gateway) = try fixture(http)
        defer { http.closeFixture(); try? FileManager.default.removeItem(at: root) }
        let input = try request(stream: false), pending = Task { try await gateway.handle(input) }
        await http.opened.wait()
        try await count(gateway, expected: 1)
        pending.cancel(); await http.cancelled.wait()
        // This health call also proves an awaiting cancelled handler does not
        // block the gateway actor while cleanup remains deliberately held.
        try await count(gateway, expected: 1)
        http.drained.signal()
        do { _ = try await pending.value; XCTFail("Cancelled header wait succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        try await count(gateway, expected: 0)
    }
    func testStreamingReturnAndRepeatedCancelDoNotEndProducerOwnershipEarly() async throws {
        let http = ShimActivityTransport(), (root, _, gateway) = try fixture(http)
        defer { http.closeFixture(); try? FileManager.default.removeItem(at: root) }
        let reply = try await gateway.handle(request())
        try await count(gateway, expected: 1)
        reply.cancel(); reply.cancel(); await http.cancelled.wait()
        try await count(gateway, expected: 1)
        http.drained.signal(); await reply.waitForCompletion()
        try await count(gateway, expected: 0)
    }
    func testCompletedProducerKeepsUnreadDownstreamCounted() async throws {
        let http = ShimActivityTransport(), (root, _, gateway) = try fixture(http)
        defer { http.closeFixture(); try? FileManager.default.removeItem(at: root) }
        let reply = try await gateway.handle(request())
        http.yield(Data("data: {\"choices\":[{\"delta\":{\"content\":\"fixture\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8))
        http.finish(); http.drained.signal(); await reply.waitForCompletion()
        try await count(gateway, expected: 1)
        let bytes = try await reply.body(); XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("fixture"))
        try await count(gateway, expected: 0)
    }
    func testNonstreamAndErrorBodyWaitForDrainThenForDownstream() async throws {
        for status in [200, 429] {
            let http = ShimActivityTransport(status: status), (root, _, gateway) = try fixture(http)
            defer { http.closeFixture(); try? FileManager.default.removeItem(at: root) }
            let input = try request(stream: false), pending = Task { try await gateway.handle(input) }
            await http.opened.wait()
            let body: JSONValue = status == 200 ? ["choices": [["message": ["content": "fixture"], "finish_reason": "stop"]]] : ["error": ["message": "fixture unavailable"]]
            http.yield(try body.encoded()); http.finish(); await http.cancelled.wait()
            try await count(gateway, expected: 1)
            http.drained.signal()
            let reply = try await pending.value
            XCTAssertEqual(reply.status, status)
            try await count(gateway, expected: 1)
            _ = try await reply.body()
            try await count(gateway, expected: 0)
        }
    }
    func testCancelledBodyRemainsBusyThroughProducerDrain() async throws {
        let http = ShimActivityTransport(), (root, _, gateway) = try fixture(http)
        defer { http.closeFixture(); try? FileManager.default.removeItem(at: root) }
        let reply = try await gateway.handle(request()), consumer = Task { try await reply.body() }
        consumer.cancel(); await http.cancelled.wait()
        try await count(gateway, expected: 1)
        http.drained.signal()
        do { _ = try await consumer.value; XCTFail("Cancelled stream returned a body") } catch { XCTAssertTrue(error is CancellationError) }
        try await count(gateway, expected: 0)
    }
    func testCancellationAfterBodyEOFAwaitsDrainAndDoesNotReturnSuccess() async throws {
        let http = ShimActivityTransport(), (root, _, gateway) = try fixture(http)
        defer { http.closeFixture(); try? FileManager.default.removeItem(at: root) }
        let input = try request(stream: false), pending = Task { try await gateway.handle(input) }
        await http.opened.wait()
        http.yield(try JSONValue.object(["choices": [["message": ["content": "fixture"], "finish_reason": "stop"]]]).encoded())
        http.finish(); await http.cancelled.wait()
        // body() has reached EOF and requested cleanup, but the transport's
        // acknowledgement is held. Cancellation must win after that drain.
        pending.cancel(); try await count(gateway, expected: 1)
        http.drained.signal()
        do { _ = try await pending.value; XCTFail("Cancellation during EOF cleanup returned success") } catch { XCTAssertTrue(error is CancellationError) }
        try await count(gateway, expected: 0)
    }
    func testConcurrentRequestsRetireIndependentlyAndNeverBelowZero() async throws {
        let first = ShimActivityTransport(), second = ShimActivityTransport(), (root, _, gateway) = try fixture(ShimActivityQueue([first, second]))
        defer { first.closeFixture(); second.closeFixture(); try? FileManager.default.removeItem(at: root) }
        let a = try await gateway.handle(request()), b = try await gateway.handle(request())
        try await count(gateway, expected: 2)
        a.cancel(); await first.cancelled.wait()
        try await count(gateway, expected: 2)
        first.drained.signal(); await a.waitForCompletion()
        try await count(gateway, expected: 1)
        b.cancel(); second.drained.signal(); await b.waitForCompletion(); a.cancel(); b.cancel()
        try await count(gateway, expected: 0)
    }
    func testTaskInstalledAfterEarlierCensusIsCapturedByAtomicCancel() async throws {
        let http = ShimActivityTransport(holdHeaders: true), (root, _, gateway) = try fixture(http)
        let ended = ShimActivitySignal()
        // Construct an inert connection without starting/binding it. Admission
        // runs the real gateway; the test drives the EOF boundary explicitly.
        let socket = ShimSocket(connection: NWConnection(host: "127.0.0.1", port: .any, using: .tcp), gateway: gateway,
                                queue: DispatchQueue(label: "shim-inert-fixture"), readTimeout: 1, ended: { ended.signal() })
        defer { socket.cancel(); http.closeFixture(); try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(socket.pendingTask())
        // The old shutdown census ran here, then a read installed this task.
        socket.serve(try request(stream: false), observeDisconnect: false)
        await http.opened.wait()
        let pending = try XCTUnwrap(socket.cancelAndTask())
        await http.cancelled.wait()
        XCTAssertFalse(ended.isSignalled)
        try await count(gateway, expected: 1)
        socket.serve(try request(), observeDisconnect: false)
        try await count(gateway, expected: 1)
        http.drained.signal(); await pending.value
        XCTAssertTrue(ended.isSignalled); XCTAssertNil(socket.pendingTask())
        try await count(gateway, expected: 0)
    }
    func testPrivateSocketDisconnectAndShutdownAwaitHeldUpstreamCleanup() async throws {
        let http = ShimActivityTransport(holdHeaders: true), (root, paths, _) = try fixture(http)
        let server = try NativeShimServer(paths: paths, port: 0, dependencies: .init(transport: http, retryBackoff: [], heartbeatSeconds: 0))
        defer { http.closeFixture(); server.stop(); try? FileManager.default.removeItem(at: root) }
        try await server.start(); let port = try XCTUnwrap(server.listeningPort); XCTAssertNotEqual(port, 8823); XCTAssertNotEqual(port, 8780)
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        client.start(queue: DispatchQueue(label: "shim-activity-fixture")); defer { client.cancel() }
        let input = try request(), header = "POST /fixture/v1/messages HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(input.body.count)\r\n\r\n"
        await withCheckedContinuation { continuation in client.send(content: Data(header.utf8) + input.body, completion: .contentProcessed { _ in continuation.resume() }) }
        await http.opened.wait(); XCTAssertEqual(server.activeRequests, 1)
        let health = try await ShimURLSessionTransport().open(.init(url: URL(string: "http://127.0.0.1:\(port)/healthz")!, method: "GET", timeout: 2))
        let healthBody = try JSONValue.decode(await health.body())
        XCTAssertEqual(healthBody["activeRequests"], 1)
        client.cancel(); await http.cancelled.wait()
        XCTAssertEqual(server.activeRequests, 1)
        let shutdown = Task { await server.shutdown() }
        for _ in 0..<100 where server.listeningPort != nil { await Task.yield() }
        let secondBegan = ShimActivitySignal(), secondFinished = ShimActivitySignal()
        let secondShutdown = Task { secondBegan.signal(); await server.shutdown(); secondFinished.signal() }
        await secondBegan.wait()
        for _ in 0..<32 { await Task.yield() }
        XCTAssertFalse(secondFinished.isSignalled)
        do { try await server.start(); XCTFail("A draining listener restarted early") } catch { XCTAssertTrue(error.localizedDescription.contains("draining")) }
        XCTAssertEqual(server.activeRequests, 1)
        http.drained.signal(); await shutdown.value; await secondShutdown.value
        XCTAssertEqual(server.activeRequests, 0); XCTAssertEqual(server.activeConnections, 0)
    }
}
