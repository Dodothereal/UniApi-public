import XCTest
@testable import UniApiCore

private final class ConfigPublicationFixture: @unchecked Sendable {
    private let lock = NSLock()
    var point: NativeCodexPublicationPoint?
    var edit: (@Sendable () throws -> Void)?
    var interrupts = true
    func fail(_ point: NativeCodexPublicationPoint, edit: (@Sendable () throws -> Void)? = nil, interrupts: Bool = true) { lock.lock(); self.point = point; self.edit = edit; self.interrupts = interrupts; lock.unlock() }
    func hit(_ point: NativeCodexPublicationPoint) throws {
        lock.lock(); let fail = self.point == point, edit = self.edit, interrupts = self.interrupts; if fail { self.point = nil; self.edit = nil }; lock.unlock()
        if fail { try edit?(); if interrupts { throw NativeFailure("Simulated publication interruption") } }
    }
}
final class TOMLStoreRegressionTests: XCTestCase {
    private func fixture(_ text: String = "model=\"original\"\n[hooks]\ncommand=\"keep\"\n", fault: ConfigPublicationFixture? = nil) throws -> (URL, URL, NativeCodexSettingsStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-commit-fixture-" + UUID().uuidString), file = root.appendingPathComponent("config.toml")
        try NativeFile.writeAtomic(Data(text.utf8), to: file)
        return (root, file, .init(configPath: file, stateDirectory: root.appendingPathComponent("state"), publicationHook: { try fault?.hit($0) }))
    }
    private func reopened(_ store: NativeCodexSettingsStore) -> NativeCodexSettingsStore { .init(configPath: store.configPath, stateDirectory: store.stateDirectory) }
    private var provider: JSONValue { ["name": "Fixture", "baseUrl": "https://fixture.invalid/v1", "apiKey": "fixture-key"] }
    func testAcknowledgedSelectRetiresPriorAndRefusesIndependentReversion() throws {
        let (root, file, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "first"]); let first = try SwitcherDisk.read(file)
        try store.select(["model": "second"])
        let journal = try JSONValue.decode(SwitcherDisk.read(store.journalPath))
        XCTAssertEqual(journal["phase"], "committed"); XCTAssertTrue(journal["priorGeneration"].isNull)
        try NativeFile.writeAtomic(first, to: file)
        XCTAssertThrowsError(try reopened(store).restore()); XCTAssertEqual(try SwitcherDisk.read(file), first)
    }
    func testSelectionCrashBeforeRenameRetainsPreviousConfigAndOriginalBackup() throws {
        let fault = ConfigPublicationFixture(), (root, file, store) = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "first"]); let first = try SwitcherDisk.read(file)
        let backup = try JSONValue.decode(SwitcherDisk.read(store.journalPath))["backupPath"]
        fault.fail(.beforeConfigRename(.select)); XCTAssertThrowsError(try store.select(["model": "second", "model_reasoning_effort": "high"]))
        XCTAssertEqual(try SwitcherDisk.read(file), first)
        XCTAssertEqual(try JSONValue.decode(SwitcherDisk.read(store.journalPath))["phase"], "pending-select")
        let restarted = reopened(store); try restarted.assertRestorable()
        XCTAssertEqual(try JSONValue.decode(SwitcherDisk.read(store.journalPath))["backupPath"], backup)
        try restarted.restore(); XCTAssertEqual(try restarted.read().config["model"], "original")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix(".uniapi-defaults-") })
    }
    func testSelectionCrashAfterRenameCommitsBeforeAnotherEditCanUsePrior() throws {
        let fault = ConfigPublicationFixture(), (root, file, store) = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "first"]); let first = try SwitcherDisk.read(file)
        fault.fail(.afterConfigRename(.select)); XCTAssertThrowsError(try store.select(["model": "second"]))
        XCTAssertEqual(try store.read().config["model"], "second")
        let restarted = reopened(store); try restarted.assertRestorable()
        XCTAssertEqual(try JSONValue.decode(SwitcherDisk.read(store.journalPath))["phase"], "committed")
        try NativeFile.writeAtomic(first, to: file)
        XCTAssertThrowsError(try restarted.restore()); XCTAssertEqual(try SwitcherDisk.read(file), first)
    }
    func testUserDefaultEditAtPreRenameWinsCASAndIsPreservedAfterRestart() throws {
        let fault = ConfigPublicationFixture(), (root, file, store) = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "first"])
        let external = Data("model=\"user-choice\"\n[hooks]\ncommand=\"keep\"\n".utf8)
        fault.fail(.beforeConfigRename(.select), edit: { try NativeFile.writeAtomic(external, to: file) }, interrupts: false)
        XCTAssertThrowsError(try store.select(["model": "second"]))
        XCTAssertEqual(try SwitcherDisk.read(file), external)
        XCTAssertThrowsError(try reopened(store).restore()); XCTAssertEqual(try SwitcherDisk.read(file), external)
    }
    func testUnrelatedEditAfterCommittedSelectSurvivesRestore() throws {
        let (root, file, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "native"], provider: provider)
        let edited = try SwitcherDisk.text(file).replacingOccurrences(of: "command=\"keep\"", with: "command=\"user-hook\"\nnew=42")
        try NativeFile.writeAtomic(Data(edited.utf8), to: file)
        try store.restore(); XCTAssertEqual(try store.read().config["hooks"]?["command"], "user-hook"); XCTAssertEqual(try store.read().config["hooks"]?["new"], 42)
    }
    func testRestoreCrashesBeforeAndAfterRenameForBothRoutedKinds() throws {
        for model in ["chatgpt-web/high", "uniapi/provider/model"] {
            for point in [NativeCodexPublicationPoint.beforeConfigRename(.restore), .afterConfigRename(.restore)] {
                let fault = ConfigPublicationFixture(), original = "model=\"" + model + "\"\nmodel_reasoning_effort=\"high\"\n[hooks]\ncommand=\"keep\"\n"
                let (root, file, store) = try fixture(original, fault: fault); defer { try? FileManager.default.removeItem(at: root) }
                try store.select(["model": "api"], provider: provider)
                fault.fail(point); XCTAssertThrowsError(try store.restore(clearWebDefault: true))
                let phase = try JSONValue.decode(SwitcherDisk.read(store.journalPath))["phase"]; XCTAssertEqual(phase, "pending-restore")
                let restarted = reopened(store)
                if point == .beforeConfigRename(.restore) {
                    XCTAssertEqual(try store.read().config["model"], "api"); try restarted.restore(clearWebDefault: true)
                } else { XCTAssertNil(try store.read().config["model"]); try restarted.assertRestorable() }
                XCTAssertFalse(try restarted.hasRestore()); XCTAssertNil(try restarted.read().config["model"])
                XCTAssertNil(try restarted.read().config["model_reasoning_effort"]); XCTAssertNil(try restarted.read().config["model_provider"])
                XCTAssertNil(try restarted.read().config["model_providers"]); XCTAssertEqual(try restarted.read().config["hooks"]?["command"], "keep")
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.appendingPathExtension("tmp").path))
            }
        }
    }
    func testUnownedRoutedCleanupAndWrongTypedEffortRecoverAtBothBoundaries() throws {
        for point in [NativeCodexPublicationPoint.beforeConfigRename(.restore), .afterConfigRename(.restore)] {
            let fault = ConfigPublicationFixture(), (root, _, store) = try fixture("model=\"chatgpt-web/high\"\nmodel_reasoning_effort=123\n[hooks]\nx=1\n", fault: fault)
            defer { try? FileManager.default.removeItem(at: root) }
            fault.fail(point); XCTAssertThrowsError(try store.restore(clearWebDefault: true))
            let restarted = reopened(store); try restarted.assertRestorable()
            XCTAssertFalse(try restarted.hasRestore())
            if point == .beforeConfigRename(.restore) { XCTAssertEqual(try restarted.read().config["model"], "chatgpt-web/high"); try restarted.restore(clearWebDefault: true) }
            XCTAssertNil(try restarted.read().config["model"]); XCTAssertNil(try restarted.read().config["model_reasoning_effort"])
        }
    }
    func testForeignDefaultEditDuringPendingRestoreNeverGetsOverwritten() throws {
        let fault = ConfigPublicationFixture(), (root, file, store) = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "native"])
        fault.fail(.beforeConfigRename(.restore)); XCTAssertThrowsError(try store.restore())
        let external = Data("model=\"user-native\"\n[hooks]\ncommand=\"keep\"\n".utf8); try NativeFile.writeAtomic(external, to: file)
        XCTAssertThrowsError(try reopened(store).assertRestorable()); XCTAssertEqual(try SwitcherDisk.read(file), external)
    }
    func testProviderExampleInsideAllStringFormsSurvivesSelectionAndRestore() throws {
        for form in 0..<3 {
            let (root, file, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try store.select(["model": "api"], provider: provider)
            let block = try JSONValue.decode(SwitcherDisk.read(store.journalPath))["providerBlock"].string
            let text = "Retain this example:" + block
            let value: String
            switch form { case 1: value = "'''" + text + "'''"; case 2: value = "\"\"\"" + text + "\"\"\""; default: value = try NativeTOML.quote(text) }
            let edited = "developer_instructions=" + value + "\n" + (try SwitcherDisk.text(file))
            try NativeFile.writeAtomic(Data(edited.utf8), to: file)
            try store.select(["model": "other"], provider: ["name": "Other", "baseUrl": "https://other.invalid/v1"])
            XCTAssertEqual(try store.read().config["developer_instructions"], .string(text))
            try store.restore(); XCTAssertEqual(try store.read().config["developer_instructions"], .string(text))
        }
    }
    func testLiteralCannotProveAnEditedOrExtendedLiveProviderIsStillOwned() throws {
        for extra in [false, true] {
            let (root, file, store) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            try store.select(["model": "api"], provider: provider)
            let block = try JSONValue.decode(SwitcherDisk.read(store.journalPath))["providerBlock"].string
            var live = try SwitcherDisk.text(file)
            if extra { live += "new_setting=true\n" } else { live = live.replacingOccurrences(of: "https://fixture.invalid/v1", with: "https://user-edited.invalid/v1") }
            let edited = "developer_instructions='''" + block + "'''\n" + live
            try NativeFile.writeAtomic(Data(edited.utf8), to: file)
            XCTAssertThrowsError(try store.restore()); XCTAssertEqual(try SwitcherDisk.text(file), edited)
        }
    }
    func testEmptyForeignProviderParentAndFollowingForeignTablesRemain() throws {
        let (root, file, store) = try fixture("model=\"native\"\n[model_providers]\n"); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "api"], provider: provider)
        try NativeFile.writeAtomic(Data((try SwitcherDisk.text(file) + "[agents.reviewer]\nmodel=\"foreign\"\n").utf8), to: file)
        try store.restore(); let config = try store.read().config
        XCTAssertEqual(config["model_providers"], [:]); XCTAssertEqual(config["agents"]?["reviewer"]["model"], "foreign")
    }
    func testFollowingForeignTableRemainsValidWhenOriginalHadNoFinalNewline() throws {
        let (root, file, store) = try fixture("model=\"native\""); defer { try? FileManager.default.removeItem(at: root) }
        try store.select(["model": "api"], provider: provider)
        try NativeFile.writeAtomic(Data((try SwitcherDisk.text(file) + "[agents.reviewer]\nmodel=\"foreign\"\n").utf8), to: file)
        try store.restore(); XCTAssertEqual(try store.read().config["agents"]?["reviewer"]["model"], "foreign"); XCTAssertEqual(try store.read().config["model"], "native")
    }
    func testStaticArraysAreSealedAndDeclaredArrayTablesRemainExtensible() throws {
        for invalid in ["a=[]\n[[a]]\nx=1\n", "a=[{x=1}]\n[[a]]\nx=2\n", "a=[{x=1}]\n[a.y]\nz=2\n", "a=[{x=1}]\na.y=2\n", "[root]\na=[{x=1}]\n[root.a.y]\nz=2\n", "[[root]]\na=[{x=1}]\n[root.a.y]\nz=2\n"] {
            XCTAssertThrowsError(try NativeTOML.parse(invalid)); XCTAssertThrowsError(try NativeTOML.patchDefaults(invalid, values: ["model": "new"]))
        }
        let valid = "[[a]]\nx=1\n[a.child]\ny=2\n[[a]]\nx=3\n[[a.children]]\nz=4\n[[a.children]]\nz=5\n"
        let parsed = try NativeTOML.parse(valid)
        XCTAssertEqual(parsed["a"]?.array.count, 2); XCTAssertEqual(parsed["a"]?.array.last?["children"].array.count, 2)
        XCTAssertEqual(try NativeTOML.parse("a.b.c=1\n[a.b.d]\nx=2\n")["a"]?["b"]["d"]["x"], 2)
    }
}
