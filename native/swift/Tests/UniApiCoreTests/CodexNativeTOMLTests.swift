import XCTest
@testable import UniApiCore

/// Pure document fixtures: no filesystem, operator settings or runtime access.
final class CodexNativeTOMLTests: XCTestCase {
    private let installed: JSONObject = [
        "openai_base_url": "http://127.0.0.1:8823/_uniapi/codex/v1", "model_catalog_json": .null,
        "features.multi_agent": true, "features.multi_agent_v2": false,
        "features.responses_websockets": false, "features.responses_websockets_v2": false
    ]
    private let original = """
    # Keep root commentary: München / 東京 / Ελληνικά.
    model = 'original-model' # default model
    model_reasoning_effort = 'high'
    model_provider = 'openai'
    openai_base_url = 'https://original.invalid/v1' # retain base comment
    model_catalog_json = 'original-catalog.json'
    instructions = 'Literal features.multi_agent = false; openai_base_url = example'
    [features] # retain feature commentary
    multi_agent = false # retain scalar commentary
    multi_agent_v2 = true
    responses_websockets = true
    responses_websockets_v2 = true
    unrelated = 'retain feature'
    [model_providers.custom]
    name = 'retain provider'
    base_url = 'https://provider.invalid/v1'
    [hooks]
    command = 'retain hook'

    """
    private func parse(_ text: String) throws -> JSONObject { try NativeTOML.parse(text) }
    private func fields(_ text: String) throws -> JSONObject { NativeTOML.transportValues(try parse(text)) }

    func testSixFieldRoundTripPreservesUnownedValuesAndComments() throws {
        let before = try parse(original), previous = NativeTOML.transportValues(before)
        XCTAssertEqual(Set(previous.keys), Set(installed.keys)); XCTAssertEqual(previous.count, 6)
        let connected = try NativeTOML.patchTransport(original, values: installed)
        XCTAssertEqual(try fields(connected), installed)
        let connectedDocument = try parse(connected)
        for key in ["model", "model_provider", "model_reasoning_effort", "instructions", "model_providers", "hooks"] {
            XCTAssertEqual(connectedDocument[key], before[key], key)
        }
        for comment in ["# Keep root commentary", "# default model", "# retain base comment", "# retain feature commentary", "# retain scalar commentary"] {
            XCTAssertTrue(connected.contains(comment), comment)
        }
        let restored = try NativeTOML.patchTransport(connected, values: previous)
        XCTAssertEqual(try parse(restored), before)
        XCTAssertTrue(restored.contains("# retain scalar commentary"))
    }
    func testRestorePreservesLaterUnrelatedEditsAndUnicodeScalarOffsets() throws {
        let prefix = "title = 'Grünwald / 東京 / Ελληνικά / e\u{301}' # non-ASCII before patch spans\n"
        let before = prefix + original, previous = try fields(before)
        var connected = try NativeTOML.patchTransport(before, values: installed)
        connected = connected.replacingOccurrences(of: "'original-model'", with: "'later-model'")
            .replacingOccurrences(of: "command = 'retain hook'", with: "command = 'später / 日本語'\nlater = [1, 2, 3]")
        connected += "[agents.reviewer]\nmodel='unrelated-reviewer'\n"
        let restored = try NativeTOML.patchTransport(connected, values: previous), result = try parse(restored)
        XCTAssertEqual(try fields(restored), previous)
        XCTAssertEqual(result["title"], "Grünwald / 東京 / Ελληνικά / e\u{301}")
        XCTAssertEqual(result["model"], "later-model")
        XCTAssertEqual(result["hooks"]?["command"], "später / 日本語")
        XCTAssertEqual(result["hooks"]?["later"], [1, 2, 3])
        XCTAssertEqual(result["agents"]?["reviewer"]["model"], "unrelated-reviewer")
        // Restoring a removed root field may prepend that owned assignment.
        // The original unowned prefix must retain its exact bytes, not offset.
        XCTAssertNotNil(Data(restored.utf8).range(of: Data(prefix.utf8)))
    }
    func testFeatureTableInsertionAndNullRemovalPreserveOtherTableMembers() throws {
        let text = "model='keep'\n[features] # retain header\nother=true # retain sibling\n[hooks]\nvalue=42\n"
        let before = try parse(text), previous = try fields(text)
        let connected = try NativeTOML.patchTransport(text, values: installed)
        XCTAssertEqual(try fields(connected), installed)
        XCTAssertEqual(try parse(connected)["features"]?["other"], true)
        XCTAssertTrue(connected.contains("[features] # retain header\n"))
        let restored = try NativeTOML.patchTransport(connected, values: previous)
        XCTAssertEqual(try parse(restored), before)
        XCTAssertTrue(restored.contains("other=true # retain sibling\n"))
    }
    func testDottedFeatureAssignmentsRoundTripWithoutDeclaringAnotherTable() throws {
        let text = "# keep dotted representation\nfeatures.multi_agent = false # keep comment\nfeatures.unrelated = 'sibling'\nmodel='keep'\n"
        let previous = try fields(text), connected = try NativeTOML.patchTransport(text, values: installed)
        XCTAssertEqual(try fields(connected), installed)
        XCTAssertFalse(connected.contains("[features]"))
        XCTAssertTrue(connected.contains("features.multi_agent = true # keep comment"))
        let restored = try NativeTOML.patchTransport(connected, values: previous)
        XCTAssertEqual(try parse(restored), try parse(text))
        XCTAssertTrue(restored.contains("features.unrelated = 'sibling'"))
    }
    func testQuotedKeysAreDistinguishedFromLiteralRootKeysContainingDots() throws {
        let text = "\"features.multi_agent\"='literal root key'\n\"openai_base_url\"='https://old.invalid' # retain root\n[\"features\"]\n\"multi_agent\"=false # retain quoted key\nother='sibling'\n"
        let connected = try NativeTOML.patchTransport(text, values: installed)
        XCTAssertEqual(try fields(connected), installed)
        XCTAssertEqual(try parse(connected)["features.multi_agent"], "literal root key")
        XCTAssertTrue(connected.contains("\"multi_agent\"=true # retain quoted key"))
        XCTAssertTrue(connected.contains("# retain root"))
        XCTAssertEqual(try parse(NativeTOML.patchTransport(connected, values: fields(text))), try parse(text))
    }
    func testNullRemovesOnlyOwnedStatementsAndRetainsNestedNames() throws {
        let text = original + "[agents.reviewer.features]\nmulti_agent=true\nresponses_websockets=true\n"
        let removed = try NativeTOML.patchTransport(text, values: installed.mapValues { _ in .null }), result = try parse(removed)
        XCTAssertTrue(try fields(removed).values.allSatisfy(\.isNull))
        XCTAssertEqual(result["features"], ["unrelated": "retain feature"])
        XCTAssertEqual(result["agents"]?["reviewer"]["features"]["multi_agent"], true)
        XCTAssertEqual(result["agents"]?["reviewer"]["features"]["responses_websockets"], true)
        XCTAssertEqual(result["instructions"], try parse(text)["instructions"])
        XCTAssertTrue(removed.contains("# Keep root commentary"))
    }
    func testNoOpAndNullRemovalOfAbsentFieldsPreserveExactBytes() throws {
        let text = "model='keep'\r\n[features]\r\nunrelated=true # keep exact whitespace\r\n"
        XCTAssertEqual(try NativeTOML.patchTransport(text, values: [:]), text)
        XCTAssertEqual(try NativeTOML.patchTransport(text, values: fields(text)), text)
        let connected = try NativeTOML.patchTransport(text, values: installed)
        XCTAssertEqual(try NativeTOML.patchTransport(connected, values: installed), connected)
    }
    func testCRLFAndNoFinalNewlineOnExistingAssignmentsArePreserved() throws {
        let text = "openai_base_url = 'https://old.invalid' # root\r\n[features]\r\nmulti_agent = false # trailing"
        let output = try NativeTOML.patchTransport(text, values: ["openai_base_url": "https://new.invalid", "features.multi_agent": true])
        XCTAssertTrue(output.contains("# root\r\n[features]\r\n"))
        XCTAssertTrue(output.hasSuffix("multi_agent = true # trailing"))
        XCTAssertFalse(output.hasSuffix("\n"))
        XCTAssertEqual(try fields(output)["features.multi_agent"], true)
    }
    func testInvalidPatchKeysAndScalarTypesAreRefused() throws {
        let invalid: [JSONObject] = [
            ["model": "unowned"], ["features.unrelated": false], ["unknown": .null],
            ["openai_base_url": true], ["openai_base_url": 12], ["model_catalog_json": []],
            ["features.multi_agent": "true"], ["features.multi_agent_v2": 0],
            ["features.responses_websockets": [:]], ["features.responses_websockets_v2": []]
        ]
        for values in invalid { XCTAssertThrowsError(try NativeTOML.patchTransport(original, values: values), String(describing: values.keys.sorted())) }
    }
    func testNonTableFeatureParentsAndMalformedDocumentsAreRefused() throws {
        for text in ["features=true\n", "features=[]\n", "features=7\n", "features='wrong type'\n",
                     "openai_base_url='one'\nopenai_base_url='two'\n", "[features]\nmulti_agent=false\nmulti_agent=true\n",
                     "features.multi_agent=false\n[features]\nother=true\n"] {
            XCTAssertThrowsError(try NativeTOML.patchTransport(text, values: installed), text)
        }
    }
    func testOwnedMultilineValuesAreRefusedForReplacementAndRemoval() throws {
        let fixtures: [(String, JSONObject)] = [
            ("openai_base_url=\"\"\"https://old.invalid\ncontinued\"\"\"\n", ["openai_base_url": "https://new.invalid"]),
            ("model_catalog_json='''old\ncatalog.json'''\n", ["model_catalog_json": "new.json"]),
            ("[features]\nmulti_agent=\"\"\"true\ncontinued\"\"\"\n", ["features.multi_agent": true])
        ]
        for (text, replacement) in fixtures {
            XCTAssertNoThrow(try parse(text))
            XCTAssertThrowsError(try NativeTOML.patchTransport(text, values: replacement))
            XCTAssertThrowsError(try NativeTOML.patchTransport(text, values: replacement.mapValues { _ in .null }))
        }
    }
    func testUnrelatedMultilineTransportExamplesRemainLiteral() throws {
        for literal in [false, true] {
            let quote = literal ? "'''" : "\"\"\""
            let example = "Example only:\nopenai_base_url='https://example.invalid'\n[features]\nmulti_agent=false\n"
            let prefix = "instructions=" + quote + example + quote + "\n"
            let text = prefix + "model='keep'\n[features]\nother=true\n"
            let output = try NativeTOML.patchTransport(text, values: installed)
            XCTAssertEqual(try fields(output), installed)
            XCTAssertEqual(try parse(output)["instructions"], .string(example))
            XCTAssertTrue(output.contains(prefix))
            let restored = try NativeTOML.patchTransport(output, values: fields(text))
            XCTAssertEqual(try parse(restored), try parse(text))
            XCTAssertTrue(restored.contains(prefix))
        }
    }
    func testLastInsertedDottedFeatureCanBeRemovedWithoutOriginalParentTable() throws {
        // Parent-owned regression: the empty feature parent may disappear when
        // removing the final inserted dotted key. That is a valid restoration.
        let text = "model='keep'\n[hooks]\nvalue=42\n", previous = try fields(text)
        let connected = try NativeTOML.patchTransport(text, values: installed)
        let restored = try NativeTOML.patchTransport(connected, values: previous)
        XCTAssertEqual(try fields(restored), previous)
        XCTAssertEqual(try parse(restored)["model"], "keep")
        XCTAssertEqual(try parse(restored)["hooks"]?["value"], 42)
    }
    func testFeatureHeaderAtEOFWithoutNewlineCanReceiveFields() throws {
        // Parent-owned regression: a missing final newline requires a separator
        // before insertion at featureHeaderEnd, including a trailing comment.
        for text in ["model='keep'\n[features]", "model='keep'\n[features] # final comment"] {
            let output = try NativeTOML.patchTransport(text, values: ["features.multi_agent": true])
            XCTAssertEqual(try fields(output)["features.multi_agent"], true)
            XCTAssertEqual(try parse(output)["model"], "keep")
            XCTAssertTrue(output.contains("[features]"))
            if text.contains("# final comment") { XCTAssertTrue(output.contains("# final comment")) }
        }
    }
}
