import XCTest
@testable import UniApiCore

final class NativeAppUpdateTests: XCTestCase {
    private final class Record: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        private var busy = 0
        func add(_ value: String) { lock.withLock { storage.append(value) } }
        var values: [String] { lock.withLock { storage } }
        func setBusy(_ value: Int) { lock.withLock { busy = value } }
        func takeBusy() -> Int { lock.withLock { defer { busy = max(0, busy - 1) }; return busy } }
    }
    private func runtime() throws -> (NativeRuntime, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uniapi-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try NativeRuntime(paths: NativePaths(root: root, home: root, dataRoot: root.appendingPathComponent("data"))), root)
    }
    private func io(_ record: Record, current: String = "0.1.16", latest: String = "0.1.17", digest: String = String(repeating: "a", count: 64),
                    bundled: String? = nil, unavailable: String? = nil, result: String? = "installed", output: String? = nil) -> NativeAppUpdateIO {
        .init(currentVersion: { NativeAppVersion(current) }, unavailable: { unavailable },
              latest: { record.add("latest"); return NativeAppVersion(latest)! },
              text: { url in record.add("text " + url.lastPathComponent); return String(repeating: "a", count: 64) + "  UniApi-macos-\(latest).zip\n" },
              download: { url, destination, progress in
                  record.add("download " + url.absoluteString); progress(0.5)
                  try Data("zip".utf8).write(to: destination)
              },
              // Staged installer scripts are sealed by their real contents.
              digest: { url in url.pathExtension == "zip" ? digest : try Data(contentsOf: url).map { String(format: "%02x", $0) }.joined() },
              extract: { _, folder in
                  record.add("extract")
                  let package = folder.appendingPathComponent("UniApi-macos-\(latest)")
                  try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
                  try FileManager.default.createDirectory(at: package.appendingPathComponent("tools"), withIntermediateDirectories: true)
                  try Data("#!/bin/bash\n".utf8).write(to: package.appendingPathComponent("install.sh"))
                  try Data("#!/bin/bash\n# transfer\n".utf8).write(to: package.appendingPathComponent("tools/install-native.sh"))
              },
              validate: { _ in record.add("validate"); return NativeAppVersion(bundled ?? latest)! },
              work: { let busy = record.takeBusy(); record.add("work \(busy)"); return .init(jobs: busy, code: 0) },
              launch: { package, resultFile, log in
                  record.add("launch " + package.lastPathComponent + " " + log.lastPathComponent)
                  if let output { try Data(output.utf8).write(to: log) }
                  if let result { try Data("{\"status\":\"\(result)\",\"version\":\"\(latest)\"}".utf8).write(to: resultFile) }
              },
              now: { 1_000_000 }, sleep: { _ in await Task.yield() })
    }

    func testVersionParsingAndOrdering() {
        XCTAssertEqual(NativeAppVersion("0.1.17")?.description, "0.1.17")
        XCTAssertNil(NativeAppVersion("0.1")); XCTAssertNil(NativeAppVersion("1.2.3.4")); XCTAssertNil(NativeAppVersion("1.2.x"))
        XCTAssertNil(NativeAppVersion("1..3")); XCTAssertNil(NativeAppVersion("-1.2.3")); XCTAssertNil(NativeAppVersion("1.2.3 "))
        XCTAssertTrue(NativeAppVersion("0.1.9")! < NativeAppVersion("0.1.17")!)
        XCTAssertTrue(NativeAppVersion("0.9.9")! < NativeAppVersion("3.0.0")!)
        XCTAssertFalse(NativeAppUpdatePolicy.isNewer(NativeAppVersion("0.1.17")!, than: NativeAppVersion("3.0.0")))
        XCTAssertFalse(NativeAppUpdatePolicy.isNewer(NativeAppVersion("0.1.17")!, than: NativeAppVersion("0.1.17")))
        XCTAssertFalse(NativeAppUpdatePolicy.isNewer(NativeAppVersion("0.1.17")!, than: nil))
    }
    func testReleaseAddressesAndChecksumAdmission() {
        let version = NativeAppVersion("0.1.17")!
        XCTAssertEqual(NativeAppUpdatePolicy.version(fromReleaseURL: URL(string: "https://github.com/Dodothereal/UniApi-public/releases/tag/v0.1.17")!), version)
        for refused in ["https://github.com/Dodothereal/UniApi-public/releases", "https://github.com/Other/UniApi-public/releases/tag/v0.1.17",
                        "http://github.com/Dodothereal/UniApi-public/releases/tag/v0.1.17", "https://example.com/Dodothereal/UniApi-public/releases/tag/v0.1.17",
                        "https://github.com/Dodothereal/UniApi-public/releases/tag/0.1.17", "https://github.com/Dodothereal/UniApi-public/releases/tag/v0.1.17-beta"] {
            XCTAssertNil(NativeAppUpdatePolicy.version(fromReleaseURL: URL(string: refused)!), refused)
        }
        XCTAssertEqual(NativeAppUpdatePolicy.packageURL(version).absoluteString, "https://github.com/Dodothereal/UniApi-public/releases/download/v0.1.17/UniApi-macos-0.1.17.zip")
        XCTAssertEqual(NativeAppUpdatePolicy.checksumURL(version).lastPathComponent, "UniApi-macos-0.1.17.zip.sha256")
        let digest = "d5b23456d14b915610bde0b54b00d0585f23b11feab07ff7ada1ea7bdb3a37b8"
        XCTAssertEqual(NativeAppUpdatePolicy.checksum(digest + "  UniApi-macos-0.1.17.zip\n", version: version), digest)
        XCTAssertEqual(NativeAppUpdatePolicy.checksum(digest.uppercased() + "  UniApi-macos-0.1.17.zip", version: version), digest)
        XCTAssertNil(NativeAppUpdatePolicy.checksum(digest + "  UniApi-macos-0.1.16.zip\n", version: version))
        XCTAssertNil(NativeAppUpdatePolicy.checksum(String(digest.dropLast()) + "  UniApi-macos-0.1.17.zip\n", version: version))
        XCTAssertNil(NativeAppUpdatePolicy.checksum("<html>Not Found</html>", version: version))
        XCTAssertNil(NativeAppUpdatePolicy.checksum(digest + "  UniApi-macos-0.1.17.zip\n" + digest + "  UniApi-macos-0.1.17.zip\n", version: version))
    }
    func testAutomaticCheckInterval() {
        XCTAssertTrue(NativeAppUpdatePolicy.shouldCheck(lastCheckedAt: nil, now: 10, automatic: true))
        XCTAssertFalse(NativeAppUpdatePolicy.shouldCheck(lastCheckedAt: nil, now: 10, automatic: false))
        XCTAssertFalse(NativeAppUpdatePolicy.shouldCheck(lastCheckedAt: 0, now: 3_600_000, automatic: true))
        XCTAssertTrue(NativeAppUpdatePolicy.shouldCheck(lastCheckedAt: 0, now: 6 * 3_600_000, automatic: true))
        XCTAssertTrue(NativeAppUpdatePolicy.busyMessage(jobs: 1, code: 2).hasPrefix("Waiting for 1 job and 2 coding turns"))
    }

    func testCheckStagesAVerifiedNewerRelease() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record))
        await updater.start(); await updater.check()
        let state = await updater.state()
        XCTAssertEqual(state["phase"].string, "ready"); XCTAssertEqual(state["latest"].string, "0.1.17")
        XCTAssertEqual(state["staged"].string, "0.1.17"); XCTAssertTrue(state["available"].bool)
        XCTAssertEqual(record.values, ["latest", "text UniApi-macos-0.1.17.zip.sha256",
            "download https://github.com/Dodothereal/UniApi-public/releases/download/v0.1.17/UniApi-macos-0.1.17.zip", "extract", "validate"])
        // The archive is removed once its contents are admitted.
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.data.appendingPathComponent("updates/0.1.17/UniApi-macos-0.1.17.zip").path))
        // A repeated check reuses the staged package.
        await updater.check()
        XCTAssertEqual(record.values.filter { $0.hasPrefix("download") }.count, 1)
    }
    func testCurrentOrNewerBuildDownloadsNothing() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record, current: "3.0.0"))
        await updater.check()
        let state = await updater.state()
        XCTAssertEqual(state["phase"].string, "current"); XCTAssertFalse(state["available"].bool)
        XCTAssertEqual(record.values, ["latest"])
    }
    func testChecksumMismatchDiscardsTheDownload() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record, digest: String(repeating: "b", count: 64)))
        await updater.check()
        let state = await updater.state()
        XCTAssertEqual(state["phase"].string, "failed"); XCTAssertTrue(state["staged"].isNull)
        XCTAssertTrue(state["message"].string.contains("checksum"))
        XCTAssertFalse(record.values.contains("extract"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.data.appendingPathComponent("updates/0.1.17").path))
    }
    func testPackageWithAnotherVersionIsRefused() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record, bundled: "0.1.15"))
        await updater.check()
        let state = await updater.state()
        XCTAssertEqual(state["phase"].string, "failed"); XCTAssertTrue(state["staged"].isNull)
        await updater.install { }
        XCTAssertFalse(record.values.contains { $0.hasPrefix("launch") })
    }
    func testUnavailableInstallationNeverChecks() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record, unavailable: "Development build"))
        await updater.start(); await updater.check()
        let state = await updater.state()
        XCTAssertEqual(state["phase"].string, "unavailable"); XCTAssertEqual(state["message"].string, "Development build")
        XCTAssertTrue(record.values.isEmpty)
    }
    private func settle(_ updater: NativeAppUpdater, until phases: Set<String>) async -> JSONValue {
        for _ in 0..<2_000 {
            let state = await updater.state()
            if phases.contains(state["phase"].string) { return state }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return await updater.state()
    }
    func testInstallWaitsForIdleThenHidesAndLaunches() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record))
        await updater.check()
        record.setBusy(2)
        await updater.install { record.add("hide") }
        let state = await settle(updater, until: ["current", "failed"])
        XCTAssertEqual(state["phase"].string, "current"); XCTAssertEqual(state["result"]["status"].string, "installed")
        let steps = record.values.drop { !$0.hasPrefix("work") }
        XCTAssertEqual(Array(steps), ["work 2", "work 1", "work 0", "validate", "hide", "launch UniApi-macos-0.1.17 update-0.1.17.log"])
    }
    func testRefusedInstallerReportsFailureAndKeepsTheStagedUpdate() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record, result: "failed"))
        await updater.check()
        await updater.install { record.add("hide") }
        let state = await settle(updater, until: ["current", "failed"])
        XCTAssertEqual(state["phase"].string, "failed"); XCTAssertEqual(state["staged"].string, "0.1.17")
        // Without a statement from the installer nothing is claimed about what was restored.
        XCTAssertTrue(state["message"].string.contains("state of the installation is unknown")); XCTAssertFalse(state["message"].string.contains("restored"))
        await updater.acknowledgeResult()
        let cleared = await updater.state()
        XCTAssertEqual(cleared["phase"].string, "ready"); XCTAssertTrue(cleared["result"].isNull)
    }
    func testFailureMessagesFollowTheInstallerLog() async throws {
        let restored = "Stopping services\nNative installation failed; previous app/service definitions and running PIDs restored. Data and configs retained.\n"
        let incomplete = "Native installation failed; recovery is incomplete. Backups and configs retained at /tmp/backup; inspect restored services before continuing.\n"
        let retained = "Native recovery could not retire only this install's idle services; current app and definitions retained. Evidence: /tmp/evidence\n" + restored
        let refused = "Checking\nAnother native transfer owns the installation lock.\n\n"
        func message(_ log: String) -> String { NativeAppUpdatePolicy.failureMessage(log: log, path: "/logs/update.log") }
        XCTAssertTrue(message(restored).contains("restored the previous version")); XCTAssertTrue(message(restored).hasSuffix("Log: /logs/update.log"))
        for log in [incomplete, retained] {
            XCTAssertTrue(message(log).contains("could not fully restore"), log); XCTAssertFalse(message(log).contains("restored the previous version"), log)
        }
        XCTAssertTrue(message(refused).contains("was not installed")); XCTAssertTrue(message(refused).contains("Another native transfer owns the installation lock."))
        XCTAssertFalse(message(refused).contains("restored"))
        XCTAssertTrue(message("").contains("unknown")); XCTAssertFalse(NativeAppUpdatePolicy.failureMessage(log: "", path: "").contains("Log:"))
        // The updater reads the log the installer wrote for that version, also after a restart.
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record, result: "failed", output: incomplete))
        await updater.check()
        await updater.install { record.add("hide") }
        let state = await settle(updater, until: ["current", "failed"])
        XCTAssertTrue(state["message"].string.contains("could not fully restore")); XCTAssertTrue(state["message"].string.contains("update-0.1.17.log"))
        let next = NativeAppUpdater(runtime: runtime, io: io(Record()))
        await next.start()
        let saved = await next.state()
        XCTAssertEqual(saved["phase"].string, "failed"); XCTAssertTrue(saved["message"].string.contains("could not fully restore"))
    }
    func testVerifiedStageSurvivesARestartOnlyWhileUnchanged() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let first = NativeAppUpdater(runtime: runtime, io: io(Record()))
        await first.check()
        let record = Record(), second = NativeAppUpdater(runtime: runtime, io: io(record))
        await second.start()
        var state = await second.state()
        XCTAssertEqual(state["phase"].string, "ready"); XCTAssertEqual(state["staged"].string, "0.1.17"); XCTAssertEqual(state["latest"].string, "0.1.17")
        XCTAssertEqual(record.values, ["validate"])
        // The same release is not downloaded again by the next check.
        await second.check()
        state = await second.state()
        XCTAssertEqual(state["phase"].string, "ready"); XCTAssertFalse(record.values.contains { $0.hasPrefix("download") })
        // A package whose installer changed after verification is discarded.
        let stage = runtime.paths.data.appendingPathComponent("updates/0.1.17")
        try Data("#!/bin/bash\nrm -rf /\n".utf8).write(to: stage.appendingPathComponent("UniApi-macos-0.1.17/tools/install-native.sh"))
        let third = NativeAppUpdater(runtime: runtime, io: io(Record()))
        await third.start()
        state = await third.state()
        XCTAssertEqual(state["phase"].string, "idle"); XCTAssertTrue(state["staged"].isNull)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        // So is one the installed build has caught up with, and one whose bundle no longer validates.
        await first.check()
        let current = NativeAppUpdater(runtime: runtime, io: io(Record(), current: "0.1.17"))
        await current.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
        let again = NativeAppUpdater(runtime: runtime, io: io(Record()))
        await again.check()
        let invalid = NativeAppUpdater(runtime: runtime, io: io(Record(), bundled: "0.1.15"))
        await invalid.start()
        state = await invalid.state()
        XCTAssertTrue(state["staged"].isNull); XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
    func testStagedPackageChangedBeforeInstallIsRefused() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record))
        await updater.check()
        try Data("changed".utf8).write(to: runtime.paths.data.appendingPathComponent("updates/0.1.17/UniApi-macos-0.1.17/install.sh"))
        await updater.install { record.add("hide") }
        let state = await settle(updater, until: ["current", "failed"])
        XCTAssertEqual(state["phase"].string, "failed"); XCTAssertTrue(state["staged"].isNull)
        XCTAssertFalse(record.values.contains("hide")); XCTAssertFalse(record.values.contains { $0.hasPrefix("launch") })
    }
    func testWaitingInstallCanBeCancelled() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), updater = NativeAppUpdater(runtime: runtime, io: io(record))
        await updater.check()
        record.setBusy(1_000_000)
        await updater.install { record.add("hide") }
        _ = await settle(updater, until: ["waiting"])
        await updater.cancelInstall()
        let state = await updater.state()
        XCTAssertEqual(state["phase"].string, "ready")
        XCTAssertFalse(record.values.contains("hide")); XCTAssertFalse(record.values.contains { $0.hasPrefix("launch") })
    }
    func testCancelDuringTheFinalCheckLaunchesNothing() async throws {
        final class Holder: @unchecked Sendable { var updater: NativeAppUpdater?; var armed = false }
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let record = Record(), holder = Holder()
        var io = io(record)
        // Cancel arrives while the signature of the waiting update is checked.
        io.validate = { _ in
            record.add("validate")
            if holder.armed { holder.armed = false; await holder.updater?.cancelInstall() }
            return NativeAppVersion("0.1.17")!
        }
        let updater = NativeAppUpdater(runtime: runtime, io: io)
        holder.updater = updater
        await updater.check()
        record.setBusy(1); holder.armed = true
        await updater.install { record.add("hide") }
        for _ in 0..<200 where holder.armed { try await Task.sleep(nanoseconds: 5_000_000) }
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let state = await updater.state()
        XCTAssertFalse(holder.armed)
        XCTAssertEqual(state["phase"].string, "ready"); XCTAssertEqual(state["staged"].string, "0.1.17")
        XCTAssertFalse(record.values.contains("hide")); XCTAssertFalse(record.values.contains { $0.hasPrefix("launch") })
    }
    func testStartReportsSavedFailureAndRemovesStaleStages() async throws {
        let (runtime, root) = try runtime(); defer { try? FileManager.default.removeItem(at: root) }
        let updates = runtime.paths.data.appendingPathComponent("updates")
        for name in ["0.1.15", "0.1.16", "0.1.18"] { try FileManager.default.createDirectory(at: updates.appendingPathComponent(name), withIntermediateDirectories: true) }
        try Data("{\"status\":\"failed\",\"version\":\"0.1.18\"}".utf8).write(to: updates.appendingPathComponent("last-result.json"))
        let updater = NativeAppUpdater(runtime: runtime, io: io(Record()))
        await updater.start()
        let state = await updater.state()
        XCTAssertEqual(state["phase"].string, "failed"); XCTAssertEqual(state["result"]["version"].string, "0.1.18")
        XCTAssertTrue(state["message"].string.contains("unknown")); XCTAssertTrue(state["staged"].isNull)
        // A folder without a verification record is not a staged update.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: updates.path).sorted(), ["last-result.json"])
    }
    func testInstallerScriptReportsOnlyValidatedValues() {
        let script = NativeAppUpdateSystem.installer
        XCTAssertTrue(script.contains("\"$package/install.sh\" --install"))
        XCTAssertTrue(script.contains("launchctl print"))
        XCTAssertFalse(script.contains("rm -rf \"$application\""))
    }
}
