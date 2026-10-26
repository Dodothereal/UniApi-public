import Foundation
import Dispatch
import UniApiCore
import Combine
import XCTest
import AppKit
@testable import UniApiPresentation

struct BenchmarkModelFixtureFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

// Reads, saves and external disk resets have separate ledger operations.
// arm(operation) holds an already captured reply. The separately named progress
// seam below pauses BEFORE reading progressJob; it captures current state only
// after release. Both ignore cancellation to exercise the real lifecycle guard.
enum BenchmarkModelTrace {
    @TaskLocal static var origin = "driver"
}
actor BenchmarkModelFixture: NativeBenchmarkModelService {
    static let failure = "private initial preference failure"
    static let diskSelection: JSONValue = ["included": ["disk"], "models": ["disk": ["disk-model"], "shared": ["disk-shared"]], "tier": "standard"]
    static let alienSelection: JSONValue = ["included": ["alien"], "models": ["alien": ["alien-model"]], "tier": "quick"]
    static let diskResults: JSONValue = ["scope": "all", "family": "disk-family", "tab": "table", "newestRun": "r1"]
    static let alienResults: JSONValue = ["scope": "all", "family": "alien-family", "tab": "table", "newestRun": "alien-newest"]
    private var selection: JSONValue = BenchmarkModelFixture.diskSelection
    private var results: JSONValue = BenchmarkModelFixture.diskResults
    private var revision = 1, newest = "r1"
    private var activeRun: String?
    private var progressJob: JSONValue = .null
    private var operations: [JSONValue] = []
    private var armNext: Set<String> = []
    private var held: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var heldReplies: [String: JSONValue] = [:]
    private var completions: [String: Int] = [:]
    private var holdNextProgressBeforeCapture = false
    private var progressBeforeCapture: CheckedContinuation<Void, Never>?
    private var resumedBeforeCapture = false
    private var summaryOrdinals: [String: Int] = [:]
    private var advanceOnSummary: (origin: String, ordinal: Int, revision: Int, newest: String)?
    private var actualEventOrdinal = 0
    private var closed = false

    // Teardown always closes admission before releasing all held continuations.
    // Failed/timed-out tests cannot leave a read parked across another test.
    func shutdown() {
        closed = true; armNext.removeAll(); holdNextProgressBeforeCapture = false
        let pending = Array(held.values); held.removeAll(); heldReplies.removeAll()
        for continuation in pending { continuation.resume(throwing: BenchmarkModelFixtureFailure(message: "Test fixture closed")) }
        let beforeCapture = progressBeforeCapture; progressBeforeCapture = nil
        beforeCapture?.resume()
    }

    func armProgressBeforeSnapshotCapture() throws {
        guard !holdNextProgressBeforeCapture, progressBeforeCapture == nil, !armNext.contains("progress"), held["progress"] == nil else {
            throw BenchmarkModelFixtureFailure(message: "Conflicting progress hold")
        }
        holdNextProgressBeforeCapture = true
    }
    func isProgressBeforeSnapshotCaptureHeld() -> Bool { progressBeforeCapture != nil }
    func releaseProgressBeforeSnapshotCapture() throws {
        guard let continuation = progressBeforeCapture else { throw BenchmarkModelFixtureFailure(message: "Progress before-snapshot seam is not held") }
        progressBeforeCapture = nil; resumedBeforeCapture = true
        operations.append(["kind": "before-snapshot-release", "operation": "progress", "semantics": "Reply not captured yet; handle will read current progressJob after this release"])
        continuation.resume()
    }
    func advanceHistoryOnSummary(origin: String, ordinal: Int, revision: Int, newest: String) throws {
        guard advanceOnSummary == nil else { throw BenchmarkModelFixtureFailure(message: "Summary transition already armed") }
        advanceOnSummary = (origin, ordinal, revision, newest)
    }
    func note(_ phase: String) {
        operations.append(["kind": "driver-phase", "phase": .string(phase), "timestamp": .number(Date().timeIntervalSince1970 * 1000)])
    }
    func recordActualEvent(_ event: NativeEvent) {
        actualEventOrdinal += 1
        operations.append(["kind": "actual-bus-event", "ordinal": .number(Double(actualEventOrdinal)), "topic": .string(event.topic), "data": event.data, "timestamp": .number(event.timestamp)])
    }

    func arm(_ operation: String) throws {
        guard !armNext.contains(operation), held[operation] == nil else { throw BenchmarkModelFixtureFailure(message: "Already armed: " + operation) }
        guard operation != "progress" || (!holdNextProgressBeforeCapture && progressBeforeCapture == nil) else { throw BenchmarkModelFixtureFailure(message: "Conflicting progress hold semantics") }
        armNext.insert(operation)
    }
    func isHeld(_ operation: String) -> Bool { held[operation] != nil }
    func release(_ operation: String, failing: Bool = false) throws {
        guard let continuation = held.removeValue(forKey: operation), let reply = heldReplies.removeValue(forKey: operation) else {
            throw BenchmarkModelFixtureFailure(message: "No held operation: " + operation)
        }
        operations.append(["kind": "release", "operation": .string(operation), "failure": .bool(failing)])
        if failing { continuation.resume(throwing: BenchmarkModelFixtureFailure(message: Self.failure)) }
        else { continuation.resume(returning: reply) }
    }
    func ledger() -> [JSONValue] { operations }
    func count(_ operation: String) -> Int { operations.filter { $0["kind"] == "request" && $0["operation"] == .string(operation) }.count }
    func completed(_ operation: String) -> Int { completions[operation, default: 0] }
    func disk() -> JSONValue { ["selection": selection, "resultsState": results] }
    func replaceSelection(_ value: JSONValue) {
        selection = value; operations.append(["kind": "external-disk-reset", "operation": "selection", "value": value])
    }
    func replaceResults(_ value: JSONValue) {
        results = value; operations.append(["kind": "external-disk-reset", "operation": "resultsState", "value": value])
    }
    func setProgressJob(_ job: JSONValue) {
        progressJob = job; operations.append(["kind": "service-job-metadata", "value": job])
    }
    func runAdmitted(_ run: String) {
        results["scope"] = "latest"; results["newestRun"] = .string(run)
        let timestamp = Date().timeIntervalSince1970 * 1000
        progressJob = ["id": .string("job-" + run), "created_at": .number(timestamp), "started_at": .number(timestamp), "kind": "bench.run", "params": ["run_id": .string(run)]]
        operations.append(["kind": "service-run-admission", "operation": "resultsState", "value": results, "job": progressJob])
    }
    func payload(_ value: Int, newest run: String = "r1", active: String? = nil) {
        revision = value; newest = run; activeRun = active
        operations.append(["kind": "payload-revision", "revision": .number(Double(value)), "newest": .string(run)])
    }
    private func admitted(_ operation: String, input: JSONObject, reply: JSONValue) async throws -> JSONValue {
        guard !closed else { throw BenchmarkModelFixtureFailure(message: "Test fixture closed") }
        operations.append(["kind": "request", "operation": .string(operation), "input": .object(input), "capturedReply": reply, "callerCancelled": .bool(Task.isCancelled),
                           "origin": .string(BenchmarkModelTrace.origin), "replyCaptureSemantics": .string(operation == "progress" && resumedBeforeCapture ? "captured-after-before-snapshot-release" : "captured-at-admission")])
        if operation == "progress" { resumedBeforeCapture = false }
        defer { completions[operation, default: 0] += 1 }
        if armNext.remove(operation) != nil {
            return try await withCheckedThrowingContinuation { continuation in
                held[operation] = continuation; heldReplies[operation] = reply
            }
        }
        return reply
    }
    func start() async throws { _ = try await admitted("start", input: [:], reply: .null) }
    func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        guard !closed else { throw BenchmarkModelFixtureFailure(message: "Test fixture closed") }
        if operation == "progress", holdNextProgressBeforeCapture {
            holdNextProgressBeforeCapture = false
            operations.append(["kind": "before-snapshot-held", "operation": "progress", "semantics": "No reply captured; waiting before reading progressJob", "origin": .string(BenchmarkModelTrace.origin)])
            await withCheckedContinuation { continuation in
                progressBeforeCapture = continuation
            }
        }
        guard !closed else { throw BenchmarkModelFixtureFailure(message: "Test fixture closed") }
        let reply: JSONValue
        switch operation {
        case "selection": reply = selection
        case "resultsState": reply = results
        case "saveSelection":
            // Speed.persist() writes independently of Results readOnly mode.
            // It updates private in-memory fake disk, never a real preference file.
            selection = .object(input)
            operations.append(["kind": "persisted-fake-edit", "operation": .string(operation), "value": selection])
            reply = selection
        case "saveResultsState":
            operations.append(["kind": "request", "operation": .string(operation), "input": .object(input), "refusedReadOnlyWrite": true])
            throw BenchmarkModelFixtureFailure(message: "Results readOnly=true must prevent persistence")
        case "catalog": reply = ["revision": .number(Double(revision)), "providers": [["id": "disk", "transport": "api"]]]
        case "progress": reply = ["revision": .number(Double(revision)), "job": progressJob]
        case "freeTestReport": reply = ["revision": .number(Double(revision))]
        case "summary":
            let origin = BenchmarkModelTrace.origin
            summaryOrdinals[origin, default: 0] += 1
            if let transition = advanceOnSummary, transition.origin == origin, transition.ordinal == summaryOrdinals[origin] {
                advanceOnSummary = nil; revision = transition.revision; newest = transition.newest; activeRun = nil
                operations.append(["kind": "history-arrival-on-buffered-event-read", "origin": .string(origin), "summaryOrdinal": .number(Double(transition.ordinal)), "newest": .string(newest), "revision": .number(Double(revision))])
            }
            let scope = input["scope"]?.string ?? ""
            reply = ["scope": .string(scope == "latest" ? activeRun ?? (newest.isEmpty ? "all" : newest) : scope), "revision": .number(Double(revision)), "runs": newest.isEmpty ? [] : [["id": .string(newest)]],
                     "cells": ["disk": ["family": "disk-family"], "alien": ["family": "alien-family"], "local": ["family": "local-family"], "pre": ["family": "pre-family"], "during": ["family": "during-family"]]]
        case "rows", "curves":
            let noActiveRows = activeRun.map { input["scope"]?.string == $0 && newest != $0 } ?? false
            reply = newest.isEmpty || noActiveRows ? [] : [["scope": input["scope"] ?? .null, "revision": .number(Double(revision))]]
        default: throw BenchmarkModelFixtureFailure(message: "Unadmitted fake operation: " + operation)
        }
        return try await admitted(operation, input: input, reply: reply)
    }
}

@MainActor final class BenchmarkModelPublicationProbe {
    private var tokens: [AnyCancellable] = []
    private(set) var records: [JSONValue] = []
    private func observe<T>(_ publisher: Published<T>.Publisher, _ field: String, _ encode: @escaping (T) -> JSONValue) {
        tokens.append(publisher.dropFirst().sink { [weak self] value in
            self?.records.append(["field": .string(field), "value": encode(value)])
        })
    }
    init(_ model: NativeSpeedModel) {
        observe(model.$selection, "selection", { $0 }); observe(model.$catalog, "catalog", { $0 })
        observe(model.$progress, "progress", { $0 }); observe(model.$free, "free", { $0 }); observe(model.$error, "error", JSONValue.string)
    }
    init(_ model: NativeResultsModel) {
        observe(model.$scope, "scope", JSONValue.string); observe(model.$family, "family", JSONValue.string)
        observe(model.$tab, "tab", JSONValue.string); observe(model.$payload, "payload", { $0 })
        observe(model.$raw, "raw", JSONValue.array); observe(model.$curves, "curves", JSONValue.array)
        observe(model.$error, "error", JSONValue.string)
    }
}

@MainActor final class BenchmarkModelOwnedTask {
    let label: String
    private(set) var finished = false
    private var task: Task<Void, Never>?
    init(_ label: String, action: @escaping @MainActor () async -> Void) {
        self.label = label
        task = Task { await action(); self.finished = true }
    }
    func cancel() { task?.cancel() }
}

@MainActor final class BenchmarkModelTestContext {
    let service = BenchmarkModelFixture()
    let events = NativeEvents()
    private var stops: [@MainActor () -> Void] = []
    private var tasks: [BenchmarkModelOwnedTask] = []

    func speed() -> NativeSpeedModel {
        let model = NativeSpeedModel(service: service)
        stops.append { model.stopListening() }; return model
    }
    func results(initialRun: String? = nil) -> NativeResultsModel {
        let model = NativeResultsModel(service: service, readOnly: true, initialRun: initialRun)
        stops.append { model.stop() }; return model
    }
    @discardableResult func start(_ label: String, action: @escaping @MainActor () async -> Void) -> BenchmarkModelOwnedTask {
        let task = BenchmarkModelOwnedTask(label, action: action); tasks.append(task); return task
    }
    func wait(_ message: String, file: StaticString = #filePath, line: UInt = #line, until predicate: @MainActor () async -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while true {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
            let ready = await predicate()
            // A predicate that resumes late must not turn a timeout into a pass.
            guard DispatchTime.now().uptimeNanoseconds < deadline else { break }
            if ready { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let ledger = await service.ledger()
        XCTFail("Timed out: \(message); ledger=\(ledger)", file: file, line: line)
        throw BenchmarkModelFixtureFailure(message: "Timed out: " + message)
    }

    func join(_ task: BenchmarkModelOwnedTask, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await wait(task.label + " completed", file: file, line: line) { task.finished }
    }
    func run(_ label: String, file: StaticString = #filePath, line: UInt = #line, action: @escaping @MainActor () async -> Void) async throws {
        let task = start(label, action: action)
        try await join(task, file: file, line: line)
    }
    func held(_ operation: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await wait(operation + " held", file: file, line: line) { await self.service.isHeld(operation) }
    }
    // Holds establish causality. These yields only let the model's incidental
    // persist/load Tasks join preparation before the test releases its hold.
    func settle() async { for _ in 0..<40 { await Task.yield() } }
    func close() async {
        for stop in stops { stop() }
        for task in tasks { task.cancel() }
        await service.shutdown()
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while tasks.contains(where: { !$0.finished }), DispatchTime.now().uptimeNanoseconds < deadline {
            do { try await Task.sleep(nanoseconds: 1_000_000) } catch { break }
        }
        XCTAssertTrue(tasks.allSatisfy { $0.finished }, "Owned tasks did not clean up: \(tasks.filter { !$0.finished }.map(\.label))")
        let resultsSaves = await service.count("saveResultsState")
        XCTAssertEqual(resultsSaves, 0, "readOnly Results must never save preferences")
        // Read AppKit's existing global only; never construct an application.
        XCTAssertNil(NSApp, "Presentation tests must remain headless")
    }
}

@MainActor enum BenchmarkModelSnapshot {
    static func field<T>(_ model: Any, _ name: String, as type: T.Type) throws -> T {
        let child = try XCTUnwrap(Mirror(reflecting: model).children.first { $0.label == name }, "Missing field: " + name)
        return try XCTUnwrap(child.value as? T, "Wrong field type: " + name)
    }
    static func results(_ model: NativeResultsModel) throws -> JSONValue {
        let explicit: String? = try field(model, "explicitRun", as: String?.self)
        let newest: String = try field(model, "newest", as: String.self)
        let chosen: Double = try field(model, "lastScopeChoice", as: Double.self)
        return ["scope": .string(model.scope), "family": .string(model.family), "tab": .string(model.tab),
                "explicitRun": explicit.map(JSONValue.string) ?? .null, "newest": .string(newest), "lastScopeChoice": .number(chosen),
                "payload": model.payload, "raw": .array(model.raw), "curves": .array(model.curves), "error": .string(model.error)]
    }
    static func preferences(_ value: JSONValue) -> JSONValue {
        .object(value.object.filter { ["scope", "family", "tab", "explicitRun", "newest", "lastScopeChoice"].contains($0.key) })
    }
}
