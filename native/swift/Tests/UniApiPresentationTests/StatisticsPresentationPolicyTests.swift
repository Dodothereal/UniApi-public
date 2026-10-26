import XCTest
import UniApiCore
@testable import UniApiPresentation

final class StatisticsPresentationPolicyTests: XCTestCase {
    func testDeepSeekHarnessNoticesStayScopedWithoutChangingTheOlderFourSources() {
        var payload: JSONValue = ["source": "dsh", "scan": ["codexExcluded": 7, "antigravityExcluded": 10, "zcodeExcluded": 8, "opencodeExcluded": 9, "dshExcluded": 3]]
        XCTAssertEqual(NativeStatsPresentationPolicy.excludedNotices(payload, detail: false), [.init(source: "dsh", count: 3)])
        payload["source"] = "all"
        XCTAssertEqual(NativeStatsPresentationPolicy.excludedNotices(payload, detail: false).map(\.source), ["codex", "antigravity", "zcode", "opencode", "dsh"])
        XCTAssertTrue(NativeStatsPresentationPolicy.excludedNotices(payload, detail: true).isEmpty)
    }

    func testSourceSpecificNoticesDoNotMixUnrelatedAppCounts() {
        var payload: JSONValue = ["source": "codex", "scan": ["codexExcluded": 327, "antigravityExcluded": 454, "zcodeExcluded": 162, "opencodeExcluded": 1540]]
        XCTAssertEqual(NativeStatsPresentationPolicy.excludedNotices(payload, detail: false), [.init(source: "codex", count: 327)])
        payload["source"] = "all"
        let all = NativeStatsPresentationPolicy.excludedNotices(payload, detail: false)
        XCTAssertEqual(all.map(\.source), ["codex", "antigravity", "zcode", "opencode"])
        XCTAssertEqual(all.map(\.count), [327, 454, 162, 1540])
        XCTAssertTrue(NativeStatsPresentationPolicy.excludedNotices(payload, detail: true).isEmpty)
        payload["source"] = "claude"
        XCTAssertTrue(NativeStatsPresentationPolicy.excludedNotices(payload, detail: false).isEmpty)
        payload["source"] = "unknown"
        XCTAssertTrue(NativeStatsPresentationPolicy.excludedNotices(payload, detail: false).isEmpty)
    }

    func testInvalidOrEmptyNoticeCountsDoNotBecomeMisleadingRecords() {
        let payload: JSONValue = ["source": "all", "scan": ["codexExcluded": -1, "antigravityExcluded": .number(.infinity), "zcodeExcluded": 1.5, "opencodeExcluded": 0]]
        XCTAssertTrue(NativeStatsPresentationPolicy.excludedNotices(payload, detail: false).isEmpty)
        XCTAssertTrue(NativeStatsPresentationPolicy.excludedNotices(["source": "all"], detail: false).isEmpty)
    }

    func testProgressStageDoesNotReuseTheFileCounterAsCompletion() {
        var value: JSONValue = ["phase": "reading", "done": 7, "total": 7]
        XCTAssertEqual(NativeStatsPresentationPolicy.progressText(value), "Reading local usage records · 7/7 files")
        value["phase"] = "assembling"
        XCTAssertEqual(NativeStatsPresentationPolicy.progressText(value), "Rebuilding usage summary…")
        value["phase"] = "folding"
        XCTAssertEqual(NativeStatsPresentationPolicy.progressText(value), "Updating usage totals…")
        value["phase"] = "complete"
        XCTAssertEqual(NativeStatsPresentationPolicy.progressText(value), "Loading selected statistics…")
        value["phase"] = "loading"
        XCTAssertEqual(NativeStatsPresentationPolicy.progressText(value), "Loading selected statistics…")
        value["phase"] = "discovering"
        XCTAssertEqual(NativeStatsPresentationPolicy.progressText(value), "Finding local usage records…")
        value["phase"] = "reading"; value["status"] = "failed"
        XCTAssertEqual(NativeStatsPresentationPolicy.progressText(value), "Usage refresh did not finish.")
    }

    func testMalformedProgressNeverDisplaysAnImpossibleFileRatio() {
        let malformed: [JSONValue] = [
            ["phase": "reading", "done": 8, "total": 7],
            ["phase": "reading", "done": -1, "total": 7],
            ["phase": "reading", "done": 1.5, "total": 7],
            ["phase": "reading", "done": .number(.nan), "total": 7],
            ["phase": "reading", "done": 1, "total": .number(.infinity)]
        ]
        for value in malformed {
            XCTAssertEqual(NativeStatsPresentationPolicy.progressText(value), "Reading local usage records…")
        }
        XCTAssertEqual(NativeStatsPresentationPolicy.progressText(["done": 5, "total": 7]), "Reading local usage records · 5/7 files")
    }
}
