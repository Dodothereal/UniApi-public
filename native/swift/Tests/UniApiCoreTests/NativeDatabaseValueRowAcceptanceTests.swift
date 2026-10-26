import Dispatch
import Foundation
import XCTest
@testable import UniApiCore

final class NativeDatabaseValueRowAcceptanceTests: XCTestCase {
    func testValueRowsPreserveFiveStorageClassesDuplicateAliasesAndBindings() throws {
        let db = try NativeDatabase()
        let sql = """
        SELECT NULL AS null_value,
               -9223372036854775808 AS integer_min,
               9223372036854775807 AS integer_max,
               9007199254740993 AS rounded_integer,
               0.10000000000000001 AS real_value,
               -1.25e15 AS large_real,
               'Grüße' AS text_value,
               CAST(X'610062' AS TEXT) AS embedded_zero_text,
               X'00FF6162' AS blob_value,
               X'' AS empty_blob,
               11 AS repeated, 22 AS repeated, 33 AS ""
        """
        let expectedHeader = [
            "null_value", "integer_min", "integer_max", "rounded_integer", "real_value",
            "large_real", "text_value", "embedded_zero_text", "blob_value", "empty_blob",
            "repeated", "repeated", ""
        ]
        let expected: [JSONValue] = [
            .null, .number(Double(Int64.min)), .number(Double(Int64.max)),
            .number(9_007_199_254_740_992), .number(0.1), .number(-1.25e15),
            .string("Grüße"), .string("a"), .string("AP9hYg=="), .null,
            .number(11), .number(22), .number(33)
        ]
        var events: [String] = []
        var headers: [[String]] = []
        var rows: [[JSONValue]] = []
        try db.forEachValueRow(sql, columns: { columns in
            events.append("header")
            headers.append(columns)
        }, consumeValues: { values in
            events.append("row")
            rows.append(values)
        })
        XCTAssertEqual(events, ["header", "row"])
        XCTAssertEqual(headers, [expectedHeader])
        XCTAssertEqual(rows.count, 1)
        assertValues(try XCTUnwrap(rows.first), expected)

        // The existing dictionary API must keep its last-alias-wins behavior.
        let legacy = try XCTUnwrap(db.query(sql).first)
        XCTAssertEqual(legacy, [
            "null_value": .null,
            "integer_min": .number(Double(Int64.min)),
            "integer_max": .number(Double(Int64.max)),
            "rounded_integer": .number(9_007_199_254_740_992),
            "real_value": .number(0.1), "large_real": .number(-1.25e15),
            "text_value": .string("Grüße"), "embedded_zero_text": .string("a"),
            "blob_value": .string("AP9hYg=="), "empty_blob": .null,
            "repeated": .number(22), "": .number(33)
        ])
        for (index, name) in expectedHeader.enumerated() where name != "repeated" {
            assertValues([try XCTUnwrap(legacy[name])], [expected[index]])
        }

        let array: JSONValue = .array([1, "x", false])
        let object: JSONValue = .object(["nested": .array([.null, .bool(true)])])
        let parameters: [JSONValue] = [
            .null, .bool(true), .bool(false), .number(0.1), .number(-0.0),
            .number(Double.greatestFiniteMagnitude), .number(Double.leastNonzeroMagnitude),
            .string("x'); SELECT ?; --\0tail"), array, object
        ]
        let boundSQL = """
        SELECT ? AS absent, ? AS enabled, ? AS disabled, ? AS fraction,
               ? AS negative_zero, ? AS largest_finite, ? AS smallest_positive,
               ? AS text, ? AS nested_array, ? AS nested_object
        """
        var boundHeaders: [[String]] = []
        var boundRows: [[JSONValue]] = []
        try db.forEachValueRow(boundSQL, parameters, columns: { boundHeaders.append($0) }, consumeValues: { boundRows.append($0) })
        XCTAssertEqual(boundHeaders, [["absent", "enabled", "disabled", "fraction", "negative_zero", "largest_finite", "smallest_positive", "text", "nested_array", "nested_object"]])
        XCTAssertEqual(boundRows.count, 1)
        let boundLegacy = try XCTUnwrap(db.query(boundSQL, parameters).first)
        let legacyZero = try XCTUnwrap(boundLegacy["negative_zero"])
        XCTAssertEqual(legacyZero, .number(0))
        // Preserve the existing API's zero bits without imposing a SQLite sign rule.
        let boundExpected: [JSONValue] = [
            .null, .number(1), .number(0), .number(0.1), legacyZero,
            .number(Double.greatestFiniteMagnitude), .number(Double.leastNonzeroMagnitude),
            .string("x'); SELECT ?; --"),
            .string(String(decoding: try array.encoded(), as: UTF8.self)),
            .string(String(decoding: try object.encoded(), as: UTF8.self))
        ]
        assertValues(try XCTUnwrap(boundRows.first), boundExpected)
        for (index, name) in try XCTUnwrap(boundHeaders.first).enumerated() {
            assertValues([try XCTUnwrap(boundLegacy[name])], [boundExpected[index]])
        }

        var emptyEvents: [String] = []
        try db.forEachValueRow("SELECT 1 AS no_rows WHERE 0", columns: { columns in
            emptyEvents.append("header")
            XCTAssertEqual(columns, ["no_rows"])
        }, consumeValues: { _ in emptyEvents.append("row") })
        XCTAssertEqual(emptyEvents, ["header"])
    }

    func testRetainedValueRowsRemainIndependentAcrossReuseAndMutation() throws {
        let db = try NativeDatabase()
        let sql = """
        WITH fixture(n, label) AS (VALUES (1, 'first'), (2, 'second'), (3, 'third'))
        SELECT n, label, CAST(label AS BLOB) AS bytes, NULL AS absent FROM fixture ORDER BY n
        """
        let expected: [[JSONValue]] = [
            [.number(1), .string("first"), .string("Zmlyc3Q="), .null],
            [.number(2), .string("second"), .string("c2Vjb25k"), .null],
            [.number(3), .string("third"), .string("dGhpcmQ="), .null]
        ]
        var headers: [[String]] = []
        var retained: [[JSONValue]] = []
        var consumerCopies: [[JSONValue]] = []
        try db.forEachValueRow(sql, columns: { headers.append($0) }, consumeValues: { values in
            retained.append(values)
            var changed = values
            changed[0] = .string("consumer-owned")
            changed.append(.string("extra"))
            consumerCopies.append(changed)
            // These earlier rows are still retained when the producer fills its next row.
            XCTAssertEqual(retained, Array(expected.prefix(retained.count)))
            XCTAssertEqual(values.count, 4)
            XCTAssertEqual(values, expected[retained.count - 1])
        })
        XCTAssertEqual(headers, [["n", "label", "bytes", "absent"]])
        XCTAssertEqual(retained, expected)
        XCTAssertEqual(consumerCopies.count, 3)
        for (index, changed) in consumerCopies.enumerated() {
            XCTAssertEqual(changed, [.string("consumer-owned")] + Array(expected[index].dropFirst()) + [.string("extra")])
        }

        // A different statement runs after the first one is finalized. Saved text and BLOB
        // values must still be owned values, independent of SQLite's column memory.
        try db.forEachValueRow("SELECT 'replacement' AS label, X'FF' AS bytes", columns: { _ in }, consumeValues: { _ in })
        XCTAssertEqual(retained, expected)
        retained[0][1] = .string("edited after traversal")
        retained[0].append(.number(99))
        XCTAssertEqual(retained[1], expected[1])
        XCTAssertEqual(retained[2], expected[2])
        XCTAssertEqual(consumerCopies[0], [.string("consumer-owned")] + Array(expected[0].dropFirst()) + [.string("extra")])
    }

    func testThrowingHeaderAndConsumerReleasePrivateStatementsAndLock() async throws {
        for stop in [CallbackStop.header, .consumer] {
            let db = try NativeDatabase()
            try db.executeScript("CREATE TABLE callback_fixture(value INTEGER); INSERT INTO callback_fixture VALUES (1), (2)")
            var events: [String] = []
            XCTAssertThrowsError(try db.forEachValueRow("SELECT value FROM callback_fixture", columns: { columns in
                events.append("header")
                XCTAssertEqual(columns, ["value"])
                if stop == .header { throw CallbackStop.header }
            }, consumeValues: { values in
                events.append("row")
                XCTAssertEqual(values.count, 1)
                throw CallbackStop.consumer
            })) { error in
                XCTAssertEqual(error as? CallbackStop, stop)
            }
            XCTAssertEqual(events, stop == .header ? ["header"] : ["header", "row"])
            // An abandoned stepped SELECT would retain a schema lock on this private table.
            XCTAssertNoThrow(try db.executeScript("DROP TABLE callback_fixture; CREATE TABLE callback_fixture(value INTEGER)"))
            await assertReadableFromAnotherQueue(db)
        }
    }

    func testPrepareBindingAndStepFailuresPreserveCallbackOrderAndRecovery() async throws {
        let db = try NativeDatabase()
        try db.executeScript("CREATE TABLE failure_fixture(value INTEGER); INSERT INTO failure_fixture VALUES (1), (2)")
        let cases: [(sql: String, parameters: [JSONValue], events: [String], message: String?)] = [
            ("SELEC value FROM failure_fixture", [], [], nil),
            ("SELECT ? AS value FROM failure_fixture", [], [], "SQL parameter count mismatch"),
            ("SELECT value FROM failure_fixture", [.number(1)], [], "SQL parameter count mismatch"),
            ("SELECT abs(-9223372036854775808) AS value FROM failure_fixture", [], ["header"], "integer overflow")
        ]
        for fixture in cases {
            var events: [String] = []
            XCTAssertThrowsError(try db.forEachValueRow(fixture.sql, fixture.parameters, columns: { columns in
                events.append("header")
                XCTAssertEqual(columns, ["value"])
            }, consumeValues: { _ in events.append("row") })) { error in
                guard let failure = error as? NativeFailure else { return XCTFail("Expected NativeFailure, received \(error)") }
                if let message = fixture.message { XCTAssertEqual(failure.message, message) }
            }
            XCTAssertEqual(events, fixture.events, fixture.sql)
            XCTAssertNoThrow(try db.executeScript("DROP TABLE failure_fixture; CREATE TABLE failure_fixture(value INTEGER); INSERT INTO failure_fixture VALUES (1), (2)"))
        }
        var recovered: [[JSONValue]] = []
        try db.forEachValueRow("SELECT value FROM failure_fixture ORDER BY value", columns: { XCTAssertEqual($0, ["value"]) }, consumeValues: { recovered.append($0) })
        XCTAssertEqual(recovered, [[.number(1)], [.number(2)]])
        await assertReadableFromAnotherQueue(db)
    }

    private enum CallbackStop: Error, Equatable { case header, consumer }

    private func assertValues(_ actual: [JSONValue], _ expected: [JSONValue], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
        for (index, pair) in zip(actual, expected).enumerated() {
            if case (.number(let a), .number(let b)) = pair {
                XCTAssertEqual(a.bitPattern, b.bitPattern, "Numeric bits at column \(index)", file: file, line: line)
            }
        }
    }

    private func assertReadableFromAnotherQueue(_ db: NativeDatabase, file: StaticString = #filePath, line: UInt = #line) async {
        let finished = expectation(description: "Private database lock released")
        // Reusing NSRecursiveLock on the throwing thread alone would miss a leaked lock.
        DispatchQueue(label: "native-database-value-row-private-test").async {
            defer { finished.fulfill() }
            do { XCTAssertEqual(try db.query("SELECT 42 AS value"), [["value": .number(42)]], file: file, line: line) }
            catch { XCTFail("Private database recovery failed: \(error)", file: file, line: line) }
        }
        await fulfillment(of: [finished], timeout: 2)
    }
}
