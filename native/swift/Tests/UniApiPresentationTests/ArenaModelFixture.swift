import Foundation
import Dispatch
import XCTest
import UniApiCore
@testable import UniApiPresentation

// Replies are captured at admission, then deliberately ignore cancellation.
// Only the actual model decides whether a released success/error can publish.
actor ArenaModelFixture: NativeArenaModelService {
    struct Call: Sendable {
        let operation: String
        let input: JSONObject
        let cancelled: Bool
    }
    private struct Reply {
        let value: JSONValue
        let hold: String?
        let failure: String?
        let publication: (String, JSONValue)?
    }
    private let events: NativeEvents
    private var plans: [String: [Reply]] = [:]
    private var defaults: [String: JSONValue] = [:]
    private var pending: [String: (CheckedContinuation<JSONValue, Error>, Reply)] = [:]
    private var calls: [Call] = []
    private var completed: [String: Int] = [:]
    private var closed = false

    init(events: NativeEvents) { self.events = events }
    func set(_ key: String, _ value: JSONValue) { defaults[key] = value }
    func enqueue(_ key: String, _ value: JSONValue, hold: String? = nil, failure: String? = nil,
                 publish: (String, JSONValue)? = nil) {
        plans[key, default: []].append(Reply(value: value, hold: hold, failure: failure, publication: publish))
    }
    func isHeld(_ name: String) -> Bool { pending[name] != nil }
    func count(_ operation: String, id: String? = nil, after: Int? = nil) -> Int {
        calls.filter { $0.operation == operation && (id == nil || $0.input["id"]?.string == id)
            && (after == nil || $0.input["after"]?.int == after) }.count
    }
    func completions(_ key: String) -> Int { completed[key] ?? 0 }
    func ledger() -> [Call] { calls }
    func release(_ name: String, failure: String? = nil) throws {
        guard let (continuation, reply) = pending.removeValue(forKey: name) else { throw NativeFailure("No held reply: " + name) }
        if let message = failure ?? reply.failure { continuation.resume(throwing: NativeFailure(message)) }
        else { continuation.resume(returning: reply.value) }
    }
    func shutdown() {
        closed = true; plans.removeAll()
        let held = Array(pending.values); pending.removeAll()
        for (continuation, _) in held { continuation.resume(throwing: NativeFailure("Fixture closed")) }
    }
    func handle(_ operation: String, input: JSONObject) async throws -> JSONValue {
        guard !closed else { throw NativeFailure("Fixture closed") }
        calls.append(Call(operation: operation, input: input, cancelled: Task.isCancelled))
        let key: String
        switch operation {
        case "events": key = "events:" + (input["id"]?.string ?? "") + ":" + String(input["after"]?.int ?? 0)
        case "ranking": key = "ranking:" + (input["mode"]?.string ?? "")
        case "files": key = "files:" + (input["id"]?.string ?? "")
        default: key = operation
        }
        let reply: Reply
        if var queue = plans[key], !queue.isEmpty { reply = queue.removeFirst(); plans[key] = queue }
        else {
            let fallback: JSONValue = ["matches", "events", "ledger.records"].contains(operation) ? [] : [:]
            reply = Reply(value: defaults[key] ?? fallback, hold: nil, failure: nil, publication: nil)
        }
        defer { completed[key, default: 0] += 1 }
        if let (topic, value) = reply.publication { await events.publish(topic, value) }
        guard !closed else { throw NativeFailure("Fixture closed") }
        if let hold = reply.hold {
            guard pending[hold] == nil else { throw NativeFailure("Duplicate hold: " + hold) }
            return try await withCheckedThrowingContinuation { pending[hold] = ($0, reply) }
        }
        if let message = reply.failure { throw NativeFailure(message) }
        return reply.value
    }
}

@MainActor final class ArenaModelOwnedTask {
    let label: String
    private(set) var finished = false
    private var task: Task<Void, Never>?
    init(_ label: String, action: @escaping @MainActor () async -> Void) {
        self.label = label
        task = Task { await action(); self.finished = true }
    }
    func cancel() { task?.cancel() }
}

@MainActor final class ArenaModelTestContext {
    let events: NativeEvents
    let service: ArenaModelFixture
    let model: NativeArenaModel
    private var tasks: [ArenaModelOwnedTask] = []
    init() {
        let events = NativeEvents(), service = ArenaModelFixture(events: events)
        self.events = events; self.service = service; model = NativeArenaModel(service: service)
    }
    @discardableResult func start(_ label: String, action: @escaping @MainActor () async -> Void) -> ArenaModelOwnedTask {
        let task = ArenaModelOwnedTask(label, action: action); tasks.append(task); return task
    }
    @discardableResult func enter() async throws -> ArenaModelOwnedTask {
        let task = start("Arena begin") { await self.model.begin(events: self.events) }
        try await join(task)
        guard model.loaded, model.readActive else { throw NativeFailure("Arena initial reads did not become ready") }
        return task
    }
    func wait(_ message: String, file: StaticString = #filePath, line: UInt = #line,
              until predicate: @MainActor () async -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let ready = await predicate()
            if ready && DispatchTime.now().uptimeNanoseconds < deadline { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let calls = await service.ledger()
        XCTFail("Timed out: \(message); calls=\(calls)", file: file, line: line)
        throw NativeFailure("Timed out: " + message)
    }
    func held(_ name: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await wait(name + " held", file: file, line: line) { await self.service.isHeld(name) }
    }
    func join(_ task: ArenaModelOwnedTask, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await wait(task.label + " completed", file: file, line: line) { task.finished }
    }
    func run(_ label: String, action: @escaping @MainActor () async -> Void) async throws {
        try await join(start(label, action: action))
    }
    func close() async {
        model.stop(); tasks.forEach { $0.cancel() }
        await service.shutdown()
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while tasks.contains(where: { !$0.finished }), DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(tasks.allSatisfy(\.finished), "Arena test tasks did not finish: \(tasks.filter { !$0.finished }.map(\.label))")
        let calls = await service.ledger()
        XCTAssertFalse(calls.contains(where: \.cancelled), "A cancelled reader dispatched another service operation")
    }
}
