import XCTest
import AppKit
import UniApiCore
@testable import UniApiPresentation

@MainActor final class ArenaModelTests: XCTestCase {
    private func fixture() -> ArenaModelTestContext {
        XCTAssertNil(NSApp, "The fixture must not construct an application or NativeRuntime")
        let context = ArenaModelTestContext()
        addTeardownBlock { await context.close() }
        return context
    }
    private func event(_ seq: Int, _ text: String = "stored") -> JSONValue {
        ["seq": .number(Double(seq)), "type": "assistant", "payload": ["text": .string(text)]]
    }
    private func page(_ start: Int, _ count: Int = 5000) -> JSONValue {
        .array((start..<(start + count)).map { event($0) })
    }
    private func ranking(_ name: String) -> JSONValue {
        ["standings": [["model": .string(name)]], "ledger": ["remote": .string(name)]]
    }
    private func journalCount(_ model: NativeArenaModel, _ name: String) throws -> Int {
        let field = try XCTUnwrap(Mirror(reflecting: model).children.first { $0.label == name }, "Missing actual model journal: " + name)
        return Mirror(reflecting: field.value).children.count
    }
    private func barrier(_ f: ArenaModelTestContext, _ id: String) async throws {
        await f.events.publish("arena.slot.live", ["slotId": "barrier", "text": .string(id)])
        try await f.wait("listener reached " + id) { f.model.live["barrier"]?["text"].string == id }
    }

    func testEventStreamIsRegisteredBeforeFirstStateReadAndReconcilesItsSnapshot() async throws {
        let f = fixture(), model = f.model, service = f.service
        await service.enqueue("state", ["presets": [["id": "old"]]], hold: "initial-state",
                              publish: ("arena.presets", [["id": "live"]]))
        f.start("held initial begin") { await model.begin(events: f.events) }
        try await f.held("initial-state")
        try await f.wait("event published inside first handle is observed") { model.state["presets"].array.first?["id"] == "live" }
        XCTAssertFalse(model.loaded)
        try await service.release("initial-state")
        try await f.wait("initial load committed") { model.loaded }
        XCTAssertEqual(model.state["presets"], [["id": "live"]])
        let count = await service.count("state"); XCTAssertEqual(count, 1)
    }

    func testCurrentReadFailureIsVisibleAndSuccessfulRetryClearsIt() async throws {
        let f = fixture(), model = f.model, service = f.service
        await service.enqueue("state", .null, failure: "current state failure")
        f.start("failed initial begin") { await model.begin(events: f.events) }
        try await f.wait("current failure and matches response") {
            let matches = await service.completions("matches")
            return model.failed && matches == 1
        }
        XCTAssertFalse(model.loaded); XCTAssertEqual(model.error, "current state failure")
        await service.set("state", ["defaults": ["count": 3]])
        try await f.run("retry") { await model.load() }
        XCTAssertTrue(model.loaded); XCTAssertFalse(model.failed); XCTAssertTrue(model.error.isEmpty)
        XCTAssertEqual(model.state["defaults"]["count"], 3)
    }

    func testOldCancelledBeginCannotStopReentryOrPublishItsLateErrorOrFollowup() async throws {
        let f = fixture(), model = f.model, service = f.service
        model.output = "retained output"; model.transcripts["cached"] = [event(1)]
        await service.enqueue("state", ["marker": "old"], hold: "old-begin")
        let old = f.start("old begin") { await model.begin(events: f.events) }
        try await f.held("old-begin"); model.stop()
        await service.set("state", ["marker": "new"])
        try await f.enter()
        // Cancellation cleanup is deliberately delivered after the new owner exists.
        old.cancel(); try await service.release("old-begin", failure: "stale state failure")
        try await f.join(old); try await barrier(f, "new-listener")
        XCTAssertTrue(model.readActive); XCTAssertEqual(model.state["marker"], "new")
        XCTAssertTrue(model.error.isEmpty); XCTAssertEqual(model.output, "retained output")
        XCTAssertEqual(model.transcripts["cached"], [event(1)])
        let matches = await service.count("matches"); XCTAssertEqual(matches, 1)
    }

    func testSupersededLoadRejectsHeldMatchesAndStaleError() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("matches", [["id": "old"]], hold: "old-matches")
        let old = f.start("old load") { await model.load() }; try await f.held("old-matches")
        await service.set("state", ["marker": "new"])
        await service.enqueue("matches", [["id": "new"]], hold: "new-matches")
        let new = f.start("new load") { await model.load() }; try await f.held("new-matches")
        try await service.release("new-matches"); try await f.join(new)
        try await service.release("old-matches", failure: "superseded matches failure"); try await f.join(old)
        XCTAssertEqual(model.matches, [["id": "new"]]); XCTAssertEqual(model.state["marker"], "new")
        XCTAssertTrue(model.error.isEmpty)
    }

    func testMatchSlotDeletionAndLiveEventsReconcileHeldInitialMatches() async throws {
        let f = fixture(), model = f.model, service = f.service
        let stale: JSONValue = [["id": "a", "slots": [["id": "sa", "status": "running"]], "live": ["sa": ["text": "old"]]], ["id": "b", "slots": []]]
        await service.enqueue("matches", stale, hold: "initial-matches")
        f.start("begin with held matches") { await model.begin(events: f.events) }
        try await f.held("initial-matches")
        await f.events.publish("arena.slot", ["id": "sa", "status": "done"])
        await f.events.publish("arena.slot.live", ["slotId": "sa", "text": "live"])
        await f.events.publish("arena.match", ["id": "c", "slots": []])
        // This case reconciles held matches, rather than superseding state reads.
        // Finish each service return before the next event can cancel its task.
        try await f.wait("match state refresh returned") { await service.completions("state") == 2 }
        await f.events.publish("arena.match.deleted", ["id": "b"])
        try await f.wait("deletion state refresh returned") { await service.completions("state") == 3 }
        try await barrier(f, "reconciled")
        try await service.release("initial-matches")
        try await f.wait("matches loaded") { model.loaded }
        XCTAssertEqual(Set(model.matches.map { $0["id"].string }), ["a", "c"])
        XCTAssertEqual(model.matches.first { $0["id"] == "a" }?["slots"].array.first?["status"], "done")
        XCTAssertEqual(model.live["sa"]?["text"], "live")
    }

    func testRankingScopeSupersedesHeldReplyBeforeNextAwaitAndCommitsBatchAtomically() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("ranking:all", ranking("old"), hold: "old-ranking")
        let old = f.start("all ranking") { await model.ranking("all") }; try await f.held("old-ranking")
        await service.enqueue("ranking:chosen", ranking("chosen"), hold: "new-ranking")
        await service.enqueue("ledger.records", [["id": "chosen-record"]], hold: "chosen-records")
        let new = f.start("chosen ranking") { await model.ranking("chosen") }; try await f.held("new-ranking")
        try await service.release("old-ranking"); try await f.join(old)
        let before = await service.count("ledger.records"); XCTAssertEqual(before, 0)
        try await service.release("new-ranking"); try await f.held("chosen-records")
        XCTAssertTrue(model.standings.isEmpty); XCTAssertTrue(model.ledger.isNull); XCTAssertTrue(model.recent.isEmpty)
        try await service.release("chosen-records"); try await f.join(new)
        XCTAssertEqual(model.standings, ranking("chosen")["standings"].array)
        XCTAssertEqual(model.ledger, ranking("chosen")["ledger"]); XCTAssertEqual(model.recent, [["id": "chosen-record"]])
    }

    func testSupersededRankingRecordsErrorCannotOverwriteNewerBatch() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.set("ranking:all", ranking("old"))
        await service.enqueue("ledger.records", [["id": "old-record"]], hold: "old-records")
        let old = f.start("old records") { await model.ranking("all") }; try await f.held("old-records")
        await service.set("ranking:random", ranking("random")); await service.set("ledger.records", [["id": "random-record"]])
        try await f.run("random ranking") { await model.ranking("random") }
        try await service.release("old-records", failure: "stale ranking records failure"); try await f.join(old)
        XCTAssertEqual(model.ledger, ranking("random")["ledger"])
        XCTAssertEqual(model.recent, [["id": "random-record"]]); XCTAssertTrue(model.error.isEmpty)
    }

    func testCancelledTranscriptFirstPageCannotDispatchNextBatchOrPublishPartialHistory() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("events:s:0", page(1), hold: "first-page")
        let read = f.start("cancel first transcript page") { await model.transcript("s") }
        try await f.held("first-page"); read.cancel()
        try await service.release("first-page"); try await f.join(read)
        XCTAssertNil(model.transcripts["s"])
        let next = await service.count("events", id: "s", after: 5000); XCTAssertEqual(next, 0)
        XCTAssertTrue(model.error.isEmpty)
    }

    func testSuspendedTranscriptSecondPageCannotPublishPartialHistoryOrRequestThirdPage() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("events:s:0", page(1))
        await service.enqueue("events:s:5000", page(5001), hold: "second-page")
        let read = f.start("held second transcript page") { await model.transcript("s") }
        try await f.held("second-page"); XCTAssertNil(model.transcripts["s"])
        model.stop(); try await service.release("second-page"); try await f.join(read)
        XCTAssertNil(model.transcripts["s"])
        let third = await service.count("events", id: "s", after: 10000); XCTAssertEqual(third, 0)
        XCTAssertFalse(model.readActive)
    }

    func testTranscriptPaginationCommitsOnlyAfterFinalPageAndUsesStoredCursor() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("events:s:0", page(1))
        await service.enqueue("events:s:5000", .array([event(5001)]), hold: "last-page")
        let read = f.start("complete paged history") { await model.transcript("s") }
        try await f.held("last-page"); XCTAssertNil(model.transcripts["s"])
        try await service.release("last-page"); try await f.join(read)
        XCTAssertEqual(model.transcripts["s"]?.count, 5001)
        XCTAssertEqual(model.transcripts["s"]?.first?["seq"], 1)
        XCTAssertEqual(model.transcripts["s"]?.last?["seq"], 5001)
        let calls = await service.count("events", id: "s"); XCTAssertEqual(calls, 2)
    }

    func testTranscriptPaginationFailureRetainsPreviousCompleteHistory() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter(); model.transcripts["s"] = [event(99, "retained")]
        let owner = try XCTUnwrap(model.beginContent("s", tab: "Transcript"))
        await service.enqueue("events:s:0", page(1))
        await service.enqueue("events:s:5000", .null, failure: "page failed")
        try await f.run("failed transcript batch") { await model.transcript("s", content: owner) }
        XCTAssertEqual(model.transcripts["s"], [event(99, "retained")])
        XCTAssertEqual(model.contentError("s", tab: "Transcript"), "page failed"); XCTAssertTrue(model.error.isEmpty)
        await service.set("events:s:0", .array([event(1, "retried")]))
        try await f.run("successful transcript retry") { await model.transcript("s", content: owner) }
        XCTAssertEqual(model.transcripts["s"]?.map { $0["seq"].int }, [1, 99])
        XCTAssertTrue(model.contentError("s", tab: "Transcript").isEmpty)
        XCTAssertTrue(model.error.isEmpty)
    }

    func testTranscriptMergesSortedLiveTailDeduplicatesAndPreservesRevealedHistory() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("events:s:0", .array([event(1, "history identity")]), hold: "history")
        let read = f.start("history plus stream") { await model.transcript("s") }; try await f.held("history")
        for value in [event(3), event(2), event(3), event(1, "redacted")] {
            await f.events.publish("arena.slot.event", ["slotId": "s", "event": value])
        }
        try await barrier(f, "tail-received"); XCTAssertNil(model.transcripts["s"])
        try await service.release("history"); try await f.join(read)
        XCTAssertEqual(model.transcripts["s"]?.map { $0["seq"].int }, [1, 2, 3])
        XCTAssertEqual(model.transcripts["s"]?.first?["payload"]["text"], "history identity")
        await f.events.publish("arena.slot.event", ["slotId": "s", "event": event(1, "redacted duplicate")])
        try await barrier(f, "duplicate-received")
        XCTAssertEqual(model.transcripts["s"]?.first?["payload"]["text"], "history identity")

        await service.enqueue("events:s:0", .array([event(1, "revealed identity")]), hold: "reveal")
        await f.events.publish("arena.match", ["id": "m", "revealed": true, "slots": [["id": "s"]]])
        try await f.held("reveal")
        await f.events.publish("arena.slot.event", ["slotId": "s", "event": event(1, "redacted overlap")])
        try await barrier(f, "reveal-overlap")
        try await service.release("reveal")
        try await f.wait("revealed transcript") { model.transcripts["s"]?.first?["payload"]["text"] == "revealed identity" }
        XCTAssertEqual(model.transcripts["s"]?.map { $0["seq"].int }, [1, 2, 3])
    }

    func testTranscriptRequestsAreIndependentPerSlotButNewestRequestWinsWithinSlot() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("events:a:0", .array([event(1, "old")]), hold: "old-a")
        await service.enqueue("events:b:0", .array([event(1, "b")]), hold: "b")
        let old = f.start("old a") { await model.transcript("a") }; try await f.held("old-a")
        let b = f.start("b") { await model.transcript("b") }; try await f.held("b")
        await service.enqueue("events:a:0", .array([event(1, "new")]), hold: "new-a")
        let new = f.start("new a") { await model.transcript("a") }; try await f.held("new-a")
        try await service.release("b"); try await f.join(b)
        XCTAssertEqual(model.transcripts["b"], [event(1, "b")]); XCTAssertNil(model.transcripts["a"])
        try await service.release("new-a"); try await f.join(new)
        try await service.release("old-a", failure: "old slot failure"); try await f.join(old)
        XCTAssertEqual(model.transcripts["a"], [event(1, "new")]); XCTAssertTrue(model.error.isEmpty)
    }

    func testHeldFilesReplyCannotEscapeItsReadLifetimeAfterReentry() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("files:s", ["files": [["path": "old.txt"]]], hold: "files")
        var oldResult: JSONValue?
        let old = f.start("old files") { oldResult = await model.call("files", ["id": "s"]) }
        try await f.held("files"); model.stop(); try await f.enter()
        await service.set("files:s", ["files": [["path": "new.txt"]]])
        let current = await model.call("files", ["id": "s"])
        try await service.release("files", failure: "old files failure"); try await f.join(old)
        XCTAssertNil(oldResult); XCTAssertEqual(current?["files"], [["path": "new.txt"]]); XCTAssertTrue(model.error.isEmpty)
    }

    func testOldReloadCannotChainRankingIntoNewLifetime() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("state", ["marker": "old reload"], hold: "reload-state")
        let old = f.start("old reload") { await model.reload(ranking: "all") }
        try await f.held("reload-state"); model.stop()
        await service.set("state", ["marker": "reentry"]); try await f.enter()
        try await service.release("reload-state"); try await f.join(old)
        XCTAssertEqual(model.state["marker"], "reentry")
        let ranks = await service.count("ranking"), records = await service.count("ledger.records")
        XCTAssertEqual(ranks, 0); XCTAssertEqual(records, 0)
    }

    func testCreateSaveDeleteAndSyncCompleteAfterDepartureAndDriverCancellation() async throws {
        let f = fixture(), model = f.model, service = f.service
        await service.set("state", ["presets": [["id": "p"]]])
        await service.set("matches", [["id": "m", "slots": [["id": "s"]]]])
        try await f.enter()
        model.transcripts["s"] = [event(1)]
        let commands: [(String, JSONObject, JSONValue)] = [
            ("match.create", [:], ["id": "created", "slots": []]),
            ("preset.save", ["title": "Saved draft"], ["id": "saved", "title": "Saved draft"]),
            ("preset.delete", ["id": "p"], ["ok": true]),
            ("delete", ["id": "m"], ["ok": true])
        ]
        var results: [String: JSONValue] = [:], drivers: [ArenaModelOwnedTask] = []
        for (op, input, result) in commands {
            await service.enqueue(op, result, hold: op)
            let task = f.start(op) { if let value = await model.call(op, input) { results[op] = value }; await model.load() }
            drivers.append(task); try await f.held(op)
        }
        await service.enqueue("ledger.sync", ["output": "sync finished"], hold: "sync")
        let sync = f.start("sync") { await model.share("ledger.sync", mode: "all") }; try await f.held("sync")
        XCTAssertTrue(model.busy)
        let statesBefore = await service.count("state"), matchesBefore = await service.count("matches")
        model.stop(); drivers.forEach { $0.cancel() }; sync.cancel()
        for ((op, _, result), driver) in zip(commands, drivers) {
            try await service.release(op); try await f.join(driver); XCTAssertEqual(results[op], result)
        }
        try await service.release("sync"); try await f.join(sync)
        XCTAssertEqual(model.matches.map { $0["id"].string }, ["created"])
        XCTAssertEqual(model.state["presets"], [["id": "saved", "title": "Saved draft"]])
        XCTAssertNil(model.transcripts["s"]); XCTAssertEqual(model.output, "sync finished")
        XCTAssertFalse(model.busy); XCTAssertFalse(model.readActive); XCTAssertTrue(model.error.isEmpty)
        let statesAfter = await service.count("state"), matchesAfter = await service.count("matches"), ranks = await service.count("ranking")
        XCTAssertEqual(statesAfter, statesBefore); XCTAssertEqual(matchesAfter, matchesBefore); XCTAssertEqual(ranks, 0)
    }

    func testSettingsCommandInvalidatesHeldStateReadWithoutDiscardingSavedResult() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("state", ["defaults": ["count": 2]], hold: "old-settings")
        let old = f.start("held settings read") { await model.load() }; try await f.held("old-settings")
        let saved: JSONValue = ["defaults": ["count": 4], "excluded": ["local-choice"]]
        await service.set("settings", saved)
        let result = await model.call("settings", ["defaults": ["count": 4]])
        try await service.release("old-settings", failure: "stale settings error"); try await f.join(old)
        XCTAssertEqual(result, saved); XCTAssertEqual(model.state, saved); XCTAssertTrue(model.error.isEmpty)
    }

    func testCommandFailureSurvivesDepartureWhileStaleReadFailureIsDiscarded() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("ranking:all", .null, hold: "ranking-error")
        let read = f.start("held ranking failure") { await model.ranking("all") }; try await f.held("ranking-error")
        await service.enqueue("ledger.sync", .null, hold: "sync-error")
        let command = f.start("held sync failure") { await model.share("ledger.sync", mode: "all") }; try await f.held("sync-error")
        model.stop(); command.cancel()
        try await service.release("ranking-error", failure: "stale read failure"); try await f.join(read)
        XCTAssertTrue(model.error.isEmpty)
        try await service.release("sync-error", failure: "owned command failure"); try await f.join(command)
        XCTAssertEqual(model.error, "owned command failure"); XCTAssertFalse(model.busy)
    }

    func testSyncResultSurvivesReentryWithoutOldOwnerRefreshingNewRanking() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("ledger.sync", ["output": "old owner completed"], hold: "reentry-sync")
        let sync = f.start("sync across reentry") { await model.share("ledger.sync", mode: "all") }
        try await f.held("reentry-sync"); model.stop(); try await f.enter()
        await service.set("ranking:chosen", ranking("chosen"))
        try await f.run("new owner ranking") { await model.ranking("chosen") }
        let before = await service.count("ranking")
        try await service.release("reentry-sync"); try await f.join(sync)
        let after = await service.count("ranking")
        XCTAssertEqual(after, before); XCTAssertEqual(model.ledger, ranking("chosen")["ledger"])
        XCTAssertEqual(model.output, "old owner completed"); XCTAssertTrue(model.readActive)
    }

    func testTransientJournalsClearAfterTranscriptCompletionCancellationAndStop() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("events:s:0", .array([event(1)]), hold: "journal-read")
        let read = f.start("journal transcript") { await model.transcript("s") }; try await f.held("journal-read")
        await f.events.publish("arena.slot.event", ["slotId": "s", "event": event(2)])
        try await barrier(f, "journal-pending")
        XCTAssertEqual(try journalCount(model, "streamEvents"), 1)
        try await service.release("journal-read"); try await f.join(read)
        XCTAssertEqual(try journalCount(model, "streamEvents"), 0)
        await f.events.publish("arena.slot.event", ["slotId": "s", "event": event(3)])
        try await barrier(f, "journal-idle")
        XCTAssertEqual(try journalCount(model, "streamEvents"), 0)
        XCTAssertEqual(model.transcripts["s"]?.map { $0["seq"].int }, [1, 2, 3])

        await service.enqueue("events:s:0", .array([event(1)]), hold: "journal-cancel")
        let cancelled = f.start("cancel journal transcript") { await model.transcript("s") }; try await f.held("journal-cancel")
        await f.events.publish("arena.slot.event", ["slotId": "s", "event": event(4)])
        try await barrier(f, "journal-cancel-pending"); cancelled.cancel()
        try await service.release("journal-cancel"); try await f.join(cancelled)
        XCTAssertEqual(try journalCount(model, "streamEvents"), 0)
        XCTAssertEqual(model.transcripts["s"]?.map { $0["seq"].int }, [1, 2, 3, 4])

        await f.events.publish("arena.match", ["id": "m", "slots": [["id": "s"]]])
        await f.events.publish("arena.slot", ["id": "s", "status": "done"])
        try await barrier(f, "journals-before-stop")
        await f.events.publish("arena.presets", [["id": "retained"]])
        try await f.wait("preset journal") { (try? self.journalCount(model, "presetChange")) == 1 }
        let state = model.state, matches = model.matches, live = model.live, transcript = model.transcripts
        model.stop()
        for name in ["streamEvents", "matchChanges", "slotChanges", "liveChanges", "presetChange", "requestedTranscripts", "transcriptRequests"] {
            XCTAssertEqual(try journalCount(model, name), 0, name + " must not retain a stopped read lifetime")
        }
        XCTAssertEqual(model.state, state); XCTAssertEqual(model.matches, matches)
        XCTAssertEqual(model.live, live); XCTAssertEqual(model.transcripts, transcript)
    }

    func testContentErrorsStayWithActiveSlotAndTabAcrossOtherSuccessReloadAndReentry() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        let a = try XCTUnwrap(model.beginContent("a", tab: "Files"))
        await service.enqueue("files:a", .null, hold: "active-a")
        let read = f.start("active a files failure") { _ = await model.call("files", ["id": "a"], content: a) }
        try await f.held("active-a"); try await service.release("active-a", failure: "a files failed"); try await f.join(read)
        XCTAssertEqual(model.contentError("a", tab: "Files"), "a files failed")
        XCTAssertTrue(model.contentError("a", tab: "Transcript").isEmpty); XCTAssertTrue(model.error.isEmpty)

        let b = try XCTUnwrap(model.beginContent("b", tab: "Files"))
        await service.set("files:b", ["files": [["path": "b.txt"]]])
        let success = await model.call("files", ["id": "b"], content: b)
        XCTAssertEqual(success?["files"], [["path": "b.txt"]])
        XCTAssertEqual(model.contentError("a", tab: "Files"), "a files failed", "Another active slot's success must not mask a genuine A failure")
        try await f.run("reload with current content error") { await model.reload(ranking: nil) }
        XCTAssertEqual(model.contentError("a", tab: "Files"), "a files failed"); XCTAssertTrue(model.error.isEmpty)

        model.endContent(a)
        XCTAssertTrue(model.contentError("a", tab: "Files").isEmpty)
        XCTAssertTrue(model.contentError("b", tab: "Files").isEmpty)
        await service.enqueue("files:b", .null, failure: "b files failed")
        _ = await model.call("files", ["id": "b"], content: b)
        XCTAssertEqual(model.contentError("b", tab: "Files"), "b files failed"); XCTAssertTrue(model.error.isEmpty)
        model.stop(); try await f.enter()
        XCTAssertTrue(model.contentError("b", tab: "Files").isEmpty); XCTAssertTrue(model.error.isEmpty)
        _ = try XCTUnwrap(model.beginContent("b", tab: "Files"))
        XCTAssertTrue(model.contentError("b", tab: "Files").isEmpty)
    }

    func testRetiredContentOwnerRejectsHeldFailureAndCannotRetireNewSlotTabOwner() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        let old = try XCTUnwrap(model.beginContent("a", tab: "Files"))
        await service.enqueue("files:a", .null, hold: "left-a")
        let read = f.start("left a files failure") { _ = await model.call("files", ["id": "a"], content: old) }
        try await f.held("left-a"); model.endContent(old)
        let b = try XCTUnwrap(model.beginContent("b", tab: "Files"))
        _ = await model.call("files", ["id": "b"], content: b)
        let current = try XCTUnwrap(model.beginContent("a", tab: "Transcript"))
        try await service.release("left-a", failure: "late abandoned files failure"); try await f.join(read)
        model.endContent(old)
        await service.enqueue("events:a:0", .null, failure: "current transcript failure")
        try await f.run("current transcript failure") { await model.transcript("a", content: current) }
        XCTAssertTrue(model.contentError("a", tab: "Files").isEmpty)
        XCTAssertEqual(model.contentError("a", tab: "Transcript"), "current transcript failure")
        XCTAssertTrue(model.contentError("b", tab: "Files").isEmpty); XCTAssertTrue(model.error.isEmpty)
        let cancelled = f.start("cancelled content admission") { XCTAssertNil(model.beginContent("a", tab: "Files")) }
        cancelled.cancel(); try await f.join(cancelled)
        XCTAssertEqual(model.contentError("a", tab: "Transcript"), "current transcript failure")
        model.endContent(current)
        XCTAssertTrue(model.contentError("a", tab: "Transcript").isEmpty)

        let closing = try XCTUnwrap(model.beginContent("a", tab: "Files"))
        await service.enqueue("files:a", .null, hold: "closing-a")
        let closed = f.start("closed a files failure") { _ = await model.call("files", ["id": "a"], content: closing) }
        try await f.held("closing-a"); model.stop(); try await f.enter()
        let reopened = try XCTUnwrap(model.beginContent("a", tab: "Files"))
        _ = await model.call("files", ["id": "a"], content: reopened)
        try await service.release("closing-a", failure: "late closed files failure"); try await f.join(closed)
        XCTAssertTrue(model.contentError("a", tab: "Files").isEmpty); XCTAssertTrue(model.error.isEmpty)
    }

    func testContentSuccessPreservesStateMatchesRankingAndCommandErrors() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        let content = try XCTUnwrap(model.beginContent("b", tab: "Files"))
        await service.enqueue("state", .null, failure: "state failed")
        await service.enqueue("matches", .null, failure: "matches failed")
        try await f.run("failed page reads") { await model.load() }
        _ = await model.call("files", ["id": "b"], content: content)
        XCTAssertEqual(model.error, "matches failed"); XCTAssertTrue(model.failed)
        let saved: JSONValue = ["defaults": ["count": 4]]
        await service.set("settings", saved)
        _ = await model.call("settings", ["defaults": ["count": 4]])
        XCTAssertEqual(model.state, saved); XCTAssertEqual(model.pageError(includeRanking: false), "matches failed")
        await service.enqueue("state", .null, failure: "state failed again")
        try await f.run("matches recovers but state still fails") { await model.load() }
        _ = await model.call("files", ["id": "b"], content: content)
        XCTAssertEqual(model.pageError(includeRanking: false), "state failed again"); XCTAssertTrue(model.failed)
        _ = await model.call("settings", ["defaults": ["count": 4]])
        XCTAssertEqual(model.state, saved); XCTAssertTrue(model.pageError(includeRanking: false).isEmpty); XCTAssertFalse(model.failed)
        await service.enqueue("matches", .null, failure: "matches failed again")
        try await f.run("state recovers but matches still fails") { await model.load() }
        XCTAssertEqual(model.error, "matches failed again"); XCTAssertTrue(model.failed)
        try await f.run("page reads recover") { await model.load() }
        XCTAssertTrue(model.error.isEmpty); XCTAssertFalse(model.failed)

        await service.enqueue("ranking:all", .null, failure: "ranking failed")
        try await f.run("failed ranking") { await model.ranking("all") }
        _ = await model.call("files", ["id": "b"], content: content)
        XCTAssertEqual(model.error, "ranking failed")
        XCTAssertTrue(model.pageError(includeRanking: false).isEmpty)
        XCTAssertEqual(model.pageError(includeRanking: true), "ranking failed")
        await service.enqueue("preset.save", .null, failure: "command failed")
        _ = await model.call("preset.save", ["title": "draft"])
        _ = await model.call("files", ["id": "b"], content: content)
        XCTAssertEqual(model.pageError(includeRanking: false), "command failed")
        XCTAssertEqual(model.pageError(includeRanking: true), "command failed")
        model.stop(); try await f.enter()
        XCTAssertEqual(model.error, "command failed", "Content retirement must preserve accepted command errors")
        _ = await model.call("preset.save", ["title": "retry"])
        XCTAssertEqual(model.error, "ranking failed", "Clearing the command's own error must not clear a current ranking failure")
        XCTAssertTrue(model.pageError(includeRanking: false).isEmpty, "Judge must not show the Ranking scope's retained error")
        XCTAssertEqual(model.pageError(includeRanking: true), "ranking failed")
        try await f.run("current ranking recovers") { await model.ranking("all") }
        XCTAssertTrue(model.pageError(includeRanking: true).isEmpty)
    }

    func testMiddleDeleteUsesItsCapturedSuccessorAfterRemovalAndReload() async throws {
        let f = fixture(), model = f.model, service = f.service
        let rows: [JSONValue] = [["id": "a"], ["id": "b"], ["id": "c"]]
        await service.set("matches", .array(rows)); try await f.enter()
        var selected = "b", completions = 0, accepted = false
        let successor = ArenaPresentationPolicy.nextMatchID(in: model.matches, after: selected, history: false)
        await service.enqueue("delete", [:], hold: "delete-middle")
        await service.enqueue("matches", .array([rows[0], rows[2]]), hold: "post-delete-list")
        let action = f.start("delete middle match") {
            accepted = await model.performMatchAction("delete", id: "b") {
                selected = successor ?? ""; completions += 1
            }
        }
        try await f.held("delete-middle")
        XCTAssertEqual(selected, "b"); XCTAssertEqual(model.matches, rows)
        try await service.release("delete-middle"); try await f.held("post-delete-list")
        XCTAssertEqual(model.matches.map { $0["id"].string }, ["a", "c"])
        XCTAssertEqual(selected, "b"); XCTAssertEqual(completions, 0)
        // Recomputing after deletion would lose the old position and select A.
        XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: model.matches, after: "b", history: false), "a")
        try await service.release("post-delete-list"); try await f.join(action)
        XCTAssertTrue(accepted); XCTAssertEqual(selected, "c"); XCTAssertEqual(completions, 1)
        let calls = await service.ledger()
        XCTAssertEqual(calls.map(\.operation), ["state", "matches", "delete", "state", "matches"])
        XCTAssertEqual(calls[2].input["id"], "b")
    }

    func testDeleteFailureKeepsSelectionAndDoesNotRefreshOrAdvance() async throws {
        let f = fixture(), model = f.model, service = f.service
        let rows: JSONValue = [["id": "a"], ["id": "b"], ["id": "c"]]
        await service.set("matches", rows); try await f.enter()
        var selected = "b", completions = 0, accepted = true
        await service.enqueue("delete", .null, failure: "delete refused")
        try await f.run("failed delete") {
            accepted = await model.performMatchAction("delete", id: "b") {
                selected = "c"; completions += 1
            }
        }
        XCTAssertFalse(accepted); XCTAssertEqual(selected, "b"); XCTAssertEqual(completions, 0)
        XCTAssertEqual(model.matches, rows.array); XCTAssertEqual(model.error, "delete refused")
        let calls = await service.ledger()
        XCTAssertEqual(calls.map(\.operation), ["state", "matches", "delete"])
    }

    func testSkipKeepsRevealedMatchSelectedUntilExplicitNext() async throws {
        let f = fixture(), model = f.model, service = f.service
        let rows: [JSONValue] = [["id": "a"], ["id": "b"], ["id": "c"]]
        await service.set("matches", .array(rows)); try await f.enter()
        var selected = "b", accepted = false
        let revealed: JSONValue = ["id": "b", "verdict": "skipped", "revealed": true, "voted_at": 123]
        await service.enqueue("skip", revealed)
        await service.set("matches", .array([rows[0], revealed, rows[2]]))
        try await f.run("skip without advancing") {
            accepted = await model.performMatchAction("skip", id: "b")
        }
        XCTAssertTrue(accepted); XCTAssertEqual(selected, "b")
        XCTAssertEqual(model.matches.first { $0["id"] == "b" }, revealed)
        selected = ArenaPresentationPolicy.nextMatchID(in: model.matches, after: selected, history: false) ?? ""
        XCTAssertEqual(selected, "c")
        let calls = await service.ledger()
        XCTAssertEqual(calls.map(\.operation), ["state", "matches", "skip", "state", "matches"])
    }

    func testReadGenerationChangesAcrossStopAndBeginButNotOrdinaryReads() async throws {
        let f = fixture(), model = f.model
        try await f.enter()
        let first = model.readGeneration
        try await f.run("ordinary page reload") { await model.reload(ranking: nil) }
        try await f.run("ordinary ranking") { await model.ranking("all") }
        try await f.run("ordinary transcript") { await model.transcript("s") }
        let owner = try XCTUnwrap(model.beginContent("s", tab: "Files"))
        _ = await model.call("files", ["id": "s"], content: owner); model.endContent(owner)
        XCTAssertEqual(model.readGeneration, first)
        model.stop()
        let stopped = model.readGeneration
        XCTAssertGreaterThan(stopped, first)
        try await f.enter()
        let resumed = model.readGeneration
        XCTAssertGreaterThan(resumed, stopped); XCTAssertTrue(model.readActive)
        // An active-to-active entry still crosses begin's internal stop. The
        // published generation survives a coalesced false/true readActive edge.
        try await f.enter()
        XCTAssertTrue(model.readActive); XCTAssertGreaterThan(model.readGeneration, resumed)
    }
}
