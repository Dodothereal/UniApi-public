import XCTest
import CSQLite
import CoreFoundation
@testable import UniApiCore


/// A unique UserDefaults suite with its persistence confined to the fixture
/// home. No cfprefsd write can reach an installed app domain or real home.
private final class IsolatedPreferenceDefaults: UserDefaults {
    let isolatedDomain: String, file: URL
    var values: [String: Any] = [:], registered: [String: Any] = [:], refuseSync = false
    init?(domain: String, file: URL) {
        isolatedDomain = domain; self.file = file
        // The logical domain may reproduce the exact production identity; its
        // underlying CFPreferences suite must still be private to this fixture.
        super.init(suiteName: "uniapi.preferences.fixture.transport." + UUID().uuidString)
    }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    override func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    override func persistentDomain(forName name: String) -> [String: Any]? { name == isolatedDomain && !values.isEmpty ? values : nil }
    override func register(defaults values: [String: Any]) { registered.merge(values) { _, new in new } }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func removePersistentDomain(forName name: String) { if name == isolatedDomain { values.removeAll() } }
    override func synchronize() -> Bool {
        guard !refuseSync else { return false }
        do { let bytes = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0); try NativeFile.writeAtomic(bytes, to: file); return true } catch { return false }
    }
}

private final class PreferenceFixture {
    let root: URL, paths: NativePaths, defaults: IsolatedPreferenceDefaults, legacy: IsolatedPreferenceDefaults, hub: IsolatedPreferenceDefaults
    let domain: String, legacyDomain: String, hubDomain: String
    var connections: [OpaquePointer] = []
    init(destinationDomain: String? = nil, legacyDomain: String? = nil, hubDomain: String? = nil, customData: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("preference-fixture-" + UUID().uuidString)
        paths = NativePaths(root: customData ? root.appendingPathComponent("checkout") : root,
                            home: root.appendingPathComponent("home"),
                            dataRoot: customData ? root.appendingPathComponent("selected-data") : nil)
        try paths.ensureDirectories()
        let suffix = UUID().uuidString
        domain = destinationDomain ?? "uniapi.preferences.fixture.native." + suffix
        self.legacyDomain = legacyDomain ?? "uniapi.preferences.fixture.legacy." + suffix
        self.hubDomain = hubDomain ?? "uniapi.preferences.fixture.hub." + suffix
        defaults = IsolatedPreferenceDefaults(domain: domain, file: root.appendingPathComponent("defaults/native.plist"))!
        legacy = IsolatedPreferenceDefaults(domain: self.legacyDomain, file: root.appendingPathComponent("defaults/legacy.plist"))!
        hub = domain == self.hubDomain ? defaults : IsolatedPreferenceDefaults(domain: self.hubDomain, file: root.appendingPathComponent("defaults/hub.plist"))!
    }
    deinit { connections.forEach { sqlite3_close($0) }; for (suite, name) in [(defaults, domain), (legacy, legacyDomain), (hub, hubDomain)] { suite.removePersistentDomain(forName: name) }; try? FileManager.default.removeItem(at: root) }
    var migration: NativePreferences { .init(paths: paths, defaults: defaults, destinationDomain: domain, legacyDefaults: legacy, legacyDomain: legacyDomain, hubDefaults: hub, hubDomain: hubDomain) }
    var website: URL { paths.home.appendingPathComponent("Library/WebKit/app.devved.uniapi.hub") }
    func marker(host: String = "127.0.0.1", port: UInt16 = 8780, clientHost: String? = nil) -> Data {
        var data = Data()
        func string(_ value: String) { let bytes = Data(value.utf8); var n = UInt32(bytes.count).littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }; data.append(1); data.append(bytes) }
        func origin(_ host: String) { string("http"); string(host); data.append(1); var n = port.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
        origin(host); origin(clientHost ?? host); return data
    }
    @discardableResult func web(_ values: [String: String], relative: String = "WebsiteData/Default/top/client", origin: Data? = nil, oldFilename: Bool = false, bigEndian: Bool = false) throws -> URL {
        let folder = website.appendingPathComponent(relative)
        try NativeFile.writeAtomic(origin ?? marker(), to: folder.appendingPathComponent("origin"))
        let file = folder.appendingPathComponent("LocalStorage/" + (oldFilename ? "http_127.0.0.1_8780.localstorage" : "localstorage.sqlite3"))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?; guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else { throw NativeFailure("Fixture SQLite unavailable") }; connections.append(database)
        guard sqlite3_exec(database, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE ItemTable(key TEXT UNIQUE,value BLOB NOT NULL);", nil, nil, nil) == SQLITE_OK else { throw NativeFailure("Fixture schema failed") }
        for (key, value) in values {
            var bytes = value.data(using: bigEndian ? .utf16BigEndian : .utf16LittleEndian)!
            if bigEndian { bytes.insert(contentsOf: [0xfe, 0xff], at: 0) }
            try insert(key, data: bytes, db: database)
        }
        return file
    }
    func insert(_ key: String, data: Data, db: OpaquePointer? = nil) throws {
        guard let db = db ?? connections.last else { throw NativeFailure("Fixture database missing") }
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO ItemTable(key,value) VALUES(?,?)", -1, &statement, nil) == SQLITE_OK, let statement else { throw NativeFailure("Fixture prepare failed") }; defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        _ = key.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        if data.isEmpty { sqlite3_bind_zeroblob(statement, 2, 0) } else { _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), transient) } }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw NativeFailure("Fixture insert failed") }
    }
    func readState(_ name: String) throws -> JSONValue { try NativeFile.readJSON(paths.bench.appendingPathComponent("state/" + name + ".json")) }
    func journal(_ defaults: JSONObject, files: JSONObject = [:]) throws {
        let value: JSONValue = ["version": 1, "domain": .string(domain), "phase": "pending", "defaults": .object(defaults), "files": .object(files), "rejected": [], "warnings": []]
        try NativeFile.writeAtomic(try value.encoded(), to: migration.journalURL)
    }
}

final class NativePreferencesTests: XCTestCase {
    func testCustomDataRootContainsMigrationJournalAndBenchmarkState() throws {
        let fixture = try PreferenceFixture(customData: true)
        try fixture.web(["uniapi.theme": "light", "uniapi.bench.sel": "{\"included\":[],\"models\":{},\"tier\":\"deep\"}"])
        let first = try fixture.migration.migrate()
        XCTAssertFalse(first.alreadyComplete)
        XCTAssertEqual(try NativeFile.readJSON(fixture.migration.journalURL)["phase"], "complete")
        XCTAssertEqual(try fixture.readState("native-selection")["tier"], "deep")
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-theme"), "light")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent("data").path))
        XCTAssertTrue(try fixture.migration.migrate().alreadyComplete)
    }
    private let curve = "[{\"temperature\":45,\"percent\":0},{\"temperature\":65,\"percent\":25},{\"temperature\":80,\"percent\":65},{\"temperature\":90,\"percent\":100}]"
    private func productionFixture() throws -> PreferenceFixture {
        try PreferenceFixture(destinationDomain: "app.devved.uniapi.hub", legacyDomain: "app.devved.uniapi", hubDomain: "app.devved.uniapi.hub")
    }
    func testProductionHubIdentityPreservesOldDefaultsAndNativeChoicesWithReadOnlyWebSources() throws {
        let fixture = try productionFixture()
        XCTAssertTrue(fixture.defaults === fixture.hub)
        fixture.hub.set(["nested": ["opaque": "old hub value"]], forKey: "oldHub.setting")
        fixture.defaults.set("auto", forKey: "uniapi-theme"); fixture.defaults.set(false, forKey: "uniapi-sidebar")
        fixture.defaults.set(0, forKey: "uniapi.stats.range"); fixture.defaults.set("", forKey: "uniapi.code.project")
        fixture.hub.set("10 20 1100 800 0 0 1920 1080", forKey: "NSWindow Frame UniApiMain")
        fixture.legacy.set("1 2 900 600 0 0 1920 1080", forKey: "NSWindow Frame UniApiMain")
        let oldDefaults = fixture.paths.home.appendingPathComponent("Library/Preferences/app.devved.uniapi.plist")
        try NativeFile.writeAtomic(try PropertyListSerialization.data(fromPropertyList: fixture.legacy.values, format: .binary, options: 0), to: oldDefaults)
        // Exactly the preserved production identity and old deployed WebKit tree.
        let database = try fixture.web(["uniapi.theme": "light", "uniapi.sidebar": "1", "uniapi.stats.range": "30", "uniapi.code.project": "web project", "uniapi.stats.source": "opencode", "uniapi.arena.prompt": "Migrated UTF16 東京", "cookie": "must not import"], relative: "originalWebsiteData", oldFilename: true)
        let sources = [database, URL(fileURLWithPath: database.path + "-wal"), URL(fileURLWithPath: database.path + "-shm"), database.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("origin"), oldDefaults]
        let bytes = try sources.map { try Data(contentsOf: $0) }
        let inodes = try sources.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? NSNumber }
        let migration = NativePreferences(paths: fixture.paths, defaults: fixture.defaults, destinationDomain: fixture.domain, legacyDefaults: fixture.legacy, legacyDomain: fixture.legacyDomain)
        let report = try migration.migrate()
        XCTAssertFalse(report.alreadyComplete); XCTAssertEqual(report.imported.sorted(), ["uniapi.arena.prompt", "uniapi.stats.source"])
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-theme"), "auto"); XCTAssertFalse(fixture.defaults.bool(forKey: "uniapi-sidebar"))
        XCTAssertEqual(fixture.defaults.integer(forKey: "uniapi.stats.range"), 0); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi.code.project"), "")
        XCTAssertEqual(fixture.defaults.string(forKey: "NSWindow Frame UniApiMain"), "10 20 1100 800 0 0 1920 1080")
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi.arena.prompt"), "Migrated UTF16 東京")
        XCTAssertEqual(fixture.defaults.values["oldHub.setting"] as? [String: [String: String]], ["nested": ["opaque": "old hub value"]])
        XCTAssertNil(fixture.defaults.object(forKey: "cookie"))
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, bytes)
        XCTAssertEqual(try sources.map { try FileManager.default.attributesOfItem(atPath: $0.path)[.systemFileNumber] as? NSNumber }, inodes)
        XCTAssertEqual(try NativeFile.readJSON(migration.journalURL)["domain"], "app.devved.uniapi.hub")
    }
    func testProductionHubWithoutFrameImportsSeparateLegacySwiftGeometry() throws {
        let fixture = try productionFixture()
        fixture.hub.set("keep", forKey: "oldHub.setting")
        fixture.legacy.set("1 2 900 600 0 0 1920 1080", forKey: "NSWindow Frame UniApiMain")
        let report = try fixture.migration.migrate()
        XCTAssertEqual(report.imported, ["NSWindow Frame UniApiMain"])
        XCTAssertEqual(fixture.defaults.string(forKey: "NSWindow Frame UniApiMain"), "1 2 900 600 0 0 1920 1080")
        XCTAssertEqual(fixture.hub.string(forKey: "oldHub.setting"), "keep")
        XCTAssertEqual(fixture.legacy.values.count, 1)
    }
    func testProductionHubPendingMigrationResumesAndCompleteDoesNotReimport() throws {
        let fixture = try productionFixture(); try fixture.web(["uniapi.theme": "light", "uniapi.stats.range": "30"])
        fixture.hub.set("keep", forKey: "oldHub.setting"); fixture.defaults.refuseSync = true
        XCTAssertThrowsError(try fixture.migration.migrate())
        XCTAssertEqual(try NativeFile.readJSON(fixture.migration.journalURL)["phase"], "pending")
        fixture.defaults.set("dark", forKey: "uniapi-theme"); fixture.defaults.set(0, forKey: "uniapi.stats.range")
        fixture.defaults.refuseSync = false
        // A pending plan is authoritative after a partial write; do not rescan.
        try fixture.insert("uniapi.theme", data: "auto".data(using: .utf16LittleEndian)!)
        let report = try fixture.migration.migrate()
        XCTAssertEqual(report.preserved.sorted(), ["uniapi-theme", "uniapi.stats.range"])
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-theme"), "dark"); XCTAssertEqual(fixture.defaults.integer(forKey: "uniapi.stats.range"), 0)
        fixture.defaults.removeObject(forKey: "uniapi-theme")
        XCTAssertTrue(try fixture.migration.migrate().alreadyComplete); XCTAssertNil(fixture.defaults.object(forKey: "uniapi-theme"))
        XCTAssertEqual(fixture.hub.string(forKey: "oldHub.setting"), "keep")
    }
    func testDevelopmentCompletionDoesNotSuppressProductionOnSameRoot() throws {
        let fixture = try productionFixture(); try fixture.web(["uniapi.theme": "light", "uniapi.bench.sel": "{\"included\":[],\"models\":{},\"tier\":\"quick\"}"])
        let domain = "app.devved.uniapi.native.development", dev = IsolatedPreferenceDefaults(domain: domain, file: fixture.root.appendingPathComponent("defaults/development.plist"))!
        dev.set("dark", forKey: "uniapi-theme")
        let development = NativePreferences(paths: fixture.paths, defaults: dev, destinationDomain: domain, legacyDefaults: fixture.legacy, legacyDomain: fixture.legacyDomain, hubDefaults: fixture.hub, hubDomain: fixture.hubDomain)
        _ = try development.migrate()
        let devJournal = try Data(contentsOf: development.journalURL)
        XCTAssertNotEqual(development.journalURL, fixture.migration.journalURL)
        let report = try fixture.migration.migrate()
        XCTAssertFalse(report.alreadyComplete); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-theme"), "light")
        XCTAssertEqual(dev.string(forKey: "uniapi-theme"), "dark"); XCTAssertTrue(report.preserved.contains("native-selection"))
        XCTAssertEqual(try Data(contentsOf: development.journalURL), devJournal)
        XCTAssertEqual(try NativeFile.readJSON(development.journalURL)["domain"], .string(domain))
        XCTAssertEqual(try NativeFile.readJSON(fixture.migration.journalURL)["domain"], "app.devved.uniapi.hub")
    }
    func testForeignDevelopmentPendingAndCompleteJournalsCannotAuthorizeProduction() throws {
        for phase in ["pending", "complete"] {
            let fixture = try productionFixture(), domain = "app.devved.uniapi.native.development"
            let foreign: JSONValue = ["version": 1, "domain": .string(domain), "phase": .string(phase), "defaults": [:], "files": [:], "rejected": [], "warnings": []]
            let bytes = try foreign.encoded(); try NativeFile.writeAtomic(bytes, to: fixture.migration.journalURL)
            fixture.hub.set("keep", forKey: "oldHub.setting")
            XCTAssertThrowsError(try fixture.migration.migrate()) { XCTAssertTrue($0.localizedDescription.contains("journal is invalid")) }
            XCTAssertEqual(fixture.hub.values.count, 1); XCTAssertEqual(try Data(contentsOf: fixture.migration.journalURL), bytes)
        }
    }
    func testLegacySwiftSourceAliasStillRefusedBeforeAnyMigrationWrites() throws {
        let fixture = try PreferenceFixture(destinationDomain: "app.devved.uniapi", legacyDomain: "app.devved.uniapi", hubDomain: "app.devved.uniapi.hub")
        fixture.defaults.set("original", forKey: "old.setting")
        XCTAssertThrowsError(try fixture.migration.migrate()) { XCTAssertTrue($0.localizedDescription.contains("legacy Swift source domain")) }
        XCTAssertEqual(fixture.defaults.values.count, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.migration.journalURL.deletingLastPathComponent().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.defaults.file.path))
    }
    func testCompleteWebAllowlistTypedAndConvertedToCurrentNativeStores() throws {
        let fixture = try PreferenceFixture()
        let values = ["uniapi.theme": "light", "uniapi.sidebar": "0", "uniapi.bench.sel": "{\"included\":[\"provider\"],\"models\":{\"provider\":[\"custom/model\"]},\"tier\":\"deep\"}", "uniapi.results.view.v1": "{\"scope\":\"run-123\",\"family\":\"family\",\"tab\":\"charts\",\"lastRunId\":\"run-456\"}", "uniapi.rank.metric": "decode", "uniapi.switcher.engine": "codex", "uniapi.code.project": "project-id", "uniapi.stats.range": "30", "uniapi.stats.source": "opencode", "uniapi.stats.measure": "thinking", "uniapi.stats.metric": "output", "uniapi.stats.ttft.log": "0", "uniapi.transcribe.lang": "de-DE", "uniapi.transcribe.notify": "0", "uniapi.arena.prompt": "Zażółć\nWrite a table: | A | B |", "uniapi.arena.mode": "chosen", "uniapi.arena.chosen": "[\"provider:model\",\"agent:custom\"]", "fans.tab": "\"history\"", "fans.history.range": "\"90d\"", "fans.curve": curve, "fans.duration": "\"never\"", "fans.boost": "\"30\"", "fans.favorites": "[\"HID:CPU\",\"SMC:GPU\"]", "cookie": "private-not-a-preference", "api_key": "private-not-a-preference"]
        try fixture.web(values)
        let report = try fixture.migration.migrate(), stored = fixture.defaults.persistentDomain(forName: fixture.domain)!
        XCTAssertTrue(report.rejected.isEmpty); XCTAssertEqual(report.imported.count, 23)
        XCTAssertEqual(stored["uniapi-theme"] as? String, "light"); XCTAssertEqual(stored["uniapi-sidebar"] as? Bool, false)
        XCTAssertEqual(stored["uniapi.stats.range"] as? Int, 30); XCTAssertEqual(stored["uniapi.stats.source"] as? String, "opencode")
        XCTAssertEqual(stored["uniapi.stats.measure"] as? String, "thinking"); XCTAssertEqual(stored["uniapi.stats.metric"] as? String, "output")
        XCTAssertEqual(stored["uniapi.stats.ttft.log"] as? Bool, false); XCTAssertEqual(stored["uniapi.transcribe.notify"] as? Bool, false)
        XCTAssertEqual(stored["uniapi.fans.tab"] as? String, "timeline"); XCTAssertEqual(stored["uniapi.fans.range"] as? String, "90d")
        XCTAssertEqual(stored["uniapi.fans.duration"] as? Int, 0); XCTAssertEqual(stored["uniapi.fans.boost"] as? Int, 1800)
        XCTAssertEqual(try JSONValue.decode(XCTUnwrap(stored["uniapi.fans.curve"] as? Data)), try JSONValue.decode(Data(curve.utf8)))
        XCTAssertEqual(stored["uniapi.fans.favorites"] as? [String], ["HID:CPU", "SMC:GPU"])
        XCTAssertEqual(stored["uniapi.arena.prompt"] as? String, values["uniapi.arena.prompt"])
        XCTAssertEqual(stored["uniapi.arena.chosen"] as? String, values["uniapi.arena.chosen"])
        XCTAssertEqual(try fixture.readState("native-selection")["models"]["provider"], ["custom/model"])
        XCTAssertEqual(try fixture.readState("native-results-view")["newestRun"], "run-456")
        XCTAssertNil(stored["cookie"]); XCTAssertNil(stored["api_key"])
        let journal = try NativeFile.readJSON(fixture.migration.journalURL); XCTAssertEqual(journal["phase"], "complete"); XCTAssertTrue(journal["defaults"].object.isEmpty)
        XCTAssertFalse(String(decoding: try Data(contentsOf: fixture.migration.journalURL), as: UTF8.self).contains("Zażółć"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.migration.journalURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testWALOnlyValuesImportedWithoutChangingAnySourceBytes() throws {
        let fixture = try PreferenceFixture(), file = try fixture.web(["uniapi.theme": "dark", "uniapi.arena.prompt": "UTF-16 text Grüße 東京"])
        let sources = [file, URL(fileURLWithPath: file.path + "-wal"), URL(fileURLWithPath: file.path + "-shm")]
        let before = try sources.map { try Data(contentsOf: $0) }
        _ = try fixture.migration.migrate()
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi.arena.prompt"), "UTF-16 text Grüße 東京")
        XCTAssertEqual(try sources.map { try Data(contentsOf: $0) }, before)
    }
    func testLegacyDefaultsFallbackWebWinsAndWindowGeometryUsesHub() throws {
        let fixture = try PreferenceFixture()
        let selection: JSONValue = ["included": ["removed-provider"], "models": ["removed-provider": ["custom-model"]], "tier": "quick"]
        fixture.legacy.set("benchmark", forKey: "uniapi-page"); fixture.legacy.set(true, forKey: "uniapi-sidebar"); fixture.legacy.set(try selection.encoded(), forKey: "uniapi-sel-v1")
        fixture.legacy.set("charts", forKey: "uniapi-results-tab"); fixture.legacy.set("gap", forKey: "uniapi-rank-metric"); fixture.legacy.set(7, forKey: "uniapi-stats-range")
        fixture.legacy.set("output", forKey: "uniapi-stats-measure"); fixture.legacy.set("messages", forKey: "uniapi-stats-model-metric"); fixture.legacy.set(false, forKey: "uniapi-stats-ttft-log")
        fixture.legacy.set("1 2 900 600 0 0 1920 1080", forKey: "NSWindow Frame UniApiMain")
        fixture.hub.set("10 20 1100 800 0 0 1920 1080", forKey: "NSWindow Frame UniApiMain")
        try fixture.web(["uniapi.sidebar": "0", "uniapi.stats.range": "30"])
        _ = try fixture.migration.migrate()
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-native-page"), "speed"); XCTAssertFalse(fixture.defaults.bool(forKey: "uniapi-sidebar"))
        XCTAssertEqual(fixture.defaults.integer(forKey: "uniapi.stats.range"), 30); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi.stats.metric"), "messages")
        XCTAssertEqual(fixture.defaults.string(forKey: "NSWindow Frame UniApiMain"), "10 20 1100 800 0 0 1920 1080")
        XCTAssertEqual(try fixture.readState("native-selection"), selection)
        XCTAssertEqual(try fixture.readState("native-results-view")["tab"], "charts")
        XCTAssertEqual(fixture.legacy.string(forKey: "uniapi-page"), "benchmark"); XCTAssertEqual(fixture.legacy.integer(forKey: "uniapi-stats-range"), 7)
    }
    func testExistingNativeChoicesFalseZeroEmptyAndOpaqueFilesArePreserved() throws {
        let fixture = try PreferenceFixture()
        fixture.defaults.set("auto", forKey: "uniapi-theme"); fixture.defaults.set(false, forKey: "uniapi-sidebar"); fixture.defaults.set(0, forKey: "uniapi.stats.range"); fixture.defaults.set("", forKey: "uniapi.code.project"); fixture.defaults.set(Data(), forKey: "uniapi.fans.curve")
        let selection = Data("{\"existing\":true}".utf8), results = Data("existing native choice, needs repair".utf8)
        try NativeFile.writeAtomic(selection, to: fixture.paths.bench.appendingPathComponent("state/native-selection.json")); try NativeFile.writeAtomic(results, to: fixture.paths.bench.appendingPathComponent("state/native-results-view.json"))
        try fixture.web(["uniapi.theme": "dark", "uniapi.sidebar": "1", "uniapi.stats.range": "7", "uniapi.code.project": "other", "fans.curve": curve, "uniapi.bench.sel": "{\"included\":[],\"models\":{},\"tier\":\"deep\"}", "uniapi.results.view.v1": "{\"scope\":\"all\",\"family\":\"\",\"tab\":\"charts\",\"lastRunId\":null}"])
        let report = try fixture.migration.migrate()
        XCTAssertEqual(report.preserved.count, 7); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-theme"), "auto"); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi.code.project"), "")
        XCTAssertEqual(fixture.defaults.data(forKey: "uniapi.fans.curve"), Data()); XCTAssertEqual(fixture.defaults.integer(forKey: "uniapi.stats.range"), 0)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.bench.appendingPathComponent("state/native-selection.json")), selection)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.bench.appendingPathComponent("state/native-results-view.json")), results)
    }
    func testCompletedMigrationNeverReimportsDeletedNativeChoices() throws {
        let fixture = try PreferenceFixture(); try fixture.web(["uniapi.theme": "dark"])
        _ = try fixture.migration.migrate(); fixture.defaults.removeObject(forKey: "uniapi-theme")
        let bytes = try Data(contentsOf: fixture.migration.journalURL), report = try fixture.migration.migrate()
        XCTAssertTrue(report.alreadyComplete); XCTAssertNil(fixture.defaults.object(forKey: "uniapi-theme")); XCTAssertEqual(try Data(contentsOf: fixture.migration.journalURL), bytes)
    }
    func testPendingJournalResumesWithoutRescanningAndKeepsLaterNativeEdit() throws {
        let fixture = try PreferenceFixture()
        try fixture.journal(["uniapi-theme": ["type": "string", "value": "dark"], "uniapi.stats.range": ["type": "integer", "value": 7]], files: ["native-selection": ["included": [], "models": [:], "tier": "quick"]])
        fixture.defaults.set("light", forKey: "uniapi-theme")
        let malformed = fixture.website.appendingPathComponent("WebsiteData/Default/top/client/LocalStorage/localstorage.sqlite3")
        try NativeFile.writeAtomic(fixture.marker(), to: malformed.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("origin")); try NativeFile.writeAtomic(Data("not sqlite".utf8), to: malformed)
        let report = try fixture.migration.migrate()
        XCTAssertEqual(report.preserved, ["uniapi-theme"]); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-theme"), "light"); XCTAssertEqual(fixture.defaults.integer(forKey: "uniapi.stats.range"), 7)
        XCTAssertEqual(try fixture.readState("native-selection")["tier"], "quick"); XCTAssertEqual(try NativeFile.readJSON(fixture.migration.journalURL)["phase"], "complete")
    }
    func testForeignWrongPortAndPartitionOriginsNeverImport() throws {
        for marker in [("evil127.0.0.1", UInt16(8780), "evil127.0.0.1"), ("127.0.0.1", UInt16(8823), "127.0.0.1"), ("127.0.0.1", UInt16(8780), "other.invalid")] {
            let fixture = try PreferenceFixture(); try fixture.web(["uniapi.theme": "dark"], origin: fixture.marker(host: marker.0, port: marker.1, clientHost: marker.2))
            let report = try fixture.migration.migrate(); XCTAssertTrue(report.imported.isEmpty); XCTAssertNil(fixture.defaults.object(forKey: "uniapi-theme"))
        }
    }
    func testOldNamedStoreUTF16BigEndianAndInvalidValuesAreBounded() throws {
        let fixture = try PreferenceFixture(); try fixture.web(["uniapi.theme": "light", "uniapi.transcribe.notify": "0", "fans.duration": "10", "fans.curve": "[{\"temperature\":90,\"percent\":100}]", "uniapi.stats.range": "90", "uniapi.arena.chosen": "[1]"], relative: "originalWebsiteData", oldFilename: true, bigEndian: true)
        try fixture.insert("uniapi.code.project", data: Data([0xff]))
        let report = try fixture.migration.migrate()
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-theme"), "light"); XCTAssertFalse(fixture.defaults.bool(forKey: "uniapi.transcribe.notify"))
        XCTAssertTrue(report.rejected.contains("fans.duration")); XCTAssertTrue(report.rejected.contains("fans.curve")); XCTAssertTrue(report.rejected.contains("uniapi.stats.range")); XCTAssertTrue(report.rejected.contains("uniapi.arena.chosen"))
        XCTAssertNil(fixture.defaults.object(forKey: "uniapi.code.project"))
    }
    func testNewestConfirmedStoreWinsWithoutResurrectingAbsentKeys() throws {
        let fixture = try PreferenceFixture()
        let older = try fixture.web(["uniapi.theme": "dark", "uniapi.code.project": "old"], relative: "originalWebsiteData/a/b")
        let newer = try fixture.web(["uniapi.theme": "light"], relative: "WebsiteData/Default/a/b")
        for file in [older, URL(fileURLWithPath: older.path + "-wal")] { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: file.path) }
        for file in [newer, URL(fileURLWithPath: newer.path + "-wal")] { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: file.path) }
        let report = try fixture.migration.migrate(); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-theme"), "light"); XCTAssertNil(fixture.defaults.object(forKey: "uniapi.code.project")); XCTAssertEqual(report.warnings.count, 1)
    }
    func testReadOnlyReturnsBeforeCreatingJournalOrWritingDefaults() throws {
        let fixture = try PreferenceFixture(), migration = NativePreferences(paths: .init(root: fixture.root, home: fixture.paths.home, readOnly: true), defaults: fixture.defaults, destinationDomain: fixture.domain)
        XCTAssertThrowsError(try migration.migrate()) { XCTAssertTrue($0.localizedDescription.contains("read-only")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: migration.journalURL.path)); XCTAssertNil(fixture.defaults.persistentDomain(forName: fixture.domain))
    }
    func testLinkedOriginAndDestinationCannotRedirectMigration() throws {
        let fixture = try PreferenceFixture(), database = try fixture.web(["uniapi.theme": "dark"])
        let marker = database.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("origin"), other = fixture.root.appendingPathComponent("outside-origin")
        try FileManager.default.moveItem(at: marker, to: other); try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: other)
        XCTAssertThrowsError(try fixture.migration.migrate()); XCTAssertNil(fixture.defaults.object(forKey: "uniapi-theme"))
        try FileManager.default.removeItem(at: marker); try FileManager.default.moveItem(at: other, to: marker)
        let directory = fixture.paths.data.appendingPathComponent("native-preferences"), outside = fixture.root.appendingPathComponent("outside-state")
        try FileManager.default.moveItem(at: directory, to: outside); try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        XCTAssertThrowsError(try fixture.migration.migrate()); XCTAssertNil(fixture.defaults.object(forKey: "uniapi-theme"))
    }
    func testUnownedPendingJournalAndMalformedGeometryFailClosed() throws {
        let fixture = try PreferenceFixture()
        try fixture.journal(["api_key": ["type": "string", "value": "never import"]])
        XCTAssertThrowsError(try fixture.migration.migrate()); XCTAssertNil(fixture.defaults.object(forKey: "api_key"))
        try FileManager.default.removeItem(at: fixture.migration.journalURL)
        fixture.legacy.set("extra 10 20 1100 800 0 0 1920 1080", forKey: "NSWindow Frame UniApiMain")
        let report = try fixture.migration.migrate(); XCTAssertTrue(report.rejected.contains("NSWindow Frame UniApiMain")); XCTAssertNil(fixture.defaults.object(forKey: "NSWindow Frame UniApiMain"))
    }
    func testSynchronizationFailureKeepsPendingJournalForRetry() throws {
        let fixture = try PreferenceFixture(); try fixture.web(["uniapi.theme": "light"])
        fixture.defaults.refuseSync = true
        XCTAssertThrowsError(try fixture.migration.migrate())
        XCTAssertEqual(try NativeFile.readJSON(fixture.migration.journalURL)["phase"], "pending")
        fixture.defaults.refuseSync = false
        _ = try fixture.migration.migrate()
        XCTAssertEqual(try NativeFile.readJSON(fixture.migration.journalURL)["phase"], "complete")
        let persisted = try PropertyListSerialization.propertyList(from: Data(contentsOf: fixture.defaults.file), options: [], format: nil) as? [String: Any]
        XCTAssertEqual(persisted?["uniapi-theme"] as? String, "light")
    }
    func testBinaryLegacyPlistsReadOnlyAndRegisteredFallbackDoesNotWin() throws {
        let fixture = try PreferenceFixture()
        fixture.defaults.register(defaults: ["uniapi-theme": "auto"])
        let old: [String: Any] = ["uniapi-page": "claude", "uniapi-sidebar": false, "uniapi-stats-range": 7, "api_key": "do not import"]
        let file = fixture.paths.home.appendingPathComponent("Library/Preferences/app.devved.uniapi.plist"), bytes = try PropertyListSerialization.data(fromPropertyList: old, format: .binary, options: 0)
        try NativeFile.writeAtomic(bytes, to: file); try fixture.web(["uniapi.theme": "dark"])
        let migration = NativePreferences(paths: fixture.paths, defaults: fixture.defaults, destinationDomain: fixture.domain)
        _ = try migration.migrate()
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-theme"), "dark"); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi-native-page"), "switcher")
        XCTAssertEqual(fixture.defaults.integer(forKey: "uniapi.stats.range"), 7); XCTAssertNil(fixture.defaults.object(forKey: "api_key")); XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testEmptyDraftsSupplementaryUnicodeAndMalformedSurrogates() throws {
        let fixture = try PreferenceFixture(); try fixture.web(["uniapi.arena.prompt": "", "uniapi.code.project": "", "uniapi.transcribe.lang": "", "uniapi.theme": "dark", "uniapi.arena.chosen": "[\"model/𝄞\"]"])
        try fixture.insert("uniapi.stats.source", data: Data([0x00, 0xd8]))
        let report = try fixture.migration.migrate()
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi.arena.prompt"), ""); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi.code.project"), ""); XCTAssertEqual(fixture.defaults.string(forKey: "uniapi.transcribe.lang"), "")
        XCTAssertEqual(fixture.defaults.string(forKey: "uniapi.arena.chosen"), "[\"model/𝄞\"]"); XCTAssertNil(fixture.defaults.object(forKey: "uniapi.stats.source"))
        XCTAssertTrue(report.warnings.contains { $0.contains("uniapi.stats.source") })
    }

}
