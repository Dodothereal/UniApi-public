import XCTest
@testable import UniApiCore

final class MediaJobsAcceptanceTests: XCTestCase {
    private func fixture() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-jobs-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return runtime
    }
    private func awaitStatus(_ id: String, _ status: String, in queue: NativeJobQueue) async throws -> JSONObject {
        for _ in 0..<300 {
            if let row = try await queue.get(id), row["status"]?.string == status { return row }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw NativeFailure("Fixture job did not reach " + status)
    }
    private func held(_ trace: MediaJobsTrace, lane: String = "shared") -> NativeJobQueue.Handler {
        { params, _ in
            await trace.enter(params["name"].string, lane: lane)
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { await trace.leave(lane: lane); throw error }
            await trace.leave(lane: lane); return params
        }
    }
    private func submitted(_ queue: NativeJobQueue, kind: String, name: String) async throws -> String {
        try await queue.submit(kind: kind, app: "fixture", title: name, params: ["name": .string(name)])["id"]!.string
    }
    private func awaitEntries(_ trace: MediaJobsTrace, count: Int) async throws {
        for _ in 0..<300 {
            if await trace.entries.count >= count { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw NativeFailure("Fixture handler was not admitted")
    }
    func testSubscriberBeforeAdmissionSeesQueuedThenRunningWithoutHandlerProgress() async throws {
        let runtime = try fixture(), trace = MediaJobsTrace()
        await runtime.jobs.register(kind: "event", handler: held(trace))
        let stream = await runtime.events.stream(), running = expectation(description: "running event")
        let reader = Task { () -> [String] in
            var statuses: [String] = []
            for await event in stream where event.topic == "job.updated" {
                statuses.append(event.data["status"].string)
                if event.data["status"].string == "running" { running.fulfill(); break }
            }
            return statuses
        }
        let id = try await submitted(runtime.jobs, kind: "event", name: "event")
        await fulfillment(of: [running], timeout: 2)
        reader.cancel()
        let statuses = await reader.value
        XCTAssertEqual(statuses, ["queued", "running"])
        _ = try await runtime.jobs.cancelAndWait(id)
    }
    func testSharedLaneDifferentKindsUsesOneLimitAndFIFOWhileOtherLaneRuns() async throws {
        let runtime = try fixture(), trace = MediaJobsTrace()
        await runtime.jobs.register(kind: "alpha", lane: "shared", concurrency: 3, handler: held(trace))
        await runtime.jobs.register(kind: "beta", lane: "shared", concurrency: 1, handler: held(trace))
        await runtime.jobs.register(kind: "outside", lane: "other", handler: held(trace, lane: "other"))
        let first = try await submitted(runtime.jobs, kind: "alpha", name: "first")
        let second = try await submitted(runtime.jobs, kind: "beta", name: "second")
        let third = try await submitted(runtime.jobs, kind: "alpha", name: "third")
        let outside = try await submitted(runtime.jobs, kind: "outside", name: "outside")
        try await awaitEntries(trace, count: 2)
        let secondQueued = try await runtime.jobs.get(second), thirdQueued = try await runtime.jobs.get(third)
        XCTAssertEqual(secondQueued?["status"], "queued"); XCTAssertEqual(thirdQueued?["status"], "queued")
        _ = try await awaitStatus(outside, "running", in: runtime.jobs)
        _ = try await runtime.jobs.cancelAndWait(first)
        _ = try await awaitStatus(second, "running", in: runtime.jobs)
        _ = try await runtime.jobs.cancelAndWait(second)
        _ = try await awaitStatus(third, "running", in: runtime.jobs)
        try await awaitEntries(trace, count: 4)
        let entries = await trace.entries, peak = await trace.peaks["shared"]
        XCTAssertEqual(entries.filter { $0 != "outside" }, ["first", "second", "third"])
        XCTAssertEqual(peak, 1)
        _ = try await runtime.jobs.cancelAndWait(third); _ = try await runtime.jobs.cancelAndWait(outside)
    }
    func testSharedLaneDifferentKindsActuallyOverlapToLimitTwo() async throws {
        let runtime = try fixture(), trace = MediaJobsTrace()
        await runtime.jobs.register(kind: "alpha", lane: "shared", concurrency: 2, handler: held(trace))
        await runtime.jobs.register(kind: "beta", lane: "shared", concurrency: 2, handler: held(trace))
        let first = try await submitted(runtime.jobs, kind: "alpha", name: "first")
        let second = try await submitted(runtime.jobs, kind: "beta", name: "second")
        let third = try await submitted(runtime.jobs, kind: "beta", name: "third")
        try await awaitEntries(trace, count: 2)
        let queued = try await runtime.jobs.get(third), peak = await trace.peaks["shared"]
        XCTAssertEqual(queued?["status"], "queued"); XCTAssertEqual(peak, 2)
        _ = try await runtime.jobs.cancelAndWait(first)
        _ = try await awaitStatus(third, "running", in: runtime.jobs)
        _ = try await runtime.jobs.cancelAndWait(second); _ = try await runtime.jobs.cancelAndWait(third)
    }
    func testCancellingQueuedKindNeverStartsItAndDoesNotCancelRunningSibling() async throws {
        let runtime = try fixture(), trace = MediaJobsTrace()
        await runtime.jobs.register(kind: "alpha", lane: "shared", handler: held(trace))
        await runtime.jobs.register(kind: "beta", lane: "shared", handler: held(trace))
        let first = try await submitted(runtime.jobs, kind: "alpha", name: "first")
        let queued = try await submitted(runtime.jobs, kind: "beta", name: "cancelled before admission")
        try await awaitEntries(trace, count: 1)
        let cancelled = try await runtime.jobs.cancelAndWait(queued)
        XCTAssertTrue(cancelled)
        let row = try await runtime.jobs.get(queued), sibling = try await runtime.jobs.get(first)
        XCTAssertEqual(row?["status"], "cancelled"); XCTAssertEqual(sibling?["status"], "running")
        _ = try await runtime.jobs.cancelAndWait(first)
        let entries = await trace.entries
        XCTAssertEqual(entries, ["first"])
    }
    func testRestartPoliciesResumeRunningAndQueuedButFailInterruptedNonresumableAndUnknown() async throws {
        let runtime = try fixture()
        let seeds: [(String, String, String)] = [("resume", "resumable", "running"), ("queued", "once", "queued"), ("failed", "once", "running"), ("unknown", "absent", "queued"), ("history", "once", "done")]
        for (index, seed) in seeds.enumerated() {
            try runtime.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at,started_at,log) VALUES (?,?, 'fixture',?,'shared',?, ?,?,1,'[\"retained\"]')", [.string(seed.0), .string(seed.1), .string(seed.0), seed.0 == "queued" ? .string("broken JSON") : .string("{}"), .string(seed.2), .number(Double(index))])
        }
        let reopened = try NativeRuntime(paths: runtime.paths)
        await reopened.jobs.register(kind: "resumable", lane: "shared") { _, _ in ["resumed": true] }
        await reopened.jobs.register(kind: "once", lane: "shared", resumable: false) { params, _ in XCTAssertTrue(params.isNull); return ["fresh": true] }
        try await reopened.jobs.recover()
        let resume = try await awaitStatus("resume", "done", in: reopened.jobs), queued = try await awaitStatus("queued", "done", in: reopened.jobs)
        let failed = try await reopened.jobs.get("failed"), unknown = try await reopened.jobs.get("unknown"), history = try await reopened.jobs.get("history")
        XCTAssertEqual(resume["result"]?["resumed"], true); XCTAssertEqual(queued["result"]?["fresh"], true)
        XCTAssertEqual(failed?["status"], "failed"); XCTAssertEqual(unknown?["status"], "failed")
        XCTAssertEqual(history?["status"], "done"); XCTAssertEqual(history?["log"], ["retained"])
    }
    func testShutdownDrainsMixedKindsThenFreshQueueAppliesRestartPolicy() async throws {
        let runtime = try fixture(), trace = MediaJobsTrace()
        await runtime.jobs.register(kind: "resume", lane: "shared", concurrency: 2, handler: held(trace))
        await runtime.jobs.register(kind: "once", lane: "shared", concurrency: 2, resumable: false, handler: held(trace))
        let resumable = try await submitted(runtime.jobs, kind: "resume", name: "resume")
        let once = try await submitted(runtime.jobs, kind: "once", name: "once")
        let queued = try await submitted(runtime.jobs, kind: "resume", name: "queued")
        try await awaitEntries(trace, count: 2)
        await runtime.jobs.suspendForShutdown()
        let resumedRuntime = try NativeRuntime(paths: runtime.paths)
        await resumedRuntime.jobs.register(kind: "resume", lane: "shared") { _, _ in ["resumed": true] }
        await resumedRuntime.jobs.register(kind: "once", lane: "shared", resumable: false) { _, _ in XCTFail("Non-resumable restarted"); return .null }
        try await resumedRuntime.jobs.recover()
        _ = try await awaitStatus(resumable, "done", in: resumedRuntime.jobs)
        _ = try await awaitStatus(queued, "done", in: resumedRuntime.jobs)
        let failed = try await resumedRuntime.jobs.get(once), active = await trace.active["shared"]
        XCTAssertEqual(failed?["status"], "failed"); XCTAssertEqual(active, 0)
    }
    func testProgressTitleResultAndBoundedLogsPersistAndScopedEventsHaveJobID() async throws {
        let runtime = try fixture(), stream = await runtime.events.stream(), emitted = expectation(description: "scoped event")
        let reader = Task { () -> JSONValue in
            for await event in stream where event.topic == "job.log-fixture.chunk" { emitted.fulfill(); return event.data }
            return .null
        }
        await runtime.jobs.register(kind: "log-fixture") { _, context in
            for index in 0..<405 { try await context.log("line \(index)") }
            try await context.setTitle("Renamed")
            try await context.progress(0.75, text: "Final phase")
            try await context.emit("chunk", ["transcriptId": "fixture"])
            return ["answer": 42]
        }
        let id = try await submitted(runtime.jobs, kind: "log-fixture", name: "original")
        let done = try await awaitStatus(id, "done", in: runtime.jobs)
        await fulfillment(of: [emitted], timeout: 2); reader.cancel()
        let event = await reader.value
        XCTAssertEqual(event["id"], .string(id)); XCTAssertEqual(event["transcriptId"], "fixture")
        XCTAssertEqual(done["title"], "Renamed"); XCTAssertEqual(done["progress"], 1); XCTAssertEqual(done["progress_text"], "Final phase")
        XCTAssertEqual(done["result"]?["answer"], 42); XCTAssertEqual(done["log"]?.array.count, 400)
        XCTAssertEqual(done["log"]?.array.first, "line 5"); XCTAssertEqual(done["log"]?.array.last, "line 404")
    }
    func testPruneUsesSevenDaysAndKeepsActiveRecentAndOtherApps() async throws {
        let runtime = try fixture(), now = Date().timeIntervalSince1970 * 1000
        for (id, status, age) in [("old", "done", 8.0), ("recent", "failed", 6.0), ("active", "running", 9.0), ("queued", "queued", 9.0)] {
            try runtime.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at,finished_at) VALUES(?,'fixture','fixture',?,'lane','{}',?,1,?)", [.string(id), .string(id), .string(status), .number(now - age * 86400000)])
        }
        let removed = try await runtime.jobs.prune(olderThan: NativeJobQueue.defaultPruneAge)
        XCTAssertEqual(removed, 1)
        let all = try await runtime.jobs.list(), active = try await runtime.jobs.list(app: "fixture", statuses: ["running", "queued"]), other = try await runtime.jobs.list(app: "other")
        XCTAssertEqual(all.count, 3); XCTAssertEqual(active.count, 2); XCTAssertTrue(other.isEmpty)
    }
}

private actor MediaJobsTrace {
    var entries: [String] = []
    var active: [String: Int] = [:]
    var peaks: [String: Int] = [:]
    func enter(_ name: String, lane: String) { entries.append(name); active[lane, default: 0] += 1; peaks[lane] = max(peaks[lane] ?? 0, active[lane] ?? 0) }
    func leave(lane: String) { active[lane, default: 0] -= 1 }
}
