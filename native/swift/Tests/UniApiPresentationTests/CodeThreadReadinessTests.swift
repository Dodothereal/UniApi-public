import Foundation
import Dispatch
import XCTest
import UniApiCore
@testable import UniApiPresentation

// The same held adapter already exercises actual Arena model ownership. Code's
// protocol has the identical domain read shape; no service algorithm is copied.
extension ArenaModelFixture: NativeCodeModelService {}

@MainActor private final class CodeReadContext {
    let events: NativeEvents
    let service: ArenaModelFixture
    let model: NativeCodeModel
    private var tasks: [ArenaModelOwnedTask] = []
    init() {
        let events = NativeEvents(), service = ArenaModelFixture(events: events)
        self.events = events; self.service = service
        model = NativeCodeModel(service: service)
    }
    func prepare() async {
        await service.set("routes", ["routes": []])
        await service.set("projects", [["id": "p", "path": "/fixture-project"]])
        await service.set("threads", [["id": "a", "project_id": "p"], ["id": "b", "project_id": "p"]])
        await service.set("thread", reply("a"))
    }
    func reply(_ id: String, seq: Int = 1, more: Bool = false) -> JSONValue {
        ["thread": ["id": .string(id), "title": .string("Thread " + id), "model": .string("model-" + id)],
         "events": [["seq": .number(Double(seq)), "type": "assistant", "thread_id": .string(id)]], "pending": [], "more": .bool(more)]
    }
    @discardableResult func start(_ name: String, _ action: @escaping @MainActor () async -> Void) -> ArenaModelOwnedTask {
        let task = ArenaModelOwnedTask(name, action: action); tasks.append(task); return task
    }
    func wait(_ action: String, until predicate: @MainActor () async -> Bool) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw NativeFailure("Timed out: " + action)
    }
    func close() async {
        model.stop(); tasks.forEach { $0.cancel() }; await service.shutdown()
        for task in tasks { try? await wait(task.label) { task.finished } }
    }
}

@MainActor final class CodeThreadReadinessTests: XCTestCase {
    private func assertLoad(_ c: CodeReadContext, thread: String, expected: Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let result = await c.model.load(project: "p", thread: thread)
        XCTAssertEqual(result, expected, file: file, line: line)
    }
    func testHeldThreadSwitchClearsOldIdentityAndWaitsForEveryHistoryPage() async throws {
        let c = CodeReadContext(); await c.prepare()
        do {
            await assertLoad(c, thread: "a", expected: true)
            await c.service.enqueue("thread", c.reply("b", more: true), hold: "first")
            await c.service.enqueue("thread", c.reply("b", seq: 2), hold: "tail")
            let task = c.start("switch b") { _ = await c.model.load(project: "p", thread: "b") }
            try await c.wait("first page") { await c.service.isHeld("first") }
            XCTAssertTrue(c.model.detailLoading); XCTAssertTrue(c.model.detail.isNull)
            XCTAssertTrue(c.model.events.isEmpty); XCTAssertTrue(c.model.pending.isEmpty)
            try await c.service.release("first")
            try await c.wait("history tail") { await c.service.isHeld("tail") }
            XCTAssertTrue(c.model.detailLoading); XCTAssertTrue(c.model.detail.isNull)
            try await c.service.release("tail"); try await c.wait("switch completion") { task.finished }
            XCTAssertFalse(c.model.detailLoading); XCTAssertEqual(c.model.detail["thread"]["id"], "b")
            XCTAssertEqual(c.model.events.map { $0["seq"].int }, [1, 2])
        } catch { await c.close(); throw error }
        await c.close()
    }
    func testReleasedOldThreadCannotOverwriteNewerReadySelection() async throws {
        let c = CodeReadContext(); await c.prepare()
        do {
            await c.service.enqueue("thread", c.reply("a"), hold: "old")
            let old = c.start("held a") { _ = await c.model.load(project: "p", thread: "a") }
            try await c.wait("held a") { await c.service.isHeld("old") }
            await c.service.set("thread", c.reply("b"))
            await assertLoad(c, thread: "b", expected: true)
            try await c.service.release("old"); try await c.wait("old completion") { old.finished }
            XCTAssertEqual(c.model.detail["thread"]["id"], "b"); XCTAssertFalse(c.model.detailLoading)
            XCTAssertEqual(c.model.events.first?["thread_id"], "b")
        } catch { await c.close(); throw error }
        await c.close()
    }
    func testFailedNewThreadLeavesNoOldDetailsAndRetryRestoresMatchingContent() async throws {
        let c = CodeReadContext(); await c.prepare()
        await assertLoad(c, thread: "a", expected: true)
        await c.service.enqueue("thread", .null, failure: "Held thread read failed")
        await assertLoad(c, thread: "b", expected: false)
        XCTAssertTrue(c.model.detail.isNull); XCTAssertFalse(c.model.detailLoading)
        XCTAssertEqual(c.model.error, "Held thread read failed")
        await c.service.set("thread", c.reply("b"))
        await assertLoad(c, thread: "b", expected: true)
        XCTAssertEqual(c.model.detail["thread"]["id"], "b"); XCTAssertTrue(c.model.error.isEmpty)
        await c.close()
    }
    func testSameThreadRefreshRetainsReadableContentDuringHoldAndFailure() async throws {
        let c = CodeReadContext(); await c.prepare()
        do {
            await assertLoad(c, thread: "a", expected: true)
            let before = c.model.detail
            await c.service.enqueue("thread", .null, hold: "refresh", failure: "Refresh failed")
            let task = c.start("refresh") { _ = await c.model.load(project: "p", thread: "a") }
            try await c.wait("refresh") { await c.service.isHeld("refresh") }
            XCTAssertFalse(c.model.detailLoading); XCTAssertEqual(c.model.detail, before)
            try await c.service.release("refresh"); try await c.wait("refresh completion") { task.finished }
            XCTAssertEqual(c.model.detail, before); XCTAssertEqual(c.model.error, "Refresh failed")
            XCTAssertFalse(c.model.detailLoading)
        } catch { await c.close(); throw error }
        await c.close()
    }
    func testDepartureRejectsHeldCompletionAndDoesNotRequestAnotherPage() async throws {
        let c = CodeReadContext(); await c.prepare()
        do {
            await c.service.enqueue("thread", c.reply("a", more: true), hold: "depart")
            let task = c.start("depart") { _ = await c.model.load(project: "p", thread: "a") }
            try await c.wait("depart") { await c.service.isHeld("depart") }
            c.model.stop(); task.cancel(); try await c.service.release("depart")
            try await c.wait("depart completion") { task.finished }
            XCTAssertFalse(c.model.detailLoading); XCTAssertTrue(c.model.detail.isNull)
            let pages = await c.service.count("thread"); XCTAssertEqual(pages, 1)
        } catch { await c.close(); throw error }
        await c.close()
    }
    func testCurrentThreadStreamTailSurvivesHeldHistoryRefreshWithoutDuplicates() async throws {
        let c = CodeReadContext(); await c.prepare()
        do {
            await c.model.listen(events: c.events, project: { "p" }, thread: { "a" })
            await assertLoad(c, thread: "a", expected: true)
            await c.service.enqueue("thread", c.reply("a"), hold: "history")
            let task = c.start("history") { _ = await c.model.load(project: "p", thread: "a") }
            try await c.wait("history") { await c.service.isHeld("history") }
            await c.events.publish("code.event", ["threadId": "a", "event": ["seq": 2, "type": "assistant", "thread_id": "a"]])
            try await c.wait("stream tail") { c.model.events.contains { $0["seq"] == 2 } }
            try await c.service.release("history"); try await c.wait("history completion") { task.finished }
            XCTAssertEqual(c.model.events.map { $0["seq"].int }, [1, 2]); XCTAssertEqual(c.model.detail["thread"]["id"], "a")
        } catch { await c.close(); throw error }
        await c.close()
    }

    func testLiveMetadataCannotSettleAnIncompleteHistoryOrItsSupersedingRefresh() async throws {
        let c = CodeReadContext(); await c.prepare()
        do {
            await c.model.listen(events: c.events, project: { "p" }, thread: { "b" })
            await c.service.enqueue("thread", c.reply("b"), hold: "original")
            let original = c.start("original b") { _ = await c.model.load(project: "p", thread: "b") }
            try await c.wait("original") { await c.service.isHeld("original") }
            await c.events.publish("code.thread", ["id": "b", "project_id": "p", "title": "Live B metadata"])
            try await c.wait("live metadata") { c.model.detail["thread"]["id"] == "b" }
            XCTAssertTrue(c.model.detailLoading); XCTAssertTrue(c.model.events.isEmpty)
            XCTAssertFalse(c.model.hasHistory(for: "b"))
            await c.service.enqueue("thread", c.reply("b"), hold: "replacement")
            let replacement = c.start("replacement b") { _ = await c.model.load(project: "p", thread: "b") }
            try await c.wait("replacement") { await c.service.isHeld("replacement") }
            XCTAssertTrue(c.model.detailLoading); XCTAssertFalse(c.model.hasHistory(for: "b"))
            try await c.service.release("original"); try await c.wait("original completion") { original.finished }
            XCTAssertTrue(c.model.detailLoading); XCTAssertTrue(c.model.events.isEmpty)
            try await c.service.release("replacement"); try await c.wait("replacement completion") { replacement.finished }
            XCTAssertFalse(c.model.detailLoading); XCTAssertTrue(c.model.hasHistory(for: "b"))
            XCTAssertEqual(c.model.events.map { $0["seq"].int }, [1])
        } catch { await c.close(); throw error }
        await c.close()
    }

    func testPermissionAddedAndResolvedDuringHeldHistoryTailRemainReconciled() async throws {
        let c = CodeReadContext(); await c.prepare()
        do {
            await c.model.listen(events: c.events, project: { "p" }, thread: { "a" })
            var original = c.reply("a"); original["pending"] = [["id": "old", "threadId": "a"]]
            await c.service.set("thread", original)
            await assertLoad(c, thread: "a", expected: true)
            var firstPage = original; firstPage["more"] = true
            await c.service.enqueue("thread", firstPage)
            await c.service.enqueue("thread", c.reply("a", seq: 2), hold: "permission-tail")
            let read = c.start("permission history") { _ = await c.model.load(project: "p", thread: "a") }
            try await c.wait("permission history tail") { await c.service.isHeld("permission-tail") }
            await c.events.publish("code.permission", ["id": "new", "threadId": "a", "tool_name": "Write"])
            await c.events.publish("code.permission.resolved", ["id": "old", "threadId": "a"])
            await c.events.publish("code.permission", ["id": "foreign", "threadId": "b"])
            await c.events.publish("code.event", ["threadId": "a", "event": ["seq": 3, "type": "assistant", "thread_id": "a"]])
            // The ordered stream-tail barrier proves the foreign request was
            // consumed, rather than merely still waiting in the event buffer.
            try await c.wait("live permission changes") { c.model.pending.map { $0["id"].string } == ["new"] && c.model.events.contains { $0["seq"] == 3 } }
            try await c.service.release("permission-tail"); try await c.wait("permission history completion") { read.finished }
            XCTAssertEqual(c.model.pending.map { $0["id"].string }, ["new"])
            XCTAssertEqual(c.model.events.map { $0["seq"].int }, [1, 2, 3])
            XCTAssertTrue(c.model.hasHistory(for: "a")); XCTAssertFalse(c.model.detailLoading)
        } catch { await c.close(); throw error }
        await c.close()
    }
}
