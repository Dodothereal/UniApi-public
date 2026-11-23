import XCTest
@testable import UniApiCore

final class ArenaDuelTests: XCTestCase {
    func testObservedStepsCountDistinctTopLevelAssistantMessages() {
        let message: JSONValue = ["type": "assistant", "payload": ["message_id": "first"]]
        let child: JSONValue = ["type": "assistant", "payload": ["message_id": "child", "parent_tool_use_id": "tool"]]
        let user: JSONValue = ["type": "user", "payload": ["message_id": "user"]]
        XCTAssertEqual(ArenaPresentationPolicy.observedSteps([message, message, child, user]), 1)
    }

    func testBinaryInsertionRanksAStablePreferenceInAtMostSeventeenDuels() {
        let expected = [7, 1, 4, 6, 2, 5, 0, 3]
        let ranks = Dictionary(uniqueKeysWithValues: expected.enumerated().map { ($0.element, $0.offset) })
        var duel = ArenaDuel(contestants: Array(0..<8))
        while let pair = duel.pair, duel.decisions <= 17 {
            duel.choose(ranks[pair.left]! < ranks[pair.right]! ? .left : .right)
        }
        XCTAssertNil(duel.pair)
        XCTAssertEqual(duel.groups, expected.map { [$0] })
        XCTAssertEqual(duel.maximumDecisions, 17)
        XCTAssertLessThanOrEqual(duel.decisions, 17)
    }

    func testTieKeepsEqualRankAndGapsAndDoesNotRankFailedSlots() throws {
        var duel = ArenaDuel(contestants: [0, 2, 3])
        XCTAssertEqual(duel.pair?.right, 2)
        duel.choose(.tie)
        duel.choose(.left)
        XCTAssertNil(duel.pair)
        XCTAssertEqual(duel.groups, [[0, 2], [3]])
        let groups = try ArenaVoteOrder.groups(ranking: .null, rankGroups: [[2, 0], [3]], finished: [0, 2, 3])
        let ranks = ArenaVoteOrder.ranks(groups)
        XCTAssertEqual(groups, [[0, 2], [3]])
        XCTAssertEqual(ranks, [0: 1, 2: 1, 3: 3])
        XCTAssertThrowsError(try ArenaVoteOrder.groups(ranking: .null, rankGroups: [[0, 0, 3]], finished: [0, 2, 3]))
        XCTAssertThrowsError(try ArenaVoteOrder.groups(ranking: .null, rankGroups: [[0, 2], [], [3]], finished: [0, 2, 3]))
        XCTAssertEqual(try ArenaVoteOrder.groups(ranking: [3, 0, 2], rankGroups: .null, finished: [0, 2, 3]), [[3], [0], [2]])
    }

    func testTrendAndRevealUseTheSameLedgerFoldAsStandings() {
        let slots: [JSONValue] = [
            ["idx": 0, "route": "fixture", "model": "alpha", "status": "done"],
            ["idx": 1, "route": "fixture", "model": "beta", "status": "done"],
            ["idx": 2, "route": "fixture", "model": "gamma", "status": "done"]
        ]
        let first = ArenaLedger.record(match: ["id": "previous", "mode": "random"], slots: slots, ranking: [0, 1, 2], voter: .null, at: 1)
        let second = ArenaLedger.record(match: ["id": "selected", "mode": "chosen"], slots: slots, ranking: [0, 1, 2], voter: .null, at: 2, tiedRanks: [0: 1, 1: 1, 2: 3])
        let before = ArenaRanking.standings([first])
        let folded = ArenaRanking.fold([second, first], mode: "all", trend: true, matchID: "selected")
        XCTAssertEqual(folded.verdict["contestants"].array.map { $0["rank"].int }, [1, 1, 3])
        XCTAssertEqual(ArenaPresentationPolicy.verdictOrder(folded.verdict), "alpha = beta > gamma")
        let alpha = ArenaContestantPolicy.key(slots[0]), beta = ArenaContestantPolicy.key(slots[1])
        XCTAssertEqual(ArenaPairMatrix(folded.comparisons)[alpha, beta]?.draws, 1)
        for series in folded.trend {
            let key = series["key"].string
            let points = series["points"].array
            XCTAssertEqual(points.map { $0["ts"].int }, [1, 2])
            XCTAssertEqual(points.last?["elo"], folded.standings.first { $0["key"].string == key }?["elo"])
            XCTAssertEqual(folded.deltas[key].int, points.last!["elo"].int - before.first { $0["key"].string == key }!["elo"].int)
        }
    }
}
