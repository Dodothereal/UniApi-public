import XCTest
import UniApiCore
@testable import UniApiPresentation

final class StatisticsThroughputPresentationTests: XCTestCase {
    private let response: JSONValue = ["avgTps": 9, "timedResponses": 1, "totalResponses": 3, "outputTokens": 99, "durationMs": 11000, "estimatedResponses": 1]
    private let streaming: JSONValue = ["avgTps": 99, "timedResponses": 1, "totalResponses": 3, "outputTokens": 99, "durationMs": 1000, "estimatedResponses": 0]

    func testStreamingSelectionNeverFallsBackToResponseDurationOrRate() {
        var throughput: JSONValue = ["summary": response, "harnesses": [["source": "codex", "avgTps": 9]]]
        XCTAssertTrue(NativeStatsRateMetric.streaming.board(throughput).isNull)
        XCTAssertNil(NativeStatsThroughputPresentation.rate(NativeStatsRateMetric.streaming.board(throughput)["summary"]))
        XCTAssertTrue(NativeStatsThroughputPresentation.streamingSource(throughput, source: "codex").isNull)
        throughput["streaming"] = ["summary": streaming, "harnesses": [["source": "dsh", "avgTps": 99]]]
        XCTAssertEqual(NativeStatsThroughputPresentation.rate(NativeStatsRateMetric.streaming.board(throughput)["summary"]), 99)
        XCTAssertEqual(NativeStatsThroughputPresentation.rate(NativeStatsRateMetric.response.board(throughput)["summary"]), 9)
        XCTAssertEqual(NativeStatsThroughputPresentation.rate(NativeStatsThroughputPresentation.streamingSource(throughput, source: "dsh")), 99)
        XCTAssertTrue(NativeStatsThroughputPresentation.streamingSource(throughput, source: "codex").isNull)
    }

    func testCoverageKeepsUnknownStreamingClocksSeparateFromResponseEstimates() {
        XCTAssertEqual(NativeStatsRateMetric.streaming.coverage(streaming), "1 / 3 streaming-timed · 2 unknown")
        XCTAssertEqual(NativeStatsRateMetric.response.coverage(response), "1 / 3 timed · 1 estimated")
        XCTAssertEqual(NativeStatsRateMetric.streaming.coverage(.null), "Streaming timing unavailable")
        XCTAssertEqual(NativeStatsRateMetric.streaming.coverage(["timedResponses": 4, "totalResponses": 3]), "Streaming timing unavailable")
        XCTAssertTrue(NativeStatsRateMetric.streaming.caption.contains("Historical Codex/Claude"))
        XCTAssertTrue(NativeStatsRateMetric.streaming.caption.contains("host-observed arrivals"))
        XCTAssertTrue(NativeStatsRateMetric.streaming.caption.contains("reported stream duration"))
    }

    func testRateRejectsMissingMalformedOrNonfiniteValuesInsteadOfDisplayingZero() {
        let invalid: [JSONValue] = [.null, "99", .number(.nan), .number(.infinity), -1]
        for value in invalid {
            XCTAssertNil(NativeStatsThroughputPresentation.rate(["avgTps": value]))
        }
        XCTAssertEqual(NativeStatsThroughputPresentation.rate(["avgTps": 0]), 0)
    }

    func testTimingDetailsNameTheMatchingDenominatorAndSecondaryLatency() {
        let raw = NativeStatsRateMetric.streaming.timingDetail(streaming)
        XCTAssertTrue(raw.contains("99 output tokens over 1.0 streaming seconds"))
        XCTAssertFalse(raw.contains("11.0 streaming seconds"))
        let secondary = NativeStatsRateMetric.response.timingDetail(response)
        XCTAssertTrue(secondary.contains("99 output tokens over 11.0 response seconds"))
        XCTAssertTrue(secondary.contains("including request latency"))
        XCTAssertTrue(secondary.contains("estimated"))
    }
}
