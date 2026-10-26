import Foundation
import SwiftUI
import XCTest
@testable import UniApiCore

@MainActor final class FanDurationG4AcceptanceTests: XCTestCase {
    private let key = "uniapi.fans.duration"
    private let snapshot: JSONValue = ["fans": [["id": 0, "minimum": 1200, "maximum": 6000, "actual": 1800, "target": 2100]]]

    func testFreshAppStorageDefaultsToTenMinutesAndBuildsTimedManualCommand() throws {
        let fixture = try FanDurationG4Fixture(); defer { fixture.clean() }
        let duration = AppStorage(wrappedValue: NativeHardwareDisplayPolicies.defaultFanDuration, key, store: fixture.defaults)
        XCTAssertEqual(duration.wrappedValue, 600)
        XCTAssertTrue(NativeHardwareDisplayPolicies.fanDurations.contains(duration.wrappedValue))
        let command = try XCTUnwrap(NativeHardwareDisplayPolicies.manualFanCommand(snapshot: snapshot, id: 0, rpm: 2300, duration: duration.wrappedValue))
        XCTAssertEqual(command["duration"], 600); XCTAssertEqual(command["speeds"], [2300])
        XCTAssertNil(fixture.defaults.persistentDomain(forName: fixture.domain)?[key])
    }

    func testEverySavedNativeDurationIncludingNeverSurvivesPageRecreation() throws {
        let fixture = try FanDurationG4Fixture(); defer { fixture.clean() }
        for saved in NativeHardwareDisplayPolicies.fanDurations {
            fixture.defaults.set(saved, forKey: key)
            let first = AppStorage(wrappedValue: NativeHardwareDisplayPolicies.defaultFanDuration, key, store: fixture.defaults)
            let reopened = AppStorage(wrappedValue: NativeHardwareDisplayPolicies.defaultFanDuration, key, store: fixture.defaults)
            XCTAssertEqual(first.wrappedValue, saved); XCTAssertEqual(reopened.wrappedValue, saved)
            let command = try XCTUnwrap(NativeHardwareDisplayPolicies.manualFanCommand(snapshot: snapshot, id: 0, rpm: 2300, duration: reopened.wrappedValue))
            XCTAssertEqual(command["duration"], .number(Double(saved)))
            XCTAssertEqual(fixture.defaults.persistentDomain(forName: fixture.domain)?[key] as? Int, saved)
        }
    }

    func testPendingMigrationOverridesOnlyFreshFallbackForAllAcceptedWebDurations() throws {
        // Exercise the real migration replay/validation with typed, synthetic
        // journals. Existing NativePreferencesTests cover original WebKit reads.
        for migrated in [0, 60, 300, 600, 1800, 3600] {
            let fixture = try FanDurationG4Fixture(); defer { fixture.clean() }
            let fresh = AppStorage(wrappedValue: NativeHardwareDisplayPolicies.defaultFanDuration, key, store: fixture.defaults)
            XCTAssertEqual(fresh.wrappedValue, 600)
            try fixture.pending(migrated)
            let report = try fixture.migration.migrate()
            XCTAssertEqual(report.imported, [key]); XCTAssertTrue(report.preserved.isEmpty)
            let migratedStorage = AppStorage(wrappedValue: NativeHardwareDisplayPolicies.defaultFanDuration, key, store: fixture.defaults)
            XCTAssertEqual(migratedStorage.wrappedValue, migrated)
            XCTAssertTrue(try fixture.migration.migrate().alreadyComplete)
            XCTAssertEqual(fixture.defaults.integer(forKey: key), migrated)
        }
    }

    func testSavedNeverAndTimedChoicesWinOverConflictingPendingMigration() throws {
        for (saved, imported) in [(0, 600), (900, 0), (3600, 60)] {
            let fixture = try FanDurationG4Fixture(); defer { fixture.clean() }
            fixture.defaults.set(saved, forKey: key)
            try fixture.pending(imported)
            let report = try fixture.migration.migrate()
            XCTAssertEqual(report.preserved, [key]); XCTAssertTrue(report.imported.isEmpty)
            let duration = AppStorage(wrappedValue: NativeHardwareDisplayPolicies.defaultFanDuration, key, store: fixture.defaults)
            XCTAssertEqual(duration.wrappedValue, saved)
            XCTAssertEqual(fixture.defaults.persistentDomain(forName: fixture.domain)?[key] as? Int, saved)
        }
    }
}

private final class FanDurationG4Fixture {
    let root: URL, paths: NativePaths, domain: String, defaults: UserDefaults
    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("fan-duration-g4-" + UUID().uuidString)
        paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        try paths.ensureDirectories()
        domain = "uniapi.fan-duration-g4.fixture." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
    }
    var migration: NativePreferences { NativePreferences(paths: paths, defaults: defaults, destinationDomain: domain) }
    func pending(_ seconds: Int) throws {
        let journal: JSONValue = ["version": 1, "domain": .string(domain), "phase": "pending", "defaults": ["uniapi.fans.duration": ["type": "integer", "value": .number(Double(seconds))]], "files": [:], "rejected": [], "warnings": []]
        try NativeFile.writeAtomic(try journal.encoded(), to: migration.journalURL)
    }
    func clean() { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
}
