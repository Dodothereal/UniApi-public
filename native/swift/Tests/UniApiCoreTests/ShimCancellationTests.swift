import XCTest
@testable import UniApiCore

private final class ShimHeldFixture: ShimTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stopped = false
    let began: @Sendable () -> Void, cancelled: @Sendable () -> Void
    init(began: @escaping @Sendable () -> Void = {}, cancelled: @escaping @Sendable () -> Void = {}) { self.began = began; self.cancelled = cancelled }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        let stream = AsyncThrowingStream<Data, Error> { continuation in lock.withLock { self.continuation = continuation } }
        began(); return .init(status: 200, chunks: stream, cancel: { self.stop() })
    }
    private func stop() { lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; let continuation = continuation; lock.unlock(); continuation?.finish(throwing: CancellationError()); cancelled() }
}
private final class ShimClockFixture: @unchecked Sendable {
    let lock = NSLock(); var calls = 0
    func now() -> Date { lock.withLock { calls += 1; return Date(timeIntervalSince1970: calls == 1 ? 0 : 20) } }
}

final class ShimCancellationTests: XCTestCase {
    func testDownstreamCancellationClosesHeldUpstreamWithoutRetry() async throws {
        let began = expectation(description: "fixture upstream opened"), cancelled = expectation(description: "fixture upstream cancelled")
        let http = ShimHeldFixture(began: { began.fulfill() }, cancelled: { cancelled.fulfill() })
        let (root, runtime, _) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        let gateway = NativeShimGateway(providers: runtime.providers, dependencies: .init(transport: http, heartbeatSeconds: 0))
        let body: JSONValue = ["model": "api-model", "stream": true, "messages": [["role": "user", "content": "fixture"]]]
        let response = try await gateway.handle(.init(method: "POST", path: "/fixture/v1/messages", headers: ["host": "localhost"], body: try body.encoded()))
        await fulfillment(of: [began], timeout: 1)
        let consumer = Task { try await response.body() }; consumer.cancel()
        do { _ = try await consumer.value; XCTFail("Cancelled downstream completed") } catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [cancelled], timeout: 1)
    }
    func testSilentUpstreamEmitsEnvelopeBeforeHeartbeatForBothTranslatedWires() async throws {
        for responses in [false, true] {
            let http = ShimHeldFixture(), clock = ShimClockFixture(), (root, runtime, _) = try SwitcherFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
            let gateway = NativeShimGateway(providers: runtime.providers, dependencies: .init(transport: http, now: { clock.now() }, heartbeatSeconds: 0.01))
            let body: JSONValue = responses ? ["model": "api-model", "stream": true, "input": "fixture"] : ["model": "api-model", "stream": true, "messages": [["role": "user", "content": "fixture"]]]
            let reply = try await gateway.handle(.init(method: "POST", path: responses ? "/fixture/v1/responses" : "/fixture/v1/messages", headers: ["host": "localhost"], body: try body.encoded()))
            var iterator = reply.chunks.makeAsyncIterator(), parser = ShimSSEParser()
            let first = try await iterator.next(), second = try await iterator.next()
            let opening = try XCTUnwrap(first), ping = try XCTUnwrap(second)
            let frames = try parser.feed(opening + ping, final: true)
            XCTAssertEqual(frames.first?.event, responses ? "response.created" : "message_start"); XCTAssertEqual(frames.last?.event, responses ? "response.heartbeat" : "ping")
            reply.cancel()
        }
    }
}
