import XCTest
import Darwin
@testable import UniApiCore

final class TransferTests: XCTestCase {
    func testNoListenerNeedsNoHubRequestButExistingWindowBlocksTransfer() async throws {
        let empty = try await NativeTransferCheck.inspect(port: 0, shimPort: 0, get: { _ in XCTFail("Unexpected hub request"); return .null }, legacyUI: { false })
        XCTAssertTrue(empty.canTransfer)
        let window = try await NativeTransferCheck.inspect(port: 0, shimPort: 0, get: { _ in XCTFail("Unexpected hub request"); return .null }, legacyUI: { true })
        XCTAssertFalse(window.canTransfer)
    }
    func testVerifiedListenerReportsWorkButAnIdleSnapshotCannotAuthorizeStoppingIt() async throws {
        let listener = try NativeOwnership.claim(port: 0)
        let busy = try await NativeTransferCheck.inspect(port: listener.port, shimPort: 0, get: { path in
            if path == "/api/health" { return ["ok": true, "apps": ["code"]] }
            if path.hasPrefix("/api/jobs") { return [["status": "queued"]] }
            return [["status": "waiting"]]
        }, legacyUI: { false })
        XCTAssertFalse(busy.canTransfer); XCTAssertEqual(busy.activeJobs, 1); XCTAssertEqual(busy.activeCode, 1)
        let idle = try await NativeTransferCheck.inspect(port: listener.port, shimPort: 0, get: { path in
            if path == "/api/health" { return ["ok": true, "apps": ["code"]] }
            if path.hasPrefix("/api/jobs") { return [] }
            return [["status": "idle", "alive": true]]
        }, legacyUI: { false })
        XCTAssertFalse(idle.canTransfer); XCTAssertEqual(idle.activeJobs, 0); XCTAssertEqual(idle.activeCode, 0)
    }
    func testUnknownListenerOrMalformedWorkInventoryIsNotIdleEvidence() async throws {
        let listener = try NativeOwnership.claim(port: 0)
        do { _ = try await NativeTransferCheck.inspect(port: listener.port, shimPort: 0, get: { _ in ["ok": true] }, legacyUI: { false }); XCTFail("Unknown listener accepted") } catch {}
        do { _ = try await NativeTransferCheck.inspect(port: listener.port, shimPort: 0, get: { path in path == "/api/health" ? ["ok": true, "apps": ["code"]] : [:] }, legacyUI: { false }); XCTFail("Malformed inventory accepted") } catch {}
    }
    func testReadyMarkerBindsToCurrentOwnerAndReadOnlyNeverWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), paths = NativePaths(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try paths.ensureDirectories()
        try NativeHealth.write(paths: paths, ready: true)
        XCTAssertTrue(try NativeHealth.read(paths: paths, expectedPID: getpid(), expectedInstance: NativeHealth.instance)["ready"].bool)
        XCTAssertThrowsError(try NativeHealth.read(paths: paths, expectedPID: getpid() + 1, expectedInstance: NativeHealth.instance))
        XCTAssertThrowsError(try NativeHealth.read(paths: paths, expectedPID: getpid(), expectedInstance: UUID().uuidString))
        try NativeHealth.write(paths: paths, ready: false)
        XCTAssertThrowsError(try NativeHealth.read(paths: paths, expectedPID: getpid(), expectedInstance: NativeHealth.instance))
        let before = try Data(contentsOf: paths.data.appendingPathComponent("native-status.json"))
        XCTAssertThrowsError(try NativeHealth.write(paths: NativePaths(root: root, readOnly: true), ready: true))
        XCTAssertEqual(try Data(contentsOf: paths.data.appendingPathComponent("native-status.json")), before)
    }
    func testShimReadinessRequiresSwiftPIDAndCurrentInstallationInstance() async throws {
        let nonce = UUID().uuidString
        let valid: JSONValue = ["ok": true, "service": "uniapi-shim", "runtime": "swift", "pid": .number(Double(getpid())), "instance": .string(nonce)]
        let health = try await NativeHealth.shim(expectedPID: getpid(), expectedInstance: nonce, get: { valid })
        XCTAssertTrue(health["ok"].bool)
        for key in ["instance", "pid", "runtime", "service", "ok"] {
            var bad = valid; bad[key] = .null
            let response = bad
            do { _ = try await NativeHealth.shim(expectedPID: getpid(), expectedInstance: nonce, get: { response }); XCTFail("Invalid shim accepted: " + key) } catch {}
        }
    }

    func testIndependentShimOwnerPreventsTransferEvenWithNoHubListener() async throws {
        let shim = try NativeOwnership.claim(port: 0)
        let busy = try await NativeTransferCheck.inspect(port: 0, shimPort: shim.port, get: { _ in XCTFail("Hub should be absent"); return .null }, shimGet: { ["ok": true, "service": "uniapi-shim", "activeRequests": 1] }, legacyUI: { false })
        XCTAssertFalse(busy.canTransfer); XCTAssertTrue(busy.shimPresent); XCTAssertEqual(busy.activeShim, 1)
        let unknown = try await NativeTransferCheck.inspect(port: 0, shimPort: shim.port, shimGet: { ["ok": true, "service": "uniapi-shim"] }, legacyUI: { false })
        XCTAssertFalse(unknown.canTransfer); XCTAssertNil(unknown.activeShim)
    }

}
