import XCTest
@testable import UniApiCore

final class ArenaMatrixTests: XCTestCase {
    func testCompactLeaderboardNamesKeepTheDifferingPart() {
        let cedar = "reading-assistant-enterprise-cedar-regional-preview-2026"
        let maple = "reading-assistant-enterprise-maple-regional-preview-2026"
        XCTAssertEqual(ArenaPresentationPolicy.compactModelNames([maple, "sample-pine", cedar, cedar]), [
            cedar: "…cedar-regional-preview-2026",
            maple: "…maple-regional-preview-2026"
        ])
    }

    func testCompactLeaderboardNamesFallBackWhenLabelsCollide() {
        let models = [
            "gpt-enterprise-x-mini-2026", "gpt-enterprise-x-pro-2026",
            "claude-enterprise-x-mini-2026", "claude-enterprise-x-ultra-2026",
            "…pro-2026"
        ]
        XCTAssertEqual(ArenaPresentationPolicy.compactModelNames(models), [
            "claude-enterprise-x-ultra-2026": "…ultra-2026"
        ])
    }

    func testScopeDrawsMissingPairsAndDirectionFollowLedgerOutcomes() {
        func slot(_ model: String, _ rank: JSONValue, status: JSONValue = "done") -> JSONValue {
            ["model": .string(model), "route": "route", "status": status, "rank": rank]
        }
        func record(_ id: String, mode: JSONValue, verdict: JSONValue, slots: [JSONValue]) -> JSONValue {
            ["v": 1, "id": .string(id), "ts": 100, "mode": mode, "verdict": verdict, "contestants": .array(slots)]
        }
        let records = [
            record("1", mode: "random", verdict: "ranked", slots: [slot("b", 2), slot("a", 1), slot("c", .null, status: "failed")]),
            record("2", mode: "chosen", verdict: "all_bad", slots: [slot("a", .null), slot("b", .null)]),
            record("3", mode: "random", verdict: "ranked", slots: [slot("a", 2), slot("b", 1)]),
        ]
        let all = ArenaPairMatrix(ArenaRanking.fold(records, mode: "all").comparisons)
        XCTAssertEqual(all["route::a", "route::b"], ArenaPairResult(wins: 1, losses: 1, draws: 1))
        XCTAssertNil(all["route::a", "route::c"])
        XCTAssertNil(all["route::a", "route::a"])
        let chosen = ArenaPairMatrix(ArenaRanking.fold(records, mode: "chosen").comparisons)
        XCTAssertEqual(chosen["route::b", "route::a"]?.sample, 1)
        XCTAssertEqual(chosen["route::b", "route::a"]?.winRate, 0)
        let directed = ArenaPairMatrix(ArenaRanking.fold(Array(records.prefix(1)), mode: "random").comparisons)
        XCTAssertEqual(directed["route::a", "route::b"]?.winRate, 1)
        XCTAssertEqual(directed["route::b", "route::a"]?.winRate, 0)
    }
}
