import Foundation
import XCTest
@testable import UniApiCore

final class ArenaPresentationG3AcceptanceTests: XCTestCase {
    func testInterleavedCategoriesKeepFirstSeenOrderAndCompletePresetPayloads() {
        let presets: [JSONValue] = [
            ["id": "custom-first", "category": "custom", "title": "Same title", "prompt": "User task", "builtin": false],
            ["id": "web-first", "category": "web", "title": "Same title", "prompt": "Built-in task", "builtin": true],
            ["id": "custom-second", "category": "custom", "title": "Second", "prompt": "Exact\nmultiline task", "builtin": false],
            ["id": "cli-first", "category": "cli", "title": "CLI", "prompt": "CLI task", "builtin": true],
            ["id": "web-second", "category": "web", "title": "Web", "prompt": "Web task", "builtin": false]
        ]
        let groups = ArenaPresentationPolicy.presetGroups(presets)
        XCTAssertEqual(groups.map(\.title), ["custom", "web", "cli"])
        XCTAssertEqual(groups.map { $0.presets.map { $0["id"].string } }, [["custom-first", "custom-second"], ["web-first", "web-second"], ["cli-first"]])
        XCTAssertEqual(groups[0].presets, [presets[0], presets[2]])
        XCTAssertEqual(groups[1].presets, [presets[1], presets[4]])
        XCTAssertEqual(groups[2].presets, [presets[3]])
        XCTAssertEqual(Set(groups.map(\.id)).count, 3)
    }

    func testCategoryMovesAndDeletionsRebuildGroupsWithoutReseedingOrEmptyCards() {
        var presets: [JSONValue] = [["id": "one", "category": "web", "builtin": true], ["id": "two", "category": "web"], ["id": "three", "category": "cli"]]
        presets[0]["category"] = "cli"
        presets.remove(at: 1)
        let groups = ArenaPresentationPolicy.presetGroups(presets)
        XCTAssertEqual(groups.map(\.category), ["cli"])
        XCTAssertEqual(groups[0].presets.map { $0["id"].string }, ["one", "three"])
        XCTAssertTrue(ArenaPresentationPolicy.presetGroups([]).isEmpty)
    }

    func testCategoryLabelsRemainExactAndMissingCategoryHasVisibleFallback() {
        let groups = ArenaPresentationPolicy.presetGroups([
            ["id": "a", "category": "Web"], ["id": "b", "category": "web"], ["id": "c"],
            ["id": "d", "category": "caf\u{00e9}"], ["id": "e", "category": "cafe\u{0301}"]
        ])
        XCTAssertEqual(groups.map(\.title), ["Web", "web", "Uncategorized", "caf\u{00e9}", "cafe\u{0301}"])
        XCTAssertEqual(Set(groups.map(\.id)).count, 5)
        XCTAssertEqual(groups.map { $0.presets.count }, [1, 1, 1, 1, 1])
    }

    func testRecentVerdictAgeUsesLedgerMillisecondsAndWebRoundingBoundaries() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (elapsed, expected) in [(0.0, "just now"), (44_999, "just now"), (45_000, "1 min ago"), (90_000, "2 min ago"), (3_599_999, "60 min ago"), (3_600_000, "1 h ago"), (5_400_000, "2 h ago"), (86_399_999, "24 h ago"), (86_400_000, "1 d ago"), (129_600_000, "2 d ago"), (-60_000, "just now")] {
            XCTAssertEqual(ArenaPresentationPolicy.verdictAge(.number(now.timeIntervalSince1970 * 1000 - elapsed), now: now), expected, "elapsed milliseconds: \(elapsed)")
        }
        let invalidTimestamps: [JSONValue] = [.null, "1800000000000", .number(.nan), .number(.infinity)]
        for invalid in invalidTimestamps {
            XCTAssertEqual(ArenaPresentationPolicy.verdictAge(invalid, now: now), "Time unavailable")
        }
    }

    func testRecentMetadataRetainsCategoryModeVerdictAndVoterAsClockAdvances() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var record: JSONValue = ["ts": .number(now.timeIntervalSince1970 * 1000 - 60_000), "mode": "chosen", "category": "reasoning", "verdict": "ranked", "voter": "fixture-voter"]
        XCTAssertEqual(ArenaPresentationPolicy.recentVerdictMetadata(record, now: now), "1 min ago · chosen · reasoning · ranked · fixture-voter")
        XCTAssertEqual(ArenaPresentationPolicy.recentVerdictMetadata(record, now: now.addingTimeInterval(3_600)), "1 h ago · chosen · reasoning · ranked · fixture-voter")
        record["category"] = .null; record["verdict"] = "all_bad"
        XCTAssertEqual(ArenaPresentationPolicy.recentVerdictMetadata(record, now: now), "1 min ago · chosen · all_bad · fixture-voter")
    }
}
