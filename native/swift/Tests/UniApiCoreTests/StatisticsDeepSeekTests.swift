import XCTest
@testable import UniApiCore

final class StatisticsDeepSeekTests: XCTestCase {
    private let at = 1_792_843_200_000.0
    private var usage: JSONValue { ["inputTokens": 10, "outputTokens": 20, "cacheReadTokens": 30, "cacheWriteTokens": 4, "reasoningTokens": 7] }
    private func header(_ id: String = "session", seed: Int = 0, depth: Int = 0) -> JSONValue {
        ["type": "session", "version": 0, "id": .string(id), "createdAt": .number(at),
         "cwd": "fixture-project", "seedLength": .number(Double(seed)), "delegationDepth": .number(Double(depth)), "parentSession": "parent"]
    }
    private func event(_ seq: Int, _ type: String, _ time: Double, _ data: JSONValue) -> JSONValue {
        ["type": .string(type), "seq": .number(Double(seq)), "time": .number(time), "data": data]
    }
    private func context() -> JSONValue {
        event(0, "request/header", at, ["header": ["config": ["provider": "fixture-provider", "model": "fixture-model", "reasoningEffort": "high"]]])
    }
    private func chunk(_ seq: Int, _ time: Double, _ body: JSONValue, turn: Int = 1, step: Int = 1) -> JSONValue {
        event(seq, "assistant/chunk", time, ["turn": .number(Double(turn)), "step": .number(Double(step)), "chunk": body])
    }
    private func message(_ seq: Int, _ time: Double, refs: JSONValue? = [1, 2, 3, 4], reported: JSONValue? = nil, turn: Int = 1) -> JSONValue {
        var row = event(seq, "assistant/message", time, ["turn": .number(Double(turn)), "step": 1,
            "message": ["id": "harness-message", "source": ["provider": "fixture-provider", "model": "routed-model"]],
            "usage": reported ?? usage])
        if let refs { row["sourceEventSeqs"] = refs }
        return row
    }
    private func complete(refs: JSONValue? = [1, 2, 3, 4], times: [Double]? = nil, finish: String = "stop", reported: JSONValue? = nil) -> [JSONValue] {
        let t = times ?? [at + 100, at + 200, at + 8_000, at + 8_100]
        return [header(), context(),
            chunk(1, t[0], ["type": "reasoning-delta", "index": 0, "text": "r"]),
            chunk(2, t[1], ["type": "text-delta", "index": 1, "text": "a"]),
            chunk(3, t[2], ["type": "usage", "usage": usage]),
            chunk(4, t[3], ["type": "finish", "reason": ["kind": .string(finish)]]),
            message(5, at + 9_000, refs: refs, reported: reported)]
    }
    private func read(_ lines: [JSONValue]) throws -> StatisticsReadResult {
        let reader = StatisticsDeepSeekReader()
        for line in lines { try reader.push(line) }
        return try reader.finish()
    }

    func testDisjointBucketsNativeReplacementAndRawClockExcludeCompletionTailAndTools() throws {
        var rows = complete()
        rows.append(event(6, "tool/call", at + 10_000, ["callId": "tool"]))
        rows.append(event(7, "tool/result", at + 900_000, ["callId": "tool"]))
        let result = try read(rows), row = try XCTUnwrap(result.records.first)
        XCTAssertEqual(result.records.count, 1); XCTAssertEqual(result.excluded, 0)
        XCTAssertEqual(row.id, "dsh:session:1:1"); XCTAssertEqual(row.source, "dsh")
        XCTAssertEqual(row.input, 10); XCTAssertEqual(row.output, 20)
        XCTAssertEqual(row.cacheRead, 30); XCTAssertEqual(row.cacheWrite, 4); XCTAssertEqual(row.grand, 64)
        XCTAssertEqual(row.thinking, 7); XCTAssertEqual(row.model, "routed-model"); XCTAssertEqual(row.effort, "high")
        XCTAssertEqual(row.streamDurationMs, 100); XCTAssertEqual(row.streamOutputTokens, 20)
        XCTAssertEqual(row.streamTiming, "dsh-host-chunk-clock")
        XCTAssertNil(row.durationMs); XCTAssertNil(row.timing)
    }

    func testOnlySuccessfulRetryCitationsSupplyStreamTiming() throws {
        let rows: [JSONValue] = [header(), context(),
            chunk(1, at + 1, ["type": "text-delta", "index": 0, "text": "failed"]),
            chunk(2, at + 2, ["type": "usage", "usage": ["inputTokens": 1, "outputTokens": 4]]),
            chunk(3, at + 3, ["type": "finish", "reason": ["kind": "error"]]),
            chunk(4, at + 100_000, ["type": "reasoning-delta", "index": 0, "text": "r"]),
            chunk(5, at + 100_050, ["type": "tool-call-delta", "index": 1, "id": "call", "argumentsDelta": "{}"]),
            chunk(6, at + 110_000, ["type": "usage", "usage": usage]),
            chunk(7, at + 110_001, ["type": "finish", "reason": ["kind": "tool-calls"]]),
            message(8, at + 120_000, refs: [4, 5, 6, 7])]
        let result = try read(rows)
        XCTAssertEqual(result.records.count, 1); XCTAssertEqual(result.records[0].output, 20)
        XCTAssertEqual(result.records[0].streamDurationMs, 50)
        var crossed = rows; crossed[crossed.count - 1]["sourceEventSeqs"] = [1, 4, 5, 6, 7]
        XCTAssertNil(try read(crossed).records[0].streamDurationMs)
    }

    func testAllThreePackedRowKindsRecoverExactUnpackedClocks() throws {
        let packed: [JSONValue] = [header(), context(),
            ["type": "text-chunks", "seq0": 1, "time0": .number(at + 10),
             "data": ["turn": 1, "step": 1, "index": 0, "dt": [10, 20], "texts": ["a", "", "b"]]],
            ["type": "reasoning-chunks", "seq0": 4, "time0": .number(at + 50),
             "data": ["turn": 1, "step": 1, "index": 1, "dt": [10], "texts": ["r", "s"]]],
            ["type": "tool-call-chunks", "seq0": 6, "time0": .number(at + 70),
             "data": ["turn": 1, "step": 1, "index": 2, "id": "call", "name": "fixture", "dt": [10], "args": ["{", "}"]]],
            chunk(8, at + 90, ["type": "usage", "usage": usage]),
            chunk(9, at + 100, ["type": "finish", "reason": ["kind": "max-tokens"]]),
            message(10, at + 200, refs: [1, 2, 3, 4, 5, 6, 7, 8, 9])]
        let plain: [JSONValue] = [header(), context(),
            chunk(1, at + 10, ["type": "text-delta", "index": 0, "text": "a"]),
            chunk(2, at + 20, ["type": "text-delta", "index": 0, "text": ""]),
            chunk(3, at + 40, ["type": "text-delta", "index": 0, "text": "b"]),
            chunk(4, at + 50, ["type": "reasoning-delta", "index": 1, "text": "r"]),
            chunk(5, at + 60, ["type": "reasoning-delta", "index": 1, "text": "s"]),
            chunk(6, at + 70, ["type": "tool-call-delta", "index": 2, "id": "call", "argumentsDelta": "{"]),
            chunk(7, at + 80, ["type": "tool-call-delta", "index": 2, "id": "call", "argumentsDelta": "}"]),
            chunk(8, at + 90, ["type": "usage", "usage": usage]),
            chunk(9, at + 100, ["type": "finish", "reason": ["kind": "max-tokens"]]),
            message(10, at + 200, refs: [1, 2, 3, 4, 5, 6, 7, 8, 9])]
        let a = try read(packed), b = try read(plain)
        XCTAssertEqual(a.records[0].streamDurationMs, 70)
        XCTAssertEqual(try JSONValue.decode(JSONEncoder().encode(a.records)), try JSONValue.decode(JSONEncoder().encode(b.records)))
    }

    func testForkBoundaryExcludesInheritedUsageButResumeMarkerDoesNotHideOwnedWork() throws {
        let rows: [JSONValue] = [header("child", seed: 3), context(),
            chunk(1, at + 1, ["type": "usage", "usage": usage]),
            message(2, at + 2, refs: []),
            chunk(3, at + 3, ["type": "usage", "usage": usage], turn: 2),
            event(4, "session/end-seed", at + 4, [:]),
            chunk(5, at + 5, ["type": "usage", "usage": usage], turn: 3)]
        let a = try read(rows), b = try read(rows)
        XCTAssertEqual(a.records.map(\.id), ["dsh:child:2:1", "dsh:child:3:1"])
        XCTAssertEqual(a.records.map(\.id), b.records.map(\.id))
        XCTAssertTrue(a.records.allSatisfy { !$0.sidechain && $0.model == "fixture-model" })
        var delegated = complete(); delegated[0] = header(depth: 2)
        XCTAssertTrue(try read(delegated).records[0].sidechain)
    }

    func testMissingDuplicateForeignAndIncompleteReferencesKeepUsageUntimed() throws {
        let refs: [JSONValue?] = [nil, [], [1, 1, 3, 4], [2, 1, 3, 4], [1, 2, 4], [1, 2, 3, 99]]
        for reference in refs {
            let row = try XCTUnwrap(try read(complete(refs: reference)).records.first)
            XCTAssertEqual(row.output, 20); XCTAssertNil(row.streamDurationMs); XCTAssertNil(row.streamOutputTokens)
        }
        var foreign = complete()
        foreign[3]["data"]["turn"] = 2
        XCTAssertNil(try read(foreign).records[0].streamDurationMs)
        let incomplete = Array(complete().prefix(5))
        let row = try XCTUnwrap(try read(incomplete).records.first)
        XCTAssertEqual(row.output, 20); XCTAssertNil(row.streamDurationMs)
    }

    func testIncompleteForkPrefixRefusesEmptyButCompleteSeedOnlyLogIsEmpty() throws {
        let reader = StatisticsDeepSeekReader()
        try reader.push(header("child", seed: 3))
        try reader.push(context())
        try reader.push(chunk(1, at + 1, ["type": "usage", "usage": usage]))
        XCTAssertThrowsError(try reader.finish())
        try reader.push(message(2, at + 2, refs: []))
        let complete = try reader.finish()
        XCTAssertTrue(complete.records.isEmpty)
        XCTAssertEqual(complete.excluded, 0)
    }

    func testInvalidOrSingleClockAndFailedFinishNeverBorrowResponseDuration() throws {
        for times in [[at + 100, at + 100, at + 300, at + 400],
                      [at + 200, at + 100, at + 300, at + 400],
                      [0, at + 100, at + 300, at + 400]] {
            let row = try XCTUnwrap(try read(complete(times: times)).records.first)
            XCTAssertEqual(row.output, 20); XCTAssertNil(row.streamDurationMs); XCTAssertNil(row.durationMs)
        }
        for reason in ["error", "aborted"] {
            let row = try XCTUnwrap(try read(complete(finish: reason)).records.first)
            XCTAssertEqual(row.output, 20); XCTAssertNil(row.streamTiming)
        }
        var changed = usage; changed["outputTokens"] = 21
        let row = try XCTUnwrap(try read(complete(reported: changed)).records.first)
        XCTAssertEqual(row.output, 21); XCTAssertNil(row.streamDurationMs)
    }

    func testMalformedAndUnknownPackedRowsPoisonReaderInsteadOfReturningAnEmptySuccess() throws {
        let valid: JSONValue = ["type": "text-chunks", "seq0": 0, "time0": .number(at),
            "data": ["turn": 1, "step": 1, "index": 0, "dt": [1, 1], "texts": ["a", "b", "c"]]]
        var malformed: [JSONValue] = []
        var row = valid; row["type"] = "future-chunks"; malformed.append(row)
        row = valid; row["data"]["dt"] = [1]; malformed.append(row)
        row = valid; row["data"]["dt"] = [1, "2"]; malformed.append(row)
        row = valid; row["data"]["texts"] = ["a", true, "c"]; malformed.append(row)
        row = valid; row["data"]["extra"] = 1; malformed.append(row)
        row = valid; row["version"] = 1; malformed.append(row)
        row = valid; row["time0"] = 9_007_199_254_740_991; malformed.append(row)
        malformed.append(event(1, "future/event", at, [:]))
        for bad in malformed {
            let reader = StatisticsDeepSeekReader(); try reader.push(header())
            XCTAssertThrowsError(try reader.push(bad)); XCTAssertThrowsError(try reader.finish())
        }
        let reader = StatisticsDeepSeekReader()
        XCTAssertThrowsError(try reader.finish())
        var version = header(); version["version"] = 1
        XCTAssertThrowsError(try reader.push(version))
    }

    func testUnknownOrdinaryEventsAndInvalidUsageAreVisibleWithoutPayloadRetention() throws {
        let reader = StatisticsDeepSeekReader(); try reader.push(header())
        try reader.push(event(0, "future/event", at, "ignored"))
        try reader.push(chunk(1, at + 1, ["type": "usage", "usage": usage]))
        var invalid = usage; invalid["outputTokens"] = "20"
        try reader.push(chunk(2, at + 2, ["type": "usage", "usage": invalid], turn: 2))
        let a = try reader.finish(), b = try reader.finish()
        XCTAssertEqual(a.records.count, 1); XCTAssertEqual(a.excluded, 1)
        XCTAssertEqual(a.records.map(\.id), b.records.map(\.id)); XCTAssertEqual(a.excluded, b.excluded)
        let zero = try read([header(), chunk(0, at, ["type": "usage", "usage": usage]),
            chunk(1, at + 1, ["type": "usage", "usage": ["inputTokens": 0, "outputTokens": 0]])])
        XCTAssertTrue(zero.records.isEmpty); XCTAssertEqual(zero.excluded, 1)
        var excessive = usage; excessive["reasoningTokens"] = 200
        let clamped = try read([header(), chunk(0, at, ["type": "usage", "usage": excessive])])
        XCTAssertEqual(clamped.records[0].thinking, 20)
    }
}
