import Foundation
import XCTest
@testable import UniApiCore

final class HomeCacheInvalidationAcceptanceTests: XCTestCase {
    func testCanonicalStatisticsCompletionInvalidatesHeldHomeBeforeScannedEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-statistics-startup-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        let file = runtime.paths.home.appendingPathComponent(".claude/projects/p/a.jsonl")
        let row: JSONValue = ["type": "assistant", "timestamp": "2026-10-10T10:00:00Z",
                              "message": ["id": "a", "model": "fixture", "usage": ["input_tokens": 100, "output_tokens": 2]]]
        try NativeFile.writeAtomic(try row.encoded(), to: file)
        let service = NativeStatisticsService(runtime: runtime), entered = expectation(description: "old Home fanout held")
        addTeardownBlock { await service.shutdownInitialGeneration() }
        let loader = heldLoader([1]) { if $0 == 1 { entered.fulfill() } }
        let pending = request {
            try await runtime.cache.readCurrent("hub:summaries") {
                let value = await loader.load()
                return value["revision"] == 1 ? ["stats": ["loaded": false]] : ["stats": service.cachedSummary()]
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        let stream = await runtime.events.stream(), scanned = expectation(description: "canonical completion event")
        let watcher = Task {
            for await event in stream where event.topic == "stats.scanned" { scanned.fulfill(); break }
        }
        defer { watcher.cancel() }
        let token = try XCTUnwrap(service.reserveInitialGeneration())
        try await service.startInitialGeneration(token)
        await fulfillment(of: [scanned], timeout: 1)
        await loader.release(1)
        let result = try await completion(of: pending).get(), calls = await loader.calls
        XCTAssertEqual(result["stats"]["grand"], 102)
        XCTAssertEqual(result["stats"]["provenance"], "corpus")
        XCTAssertEqual(calls, 2, "Obsolete pending Home work must retry against the actual published generation")
        await service.shutdownInitialGeneration()
    }
    func testReadCurrentReturnsPublishedLatestAfterHeldLoadIsInvalidated() async throws {
        let cache = NativePayloadCache(), entered = expectation(description: "old load entered")
        let loader = heldLoader([1]) { if $0 == 1 { entered.fulfill() } }
        let pending = request { try await cache.readCurrent("home") { await loader.load() } }
        await fulfillment(of: [entered], timeout: 2)

        await cache.invalidate("home")
        let published = try await cache.read("home") { ["revision": 42, "latest": true] }
        await loader.release(1)

        let returned = try await completion(of: pending).get()
        let cached = await cache.peek("home"), calls = await loader.calls
        XCTAssertEqual(returned, published)
        XCTAssertEqual(cached, published)
        XCTAssertEqual(calls, 1, "Retry must reuse the newly published payload")
    }

    func testReadCurrentSurvivesRepeatedInvalidationsWithoutReturningObsoleteLoads() async throws {
        let cache = NativePayloadCache()
        let entered = (1...3).map { expectation(description: "load \($0) entered") }
        let loader = heldLoader([1, 2, 3]) { if (1...3).contains($0) { entered[$0 - 1].fulfill() } }
        let pending = request { try await cache.readCurrent("home") { await loader.load() } }

        for attempt in 1...2 {
            await fulfillment(of: [entered[attempt - 1]], timeout: 2)
            await cache.invalidate("home")
            await loader.release(attempt)
        }
        await fulfillment(of: [entered[2]], timeout: 2)
        await loader.release(3)

        let returned = try await completion(of: pending).get()
        let cached = await cache.peek("home"), calls = await loader.calls
        XCTAssertEqual(returned, ["revision": 3])
        XCTAssertEqual(cached, returned)
        XCTAssertEqual(calls, 3)
    }

    func testReadCurrentDoesNotRetryGenuineLoaderFailureEvenAfterInvalidation() async throws {
        let cache = NativePayloadCache(), entered = expectation(description: "failing load entered")
        let loader = heldLoader([1]) { if $0 == 1 { entered.fulfill() } }
        let pending = request {
            try await cache.readCurrent("home") {
                let payload = await loader.load()
                if payload["revision"] == 1 { throw HomeCacheAcceptanceFailure.loaderFailed }
                return payload
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        await cache.invalidate("home")
        await loader.release(1)

        switch try await completion(of: pending) {
        case .failure(let error): XCTAssertEqual(error as? HomeCacheAcceptanceFailure, .loaderFailed)
        case .success: XCTFail("A genuine failure was hidden by a retry")
        }
        let calls = await loader.calls, cached = await cache.peek("home")
        XCTAssertEqual(calls, 1)
        XCTAssertNil(cached)
    }

    func testReadCurrentDoesNotLoopWhenLoaderCancelsWithoutInvalidation() async throws {
        let cache = NativePayloadCache(), loader = heldLoader([])
        let pending = request {
            try await cache.readCurrent("home") {
                let payload = await loader.load()
                if payload["revision"] == 1 { throw CancellationError() }
                return payload
            }
        }

        assertCancellation(try await completion(of: pending))
        let calls = await loader.calls, cached = await cache.peek("home")
        XCTAssertEqual(calls, 1, "Loader cancellation alone must not trigger another load")
        XCTAssertNil(cached)
    }

    func testCancelledWaiterCannotReturnSuccessOrCancelAnotherWaiter() async throws {
        let cache = NativePayloadCache(), entered = expectation(description: "shared load entered")
        let survivorEntered = expectation(description: "surviving request started")
        let loader = heldLoader([1]) { if $0 == 1 { entered.fulfill() } }
        // Cancel the request that started the flight, so ownership cannot be
        // mistaken for permission to cancel work needed by another caller.
        let cancelled = request { try await cache.readCurrent("home") { await loader.load() } }
        await fulfillment(of: [entered], timeout: 2)
        let survivor = request {
            survivorEntered.fulfill()
            return try await cache.readCurrent("home") { await loader.load() }
        }
        await fulfillment(of: [survivorEntered], timeout: 2)
        cancelled.cancel()
        await loader.release(1)

        assertCancellation(try await completion(of: cancelled))
        let returned = try await completion(of: survivor).get()
        let cached = await cache.peek("home"), calls = await loader.calls
        XCTAssertEqual(returned, ["revision": 1])
        XCTAssertEqual(cached, returned)
        XCTAssertEqual(calls, 1, "Cancelling one waiter must preserve the shared flight")
    }

    func testHubSnapshotInvalidatedWhileHeldReturnsThePublishedSixDomainTruth() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("home-cache-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        let entered = expectation(description: "all six old summary readers entered")
        let reader = HomeCacheSummaryGate { entered.fulfill() }
        addTeardownBlock { await reader.close() }
        let service = NativeHubSummaries(runtime: runtime, read: { await reader.read($0) })
        let oldRequest = request { try await service.snapshot() }
        await fulfillment(of: [entered], timeout: 2)

        await reader.selectLatest()
        await runtime.cache.invalidate("hub:summaries")
        let currentRequest = request { try await service.snapshot() }
        let published = try await completion(of: currentRequest).get()
        XCTAssertEqual(published, homeCacheSummaryTruth)
        await reader.releaseOld()

        let returned = try await completion(of: oldRequest).get()
        let cached = await runtime.cache.peek("hub:summaries"), calls = await reader.calls
        XCTAssertEqual(returned, published)
        XCTAssertEqual(cached, homeCacheSummaryTruth)
        XCTAssertEqual(returned.object.count, 6)
        for (_, value) in returned.object { XCTAssertTrue(value["error"].isNull) }
        XCTAssertEqual(calls, 12, "Only the obsolete and replacement six-domain reads should run")
    }

    func testForcedReadCurrentForcesOnceThenReusesReplacementWithoutThirdReload() async throws {
        let cache = NativePayloadCache(), entered = expectation(description: "forced reload entered")
        let seed = try await cache.read("home") { ["revision": 0] }
        XCTAssertEqual(seed, ["revision": 0])
        let loader = heldLoader([1]) { if $0 == 1 { entered.fulfill() } }
        let pending = request { try await cache.readCurrent("home", force: true) { await loader.load() } }
        await fulfillment(of: [entered], timeout: 2)

        await cache.invalidate("home")
        let published = try await cache.read("home", force: true) { await loader.load() }
        XCTAssertEqual(published, ["revision": 2])
        await loader.release(1)

        let returned = try await completion(of: pending).get()
        let cached = await cache.peek("home"), calls = await loader.calls
        XCTAssertEqual(returned, published)
        XCTAssertEqual(cached, published)
        XCTAssertEqual(calls, 2, "The invalidation retry must drop force instead of loading a third time")
    }

    func testOrdinaryReadStillThrowsCancellationAndCannotPublishAnInvalidatedLoad() async throws {
        let cache = NativePayloadCache(), entered = expectation(description: "strict load entered")
        let loader = heldLoader([1]) { if $0 == 1 { entered.fulfill() } }
        let pending = request { try await cache.read("home") { await loader.load() } }
        await fulfillment(of: [entered], timeout: 2)
        await cache.invalidate("home")
        let published = try await cache.read("home") { await loader.load() }
        await loader.release(1)

        assertCancellation(try await completion(of: pending))
        let cached = await cache.peek("home"), calls = await loader.calls
        XCTAssertEqual(published, ["revision": 2])
        XCTAssertEqual(cached, published)
        XCTAssertEqual(calls, 2)
    }

    private func heldLoader(_ held: Set<Int>, started: @escaping @Sendable (Int) -> Void = { _ in }) -> HomeCacheHeldLoader {
        let loader = HomeCacheHeldLoader(held: held, started: started)
        addTeardownBlock { await loader.close() }
        return loader
    }

    private func request(_ operation: @escaping @Sendable () async throws -> JSONValue) -> Task<JSONValue, Error> {
        let task = Task { try await operation() }
        addTeardownBlock { task.cancel() }
        return task
    }

    private func completion(of task: Task<JSONValue, Error>) async throws -> Result<JSONValue, Error> {
        let completed = expectation(description: "cache request completed"), result = HomeCacheCompletion()
        let observer = Task {
            await result.store(await task.result)
            completed.fulfill()
        }
        defer { observer.cancel() }
        await fulfillment(of: [completed], timeout: 2)
        guard let outcome = await result.value else {
            task.cancel()
            throw HomeCacheAcceptanceFailure.timedOut
        }
        return outcome
    }

    private func assertCancellation(_ result: Result<JSONValue, Error>, file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .failure(let error): XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)", file: file, line: line)
        case .success: XCTFail("Cancelled request returned a successful payload", file: file, line: line)
        }
    }
}

private enum HomeCacheAcceptanceFailure: Error, Equatable { case loaderFailed, timedOut }

private actor HomeCacheCompletion {
    private(set) var value: Result<JSONValue, Error>?
    func store(_ result: Result<JSONValue, Error>) { value = result }
}

private actor HomeCacheHeldLoader {
    private(set) var calls = 0
    private let held: Set<Int>
    private let started: @Sendable (Int) -> Void
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var closed = false

    init(held: Set<Int>, started: @escaping @Sendable (Int) -> Void) {
        self.held = held; self.started = started
    }
    func load() async -> JSONValue {
        calls += 1
        let attempt = calls
        started(attempt)
        // Deliberately ignore cancellation: invalidation must also reject a
        // loader that finishes with stale data instead of throwing promptly.
        if held.contains(attempt), !released.contains(attempt), !closed {
            await withCheckedContinuation { waiting[attempt] = $0 }
        }
        return ["revision": .number(Double(attempt))]
    }
    func release(_ attempt: Int) {
        released.insert(attempt)
        waiting.removeValue(forKey: attempt)?.resume()
    }
    func close() {
        closed = true
        let pending = waiting.values; waiting = [:]
        for continuation in pending { continuation.resume() }
    }
}

private let homeCacheSummaryTruth: JSONValue = [
    "switcher": ["current": "subscription"],
    "code": ["pendingPermissions": 3, "threads": 2],
    "arena": ["pendingVotes": 2],
    "transcribe": ["completed": 5],
    "stats": ["input": 321, "output": 45, "nested": [["model": "fixture", "tokens": 366]]],
    "bench": ["planned": 7, "running": false]
]

private actor HomeCacheSummaryGate {
    private(set) var calls = 0
    private var oldDomains: Set<String> = []
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var latest = false, released = false
    private let started: @Sendable () -> Void

    init(started: @escaping @Sendable () -> Void) { self.started = started }
    func read(_ domain: String) async -> JSONValue {
        calls += 1
        if latest { return homeCacheSummaryTruth[domain] }
        oldDomains.insert(domain)
        if oldDomains.count == 6 { started() }
        if !released { await withCheckedContinuation { waiting.append($0) } }
        return ["obsolete": true, "domain": .string(domain)]
    }
    func selectLatest() { latest = true }
    func releaseOld() {
        released = true
        let pending = waiting; waiting = []
        for continuation in pending { continuation.resume() }
    }
    func close() { latest = true; releaseOld() }
}
