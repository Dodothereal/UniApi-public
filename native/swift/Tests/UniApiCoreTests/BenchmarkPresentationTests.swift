import XCTest
@testable import UniApiCore

actor BenchmarkTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { continuation = $0 } } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class BenchmarkPresentationTests: XCTestCase {
    @MainActor func testReloadDuringSavedPreferenceReadWaitsBeforeCapturingSpeedSelectionOrResultsScope() async {
        for field in ["selection", "scope"] {
            let lifecycle = BenchmarkPageLifecycle(), events = NativeEvents(), gate = BenchmarkTestGate()
            let entered = expectation(description: field + " preferences held"), reloadEntered = expectation(description: "Reload requested")
            var selected = "default", restored = 0, reads: [String] = [], commits: [String] = []
            func load() async {
                guard await lifecycle.ready() else { return }
                let chosen = selected
                await lifecycle.perform(read: { reads.append(chosen); return chosen }, commit: { commits.append($0) }, failed: { XCTFail($0.localizedDescription) })
            }
            let mount = Task {
                await lifecycle.begin(events: events, matches: { _ in false }, prepare: {
                    await lifecycle.restore(read: { restored += 1; entered.fulfill(); await gate.wait(); return "saved-" + field }, commit: { selected = $0 }, failed: { XCTFail($0.localizedDescription) })
                }, initial: { await load() }, changed: { _ in await load() })
            }
            await fulfillment(of: [entered], timeout: 2)
            let reload = Task { reloadEntered.fulfill(); await load() }
            await fulfillment(of: [reloadEntered], timeout: 2)
            XCTAssertTrue(reads.isEmpty); XCTAssertTrue(commits.isEmpty)
            await gate.release(); await mount.value; await reload.value
            XCTAssertEqual(restored, 1); XCTAssertFalse(commits.isEmpty)
            XCTAssertTrue(reads.allSatisfy { $0 == "saved-" + field }); XCTAssertTrue(commits.allSatisfy { $0 == "saved-" + field })
            await load(); XCTAssertEqual(restored, 1); lifecycle.stop()
        }
    }
    @MainActor func testPreferenceEditsAndDeferredPersistSurviveHeldRestoreWithoutDiscardingOtherProviders() async {
        let lifecycle = BenchmarkPageLifecycle(), gate = BenchmarkTestGate(), entered = expectation(description: "saved preferences held")
        let persistRequested = expectation(description: "persist waiting for preferences")
        var edits = BenchmarkPreferenceEdits(), selection: JSONValue = ["tier": "standard", "included": [], "models": [:]], persisted: [JSONValue] = []
        let saved: JSONValue = ["tier": "deep", "included": ["one", "two"], "models": ["one": ["old"], "two": ["keep"]], "scope": "old-run", "family": "keep-family", "tab": "charts"]
        let mount = Task {
            await lifecycle.begin(events: NativeEvents(), matches: { _ in false }, prepare: {
                await lifecycle.restore(read: { entered.fulfill(); await gate.wait(); return saved }, commit: { selection = edits.restoring($0) }, failed: { XCTFail($0.localizedDescription) })
            }, initial: {}, changed: { _ in })
        }
        await fulfillment(of: [entered], timeout: 2)
        // A choice returned to its default is still explicit; unrelated saved
        // providers/family/tab must be retained when the held read returns.
        edits.set("tier", "quick"); edits.set("tier", "standard"); edits.set("scope", "all")
        edits.include("one", false); edits.include("new", true); edits.selectModels("new", ["chosen"])
        let persist = Task { persistRequested.fulfill(); if await lifecycle.ready() { persisted.append(selection) } }
        await fulfillment(of: [persistRequested], timeout: 2)
        XCTAssertTrue(persisted.isEmpty)
        await gate.release(); await mount.value; await persist.value
        XCTAssertEqual(selection["tier"], "standard"); XCTAssertEqual(selection["scope"], "all")
        XCTAssertEqual(selection["included"], ["two", "new"]); XCTAssertEqual(selection["models"]["two"], ["keep"])
        XCTAssertEqual(selection["models"]["new"], ["chosen"]); XCTAssertEqual(selection["family"], "keep-family"); XCTAssertEqual(selection["tab"], "charts")
        XCTAssertEqual(persisted, [selection]); lifecycle.stop()
    }
    @MainActor func testCancelledReloadDoesNotCancelVisibleLifetimesSharedPreparation() async {
        let lifecycle = BenchmarkPageLifecycle(), gate = BenchmarkTestGate(), entered = expectation(description: "preparing")
        let requested = expectation(description: "reload waiting")
        var restores = 0, initialLoads = 0, reloadLoads = 0
        let mount = Task {
            await lifecycle.begin(events: NativeEvents(), matches: { _ in false }, prepare: {
                await lifecycle.restore(read: { entered.fulfill(); await gate.wait(); return 1 }, commit: { restores += $0 }, failed: { XCTFail($0.localizedDescription) })
            }, initial: { initialLoads += 1 }, changed: { _ in })
        }
        await fulfillment(of: [entered], timeout: 2)
        let reload = Task { requested.fulfill(); if await lifecycle.ready() { reloadLoads += 1 } }
        await fulfillment(of: [requested], timeout: 2); reload.cancel()
        await gate.release(); await mount.value; await reload.value
        XCTAssertEqual(restores, 1); XCTAssertEqual(initialLoads, 1); XCTAssertEqual(reloadLoads, 0); lifecycle.stop()
    }
    @MainActor func testOwnerCancellationOrDepartureRejectsPreparationAndWaitingReloadAndAllowsNewLifetime() async {
        for cancelOwner in [true, false] {
            let lifecycle = BenchmarkPageLifecycle(), events = NativeEvents(), gate = BenchmarkTestGate()
            let entered = expectation(description: "old preparation held"), requested = expectation(description: "old reload waiting")
            var values: [String] = []
            let mount = Task {
                await lifecycle.begin(events: events, matches: { _ in true }, prepare: {
                    await lifecycle.restore(read: { entered.fulfill(); await gate.wait(); return "old preferences" }, commit: { values.append($0) }, failed: { _ in values.append("old failure") })
                }, initial: { values.append("old initial") }, changed: { _ in values.append("old event") })
            }
            await fulfillment(of: [entered], timeout: 2)
            let reload = Task { requested.fulfill(); if await lifecycle.ready() { values.append("old reload") } }
            await fulfillment(of: [requested], timeout: 2)
            await events.publish("bench.finished", [:])
            if cancelOwner { mount.cancel() } else { lifecycle.stop() }
            await gate.release(); await mount.value; await reload.value
            XCTAssertTrue(values.isEmpty)
            await lifecycle.begin(events: events, matches: { _ in false }, prepare: {
                await lifecycle.restore(read: { "new preferences" }, commit: { values.append($0) }, failed: { XCTFail($0.localizedDescription) })
            }, initial: { values.append("new initial") }, changed: { _ in })
            XCTAssertEqual(values, ["new preferences", "new initial"]); lifecycle.stop()
        }
    }
    @MainActor func testFailedPreferenceInitializationRetriesOnReloadAndRestoresOnceInEachLifetime() async {
        let lifecycle = BenchmarkPageLifecycle(), events = NativeEvents()
        var attempts = 0, errors = 0, restores = 0, initialLoads = 0
        func prepare() async -> Bool {
            await lifecycle.restore(read: { () async throws -> Int in
                attempts += 1; if attempts == 1 { throw NativeFailure("temporary settings read failure") }; return 1
            }, commit: { restores += $0 }, failed: { _ in errors += 1 })
        }
        await lifecycle.begin(events: events, matches: { _ in false }, prepare: { await prepare() }, initial: { initialLoads += 1 }, changed: { _ in })
        XCTAssertEqual(errors, 1); XCTAssertEqual(initialLoads, 0)
        let ready = await lifecycle.ready(); XCTAssertTrue(ready)
        let again = await lifecycle.ready(); XCTAssertTrue(again)
        XCTAssertEqual(attempts, 2); XCTAssertEqual(restores, 1)
        lifecycle.stop()
        await lifecycle.begin(events: events, matches: { _ in false }, prepare: { await prepare() }, initial: { initialLoads += 1 }, changed: { _ in })
        XCTAssertEqual(attempts, 3); XCTAssertEqual(restores, 2); XCTAssertEqual(initialLoads, 1); lifecycle.stop()
    }
    @MainActor func testUserScopeInvalidationRejectsOldPayloadBeforeDeferredReloadBegins() async {
        let lifecycle = BenchmarkPageLifecycle(), gate = BenchmarkTestGate(), entered = expectation(description: "old payload held")
        await lifecycle.begin(events: NativeEvents(), matches: { _ in false }, initial: {}, changed: { _ in })
        var payloads: [String] = []
        let old = Task {
            await lifecycle.perform(read: { entered.fulfill(); await gate.wait(); return "old scope" }, commit: { payloads.append($0) }, failed: { _ in payloads.append("old error") })
        }
        await fulfillment(of: [entered], timeout: 2)
        lifecycle.invalidate() // Results.choose does this before scheduling its load Task.
        await gate.release(); await old.value; XCTAssertTrue(payloads.isEmpty)
        await lifecycle.perform(read: { "chosen scope" }, commit: { payloads.append($0) }, failed: { XCTFail($0.localizedDescription) })
        XCTAssertEqual(payloads, ["chosen scope"]); lifecycle.stop()
    }
    @MainActor func testStartupBuffersFinalEventBeforeInitialReadCompletes() async {
        let events = NativeEvents(), lifecycle = BenchmarkPageLifecycle(), gate = BenchmarkTestGate()
        let entered = expectation(description: "initial read entered"), refreshed = expectation(description: "final event read committed")
        var values: [String] = []
        let mount = Task {
            await lifecycle.begin(events: events, matches: { $0.topic == "bench.finished" }, initial: {
                await lifecycle.perform(read: { entered.fulfill(); await gate.wait(); return "old" }, commit: { values.append($0) }, failed: { XCTFail($0.localizedDescription) })
            }, changed: { _ in
                await lifecycle.perform(read: { "finished" }, commit: { values.append($0); refreshed.fulfill() }, failed: { XCTFail($0.localizedDescription) })
            })
        }
        await fulfillment(of: [entered], timeout: 2)
        await events.publish("bench.finished", [:]); await gate.release(); await mount.value
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(values, ["old", "finished"]); lifecycle.stop()
    }
    @MainActor func testDisappearAndReentryRejectOldLifetimeReadAndQueuedEvent() async {
        let events = NativeEvents(), lifecycle = BenchmarkPageLifecycle(), gate = BenchmarkTestGate()
        let entered = expectation(description: "old read entered")
        var values: [String] = []
        let mount = Task {
            await lifecycle.begin(events: events, matches: { _ in true }, initial: {
                await lifecycle.perform(read: { entered.fulfill(); await gate.wait(); return "old" }, commit: { values.append($0) }, failed: { _ in XCTFail("old failure committed") })
            }, changed: { _ in values.append("old-event") })
        }
        await fulfillment(of: [entered], timeout: 2); await events.publish("bench.finished", [:]); lifecycle.stop()
        await lifecycle.begin(events: events, matches: { _ in true }, initial: {
            await lifecycle.perform(read: { "new" }, commit: { values.append($0) }, failed: { XCTFail($0.localizedDescription) })
        }, changed: { _ in values.append("new-event") })
        await gate.release(); await mount.value
        XCTAssertEqual(values, ["new"]); lifecycle.stop()
    }
    @MainActor func testLateResponseAndLateFailureCannotOverwriteNewerScope() async {
        let events = NativeEvents(), lifecycle = BenchmarkPageLifecycle()
        await lifecycle.begin(events: events, matches: { _ in false }, initial: {}, changed: { _ in })
        for fails in [false, true] {
            let gate = BenchmarkTestGate(), entered = expectation(description: "slow read entered")
            var values: [String] = []
            let slow = Task {
                await lifecycle.perform(read: { () async throws -> String in
                    entered.fulfill(); await gate.wait(); if fails { throw NativeFailure("late failure") }; return "old scope"
                }, commit: { values.append($0) }, failed: { _ in values.append("late error") })
            }
            await fulfillment(of: [entered], timeout: 2)
            await lifecycle.perform(read: { "new scope" }, commit: { values.append($0) }, failed: { XCTFail($0.localizedDescription) })
            await gate.release(); await slow.value; XCTAssertEqual(values, ["new scope"])
        }
        lifecycle.stop()
    }
    @MainActor func testCancelledInitialReadCannotCommitOrStartEventReload() async {
        let events = NativeEvents(), lifecycle = BenchmarkPageLifecycle(), gate = BenchmarkTestGate()
        let entered = expectation(description: "initial read entered")
        var commits = 0
        let mount = Task {
            await lifecycle.begin(events: events, matches: { _ in true }, initial: {
                await lifecycle.perform(read: { entered.fulfill(); await gate.wait(); return 1 }, commit: { commits += $0 }, failed: { _ in commits += 10 })
            }, changed: { _ in commits += 100 })
        }
        await fulfillment(of: [entered], timeout: 2); mount.cancel(); await events.publish("bench.finished", [:]); await gate.release(); await mount.value
        XCTAssertEqual(commits, 0); lifecycle.stop()
    }
    func testFamilyClearsOnlyWhenAbsentFromLoadedScopeAndFiltersMatchAllTerms() {
        let a: JSONValue = ["cells": ["p|a": ["family": "a"]]], b: JSONValue = ["cells": ["p|b": ["family": "b"]]]
        XCTAssertEqual(BenchmarkPresentation.family("a", summary: a), "a")
        XCTAssertEqual(BenchmarkPresentation.family("a", summary: b), "")
        XCTAssertEqual(BenchmarkPresentation.family("missing", summary: ["cells": [:]]), "")
        let report: JSONValue = ["rows": [["provider": "First Provider", "model": "MODEL Alpha", "outcome": "works"], ["provider": "Other", "model": "Alpha", "outcome": "denied"]]]
        XCTAssertEqual(BenchmarkPresentation.freeRows(report, query: "FIRST alpha").count, 1)
        XCTAssertEqual(BenchmarkPresentation.freeRows(report, query: "Alpha", outcome: "denied").count, 1)
        XCTAssertTrue(BenchmarkPresentation.freeRows(report, query: "missing").isEmpty)
        XCTAssertEqual(BenchmarkPresentation.outcomes.count, 8)
    }
}
