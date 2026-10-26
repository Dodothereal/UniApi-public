import XCTest
@testable import UniApiCore

final class HubSummaryBoundaryTests: XCTestCase {
    private func runtime() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hub-fanout-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeRuntime(paths: NativePaths(root: root, home: root))
    }
    func testAllSixReadersStartBeforeAnyReaderFinishes() async throws {
        let runtime = try runtime(), started = expectation(description: "six parallel readers")
        let gate = HubBoundaryGate { started.fulfill() }
        let service = NativeHubSummaries(runtime: runtime, read: { try await gate.read($0) })
        let first = Task { try await service.snapshot() }, second = Task { try await service.snapshot() }
        await fulfillment(of: [started], timeout: 1)
        await gate.finish()
        let a = try await first.value, b = try await second.value
        XCTAssertEqual(a, b); XCTAssertEqual(a.object.count, 6)
        XCTAssertEqual(a["arena"]["error"], "fixture failure")
        let calls = await gate.calls; XCTAssertEqual(calls, 6)
    }
    func testRepeatedOptimizedCoalescingPreservesWideRecursiveValuesAndErrors() async throws {
        let runtime = try runtime(), fixture = HubBoundaryReader()
        let service = NativeHubSummaries(runtime: runtime, read: { try await fixture.read($0) })
        for _ in 0..<40 {
            await runtime.cache.invalidate("hub:")
            async let first = service.snapshot(), second = service.snapshot()
            let a = try await first, b = try await second
            XCTAssertEqual(a, b); XCTAssertEqual(a.object.count, 6)
            XCTAssertEqual(a["stats"]["nested"].array.count, 8)
            XCTAssertEqual(a["arena"]["error"], "fixture failure")
        }
        let calls = await fixture.calls; XCTAssertEqual(calls, 240)
    }
    func testInvalidationCancelsAllOwnedFanoutReadersAndDoesNotCacheTheirResults() async throws {
        let runtime = try runtime(), started = expectation(description: "readers started"), stopped = expectation(description: "readers stopped")
        let replacement = expectation(description: "replacement readers started"), completed = expectation(description: "current snapshot completed")
        let fixture = HubBoundaryCancellation(started: { started.fulfill() }, stopped: { stopped.fulfill() }, replacement: { replacement.fulfill() })
        let service = NativeHubSummaries(runtime: runtime, read: { try await fixture.read($0) })
        let pending = Task {
            let result: Result<JSONValue, Error>
            do { result = .success(try await service.snapshot()) }
            catch { result = .failure(error) }
            await fixture.record(result)
            completed.fulfill()
        }
        addTeardownBlock { pending.cancel(); await fixture.finish() }
        await fulfillment(of: [started], timeout: 1)
        await runtime.cache.invalidate("hub:")
        await fulfillment(of: [stopped, replacement], timeout: 2)
        let stale = await runtime.cache.peek("hub:summaries"); XCTAssertNil(stale)
        // snapshot now opts into readCurrent: invalidated fanout still drains,
        // but its uncancelled caller retries instead of exposing cancellation.
        // Ordinary read retains its strict contract in HomeCacheInvalidationAcceptanceTests.
        await fixture.finish()
        await fulfillment(of: [completed], timeout: 2)
        guard let result = await fixture.result else { XCTFail("Snapshot did not finish"); return }
        let value = try result.get(), cached = await runtime.cache.peek("hub:summaries")
        XCTAssertEqual(value.object.count, 6)
        for (domain, summary) in value.object {
            XCTAssertEqual(summary, ["domain": .string(domain), "current": true])
            XCTAssertTrue(summary["error"].isNull)
        }
        XCTAssertEqual(cached, value)
        let counts = await fixture.counts
        XCTAssertEqual(counts.entered, 12)
        XCTAssertEqual(counts.cancelled, 6)
    }
}
private actor HubBoundaryGate {
    var calls = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private let started: @Sendable () -> Void
    init(_ started: @escaping @Sendable () -> Void) { self.started = started }
    func read(_ domain: String) async throws -> JSONValue {
        calls += 1
        if calls == 6 { started() }
        await withCheckedContinuation { waiting.append($0) }
        if domain == "arena" { throw NativeFailure("fixture failure") }
        return ["domain": .string(domain)]
    }
    func finish() { let pending = waiting; waiting = []; for value in pending { value.resume() } }
}
private actor HubBoundaryReader {
    var calls = 0
    func read(_ domain: String) async throws -> JSONValue {
        calls += 1; await Task.yield()
        if domain == "arena" { throw NativeFailure("fixture failure") }
        return ["domain": .string(domain), "nested": .array((0..<8).map { ["n": .number(Double($0)), "values": [true, .null, ["inner": "fixture"]]] })]
    }
}
private actor HubBoundaryCancellation {
    private var entered = 0, cancelled = 0
    private var oldReaders: [String: CheckedContinuation<Void, Error>] = [:]
    private var newReaders: [CheckedContinuation<Void, Never>] = []
    private var closed = false
    private let started: @Sendable () -> Void, stopped: @Sendable () -> Void, replacement: @Sendable () -> Void
    private(set) var result: Result<JSONValue, Error>?
    var counts: (entered: Int, cancelled: Int) { (entered, cancelled) }
    init(started: @escaping @Sendable () -> Void, stopped: @escaping @Sendable () -> Void, replacement: @escaping @Sendable () -> Void) {
        self.started = started; self.stopped = stopped; self.replacement = replacement
    }
    func read(_ domain: String) async throws -> JSONValue {
        entered += 1
        if entered <= 6 {
            if entered == 6 { started() }
            do {
                try await withTaskCancellationHandler {
                    try Task.checkCancellation()
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        if closed || Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                        else { oldReaders[domain] = continuation }
                    }
                } onCancel: {
                    Task { await self.cancel(domain) }
                }
                return ["obsolete": true]
            } catch {
                cancelled += 1; if cancelled == 6 { stopped() }
                throw error
            }
        }
        if entered == 12 { replacement() }
        if !closed { await withCheckedContinuation { newReaders.append($0) } }
        return ["domain": .string(domain), "current": true]
    }
    private func cancel(_ domain: String) { oldReaders.removeValue(forKey: domain)?.resume(throwing: CancellationError()) }
    func record(_ result: Result<JSONValue, Error>) { self.result = result }
    func finish() {
        closed = true
        let old = oldReaders.values; oldReaders = [:]
        for continuation in old { continuation.resume(throwing: CancellationError()) }
        let current = newReaders; newReaders = []
        for continuation in current { continuation.resume() }
    }
}
