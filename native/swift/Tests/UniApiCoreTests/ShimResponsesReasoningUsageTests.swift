import Foundation
import XCTest
@testable import UniApiCore

final class ShimResponsesReasoningUsageTests: XCTestCase {
    private final class Clock { var now = 0.0 }
    private func stream() throws -> ShimResponsesStream {
        ShimResponsesStream(model: "fixture-model", tools: try ShimToolMap([:]))
    }
    private func terminalUsage(_ stream: inout ShimResponsesStream) throws -> JSONValue {
        try XCTUnwrap(stream.finish().first { $0.event == "response.completed" }).data["response"]["usage"]
    }
    private func usage(_ output: JSONValue, _ reasoning: JSONValue) -> JSONValue {
        ["usage": ["prompt_tokens": 7, "completion_tokens": output, "completion_tokens_details": ["reasoning_tokens": reasoning]]]
    }

    func testExplicitReasoningIncludingZeroIsForwardedWithoutChangingTotal() throws {
        for count in [0, 4] {
            var translated = try stream()
            _ = translated.feedOpenAI(usage(10, .number(Double(count))))
            let result = try terminalUsage(&translated)
            XCTAssertEqual(result["input_tokens"], 7)
            XCTAssertEqual(result["output_tokens"], 10)
            XCTAssertEqual(result["total_tokens"], 17)
            XCTAssertEqual(result["output_tokens_details"]["reasoning_tokens"], .number(Double(count)))
        }
    }
    func testMissingInvalidOrStaleReasoningIsNotInvented() throws {
        let invalid: [JSONValue] = [.null, .number(-1), .number(1.5), .number(11), .bool(true), .string("4")]
        for value in invalid {
            var translated = try stream()
            _ = translated.feedOpenAI(usage(10, value))
            let result = try terminalUsage(&translated)
            XCTAssertEqual(result["output_tokens"], 10)
            XCTAssertTrue(result["output_tokens_details"].isNull)
        }
        for output in [JSONValue.string("10"), .number(10.5), .number(-1)] {
            var translated = try stream()
            _ = translated.feedOpenAI(usage(output, 4))
            XCTAssertTrue(try terminalUsage(&translated)["output_tokens_details"].isNull)
        }
        var absent = try stream()
        _ = absent.feedOpenAI(["usage": ["completion_tokens": 10]])
        _ = absent.feedOpenAI(["usage": ["completion_tokens_details": ["reasoning_tokens": 4]]])
        XCTAssertTrue(try terminalUsage(&absent)["output_tokens_details"].isNull)
        var changed = try stream()
        _ = changed.feedOpenAI(usage(10, 4))
        _ = changed.feedOpenAI(["usage": ["completion_tokens": 12]])
        let result = try terminalUsage(&changed)
        XCTAssertEqual(result["output_tokens"], 12)
        XCTAssertTrue(result["output_tokens_details"].isNull)
    }
    func testAnthropicUsageRemainsWithoutInventedReasoningDetail() throws {
        var translated = try stream()
        _ = translated.feedAnthropic(["type": "message_start", "message": ["usage": ["input_tokens": 7]]])
        _ = translated.feedAnthropic(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 10]])
        let result = try terminalUsage(&translated)
        XCTAssertEqual(result["output_tokens"], 10)
        XCTAssertTrue(result["output_tokens_details"].isNull)
    }
    func testTranslatedTerminalAndSyntheticCodexUsageMatchObserverCounters() throws {
        let clock = Clock(), model = "uniapi/example/model"
        var translated = try stream()
        var frames = translated.feedOpenAI(["choices": [["delta": ["content": "first"]]]])
        frames += translated.feedOpenAI(["choices": [["delta": ["content": "second"], "finish_reason": "stop"]]])
        frames += translated.feedOpenAI(usage(10, 4))
        frames += translated.finish()
        var observer = NativeCodexStreamTimingObserver(requestedModel: model, uptime: { clock.now })
        for frame in frames { clock.now += 1; observer.feedDelivered(try frame.encoded()) }
        let observation = try XCTUnwrap(observer.finish(success: true, completedAt: 1234))
        let terminal = try XCTUnwrap(frames.first { $0.event == "response.completed" }).data["response"]
        let output = terminal["usage"]["output_tokens"], reasoning = terminal["usage"]["output_tokens_details"]["reasoning_tokens"]
        let reader = StatisticsCodexReader()
        reader.push(["type": "turn_context", "payload": ["turn_id": "turn", "model": .string(model)]])
        // This fixture exercises the transcript shape, not the Codex CLI itself.
        reader.push(["type": "token_usage_record", "timestamp": "2026-10-28T12:00:00Z", "payload": ["turn_id": "turn", "response_id": terminal["id"], "usage": ["input_tokens": 7, "output_tokens": output, "reasoning_output_tokens": reasoning]]])
        let record = try XCTUnwrap(reader.finish().records.first)
        let measured = try XCTUnwrap(StatisticsNativeStreamTiming.applying(observation, to: record))
        XCTAssertEqual(measured.output, 10); XCTAssertEqual(measured.thinking, 4)
        XCTAssertEqual(measured.streamOutputTokens, 6)
    }
}
