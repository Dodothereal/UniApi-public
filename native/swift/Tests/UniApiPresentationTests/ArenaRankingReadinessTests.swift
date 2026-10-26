import XCTest
import AppKit
import UniApiCore
@testable import UniApiPresentation

@MainActor final class ArenaRankingReadinessTests: XCTestCase {
    private func fixture() -> ArenaModelTestContext {
        XCTAssertNil(NSApp, "Ranking fixtures must not construct an application or NativeRuntime")
        let context = ArenaModelTestContext()
        addTeardownBlock { await context.close() }
        return context
    }
    private func ranking(_ name: String) -> JSONValue {
        ["standings": [["key": .string(name), "route": "fixture", "model": .string(name), "elo": 1016]],
         "ledger": ["remote": .string(name), "files": 3, "unpublished": 1, "behind": 2, "git": false]]
    }
    private func seed(_ f: ArenaModelTestContext, mode: String = "all", name: String = "saved") async throws {
        await f.service.set("ranking:" + mode, ranking(name))
        await f.service.set("ledger.records", [["id": .string(name)]])
        try await f.run("seed " + mode) { await f.model.ranking(mode) }
    }

    func testInitialRankingWaitsForBothStandingsAndRecentLedgerBeforeBecomingReady() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        XCTAssertEqual(model.rankingPhase(for: "all"), .pending)
        XCTAssertFalse(model.rankingHasContent(for: "all"))
        await service.enqueue("ranking:all", ranking("first"), hold: "standings")
        await service.enqueue("ledger.records", [["id": "first"]], hold: "records")
        let read = f.start("first ranking") { await model.ranking("all") }
        try await f.held("standings")
        XCTAssertEqual(model.rankingPhase(for: "all"), .loading)
        XCTAssertFalse(model.rankingHasContent(for: "all"))
        try await service.release("standings"); try await f.held("records")
        XCTAssertEqual(model.rankingPhase(for: "all"), .loading)
        XCTAssertNil(model.rankingLoadedMode)
        XCTAssertTrue(model.standings.isEmpty); XCTAssertTrue(model.ledger.isNull)
        try await service.release("records"); try await f.join(read)
        XCTAssertEqual(model.rankingPhase(for: "all"), .ready)
        XCTAssertTrue(model.rankingHasContent(for: "all"))
        XCTAssertEqual(model.standings, ranking("first")["standings"].array)
        XCTAssertEqual(model.ledger, ranking("first")["ledger"])
        XCTAssertEqual(model.recent, [["id": "first"]])
    }

    func testFailedFirstLedgerReadDoesNotBecomeEmptyAndReloadCanRecoverToConfirmedEmpty() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.set("ranking:all", ranking("uncommitted"))
        await service.enqueue("ledger.records", .null, failure: "ledger read failed")
        try await f.run("failed first ranking") { await model.ranking("all") }
        XCTAssertEqual(model.rankingPhase(for: "all"), .failed)
        XCTAssertFalse(model.rankingHasContent(for: "all")); XCTAssertTrue(model.ledger.isNull)
        XCTAssertEqual(model.pageError(includeRanking: true), "ledger read failed")
        XCTAssertTrue(model.pageError(includeRanking: false).isEmpty)

        let empty: JSONValue = ["standings": [], "ledger": ["files": 0, "unpublished": 0, "behind": 0, "git": false]]
        await service.set("ranking:all", empty)
        await service.enqueue("ledger.records", [], hold: "empty-records")
        let retry = f.start("reload empty ranking") { await model.reload(ranking: "all") }
        try await f.held("empty-records")
        XCTAssertEqual(model.rankingPhase(for: "all"), .loading)
        XCTAssertFalse(model.rankingHasContent(for: "all"))
        try await service.release("empty-records"); try await f.join(retry)
        XCTAssertEqual(model.rankingPhase(for: "all"), .ready)
        XCTAssertTrue(model.rankingHasContent(for: "all"))
        XCTAssertTrue(model.standings.isEmpty); XCTAssertEqual(model.ledger, empty["ledger"])
        XCTAssertTrue(model.recent.isEmpty); XCTAssertTrue(model.error.isEmpty)
    }

    func testSameScopeRefreshRetainsSuccessfulContentThroughFailureAndRetry() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter(); try await seed(f)
        await service.enqueue("ranking:all", ranking("replacement"), hold: "refresh")
        let refresh = f.start("same-scope refresh") { await model.reload(ranking: "all") }
        try await f.held("refresh")
        XCTAssertEqual(model.rankingPhase(for: "all"), .loading)
        XCTAssertTrue(model.rankingHasContent(for: "all"))
        XCTAssertEqual(model.standings, ranking("saved")["standings"].array)
        XCTAssertEqual(model.ledger, ranking("saved")["ledger"])
        XCTAssertEqual(model.recent, [["id": "saved"]])
        try await service.release("refresh", failure: "refresh failed"); try await f.join(refresh)
        XCTAssertEqual(model.rankingPhase(for: "all"), .failed)
        XCTAssertTrue(model.rankingHasContent(for: "all"))
        XCTAssertEqual(model.standings, ranking("saved")["standings"].array)
        XCTAssertEqual(model.error, "refresh failed")

        await service.set("ranking:all", ranking("replacement"))
        await service.enqueue("ledger.records", [["id": "replacement"]], hold: "retry-records")
        let retry = f.start("same-scope retry") { await model.reload(ranking: "all") }
        try await f.held("retry-records")
        XCTAssertEqual(model.rankingPhase(for: "all"), .loading)
        XCTAssertTrue(model.rankingHasContent(for: "all"))
        XCTAssertEqual(model.recent, [["id": "saved"]])
        try await service.release("retry-records"); try await f.join(retry)
        XCTAssertEqual(model.rankingPhase(for: "all"), .ready)
        XCTAssertEqual(model.standings, ranking("replacement")["standings"].array)
        XCTAssertEqual(model.recent, [["id": "replacement"]]); XCTAssertTrue(model.error.isEmpty)
    }

    func testScopeChangeHidesPreviousRowsBeforeRequestStartsAndAfterNewScopeFailure() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter(); try await seed(f)
        // The page can select Chosen before its task is admitted. Raw All data
        // remains cached, but must not qualify as content for the selected scope.
        XCTAssertFalse(model.rankingHasContent(for: "chosen"))
        XCTAssertEqual(model.rankingPhase(for: "chosen"), .pending)
        await service.enqueue("ranking:chosen", .null, hold: "chosen", failure: "chosen failed")
        let read = f.start("chosen ranking") { await model.ranking("chosen") }
        try await f.held("chosen")
        XCTAssertEqual(model.rankingPhase(for: "chosen"), .loading)
        XCTAssertFalse(model.rankingHasContent(for: "chosen"))
        try await service.release("chosen"); try await f.join(read)
        XCTAssertEqual(model.rankingPhase(for: "chosen"), .failed)
        XCTAssertFalse(model.rankingHasContent(for: "chosen"))
        XCTAssertEqual(model.standings, ranking("saved")["standings"].array)
        XCTAssertEqual(model.error, "chosen failed")
        try await seed(f, mode: "chosen", name: "chosen")
        XCTAssertEqual(model.rankingPhase(for: "chosen"), .ready)
        XCTAssertTrue(model.rankingHasContent(for: "chosen"))
        XCTAssertFalse(model.rankingHasContent(for: "all")); XCTAssertTrue(model.error.isEmpty)
    }

    func testSupersededScopeSuccessCannotSettleTheNewScopeOrDispatchItsLedgerRead() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("ranking:all", ranking("obsolete"), hold: "old")
        let old = f.start("old all ranking") { await model.ranking("all") }; try await f.held("old")
        await service.enqueue("ranking:chosen", ranking("chosen"), hold: "new")
        await service.enqueue("ledger.records", [["id": "chosen"]], hold: "new-records")
        let new = f.start("new chosen ranking") { await model.ranking("chosen") }; try await f.held("new")
        try await service.release("old"); try await f.join(old)
        XCTAssertEqual(model.rankingLoadingMode, "chosen")
        XCTAssertEqual(model.rankingPhase(for: "chosen"), .loading)
        XCTAssertFalse(model.rankingHasContent(for: "all")); XCTAssertFalse(model.rankingHasContent(for: "chosen"))
        let count = await service.count("ledger.records"); XCTAssertEqual(count, 0)
        try await service.release("new"); try await f.held("new-records")
        XCTAssertEqual(model.rankingPhase(for: "chosen"), .loading)
        try await service.release("new-records"); try await f.join(new)
        XCTAssertEqual(model.rankingPhase(for: "chosen"), .ready)
        XCTAssertEqual(model.ledger, ranking("chosen")["ledger"])
    }

    func testSupersededSameScopeErrorCannotClearReplacementLoadingOrItsRetainedContent() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter(); try await seed(f)
        await service.enqueue("ledger.records", [["id": "obsolete"]], hold: "old-records")
        let old = f.start("obsolete all refresh") { await model.ranking("all") }; try await f.held("old-records")
        await service.enqueue("ranking:all", ranking("replacement"), hold: "replacement")
        await service.set("ledger.records", [["id": "replacement"]])
        let new = f.start("replacement all refresh") { await model.ranking("all") }; try await f.held("replacement")
        try await service.release("old-records", failure: "obsolete failure"); try await f.join(old)
        XCTAssertEqual(model.rankingPhase(for: "all"), .loading)
        XCTAssertTrue(model.rankingHasContent(for: "all"))
        XCTAssertEqual(model.standings, ranking("saved")["standings"].array)
        XCTAssertTrue(model.error.isEmpty)
        try await service.release("replacement"); try await f.join(new)
        XCTAssertEqual(model.rankingPhase(for: "all"), .ready)
        XCTAssertEqual(model.recent, [["id": "replacement"]])
    }

    func testCancelledInitialRankingReturnsToPendingAndCanRetry() async throws {
        let f = fixture(), model = f.model, service = f.service
        try await f.enter()
        await service.enqueue("ranking:all", ranking("cancelled"), hold: "cancelled")
        let read = f.start("cancelled ranking") { await model.ranking("all") }; try await f.held("cancelled")
        read.cancel(); try await service.release("cancelled"); try await f.join(read)
        XCTAssertEqual(model.rankingPhase(for: "all"), .pending)
        XCTAssertNil(model.rankingLoadingMode); XCTAssertFalse(model.rankingHasContent(for: "all"))
        XCTAssertTrue(model.ledger.isNull); XCTAssertTrue(model.error.isEmpty)
        let count = await service.count("ledger.records"); XCTAssertEqual(count, 0)
        try await seed(f)
        XCTAssertEqual(model.rankingPhase(for: "all"), .ready)
    }

    func testStoppedReadCannotSettleNewLifetimeRankingOnLateSuccessOrError() async throws {
        for failure in [nil, "old lifetime failed"] as [String?] {
            let f = fixture(), model = f.model, service = f.service
            try await f.enter(); try await seed(f)
            await service.enqueue("ledger.records", [["id": "old lifetime"]], hold: "old-lifetime")
            let old = f.start("old lifetime ranking") { await model.ranking("all") }; try await f.held("old-lifetime")
            model.stop()
            XCTAssertNil(model.rankingLoadingMode)
            XCTAssertEqual(model.rankingPhase(for: "all"), .ready)
            XCTAssertTrue(model.rankingHasContent(for: "all"))
            try await f.enter()
            await service.enqueue("ranking:chosen", ranking("new lifetime"), hold: "new-lifetime")
            await service.set("ledger.records", [["id": "new lifetime"]])
            let new = f.start("new lifetime ranking") { await model.ranking("chosen") }; try await f.held("new-lifetime")
            try await service.release("old-lifetime", failure: failure); try await f.join(old)
            XCTAssertEqual(model.rankingPhase(for: "chosen"), .loading)
            XCTAssertFalse(model.rankingHasContent(for: "chosen"))
            XCTAssertEqual(model.standings, ranking("saved")["standings"].array)
            XCTAssertTrue(model.error.isEmpty); XCTAssertTrue(model.readActive)
            try await service.release("new-lifetime"); try await f.join(new)
            XCTAssertEqual(model.rankingPhase(for: "chosen"), .ready)
            XCTAssertTrue(model.rankingHasContent(for: "chosen"))
            XCTAssertEqual(model.recent, [["id": "new lifetime"]])
        }
    }
}
