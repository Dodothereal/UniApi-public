import XCTest
@testable import UniApiCore

final class ArenaNavigationPolicyTests: XCTestCase {
    private func match(_ id: String, voted: Bool = false) -> JSONValue {
        ["id": .string(id), "voted_at": voted ? 123 : .null]
    }

    func testHistoryAdvancesThroughJudgedMatchesInDisplayedOrderAndWraps() {
        // History's newest-first order is supplied by the page, not rebuilt here.
        let rows = [match("newest", voted: true), match("middle", voted: true), match("oldest", voted: true)]
        XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: "newest", history: true), "middle")
        XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: "middle", history: true), "oldest")
        XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: "oldest", history: true), "newest")
    }

    func testJudgeAdvancesPastCurrentBeforeWrappingAndSkipsExistingVerdicts() {
        let rows = [match("first"), match("current"), match("judged", voted: true), match("last")]
        XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: "current", history: false), "last")
        XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: "last", history: false), "first")
        XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: "judged", history: false), "last")
    }

    func testMissingOrDeletedSelectionStartsAtFirstEligibleDisplayedMatch() {
        let rows = [match("judged", voted: true), match("first"), match("second")]
        for selected in ["", "deleted"] {
            XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: selected, history: true), "judged")
            XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: selected, history: false), "first")
        }
    }

    func testEmptyAndExhaustedListsDoNotReselectTheCurrentMatch() {
        for history in [false, true] {
            XCTAssertNil(ArenaPresentationPolicy.nextMatchID(in: [], after: "current", history: history))
            XCTAssertNil(ArenaPresentationPolicy.nextMatchID(in: [match("current")], after: "current", history: history))
        }
        let rows = [match("current"), match("judged", voted: true)]
        XCTAssertNil(ArenaPresentationPolicy.nextMatchID(in: rows, after: "current", history: false))
        XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: "current", history: true), "judged")
    }

    func testHistorySelectionDoesNotReplaceJudgeAndSkipRemainsUntilNext() {
        let ready: JSONValue = ["id": "ready", "status": "done", "created_at": 1]
        let prior: JSONValue = ["id": "prior", "status": "done", "voted_at": 10, "created_at": 2]
        var selection = ArenaMatchSelection()
        selection[.history] = "prior"
        XCTAssertEqual(selection.current(selection.visible([prior, ready], in: .judge), in: .judge)?["id"], "ready")
        selection[.judge] = "ready"
        var skipped = ready
        skipped["voted_at"] = 11
        XCTAssertEqual(selection.visible([prior, skipped], in: .judge), [skipped])
        XCTAssertEqual(selection.current(selection.visible([prior, skipped], in: .history), in: .history), prior)
        selection[.judge] = nil
        XCTAssertTrue(selection.visible([prior, skipped], in: .judge).isEmpty)
        XCTAssertEqual(selection[.history], "prior")
    }

    func testNextWrapsFromSkippedMatchToFirstReadyMatchInJudgeOrder() {
        let first: JSONValue = ["id": "first", "status": "done", "created_at": 1]
        let skipped: JSONValue = ["id": "skipped", "status": "done", "created_at": 2, "voted_at": 4]
        let running: JSONValue = ["id": "running", "status": "running", "created_at": 3]
        var selection = ArenaMatchSelection()
        selection[.judge] = "skipped"
        let rows = selection.visible([first, skipped, running], in: .judge)
        XCTAssertEqual(ArenaPresentationPolicy.nextMatchID(in: rows, after: "skipped", history: false), "first")
    }
}
