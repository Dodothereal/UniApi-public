import XCTest
@testable import UniApiCore

private final class TOMLPublicationFault: @unchecked Sendable {
    private let lock = NSLock()
    private var point: NativeCodexPublicationPoint?
    func arm(_ point: NativeCodexPublicationPoint) { lock.lock(); self.point = point; lock.unlock() }
    func check(_ current: NativeCodexPublicationPoint) throws {
        lock.lock(); let fail = point == current; if fail { point = nil }; lock.unlock()
        if fail { throw NativeFailure("Fixture interrupted publication") }
    }
}
final class TOMLRecoveryTests: XCTestCase {
    private func fixture(_ text: String = "model=\"original\"\n[hooks]\ncommand=\"keep\"\n", fault: TOMLPublicationFault? = nil) throws -> (URL, URL, NativeCodexSettingsStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("toml-recovery-" + UUID().uuidString), file = root.appendingPathComponent("config.toml")
        try NativeFile.writeAtomic(Data(text.utf8), to: file)
        return (root, file, .init(configPath: file, stateDirectory: root.appendingPathComponent("state"), publicationHook: { try fault?.check($0) }))
    }
    func testSecondSelectionInterruptedBeforeConfigRenameRemainsRestorable() throws {
        let fault = TOMLPublicationFault(), (root, file, store) = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: root) }
        let original = try store.read().config
        try store.select(["model": "first"]); let first = try SwitcherDisk.read(file)
        fault.arm(.beforeConfigRename(.select))
        XCTAssertThrowsError(try store.select(["model": "second", "model_reasoning_effort": "high"]))
        XCTAssertEqual(try SwitcherDisk.read(file), first)
        XCTAssertTrue(try store.hasRestore()); try store.assertRestorable(); try store.restore()
        XCTAssertEqual(try store.read().config, original); XCTAssertFalse(try store.hasRestore())
        let backups = try FileManager.default.contentsOfDirectory(at: store.stateDirectory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "toml" }
        XCTAssertEqual(backups.count, 1)
    }
    func testInterruptedProviderReplacementRestoresPreviousBlockAndRetainsUnrelatedEdits() throws {
        let fault = TOMLPublicationFault(), (root, file, store) = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: root) }
        let provider: JSONValue = ["name": "First", "baseUrl": "https://first.invalid/v1", "apiKey": "fixture-first-key"]
        try store.select(["model": "first"], provider: provider); let first = try SwitcherDisk.text(file)
        fault.arm(.beforeConfigRename(.select))
        XCTAssertThrowsError(try store.select(["model": "second"], provider: ["name": "Second", "baseUrl": "https://second.invalid/v1", "apiKey": "fixture-second-key"]))
        let interrupted = first.replacingOccurrences(of: "command=\"keep\"", with: "command=\"keep\"\nlater=2")
        try NativeFile.writeAtomic(Data(interrupted.utf8), to: file)
        try store.restore()
        let config = try store.read().config
        XCTAssertEqual(config["model"], "original"); XCTAssertNil(config["model_provider"]); XCTAssertNil(config["model_providers"])
        XCTAssertEqual(config["hooks"]?["command"], "keep"); XCTAssertEqual(config["hooks"]?["later"], 2)
    }
    func testThirdSelectionAfterInterruptedSecondStillUsesFirstOriginalBackup() throws {
        let fault = TOMLPublicationFault(), (root, _, store) = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "first"])
        fault.arm(.beforeConfigRename(.select)); XCTAssertThrowsError(try store.select(["model": "second"]))
        try store.select(["model": "third"]); XCTAssertEqual(try store.read().config["model"], "third")
        try store.restore(); XCTAssertEqual(try store.read().config["model"], "original")
    }
    func testRealExternalEditCannotMasqueradeAsThePriorGeneration() throws {
        let (root, file, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "first"]); let first = try SwitcherDisk.text(file)
        try store.select(["model": "second"])
        let external = first.replacingOccurrences(of: "\"first\"", with: "\"user-chosen\"")
        try NativeFile.writeAtomic(Data(external.utf8), to: file)
        XCTAssertThrowsError(try store.restore()); XCTAssertTrue(try store.hasRestore()); XCTAssertEqual(try SwitcherDisk.text(file), external)
    }
    func testFirstSelectionInterruptedWithWrongTypedDefaultRetiresJournalWithoutWritingConfig() throws {
        let fault = TOMLPublicationFault(), text = "model=123\n[hooks]\ncommand=\"keep\"\n", (root, file, store) = try fixture(text, fault: fault)
        defer { try? FileManager.default.removeItem(at: root) }
        fault.arm(.beforeConfigRename(.select)); XCTAssertThrowsError(try store.select(["model": "native"]))
        try store.assertRestorable(); XCTAssertFalse(try store.hasRestore()); XCTAssertEqual(try SwitcherDisk.text(file), text)
    }
    func testMalformedPriorGenerationCannotEraseAnExternalOwnedEdit() throws {
        let (root, file, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "first"]); try store.select(["model": "second"])
        var journal = try JSONValue.decode(SwitcherDisk.read(store.journalPath)); journal["priorGeneration"]["values"] = [:]
        try NativeFile.writeAtomic(try journal.encoded(), to: store.journalPath)
        let external = "model=\"external\"\n"; try NativeFile.writeAtomic(Data(external.utf8), to: file)
        XCTAssertThrowsError(try store.restore()); XCTAssertEqual(try SwitcherDisk.text(file), external)
    }
    func testTOMLRejectsTrailingStatementsAndLoneCarriageReturnsWithoutPatching() throws {
        for text in ["model=\"first\" other=\"keep\"\n", "model_reasoning_effort=\"high\" model=\"other\"\n", "model_provider=\"openai\" [hooks]\n", "model=\"first\"\r"] {
            XCTAssertThrowsError(try NativeTOML.parse(text))
            XCTAssertThrowsError(try NativeTOML.patchDefaults(text, values: ["model": "changed"]))
        }
        for text in ["model=\"first\"", "model=\"first\" # comment", "model=\"first\"\r\n[hooks]\r\nother=\"keep\"\r\n"] { XCTAssertNoThrow(try NativeTOML.parse(text)) }
    }
    func testDottedTablesCannotBeRedefinedButHeaderImplicitParentsCanBeDeclared() throws {
        for text in ["a.b=1\n[a]\nc=2\n", "a.b.c=1\n[a.b]\nd=2\n", "[root]\na.b=1\n[root.a]\nc=2\n", "a={b=1}\n[a.c]\nx=2\n"] { XCTAssertThrowsError(try NativeTOML.parse(text)) }
        XCTAssertEqual(try NativeTOML.parse("[a.b]\nx=1\n[a]\nc=2\n")["a"]?["c"], 2)
        XCTAssertEqual(try NativeTOML.parse("a.b=1\n[a.c]\nx=2\n")["a"]?["c"]["x"], 2)
        XCTAssertEqual(try NativeTOML.parse("a.b=1\na.c=2\n")["a"]?["c"], 2)
        XCTAssertEqual(try NativeTOML.parse("[[a]]\nname=\"one\"\n[a.b]\nx=1\n[[a]]\nname=\"two\"\n[a.b]\nx=2\n")["a"]?.array.last?["b"]["x"], 2)
    }
}
