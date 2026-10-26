import Foundation
import XCTest
@testable import UniApiCore

final class StatisticsCachedRecordColumnsAcceptanceTests: XCTestCase {
    func testActualSQLiteStorageClassesKeepCompleteLegacyRecord() throws {
        let db = try NativeDatabase()
        let sql = """
        SELECT 'fixture/path' AS path, 'message' AS msg_id, 'codex' AS source,
               1792000854309.125 AS ts, 'model' AS model, 'project' AS project,
               'session' AS session, 1 AS sidechain, 'high' AS effort,
               9007199254740993 AS input, 0.1 AS output, -0.0 AS thinking,
               '23.5' AS cache_write, X'00FF' AS cache_read, NULL AS web_search,
               7 AS web_fetch, '2026-10-14' AS raw_day, 12.125 AS duration_ms,
               CAST(X'74696D65007461696C' AS TEXT) AS timing, 'ignored' AS future_column
        """
        let (path, result) = try compareSQLite(db, sql)
        XCTAssertEqual(path, "fixture/path")
        XCTAssertEqual(result.source, "codex")
        XCTAssertEqual(result.input.bitPattern, Double(9_007_199_254_740_992).bitPattern)
        XCTAssertEqual(result.cacheWrite, 23.5)
        XCTAssertEqual(result.cacheRead, 0)
        XCTAssertEqual(result.webSearch, 0)
        XCTAssertEqual(result.durationMs, 12.125)
        XCTAssertEqual(result.timing, "time")
        XCTAssertTrue(result.sidechain)
    }

    func testLegacyMissingColumnsAndNullOptionalsKeepOriginalDefaults() throws {
        let db = try NativeDatabase()
        let (_, legacy) = try compareSQLite(db, "SELECT 'old' AS path, 'm' AS msg_id, 1 AS ts, 'model' AS model")
        XCTAssertEqual(legacy.source, "")
        XCTAssertEqual(legacy.project, "")
        XCTAssertEqual(legacy.session, "")
        XCTAssertFalse(legacy.sidechain)
        XCTAssertNil(legacy.durationMs)
        XCTAssertNil(legacy.timing)
        for duration in ["NULL", "0", "'0'", "''", "12.5"] {
            for timing in ["NULL", "''", "'response'", "7"] {
                let (_, record) = try compareSQLite(db, "SELECT \(duration) AS duration_ms, \(timing) AS timing")
                XCTAssertEqual(record.durationMs == nil, duration == "NULL")
                XCTAssertEqual(record.timing == nil, timing == "NULL")
                XCTAssertEqual(record.project, "")
            }
        }
        var rows = 0, headers = 0
        try db.forEachValueRow("SELECT 'unused' AS future_column WHERE 0", columns: { names in
            headers += 1
            let columns = StatisticsCachedRecordColumns(names)
            XCTAssertEqual(columns.path(in: []), "")
            assertRecord(columns.usage(in: []), original([:]))
        }) { _ in rows += 1 }
        XCTAssertEqual(headers, 1)
        XCTAssertEqual(rows, 0)
    }

    func testHeaderOrderDuplicatesAndNewStatementsResolveWithoutStaleIndices() throws {
        let db = try NativeDatabase()
        let queries = [
            "SELECT 'first' AS path, 'last' AS path, 1 AS input, 23 AS input, 'old' AS model, 'new' AS model",
            "SELECT 'new' AS model, 'last' AS path, 23 AS input, 'unrelated' AS extra",
            "SELECT NULL AS model, NULL AS path, NULL AS input, 1 AS sidechain",
            "SELECT 12 AS unknown, 99 AS \"\""
        ]
        let first = try compareSQLite(db, queries[0])
        XCTAssertEqual(first.0, "last")
        XCTAssertEqual(first.1.model, "new")
        XCTAssertEqual(first.1.input, 23)
        for sql in queries.dropFirst() { _ = try compareSQLite(db, sql) }
        let names = ["model", "path", "model", "input", "input", "duration_ms"]
        let values: [JSONValue] = ["old", "p", "new", 1, 2, .null]
        let plan = StatisticsCachedRecordColumns(names)
        XCTAssertEqual(plan.path(in: values), "p")
        assertRecord(plan.usage(in: values), original(dictionary(names, values)))
        XCTAssertEqual(plan.usage(in: values).model, "new")
        XCTAssertEqual(plan.usage(in: values).input, 2)
        let empty = StatisticsCachedRecordColumns([])
        assertRecord(empty.usage(in: values), original([:]))
    }

    func testEveryScalarCoercionAndNumericBitMatchesLiteralPreviousDecoder() {
        let names = ["path", "msg_id", "source", "ts", "model", "project", "session", "sidechain", "effort",
                     "input", "output", "thinking", "cache_write", "cache_read", "web_search", "web_fetch", "raw_day", "duration_ms", "timing"]
        let plan = StatisticsCachedRecordColumns(names)
        let variants: [JSONValue] = [.null, .number(-0.0), .number(0.1), .number(Double.leastNonzeroMagnitude),
            .number(Double.greatestFiniteMagnitude), .number(Double.infinity), .number(-Double.infinity),
            .number(Double.nan), .string("123.25"), .string("-0.0"), .string("not a number"), .string(""),
            .bool(true), .bool(false), .array([1]), .object(["value": 1])]
        for (column, name) in names.enumerated() {
            for variant in variants {
                var values: [JSONValue] = ["p", "id", "codex", 1792000854309.125, "model", "project", "session", 1, "high",
                                         1, 2, 3, 4, 5, 6, 7, "2026-10-14", 12.125, "response"]
                values[column] = variant
                let row = dictionary(names, values)
                XCTAssertEqual(plan.path(in: values), JSONValue.object(row)["path"].string, name)
                assertRecord(plan.usage(in: values), original(row), name)
            }
        }
    }

    // Literal cached-record decoder from the preceding production service. It
    // deliberately uses the dictionary API and never calls the new column plan.
    private func original(_ row: JSONObject) -> StatisticsUsage {
        let r = JSONValue.object(row)
        var e = StatisticsUsage(id: r["msg_id"].string, source: r["source"].string, ts: r["ts"].double, model: r["model"].string)
        e.project = r["project"].string; e.session = r["session"].string; e.sidechain = r["sidechain"].int == 1; e.effort = r["effort"].string
        e.input = r["input"].double; e.output = r["output"].double; e.thinking = r["thinking"].double; e.cacheWrite = r["cache_write"].double; e.cacheRead = r["cache_read"].double; e.webSearch = r["web_search"].double; e.webFetch = r["web_fetch"].double
        e.rawDay = r["raw_day"].string; e.durationMs = r["duration_ms"].isNull ? nil : r["duration_ms"].double; e.timing = r["timing"].isNull ? nil : r["timing"].string
        return e
    }

    private func dictionary(_ names: [String], _ values: [JSONValue]) -> JSONObject {
        var row: JSONObject = [:]
        for (name, value) in zip(names, values) { row[name] = value }
        return row
    }

    private func compareSQLite(_ db: NativeDatabase, _ sql: String, file: StaticString = #filePath, line: UInt = #line) throws -> (String, StatisticsUsage) {
        let old = try XCTUnwrap(db.query(sql).first, file: file, line: line)
        var plan = StatisticsCachedRecordColumns([]), result: (String, StatisticsUsage)?
        try db.forEachValueRow(sql, columns: { plan = StatisticsCachedRecordColumns($0) }) { values in
            XCTAssertNil(result, file: file, line: line)
            result = (plan.path(in: values), plan.usage(in: values))
        }
        let found = try XCTUnwrap(result, file: file, line: line)
        XCTAssertEqual(found.0, JSONValue.object(old)["path"].string, file: file, line: line)
        assertRecord(found.1, original(old), sql, file: file, line: line)
        return found
    }

    private func assertRecord(_ a: StatisticsUsage, _ b: StatisticsUsage, _ context: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual([a.id, a.source, a.model, a.project, a.session, a.effort, a.rawDay],
                       [b.id, b.source, b.model, b.project, b.session, b.effort, b.rawDay], context, file: file, line: line)
        XCTAssertEqual(a.sidechain, b.sidechain, context, file: file, line: line)
        XCTAssertEqual(a.timing, b.timing, context, file: file, line: line)
        XCTAssertEqual(a.durationMs?.bitPattern, b.durationMs?.bitPattern, context, file: file, line: line)
        let left = [a.ts, a.input, a.output, a.thinking, a.cacheWrite, a.cacheRead, a.webSearch, a.webFetch, a.grand]
        let right = [b.ts, b.input, b.output, b.thinking, b.cacheWrite, b.cacheRead, b.webSearch, b.webFetch, b.grand]
        XCTAssertEqual(left.map(\.bitPattern), right.map(\.bitPattern), context, file: file, line: line)
    }
}
