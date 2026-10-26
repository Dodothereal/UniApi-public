import XCTest
import Darwin
@testable import UniApiCore

private final class RoutePublicationFault: @unchecked Sendable {
    private let lock = NSLock()
    private var point: NativeCodexPublicationPoint?
    private var edit: (@Sendable () throws -> Void)?
    private var interrupts = true
    func arm(_ point: NativeCodexPublicationPoint, interrupts: Bool = true, edit: (@Sendable () throws -> Void)? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.point = point; self.interrupts = interrupts; self.edit = edit
    }
    func hit(_ point: NativeCodexPublicationPoint) throws {
        lock.lock()
        let matches = self.point == point, edit = self.edit, interrupts = self.interrupts
        if matches { self.point = nil; self.edit = nil }
        lock.unlock()
        if matches {
            try edit?()
            if interrupts { throw NativeFailure("Fixture interrupted config publication") }
        }
    }
}

final class CodexNativeRouteStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL, paths: NativePaths, store: NativeCodexRouteStore
        var config: URL { store.configPath }
        func receipt() throws -> String { SwitcherDisk.hash(try SwitcherDisk.read(config)) }
        func reopened(readOnly: Bool = false) -> NativeCodexRouteStore {
            .init(paths: .init(root: paths.root, home: paths.home, readOnly: readOnly))
        }
    }
    private let original = """
    # Retain root comment and literal transport examples.
    model = "original-model" # selected default
    model_reasoning_effort = "high"
    model_provider = "openai"
    openai_base_url = "" # original empty transport
    developer_instructions = 'features.multi_agent = false'
    [features]
    multi_agent = false # original feature comment
    multi_agent_v2 = true
    responses_websockets = true
    responses_websockets_v2 = true
    unrelated = "retain-feature"
    [model_providers.foreign]
    name = "Retained provider"
    base_url = "https://fixture.invalid/v1"
    [hooks]
    command = "retain-hook"

    """
    private func fixture(_ text: String? = nil, fault: RoutePublicationFault? = nil, writeConfig: Bool = true) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-route-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let paths = NativePaths(root: root.appendingPathComponent("repo"), home: root.appendingPathComponent("home"))
        _ = try NativeCodexRoutingSecret.load(paths, create: true)
        let store = NativeCodexRouteStore(paths: paths, publicationHook: { try fault?.hit($0) })
        if writeConfig { try NativeFile.writeAtomic(Data((text ?? original).utf8), to: store.configPath) }
        return Fixture(root: root, paths: paths, store: store)
    }
    private func document(_ fixture: Fixture) throws -> JSONObject { try NativeTOML.parse(SwitcherDisk.text(fixture.config)) }
    private func journal(_ fixture: Fixture) throws -> JSONValue { try JSONValue.decode(SwitcherDisk.read(fixture.store.journalPath, missing: false)) }
    private func write(_ text: String, to fixture: Fixture) throws { try NativeFile.writeAtomic(Data(text.utf8), to: fixture.config) }
    private func permissions(_ file: URL) throws -> Int { (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1 }
    private func tree(_ root: URL) -> [String] { FileManager.default.subpaths(atPath: root.path)?.sorted() ?? [] }

    func testBaseURLAndPrivatePaths() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        XCTAssertEqual(try f.store.baseURL(), "http://127.0.0.1:8823/_uniapi/codex/" + (try NativeCodexRoutingSecret.load(f.paths)) + "/v1")
        XCTAssertEqual(try f.store.baseURL(port: 19999), "http://127.0.0.1:19999/_uniapi/codex/" + (try NativeCodexRoutingSecret.load(f.paths)) + "/v1")
        XCTAssertEqual(f.config, f.paths.home.appendingPathComponent(".codex/config.toml"))
        XCTAssertEqual(f.store.stateDirectory, f.paths.data.appendingPathComponent("codex/native-route", isDirectory: true))
        XCTAssertEqual(f.store.catalog.file, f.store.stateDirectory.appendingPathComponent("uniapi-catalog.json"))
        XCTAssertEqual(f.store.catalog.providersFile, f.paths.providers)
    }
    func testPrivateTOMLRoundTripAndExactBackup() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try SwitcherDisk.read(f.config), parsed = try document(f)
        let status = try f.store.connect(expectedConfigSHA256: f.receipt())
        XCTAssertEqual(status["connected"], true); XCTAssertEqual(status["phase"], "committed")
        XCTAssertTrue(status["baseUrl"].string.contains("<private>"))
        XCTAssertFalse(String(decoding: try status.encoded(), as: UTF8.self).contains(try NativeCodexRoutingSecret.load(f.paths)))
        let saved = try journal(f), backup = URL(fileURLWithPath: saved["backupPath"].string)
        XCTAssertEqual(saved["previous"], .object(NativeTOML.transportValues(parsed)))
        XCTAssertEqual(try SwitcherDisk.read(backup), before)
        XCTAssertEqual(try permissions(backup), 0o600); XCTAssertEqual(try permissions(f.store.journalPath), 0o600)
        XCTAssertEqual(try permissions(f.config), 0o600)
        let installed = try document(f)
        XCTAssertEqual(installed["openai_base_url"], .string(try f.store.baseURL()))
        XCTAssertNil(installed["model_catalog_json"])
        XCTAssertEqual(installed["features"]?["multi_agent"], true)
        for key in ["multi_agent_v2", "responses_websockets", "responses_websockets_v2"] { XCTAssertEqual(installed["features"]?[key], false) }
        XCTAssertEqual(installed["model_providers"], parsed["model_providers"])
        XCTAssertEqual(installed["model_provider"], "openai"); XCTAssertEqual(installed["model"], "original-model")
        XCTAssertEqual(try f.store.restore()["connected"], false)
        XCTAssertEqual(try document(f), parsed)
        XCTAssertEqual(try SwitcherDisk.read(f.config), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.journalPath.path))
        XCTAssertEqual(try SwitcherDisk.read(backup), before)
    }
    func testRestorePreservesLaterDefaultsProviderAndUnrelatedEdits() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.store.connect(expectedConfigSHA256: f.receipt())
        let text = try SwitcherDisk.text(f.config)
            .replacingOccurrences(of: "\"original-model\"", with: "\"later-model\"")
            .replacingOccurrences(of: "model_reasoning_effort = \"high\"", with: "model_reasoning_effort = \"low\"")
            .replacingOccurrences(of: "model_provider = \"openai\"", with: "model_provider = \"foreign\"")
            .replacingOccurrences(of: "command = \"retain-hook\"", with: "command = \"later-hook\"\nlater = 42")
        try write(text, to: f)
        _ = try f.store.restore()
        let restored = try document(f)
        XCTAssertEqual(restored["model"], "later-model"); XCTAssertEqual(restored["model_reasoning_effort"], "low")
        XCTAssertEqual(restored["model_provider"], "foreign"); XCTAssertEqual(restored["hooks"]?["later"], 42)
        XCTAssertEqual(restored["hooks"]?["command"], "later-hook")
        XCTAssertEqual(NativeTOML.transportValues(restored), NativeTOML.transportValues(try NativeTOML.parse(original)))
        XCTAssertTrue(try SwitcherDisk.text(f.config).contains("# original feature comment"))
    }
    func testDefaultsJournalAndCatalogMembershipRemainUntouched() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let defaults = f.paths.data.appendingPathComponent("codex/defaults-journal.json"), sentinel = Data("private defaults owner fixture".utf8)
        try NativeFile.writeAtomic(sentinel, to: defaults)
        let choices: JSONValue = ["providerIds": ["fixture"], "workerModels": ["uniapi/fixture/worker"]]
        try f.store.catalog.write(choices); let membership = try SwitcherDisk.read(f.store.catalog.file)
        _ = try f.store.connect(expectedConfigSHA256: f.receipt()); _ = try f.store.restore()
        XCTAssertEqual(try SwitcherDisk.read(defaults), sentinel)
        XCTAssertEqual(try SwitcherDisk.read(f.store.catalog.file), membership)
    }
    func testRestorePreservesLaterWrongTypedUnownedProviderDefault() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.store.connect(expectedConfigSHA256: f.receipt())
        try write(SwitcherDisk.text(f.config).replacingOccurrences(of: "model_provider = \"openai\"", with: "model_provider = 7"), to: f)
        _ = try f.store.restore()
        XCTAssertEqual(try document(f)["model_provider"], 7)
        XCTAssertEqual(try document(f)["openai_base_url"], "")
    }
    func testForeignBridgeCatalogAndNonOpenAIProviderAreRefused() throws {
        for text in ["openai_base_url='http://127.0.0.1:9555/v1'\n", "openai_base_url='http://127.0.0.1:8823/_uniapi/codex/unowned/v1'\n",
                     "openai_base_url=' '\n", "model_catalog_json='foreign.json'\n", "model_catalog_json=''\n", "model_provider='foreign'\n", "model_provider=''\n"] {
            let f = try fixture(text); defer { try? FileManager.default.removeItem(at: f.root) }
            let before = try SwitcherDisk.read(f.config)
            XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt()))
            XCTAssertEqual(try SwitcherDisk.read(f.config), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.journalPath.path))
        }
    }
    func testBadPreexistingTypesAreNeverNormalizedIntoOwnership() throws {
        for text in ["openai_base_url=42\n", "model_catalog_json=false\n", "features=[]\n", "features=true\n", "model_provider=7\n",
                     "features.multi_agent='true'\n", "features.multi_agent_v2=1\n", "features.responses_websockets=[]\n", "features.responses_websockets_v2={}\n"] {
            let f = try fixture(text); defer { try? FileManager.default.removeItem(at: f.root) }
            XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt()))
            XCTAssertEqual(try SwitcherDisk.text(f.config), text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.journalPath.path))
        }
    }
    func testReadOnlyMutationsAndStatusCreateNothing() throws {
        let f = try fixture(writeConfig: false); defer { try? FileManager.default.removeItem(at: f.root) }
        let reader = f.reopened(readOnly: true), before = tree(f.root)
        XCTAssertEqual(try reader.status()["connected"], false)
        XCTAssertThrowsError(try reader.connect(expectedConfigSHA256: SwitcherDisk.hash(Data())))
        XCTAssertThrowsError(try reader.restore())
        XCTAssertEqual(tree(f.root), before)
    }
    func testWritableStatusAlsoCreatesNoConfigLockOrJournal() throws {
        let f = try fixture(writeConfig: false); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = tree(f.root)
        XCTAssertEqual(try f.store.status()["connected"], false)
        XCTAssertEqual(tree(f.root), before)
    }
    func testExpectedHandoffReceiptAndInvalidPortRefuseBeforeJournal() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try SwitcherDisk.read(f.config)
        XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt(), port: 0))
        XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt(), port: 65536))
        XCTAssertEqual(try SwitcherDisk.read(f.config), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.journalPath.path))
    }
    func testOwnedIdempotencePreservesOriginalBackupAndRequiresExplicitPortChange() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let receipt = try f.receipt()
        _ = try f.store.connect(expectedConfigSHA256: receipt, port: 19999)
        let bytes = try SwitcherDisk.read(f.config), saved = try SwitcherDisk.read(f.store.journalPath)
        XCTAssertEqual(try f.store.connect(expectedConfigSHA256: receipt, port: 19999)["connected"], true)
        XCTAssertEqual(try SwitcherDisk.read(f.config), bytes); XCTAssertEqual(try SwitcherDisk.read(f.store.journalPath), saved)
        XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt(), port: 8823))
        XCTAssertEqual(try SwitcherDisk.read(f.store.journalPath), saved)
    }
    func testInstallCrashesBeforeAndAfterRenameReconcileOnlyOnMutation() throws {
        for point in [NativeCodexPublicationPoint.beforeConfigRename(.select), .afterConfigRename(.select)] {
            let fault = RoutePublicationFault(), f = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: f.root) }
            let original = try SwitcherDisk.read(f.config)
            fault.arm(point); XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt()))
            let saved = try SwitcherDisk.read(f.store.journalPath), current = try SwitcherDisk.read(f.config)
            XCTAssertEqual(try journal(f)["phase"], "pending-install")
            let reader = f.reopened(readOnly: true), didRename = point == .afterConfigRename(.select)
            XCTAssertEqual(try reader.status()["connected"], .bool(didRename))
            XCTAssertEqual(try reader.status()["canRestore"], false)
            XCTAssertEqual(try SwitcherDisk.read(f.config), current); XCTAssertEqual(try SwitcherDisk.read(f.store.journalPath), saved)
            _ = try f.reopened().restore()
            XCTAssertEqual(try SwitcherDisk.read(f.config), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.journalPath.path))
            XCTAssertFalse(tree(f.root).contains { $0.contains(".uniapi-route-") })
        }
    }
    func testRestoreCrashesBeforeAndAfterRenameAreRetryable() throws {
        for point in [NativeCodexPublicationPoint.beforeConfigRename(.restore), .afterConfigRename(.restore)] {
            let fault = RoutePublicationFault(), f = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: f.root) }
            let before = try SwitcherDisk.read(f.config)
            _ = try f.store.connect(expectedConfigSHA256: f.receipt())
            fault.arm(point); XCTAssertThrowsError(try f.store.restore())
            XCTAssertEqual(try journal(f)["phase"], "pending-restore")
            let bytes = try SwitcherDisk.read(f.config), saved = try SwitcherDisk.read(f.store.journalPath)
            XCTAssertEqual(try f.reopened().status()["connected"], .bool(point == .beforeConfigRename(.restore)))
            XCTAssertEqual(try SwitcherDisk.read(f.config), bytes); XCTAssertEqual(try SwitcherDisk.read(f.store.journalPath), saved)
            XCTAssertEqual(try f.reopened().restore()["connected"], false)
            XCTAssertEqual(try SwitcherDisk.read(f.config), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.store.journalPath.path))
        }
    }
    func testPendingInstallBeforeRenameCanRetryWithFreshReceipt() throws {
        let fault = RoutePublicationFault(), f = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: f.root) }
        fault.arm(.beforeConfigRename(.select)); XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt()))
        let saved = try SwitcherDisk.read(f.store.journalPath)
        XCTAssertThrowsError(try f.reopened().connect(expectedConfigSHA256: "stale-receipt"))
        XCTAssertEqual(try SwitcherDisk.read(f.store.journalPath), saved)
        XCTAssertEqual(try f.reopened().connect(expectedConfigSHA256: f.receipt())["connected"], true)
        _ = try f.reopened().restore(); XCTAssertEqual(try SwitcherDisk.text(f.config), original)
    }
    func testImmediateWholeByteCASPreservesUnrelatedEditAtInstallBoundary() throws {
        let fault = RoutePublicationFault(), f = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: f.root) }
        let file = f.config, edit = Data((original + "[later]\nvalue=42\n").utf8)
        fault.arm(.beforeConfigRename(.select), interrupts: false, edit: { try NativeFile.writeAtomic(edit, to: file) })
        XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt()))
        XCTAssertEqual(try SwitcherDisk.read(file), edit)
        XCTAssertEqual(try f.reopened().status()["owned"], false)
        _ = try f.reopened().restore(); XCTAssertEqual(try SwitcherDisk.read(file), edit)
    }
    func testImmediateWholeByteCASPreservesUnrelatedEditAtRestoreBoundary() throws {
        let fault = RoutePublicationFault(), f = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: f.root) }
        _ = try f.store.connect(expectedConfigSHA256: f.receipt())
        let file = f.config, edit = Data((try SwitcherDisk.text(file) + "[later]\nvalue=43\n").utf8)
        fault.arm(.beforeConfigRename(.restore), interrupts: false, edit: { try NativeFile.writeAtomic(edit, to: file) })
        XCTAssertThrowsError(try f.store.restore()); XCTAssertEqual(try SwitcherDisk.read(file), edit)
        _ = try f.reopened().restore()
        XCTAssertEqual(try document(f)["later"]?["value"], 43)
        XCTAssertEqual(NativeTOML.transportValues(try document(f)), NativeTOML.transportValues(try NativeTOML.parse(original)))
    }
    func testChangedOwnedFieldFailsClosedInEveryJournalPhase() throws {
        for point in [NativeCodexPublicationPoint.beforeConfigRename(.select), .afterConfigRename(.select), .beforeConfigRename(.restore), .afterConfigRename(.restore)] {
            let fault = RoutePublicationFault(), f = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: f.root) }
            if point == .beforeConfigRename(.restore) || point == .afterConfigRename(.restore) {
                _ = try f.store.connect(expectedConfigSHA256: f.receipt()); fault.arm(point); XCTAssertThrowsError(try f.store.restore())
            } else { fault.arm(point); XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt())) }
            let text = try NativeTOML.patchTransport(SwitcherDisk.text(f.config), values: ["openai_base_url": "https://operator.invalid/v1"])
            try write(text, to: f)
            let saved = try SwitcherDisk.read(f.store.journalPath)
            XCTAssertThrowsError(try f.reopened().status()); XCTAssertThrowsError(try f.reopened().restore())
            XCTAssertThrowsError(try f.reopened().connect(expectedConfigSHA256: f.receipt()))
            XCTAssertEqual(try SwitcherDisk.text(f.config), text); XCTAssertEqual(try SwitcherDisk.read(f.store.journalPath), saved)
        }
    }
    func testOwnedEditAfterRealRenameRetainsPendingJournal() throws {
        for operation in [NativeCodexWriteOperation.select, .restore] {
            let fault = RoutePublicationFault(), f = try fixture(fault: fault); defer { try? FileManager.default.removeItem(at: f.root) }
            if operation == .restore { _ = try f.store.connect(expectedConfigSHA256: f.receipt()) }
            let file = f.config
            fault.arm(.afterConfigRename(operation), interrupts: false, edit: {
                let changed = try NativeTOML.patchTransport(SwitcherDisk.text(file), values: ["openai_base_url": "https://operator.invalid/after-rename"])
                try NativeFile.writeAtomic(Data(changed.utf8), to: file)
            })
            if operation == .select { XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt())) }
            else { XCTAssertThrowsError(try f.store.restore()) }
            XCTAssertEqual(try journal(f)["phase"], operation == .select ? "pending-install" : "pending-restore")
            XCTAssertEqual(try document(f)["openai_base_url"], "https://operator.invalid/after-rename")
            let config = try SwitcherDisk.read(file), saved = try SwitcherDisk.read(f.store.journalPath)
            XCTAssertThrowsError(try f.reopened().restore())
            XCTAssertEqual(try SwitcherDisk.read(file), config); XCTAssertEqual(try SwitcherDisk.read(f.store.journalPath), saved)
        }
    }
    func testCommittedJournalRejectsOperatorReversionAndMixedOwnership() throws {
        for change in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            _ = try f.store.connect(expectedConfigSHA256: f.receipt())
            let text = change ? try NativeTOML.patchTransport(SwitcherDisk.text(f.config), values: ["features.multi_agent_v2": true]) : original
            try write(text, to: f)
            XCTAssertThrowsError(try f.reopened().restore()); XCTAssertThrowsError(try f.reopened().status())
            XCTAssertEqual(try SwitcherDisk.text(f.config), text)
        }
    }
    func testStrictJournalIdentityAndBackupValidationFailClosed() throws {
        let mutations: [(inout JSONValue) -> Void] = [
            { $0["version"] = 2 }, { $0["configPath"] = "foreign/config.toml" }, { $0["phase"] = "unknown" },
            { $0["generation"] = "not-a-generation" }, { $0["previous"] = [:] }, { $0["installed"]["features.multi_agent"] = false },
            { $0["backupPath"] = "../outside.toml" }, { $0["backupSHA256"] = .string(String(repeating: "0", count: 64)) },
            { $0["port"] = 1.5 }, { $0["extra"] = true }
        ]
        for mutate in mutations {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            _ = try f.store.connect(expectedConfigSHA256: f.receipt())
            let bytes = try SwitcherDisk.read(f.config)
            var value = try journal(f); mutate(&value); try NativeFile.writeAtomic(try value.encoded(), to: f.store.journalPath)
            let saved = try SwitcherDisk.read(f.store.journalPath)
            XCTAssertThrowsError(try f.reopened().status()); XCTAssertThrowsError(try f.reopened().restore())
            XCTAssertEqual(try SwitcherDisk.read(f.config), bytes); XCTAssertEqual(try SwitcherDisk.read(f.store.journalPath), saved)
        }
    }
    func testMissingAlteredOrNonPrivateBackupNeverAuthorizesRestore() throws {
        for mode in 0..<3 {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            _ = try f.store.connect(expectedConfigSHA256: f.receipt())
            let backup = URL(fileURLWithPath: try journal(f)["backupPath"].string), bytes = try SwitcherDisk.read(f.config)
            switch mode {
            case 0: try FileManager.default.removeItem(at: backup)
            case 1: try NativeFile.writeAtomic(Data((original + "# alteration\n").utf8), to: backup)
            default: try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backup.path)
            }
            XCTAssertThrowsError(try f.reopened().restore()); XCTAssertThrowsError(try f.reopened().status())
            XCTAssertEqual(try SwitcherDisk.read(f.config), bytes)
        }
    }
    func testLinkedJournalAndBackupAreRejected() throws {
        for targetJournal in [false, true] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            _ = try f.store.connect(expectedConfigSHA256: f.receipt())
            let target = targetJournal ? f.store.journalPath : URL(fileURLWithPath: try journal(f)["backupPath"].string)
            let bytes = try SwitcherDisk.read(f.config), moved = f.root.appendingPathComponent("private-moved-file")
            try FileManager.default.moveItem(at: target, to: moved)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
            XCTAssertThrowsError(try f.reopened().restore()); XCTAssertEqual(try SwitcherDisk.read(f.config), bytes)
        }
    }
    func testLinkedStateDirectoryCannotRedirectPrivateBackupWrites() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let destination = f.root.appendingPathComponent("foreign-directory"), parent = f.paths.data.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The fixture now seeds the private route capability in this directory.
        // Retain it before installing the hostile directory link.
        try FileManager.default.moveItem(at: f.store.stateDirectory, to: f.root.appendingPathComponent("retained-native-route"))
        try FileManager.default.createSymbolicLink(at: f.store.stateDirectory, withDestinationURL: destination)
        let bytes = try SwitcherDisk.read(f.config)
        XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt()))
        XCTAssertEqual(try SwitcherDisk.read(f.config), bytes)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }
    func testInheritedACLIsRefusedBeforeWritingFullConfigBackup() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.store.stateDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var acl: acl_t? = acl_init(1)
        guard acl != nil else { throw NativeFailure("Cannot allocate fixture ACL") }
        defer { if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        guard acl_create_entry(&acl, &entry) == 0, let entry else { throw NativeFailure("Cannot create fixture ACL entry") }
        var everyone = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!.uuid
        guard acl_set_tag_type(entry, ACL_EXTENDED_ALLOW) == 0,
              withUnsafePointer(to: &everyone, { acl_set_qualifier(entry, $0) }) == 0 else { throw NativeFailure("Cannot identify fixture ACL principal") }
        var permissions: acl_permset_t?, flags: acl_flagset_t?
        guard acl_get_permset(entry, &permissions) == 0, let permissions,
              acl_add_perm(permissions, ACL_READ_DATA) == 0, acl_add_perm(permissions, ACL_SEARCH) == 0,
              acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flags) == 0, let flags,
              acl_add_flag_np(flags, ACL_ENTRY_FILE_INHERIT) == 0, acl_add_flag_np(flags, ACL_ENTRY_DIRECTORY_INHERIT) == 0,
              let acl, acl_set_file(f.store.stateDirectory.path, ACL_TYPE_EXTENDED, acl) == 0 else { throw NativeFailure("Cannot install fixture ACL") }
        let bytes = try SwitcherDisk.read(f.config)
        let existing = try FileManager.default.contentsOfDirectory(atPath: f.store.stateDirectory.path).sorted()
        let existingBytes = try Dictionary(uniqueKeysWithValues: existing.map { ($0, try SwitcherDisk.read(f.store.stateDirectory.appendingPathComponent($0))) })
        XCTAssertThrowsError(try f.store.connect(expectedConfigSHA256: f.receipt()))
        XCTAssertEqual(try SwitcherDisk.read(f.config), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.store.stateDirectory.path).sorted(), existing)
        for (name, data) in existingBytes { XCTAssertEqual(try SwitcherDisk.read(f.store.stateDirectory.appendingPathComponent(name)), data) }
    }
    func testRestoreWhenFeaturesWereInitiallyAbsent() throws {
        // Parent-owned NativeTOML regression: removing the last inserted dotted
        // feature must accept an absent parent as well as an empty feature table.
        let f = try fixture("model='original'\n# unrelated\n[hooks]\ncommand='keep'\n")
        defer { try? FileManager.default.removeItem(at: f.root) }
        let previous = NativeTOML.transportValues(try document(f))
        _ = try f.store.connect(expectedConfigSHA256: f.receipt())
        _ = try f.store.restore()
        XCTAssertEqual(NativeTOML.transportValues(try document(f)), previous)
        XCTAssertEqual(try document(f)["hooks"]?["command"], "keep")
        XCTAssertEqual(try document(f)["model"], "original")
    }
}
