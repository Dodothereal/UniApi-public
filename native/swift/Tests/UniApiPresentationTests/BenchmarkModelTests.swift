import XCTest
import AppKit
import UniApiCore
@testable import UniApiPresentation

final class BenchmarkModelTests: XCTestCase {
    @MainActor private func fixture() -> BenchmarkModelTestContext {
        XCTAssertNil(NSApp, "Reading the existing global must not create an application")
        let context = BenchmarkModelTestContext()
        addTeardownBlock { await context.close() }
        return context
    }
    @MainActor private func snapshot(_ model: NativeResultsModel) throws -> JSONValue { try BenchmarkModelSnapshot.results(model) }
    @MainActor private func preferences(_ value: JSONValue) -> JSONValue { BenchmarkModelSnapshot.preferences(value) }
    @MainActor private func assertPayload(_ model: NativeResultsModel, revision: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.payload["revision"], revision, file: file, line: line)
        XCTAssertEqual(model.raw.first?["revision"], revision, file: file, line: line)
        XCTAssertEqual(model.curves.first?["revision"], revision, file: file, line: line)
    }

    @MainActor func testSpeedRestoresOncePreservesPersistedLocalEditsAcrossDiskDriftAndReentryEvents() async throws {
        let f = fixture(), service = f.service, model = f.speed()
        try await f.run("model begin") { await model.begin(events: f.events) }
        XCTAssertEqual(model.selection, BenchmarkModelFixture.diskSelection)
        model.tier("deep"); model.toggle("disk"); model.models("local", ["z", "a", "a"])
        let local = model.selection
        XCTAssertEqual(local, ["tier": "deep", "included": ["local"], "models": ["disk": ["disk-model"], "shared": ["disk-shared"], "local": ["a", "z"]]])
        try await f.wait("three real model persistence calls completed") { await service.completed("saveSelection") == 3 }
        let persisted = await service.disk()["selection"]
        XCTAssertEqual(persisted, local)
        model.stopListening()
        // Drift occurs only after real model edits reached private fake disk.
        await service.replaceSelection(BenchmarkModelFixture.alienSelection); await service.payload(2)
        try await f.run("model begin") { await model.begin(events: f.events) }
        XCTAssertEqual(model.selection, local); XCTAssertEqual(model.catalog["revision"], 2)
        let reads = await service.count("selection"), starts = await service.count("start")
        XCTAssertEqual(reads, 1); XCTAssertEqual(starts, 1)
        await service.payload(3); await f.events.publish("job.progress", ["app": "bench"])
        try await f.wait("Speed event after reentry") { model.catalog["revision"] == 3 }
        XCTAssertEqual(model.progress["revision"], 3); XCTAssertEqual(model.free["revision"], 3)
        let beforeFailure = model.catalog
        try await service.arm("catalog")
        let failed = f.start("current catalog failure") { await model.reload() }
        try await f.held("catalog"); try await service.release("catalog", failing: true); try await f.join(failed)
        XCTAssertEqual(model.error, BenchmarkModelFixture.failure); XCTAssertEqual(model.catalog, beforeFailure)
        try await f.run("model reload") { await model.reload() }; XCTAssertTrue(model.error.isEmpty); XCTAssertEqual(model.catalog, beforeFailure)
    }

    @MainActor func testResultsReentryPreservesLocalViewStateWhileRefreshingPayloadAndEvents() async throws {
        let f = fixture(), service = f.service, model = f.results(initialRun: "link-run")
        try await f.run("model begin") { await model.begin(events: f.events) }; XCTAssertEqual(model.scope, "link-run")
        model.choose("local-run"); model.chooseFamily("local-family"); model.chooseTab("charts")
        try await f.wait("local Results choice loaded") { model.payload["scope"] == "local-run" && !model.busy }
        let local = try snapshot(model)
        XCTAssertEqual(local["explicitRun"], "local-run"); XCTAssertEqual(local["newest"], "r1")
        XCTAssertGreaterThan(local["lastScopeChoice"].double, 0)
        model.stop(); await service.replaceResults(BenchmarkModelFixture.alienResults); await service.payload(2, newest: "r2")
        try await service.arm("summary")
        let resume = f.start("Results held reentry payload") { await model.begin(events: f.events) }
        try await f.held("summary")
        XCTAssertEqual(preferences(try snapshot(model)), preferences(local))
        try await service.release("summary"); try await f.join(resume)
        assertPayload(model, revision: 2)
        let after = try snapshot(model), reads = await service.count("resultsState")
        XCTAssertEqual(reads, 1); XCTAssertEqual(after["scope"], "local-run")
        XCTAssertEqual(after["explicitRun"], "local-run"); XCTAssertEqual(after["newest"], "r2")
        await service.payload(3, newest: "r3"); await f.events.publish("bench.row", [:])
        try await f.wait("Results row event after reentry") { model.payload["revision"] == 3 }
        XCTAssertEqual(model.scope, "local-run")
        let beforeFailure = model.payload
        try await service.arm("summary")
        let failed = f.start("current Results summary failure") { await model.load() }
        try await f.held("summary"); try await service.release("summary", failing: true); try await f.join(failed)
        XCTAssertEqual(model.error, BenchmarkModelFixture.failure); XCTAssertFalse(model.busy)
        XCTAssertEqual(model.payload, beforeFailure)
        try await f.run("model load") { await model.load() }; XCTAssertTrue(model.error.isEmpty)
        try await Task.sleep(nanoseconds: 2_000_000)
        await service.payload(4, newest: "r4"); await f.events.publish("bench.started", ["run_id": "r4"])
        try await f.wait("new start supersedes earlier explicit choice") { model.scope == "latest" && model.payload["revision"] == 4 }
        XCTAssertTrue(model.family.isEmpty); XCTAssertTrue(try snapshot(model)["explicitRun"].isNull)
    }

    @MainActor func testResultsStillFollowsAnUnobservedExternalRunUsingItsPriorNewestSentinel() async throws {
        let f = fixture(), service = f.service, model = f.results()
        try await f.run("model begin") { await model.begin(events: f.events) }
        XCTAssertEqual(model.scope, "all"); XCTAssertEqual(try snapshot(model)["newest"], "r1")
        model.stop()
        await service.replaceResults(["scope": "all", "family": "disk-family", "tab": "table", "newestRun": "r2"])
        await service.payload(2, newest: "r2"); try await f.run("model begin") { await model.begin(events: f.events) }
        try await f.wait("unobserved new run follows latest") { model.scope == "latest" && model.payload["scope"] == "r2" }
        XCTAssertEqual(try snapshot(model)["newest"], "r2")
        let reads = await service.count("resultsState"); XCTAssertEqual(reads, 1)
    }

    @MainActor func testResultsEmptyHistoryFollowsFirstRunCompletedWhileHidden() async throws {
        try await hiddenRun(activeBeforeRows: false)
    }
    @MainActor func testResultsFollowsHiddenActiveStartBeforeItsFirstNewRow() async throws {
        try await hiddenRun(activeBeforeRows: true)
    }
    @MainActor private func hiddenRun(activeBeforeRows: Bool) async throws {
        let f = fixture(), service = f.service, model = f.results()
        let initialNewest = activeBeforeRows ? "r1" : ""
        await service.replaceResults(["scope": "all", "family": "", "tab": "table", "newestRun": .string(initialNewest)])
        await service.payload(1, newest: initialNewest); try await f.run("model begin") { await model.begin(events: f.events) }
        model.choose("all")
        try await f.wait("All before hidden start") { model.payload["scope"] == "all" && !model.busy }
        let before = try snapshot(model); model.stop()
        try await Task.sleep(nanoseconds: 2_000_000)
        await service.runAdmitted("new-run")
        await service.payload(2, newest: activeBeforeRows ? "r1" : "new-run", active: activeBeforeRows ? "new-run" : nil)
        try await f.run("model begin") { await model.begin(events: f.events) }
        try await f.wait("hidden start selects latest without any event") { model.scope == "latest" && model.payload["scope"] == "new-run" && !model.busy }
        XCTAssertTrue(try snapshot(model)["explicitRun"].isNull); XCTAssertEqual(model.payload["revision"], 2)
        if activeBeforeRows {
            XCTAssertEqual(model.payload["runs"].array.first?["id"], "r1")
            XCTAssertTrue(model.raw.isEmpty); XCTAssertTrue(model.curves.isEmpty)
        } else {
            XCTAssertTrue(before["payload"]["runs"].array.isEmpty)
            XCTAssertEqual(model.payload["runs"].array.first?["id"], "new-run")
        }
    }

    @MainActor func testResultsAllChosenAfterStartBeforeFirstRowSurvivesReentry() async throws {
        try await choiceAfterStart(heldInitialProgress: false, historical: false)
    }
    @MainActor func testResultsAllChosenDuringHeldInitialProgressSurvivesFirstRow() async throws {
        try await choiceAfterStart(heldInitialProgress: true, historical: false)
    }
    @MainActor func testResultsExplicitHistoricalRunSurvivesHiddenRowArrival() async throws {
        try await choiceAfterStart(heldInitialProgress: false, historical: true)
    }
    @MainActor private func choiceAfterStart(heldInitialProgress: Bool, historical: Bool) async throws {
        let f = fixture(), service = f.service, model = f.results()
        await service.replaceResults(["scope": "latest", "family": "", "tab": "table", "newestRun": "r0"])
        await service.payload(1, newest: "r0")
        if heldInitialProgress {
            await service.runAdmitted("r1"); await service.payload(2, newest: "r0", active: "r1")
            try await service.arm("progress")
            let first = f.start("held initial Results progress") { await model.begin(events: f.events) }
            try await f.held("progress"); try await Task.sleep(nanoseconds: 2_000_000)
            model.choose("all"); model.chooseFamily("local-family"); model.chooseTab("charts"); await f.settle()
            try await service.release("progress"); try await f.join(first)
        } else {
            try await f.run("model begin") { await model.begin(events: f.events) }
            await service.runAdmitted("r1"); await service.payload(2, newest: "r0", active: "r1")
            await f.events.publish("bench.started", ["run_id": "r1"])
            try await f.wait("observed start with old row history") { model.payload["scope"] == "r1" && model.payload["revision"] == 2 }
            try await Task.sleep(nanoseconds: 2_000_000)
            model.choose(historical ? "historical-run" : "all"); model.chooseFamily("local-family"); model.chooseTab("charts")
        }
        let chosen = historical ? "historical-run" : "all"
        try await f.wait("later choice loaded") { model.scope == chosen && model.payload["scope"] == .string(chosen) && !model.busy }
        let before = try snapshot(model)
        XCTAssertEqual(before["newest"], "r0"); XCTAssertGreaterThan(before["lastScopeChoice"].double, 0)
        model.stop()
        if !historical {
            // Explicit independent fake-disk seed isolates row-arrival fallback;
            // readOnly Results never persisted this choice itself.
            await service.replaceResults(["scope": "all", "family": "local-family", "tab": "charts", "newestRun": "r0"])
        }
        await service.payload(3, newest: "r1"); try await f.run("model begin") { await model.begin(events: f.events) }
        try await f.wait("known start first row preserves later choice") { model.scope == chosen && model.payload["scope"] == .string(chosen) && model.payload["revision"] == 3 }
        let reads = await service.count("resultsState"); XCTAssertEqual(reads, 1)
        let after = try snapshot(model)
        if historical { XCTAssertEqual(after["explicitRun"], "historical-run") }
        else {
            XCTAssertEqual(after["lastScopeChoice"], before["lastScopeChoice"])
            XCTAssertEqual(model.family, "local-family"); XCTAssertEqual(model.tab, "charts")
        }
    }

    @MainActor func testResultsBufferedOlderStartCannotOverrideLaterAllDuringActiveR2RowArrival() async throws {
        let f = fixture(), service = f.service, model = f.results()
        await service.replaceResults(["scope": "all", "family": "", "tab": "table", "newestRun": "r0"])
        await service.payload(1, newest: "r0"); try await f.run("model begin") { await model.begin(events: f.events) }
        model.stop()
        let stream = await f.events.stream()
        let observer = f.start("actual bus event recorder") {
            for await event in stream { await service.recordActualEvent(event) }
        }
        let origin = "buffered-resume-begin-and-listener"
        try await service.armProgressBeforeSnapshotCapture()
        // The actual lifecycle's listener inherits begin's Task-local origin.
        // choose() creates its own Task from the test's different origin. Thus
        // summary ordinal 2 here belongs to the older buffered J1 handler.
        try await service.advanceHistoryOnSummary(origin: origin, ordinal: 2, revision: 3, newest: "r2")
        let resume = f.start("buffered Results resume") {
            await BenchmarkModelTrace.$origin.withValue(origin) { await model.begin(events: f.events) }
        }
        try await f.wait("progress held before snapshot capture") { await service.isProgressBeforeSnapshotCaptureHeld() }
        await service.note("resume held before J1 starts")
        await service.runAdmitted("r1"); await f.events.publish("bench.started", ["run_id": "r1"])
        try await f.wait("J1 actual publication precedes J2 metadata") {
            await service.ledger().filter { $0["kind"] == "actual-bus-event" }.count == 1
        }
        await service.runAdmitted("r2"); await service.payload(2, newest: "r1", active: "r2")
        await f.events.publish("bench.started", ["run_id": "r2"])
        try await f.wait("both actual events buffered during prepare") {
            await service.ledger().filter { $0["kind"] == "actual-bus-event" }.count == 2
        }
        try await Task.sleep(nanoseconds: 2_000_000)
        model.choose("all"); model.chooseFamily("local-family"); model.chooseTab("charts"); await f.settle()
        let chosen = try snapshot(model)
        await service.note("later All choice before progress snapshot")
        try await service.releaseProgressBeforeSnapshotCapture(); try await f.join(resume)
        let afterBuffer = try snapshot(model)
        XCTAssertEqual(model.scope, "all", "Buffered drain snapshot: \(afterBuffer)")
        assertPayload(model, revision: 3)
        let ledger = await service.ledger(), events = ledger.filter { $0["kind"] == "actual-bus-event" }
        XCTAssertEqual(events.map { $0["data"]["run_id"] }, ["r1", "r2"])
        XCTAssertTrue(events.allSatisfy { $0["timestamp"].double < chosen["lastScopeChoice"].double })
        let summaries = ledger.filter { $0["kind"] == "request" && $0["operation"] == "summary" && $0["origin"] == .string(origin) }
        XCTAssertGreaterThanOrEqual(summaries.count, 3, "\(ledger)")
        let initial = try XCTUnwrap(summaries.first), olderEvent = try XCTUnwrap(summaries.dropFirst().first)
        XCTAssertEqual(initial["input"]["scope"], "all")
        XCTAssertEqual(initial["capturedReply"]["runs"].array.first?["id"], "r1")
        XCTAssertEqual(olderEvent["capturedReply"]["runs"].array.first?["id"], "r2")
        let arrivals = ledger.filter { $0["kind"] == "history-arrival-on-buffered-event-read" }
        XCTAssertEqual(arrivals.count, 1); XCTAssertEqual(arrivals.first?["summaryOrdinal"], 2)
        XCTAssertEqual(arrivals.first?["newest"], "r2")
        let progress = ledger.filter { $0["kind"] == "request" && $0["operation"] == "progress" && $0["origin"] == .string(origin) }
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress.first?["capturedReply"]["job"]["params"]["run_id"], "r2")
        XCTAssertEqual(progress.first?["replyCaptureSemantics"], "captured-after-before-snapshot-release")
        // Supporting private-state evidence accompanies the observable assertions.
        let starts: Set<String> = try BenchmarkModelSnapshot.field(model, "reconciledRunStarts", as: Set<String>.self)
        XCTAssertTrue(starts.contains("r1") && starts.contains("r2"))
        // Stay active: a second begin would repair a String-based implementation
        // before its row-arrival fallback became observable.
        await service.payload(4, newest: "r2"); try await f.run("model load") { await model.load() }
        let afterActiveLoad = try snapshot(model)
        XCTAssertEqual(model.scope, "all", "Active-load snapshot: \(afterActiveLoad)")
        XCTAssertEqual(model.payload["scope"], "all"); assertPayload(model, revision: 4)
        XCTAssertEqual(model.family, "local-family"); XCTAssertEqual(model.tab, "charts")
        XCTAssertEqual(afterActiveLoad["lastScopeChoice"], chosen["lastScopeChoice"])
        observer.cancel(); try await f.join(observer)
    }

    @MainActor func testResultsInitialProgressFailureRetriesUncommittedPreferences() async throws {
        try await progressFailure(resume: false)
    }
    @MainActor func testResultsResumeProgressFailurePreservesSuccessfulPreferencesAndRetriesMetadata() async throws {
        try await progressFailure(resume: true)
    }
    @MainActor private func progressFailure(resume: Bool) async throws {
        let f = fixture(), service = f.service, model = f.results()
        var before: JSONValue = .null
        if resume {
            try await f.run("model begin") { await model.begin(events: f.events) }
            model.choose("local-run"); model.chooseFamily("local-family"); model.chooseTab("charts")
            try await f.wait("local view before metadata failure") { model.payload["scope"] == "local-run" && !model.busy }
            before = try snapshot(model); model.stop(); await service.replaceResults(BenchmarkModelFixture.alienResults)
        }
        try await service.arm("progress")
        let first = f.start("held failing Results progress") { await model.begin(events: f.events) }
        try await f.held("progress")
        let held = try snapshot(model)
        try await service.release("progress", failing: true); try await f.join(first)
        XCTAssertEqual(model.error, BenchmarkModelFixture.failure)
        XCTAssertEqual(preferences(try snapshot(model)), preferences(held))
        if resume { XCTAssertEqual(preferences(held), preferences(before)) }
        else { XCTAssertTrue(model.payload.isNull) }
        let readsAfterFailure = await service.count("resultsState"); XCTAssertEqual(readsAfterFailure, 1)
        model.stop(); await service.payload(2); try await f.run("model begin") { await model.begin(events: f.events) }
        let reads = await service.count("resultsState"), progressReads = await service.count("progress")
        XCTAssertEqual(reads, resume ? 1 : 2); XCTAssertEqual(progressReads, resume ? 3 : 2)
        XCTAssertTrue(model.error.isEmpty); assertPayload(model, revision: 2)
        if resume { XCTAssertEqual(preferences(try snapshot(model)), preferences(before)) }
    }

    @MainActor func testSpeedCancelledHeldStartNeverPublishesLateAndRetriesOnReentry() async throws {
        try await speedStartRetry(cancel: true)
    }
    @MainActor func testSpeedFailedHeldStartSurfacesCurrentErrorAndRetriesOnReentry() async throws {
        try await speedStartRetry(cancel: false)
    }
    @MainActor private func speedStartRetry(cancel: Bool) async throws {
        let f = fixture(), service = f.service, model = f.speed(), probe = BenchmarkModelPublicationProbe(model)
        try await service.arm("start")
        let first = f.start("held Speed start") { await model.begin(events: f.events) }
        try await f.held("start")
        if cancel { first.cancel(); model.stopListening() }
        let selection = model.selection, checkpoint = probe.records
        try await service.release("start", failing: !cancel); try await f.join(first); await f.settle()
        if cancel { XCTAssertEqual(model.selection, selection); XCTAssertEqual(probe.records, checkpoint) }
        else { XCTAssertEqual(model.error, BenchmarkModelFixture.failure) }
        let readsBeforeRetry = await service.count("selection")
        XCTAssertEqual(readsBeforeRetry, 0, "A cancelled or failed start must not dispatch the next preference read")
        model.stopListening(); try await f.run("model begin") { await model.begin(events: f.events) }
        let starts = await service.count("start"), reads = await service.count("selection")
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(reads, 1, "Only the successful re-entry may read preferences")
        XCTAssertEqual(model.selection, BenchmarkModelFixture.diskSelection); XCTAssertTrue(model.error.isEmpty)
    }

    @MainActor func testSpeedCancelledInitialSelectionRetainsPendingEditsAndRereadsOnRetry() async throws {
        try await speedPending(cancel: true)
    }
    @MainActor func testSpeedFailedInitialSelectionRetainsPendingEditsAndRereadsOnRetry() async throws {
        try await speedPending(cancel: false)
    }
    @MainActor private func speedPending(cancel: Bool) async throws {
        let f = fixture(), service = f.service, model = f.speed(), probe = BenchmarkModelPublicationProbe(model)
        model.toggle("pre"); await f.settle()
        try await service.arm("selection")
        let first = f.start("held initial Speed selection") { await model.begin(events: f.events) }
        try await f.held("selection")
        model.tier("deep"); model.models("shared", ["during"]); await f.settle()
        if cancel { first.cancel(); model.stopListening() }
        let selection = model.selection, checkpoint = probe.records
        try await service.release("selection", failing: !cancel); try await f.join(first); await f.settle()
        XCTAssertEqual(model.selection, selection)
        if cancel { XCTAssertEqual(probe.records, checkpoint) }
        else { XCTAssertEqual(model.error, BenchmarkModelFixture.failure) }
        let earlySaves = await service.count("saveSelection"); XCTAssertEqual(earlySaves, 0, "Pending edits were not persisted")
        model.stopListening(); await service.replaceSelection(BenchmarkModelFixture.alienSelection); try await f.run("model begin") { await model.begin(events: f.events) }
        XCTAssertEqual(model.selection, ["tier": "deep", "included": ["alien", "pre", "shared"], "models": ["alien": ["alien-model"], "shared": ["during"]]])
        let reads = await service.count("selection"); XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.catalog["revision"], 1); XCTAssertTrue(model.error.isEmpty)
    }

    @MainActor func testResultsCancelledInitialRestoreRetainsPendingEditsAndChoiceTimeOnRetry() async throws {
        try await resultsPending(cancel: true)
    }
    @MainActor func testResultsFailedInitialRestoreRetainsPendingEditsAndChoiceTimeOnRetry() async throws {
        try await resultsPending(cancel: false)
    }
    @MainActor private func resultsPending(cancel: Bool) async throws {
        let f = fixture(), service = f.service, model = f.results(), probe = BenchmarkModelPublicationProbe(model)
        model.chooseFamily("pre-family"); model.chooseTab("table"); await f.settle()
        try await service.arm("resultsState")
        let first = f.start("held initial Results preferences") { await model.begin(events: f.events) }
        try await f.held("resultsState")
        model.choose("all"); model.chooseTab("charts"); await f.settle()
        if cancel { first.cancel(); model.stop() }
        let before = try snapshot(model), checkpoint = probe.records
        try await service.release("resultsState", failing: !cancel); try await f.join(first); await f.settle()
        XCTAssertEqual(preferences(try snapshot(model)), preferences(before)); XCTAssertTrue(model.payload.isNull)
        if cancel { XCTAssertEqual(probe.records, checkpoint) }
        else { XCTAssertEqual(model.error, BenchmarkModelFixture.failure) }
        model.stop()
        var disk = BenchmarkModelFixture.alienResults; disk["newestRun"] = "r1"; disk["scope"] = "latest"
        await service.replaceResults(disk); try await f.run("model begin") { await model.begin(events: f.events) }
        let after = try snapshot(model), reads = await service.count("resultsState")
        XCTAssertEqual(reads, 2); XCTAssertEqual(model.scope, "all"); XCTAssertEqual(after["newest"], "r1")
        XCTAssertEqual(model.family, "pre-family"); XCTAssertEqual(model.tab, "charts")
        XCTAssertEqual(after["lastScopeChoice"], before["lastScopeChoice"]); XCTAssertTrue(model.error.isEmpty)
    }

    @MainActor func testSpeedEditsBeforeAndDuringFirstRestoreOverlayOnlyTheirFieldsAndPersist() async throws {
        let f = fixture(), service = f.service, model = f.speed()
        model.tier("quick"); model.toggle("pre"); model.models("shared", ["before"]); await f.settle()
        try await service.arm("selection")
        let first = f.start("Speed before/during edit overlay") { await model.begin(events: f.events) }
        try await f.held("selection")
        model.tier("deep"); model.models("shared", ["during"]); model.toggle("during"); await f.settle()
        try await service.release("selection"); try await f.join(first)
        XCTAssertEqual(model.selection, ["tier": "deep", "included": ["disk", "during", "pre", "shared"], "models": ["disk": ["disk-model"], "shared": ["during"]]])
        try await f.wait("overlay's three real persistence calls completed") { await service.completed("saveSelection") == 3 }
        let disk = await service.disk()["selection"]
        XCTAssertEqual(disk, model.selection)
    }

    @MainActor func testResultsEditsBeforeAndDuringFirstRestoreKeepUntouchedFieldsAndLastTabChoice() async throws {
        let f = fixture(), service = f.service, model = f.results()
        model.chooseFamily("pre-family"); model.chooseTab("charts"); await f.settle()
        try await service.arm("resultsState")
        let first = f.start("Results before/during edit overlay") { await model.begin(events: f.events) }
        try await f.held("resultsState")
        model.choose("local-run"); model.chooseTab("table"); await f.settle()
        try await service.release("resultsState"); try await f.join(first)
        try await f.wait("Results overlay payload ready") { model.payload["scope"] == "local-run" && !model.busy }
        XCTAssertEqual(model.scope, "local-run"); XCTAssertEqual(model.family, "pre-family"); XCTAssertEqual(model.tab, "table")
        XCTAssertEqual(try snapshot(model)["explicitRun"], "local-run")
        let reads = await service.count("resultsState"); XCTAssertEqual(reads, 1)
    }
}
