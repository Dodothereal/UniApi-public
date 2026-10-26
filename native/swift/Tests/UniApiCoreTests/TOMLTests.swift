import XCTest
import Darwin
@testable import UniApiCore

final class TOMLTests: XCTestCase {
    private func fixture(_ text: String) throws -> (URL, URL, NativeCodexSettingsStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toml-" + UUID().uuidString)
        let file = root.appendingPathComponent("config.toml")
        try NativeFile.writeAtomic(Data(text.utf8), to: file)
        return (root, file, NativeCodexSettingsStore(configPath: file, stateDirectory: root.appendingPathComponent("state")))
    }
    func testDocumentPreservesCommentsNestedKeysAndCRLF() throws {
        let tail = "# retain this\r\n[hooks]\r\ncommand = \"notify\"\r\n[plugins.example]\r\nenabled = true\r\n[agents.review]\r\nmodel = \"review\"\r\n"
        let input = "\"model\" = \"native\" # owned comment\r\nmodel_reasoning_effort = \"ultra\"\r\n" + tail
        let output = try NativeTOML.patchDefaults(input, values: ["model": "other", "model_reasoning_effort": .null])
        XCTAssertEqual(output, "model = \"other\"\r\n" + tail)
    }
    func testFakeAssignmentsMultilineAndInjectionCannotChangeHooks() throws {
        let input = "developer_instructions = \"\"\"\nmodel = \"fiction\"\n\"\"\"\nmodel = \"native\"\n"
        XCTAssertEqual(try NativeTOML.patchDefaults(input, values: ["model": "new"]), input.replacingOccurrences(of: "model = \"native\"", with: "model = \"new\""))
        let attack = "quote\"\n[hooks]\ncommand=\"arbitrary"
        let edited = try NativeTOML.parse(NativeTOML.patchDefaults("[hooks]\ncommand=\"keep\"\n", values: ["model": .string(attack)]))
        XCTAssertEqual(edited["model"], .string(attack)); XCTAssertEqual(edited["hooks"]?["command"], "keep")
        XCTAssertThrowsError(try NativeTOML.patchDefaults("model=\"\"\"\na\n\"\"\"\n", values: ["model": "new"]))
        XCTAssertThrowsError(try NativeTOML.patchDefaults("model=\"unclosed", values: ["model": "new"]))
    }
    func testArraysDottedQuotedKeysAndTablesOfArrays() throws {
        let input = "title='fixture'\nvalues = [1, 0x10, true, \"é\",]\ninline={ x=1, nested.key=\"value\" }\n[[agents]]\nname=\"first\"\n[agents.hooks]\nnotify=[\"a\",\"b\"]\n[[agents]]\nname=\"second\"\n[agents.hooks]\nnotify=[]\n[\"plugins.a\"]\n'quoted.key'=\"yes\"\n"
        let parsed = try NativeTOML.parse(input)
        XCTAssertEqual(parsed["values"]?.array.count, 4); XCTAssertEqual(parsed["inline"]?["nested"]["key"], "value")
        XCTAssertEqual(parsed["agents"]?.array.count, 2); XCTAssertEqual(parsed["agents"]?.array.last?["name"], "second")
        XCTAssertEqual(parsed["plugins.a"]?["quoted.key"], "yes")
        XCTAssertThrowsError(try NativeTOML.parse("x=1\nx=2\n")); XCTAssertThrowsError(try NativeTOML.parse("x={a=1}\nx.b=2\n"))
    }
    func testPrivateBackupRestoreAndLaterUnrelatedEdit() throws {
        let original = "model=\"native\"\nmodel_reasoning_effort=\"ultra\"\n[hooks]\na=1\n"
        let (root, file, store) = try fixture(original); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "chatgpt-web/pro", "model_reasoning_effort": .null])
        let edited = try SwitcherDisk.text(file) + "b=2\n"; try NativeFile.writeAtomic(Data(edited.utf8), to: file)
        try store.restore()
        let parsed = try store.read().config
        XCTAssertEqual(parsed["model"], "native"); XCTAssertEqual(parsed["hooks"]?["b"], 2); XCTAssertFalse(try store.hasRestore())
        let backups = try FileManager.default.contentsOfDirectory(at: store.stateDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "toml" }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: backups[0].path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testExternalOwnedChangeAndProviderBlockAreProtected() throws {
        let original = "model=\"native\"\n[model_providers.existing]\nname=\"Keep\"\n"
        let (root, file, store) = try fixture(original); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "api"], provider: ["name": "Fixture", "baseUrl": "https://fixture.invalid/v1", "apiKey": "private-fixture-key"])
        XCTAssertEqual(try store.read().config["model_provider"], "uniapi_managed")
        try store.select(["model": "native", "model_reasoning_effort": "high"]); XCTAssertNil(try store.read().config["model_provider"])
        try store.restore(); XCTAssertEqual(try store.read().config, try NativeTOML.parse(original))
        try store.select(["model": "changed"]); try NativeFile.writeAtomic(Data("model=\"external\"\n".utf8), to: file)
        XCTAssertThrowsError(try store.restore()); XCTAssertEqual(try SwitcherDisk.text(file), "model=\"external\"\n")
    }
    func testBridgeFieldsAndStaleJournalRecovery() throws {
        let input = "openai_base_url=\"http://127.0.0.1:17841/v1\"\nmodel_catalog_json=\"catalog.json\"\nmodel=\"native\"\n"
        let (root, file, store) = try fixture(input); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "web"]); try NativeFile.writeAtomic(Data(input.utf8), to: file)
        try store.assertRestorable(); XCTAssertFalse(try store.hasRestore()); XCTAssertEqual(try SwitcherDisk.text(file), input)
        try store.select(["model": "different"]); try store.restore(); XCTAssertEqual(try store.read().config, try NativeTOML.parse(input))
    }
    func testCASLinksAndFIFORefusal() throws {
        let (root, file, store) = try fixture("model=\"native\"\n"); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try SwitcherDisk.atomic(file, Data("model=\"new\"\n".utf8), expected: Data("old".utf8)))
        let target = root.appendingPathComponent("real.toml"); try FileManager.default.moveItem(at: file, to: target); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try store.select(["model": "new"]))
        try FileManager.default.removeItem(at: file); XCTAssertEqual(mkfifo(file.path, 0o600), 0); XCTAssertThrowsError(try store.read())
    }
    func testDatetimeAndNumericFieldsRemainUntouchedAndInvalidScalarsAreRejected() throws {
        let tail = "[hooks]\ncreated = 1979-05-27 07:32:00Z\nlocal_time = 07:32:00.25\nratio=1_000.25e-2\nflags=0xA_B\n"
        let input = "model=\"native\"\n" + tail
        let output = try NativeTOML.patchDefaults(input, values: ["model": "new"])
        XCTAssertTrue(output.hasSuffix(tail))
        for literal in ["2026-02-31", "2026-99-01", "07:99:00", "1_.0", "0x_ff", "9223372036854775808"] { XCTAssertThrowsError(try NativeTOML.parse("value=" + literal + "\n")) }
    }
    func testWrongTypedDefaultCannotProduceAnInvalidRecoveryJournal() throws {
        let (root, _, store) = try fixture("model=123\n[hooks]\nvalue=1\n"); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "native"]); XCTAssertTrue(try store.hasRestore()); try store.restore()
        XCTAssertNil(try store.read().config["model"]); XCTAssertEqual(try store.read().config["hooks"]?["value"], 1)
    }
}
