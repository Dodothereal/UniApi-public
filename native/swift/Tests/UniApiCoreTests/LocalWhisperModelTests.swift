import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import UniApiCore

private actor WhisperTestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        signalled = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private final class WhisperLifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
        lock.lock(); defer { lock.unlock() }; values.append(value)
    }
    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }; return values
    }
}

final class LocalWhisperModelTests: XCTestCase {
    private let bytes = Data("small offline Whisper fixture".utf8)
    private let progress: NativeLocalWhisperModels.Progress = { _, _ in }
    private func fixture() throws -> NativePaths {
        // Resolve the system temp alias in the test; production rejects linked ancestors.
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("whisper-model-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return NativePaths(root: root, home: root)
    }
    private func descriptor(_ data: Data, count: Int64? = nil, hash: String? = nil) -> LocalWhisperAssets {
        LocalWhisperAssets(url: URL(string: "https://example.invalid/offline-model")!,
            bytes: count ?? Int64(data.count),
            sha256: hash ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
    private func modelURL(_ paths: NativePaths) -> URL {
        paths.data.appendingPathComponent("local-models/whisper/ggml-large-v3-turbo-q5_0.bin")
    }
    private func store(_ paths: NativePaths, data: Data, asset: LocalWhisperAssets? = nil) -> NativeLocalWhisperModels {
        NativeLocalWhisperModels(paths: paths, assets: asset ?? descriptor(data), downloader: { _, file, _, report in
            try file.write(contentsOf: data)
            try await report(0.5, "Offline fixture")
        })
    }
    private func assertNoPartials(_ paths: NativePaths, file: StaticString = #filePath, line: UInt = #line) throws {
        let directory = modelURL(paths).deletingLastPathComponent()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".part") }, file: file, line: line)
    }
    private func assertFailure(_ operation: () async throws -> Void,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected failure", file: file, line: line) } catch { }
    }

    func testPinnedProductionDescriptor() {
        let asset = LocalWhisperAssets.production
        XCTAssertEqual(asset.bytes, 574041195)
        XCTAssertEqual(asset.sha256, "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
        XCTAssertTrue(asset.url.absoluteString.contains("/87cd18b47b941d2f65d09981dad23bb7d0481c77/"))
        XCTAssertEqual(asset.url.host, "huggingface.co")
    }

    func testOnlyKnownSystemVarAliasIsNormalizedAtComponentBoundary() throws {
        XCTAssertEqual(try NativeLocalWhisperModels.modelStoragePath("/var"), "/private/var")
        XCTAssertEqual(try NativeLocalWhisperModels.modelStoragePath("/var/folders/fixture/data"),
                       "/private/var/folders/fixture/data")
        for unchanged in ["/var-other/fixture", "/variable/fixture", "/private/var/folders/fixture", "/Users/fixture/var"] {
            XCTAssertEqual(try NativeLocalWhisperModels.modelStoragePath(unchanged), unchanged)
        }
    }

    func testSystemTempAliasSupportsInstallStatusLeaseAndRemovalButRejectsPlantedChildLink() async throws {
        // Exercise NativePaths' actual standardization of the host's existing temp path.
        let paths = try fixture(), models = store(paths, data: bytes)
        try await models.install(progress: progress)
        let state = await models.status(); XCTAssertTrue(state["available"].bool)
        let data = try await models.withModel { try Data(contentsOf: $0) }
        XCTAssertEqual(data, bytes)
        try await models.remove()
        let directory = modelURL(paths).deletingLastPathComponent()
        let relocated = paths.root.appendingPathComponent("relocated-whisper")
        try FileManager.default.moveItem(at: directory, to: relocated)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: relocated)
        await assertFailure { try await models.install(progress: self.progress) }
        let linked = await models.status(); XCTAssertFalse(linked["available"].bool)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: relocated.path), [".model.lock"])
    }
    func testExplicitInstallStatusPermissionsLeaseAndRemove() async throws {
        let paths = try fixture(), data = bytes
        let models = store(paths, data: data)
        let initial = await models.status()
        XCTAssertFalse(initial["available"].bool)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.data.path))
        try await models.install(progress: progress)
        let installed = await models.status()
        XCTAssertTrue(installed["available"].bool)
        XCTAssertEqual(try Data(contentsOf: modelURL(paths)), data)
        let permissions: [(URL, mode_t)] = [(modelURL(paths), 0o600),
            (modelURL(paths).deletingLastPathComponent(), 0o700),
            (paths.data.appendingPathComponent("local-models"), 0o700)]
        for (url, expected) in permissions {
            var info = stat(); XCTAssertEqual(lstat(url.path, &info), 0)
            XCTAssertEqual(info.st_mode & 0o777, expected)
        }
        let leased = try await models.withModel { try Data(contentsOf: $0) }
        XCTAssertEqual(leased, data)
        try await models.remove()
        let removed = await models.status()
        XCTAssertFalse(removed["available"].bool)
        try assertNoPartials(paths)
    }
    func testSizeAndChecksumMismatchNeverPublish() async throws {
        for asset in [descriptor(bytes, count: Int64(bytes.count + 1)),
                      descriptor(bytes, hash: String(repeating: "0", count: 64))] {
            let paths = try fixture(), models = store(paths, data: bytes, asset: asset)
            await assertFailure { try await models.install(progress: self.progress) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL(paths).path))
            try assertNoPartials(paths)
        }
    }
    func testCancellationCleansOnlyItsPartial() async throws {
        let paths = try fixture(), started = WhisperTestSignal(), data = bytes
        let models = NativeLocalWhisperModels(paths: paths, assets: descriptor(data), downloader: { _, handle, _, _ in
            try handle.write(contentsOf: data)
            await started.signal()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        let task = Task { try await models.install(progress: progress) }
        await started.wait()
        let foreign = modelURL(paths).deletingLastPathComponent().appendingPathComponent("someone-else.part")
        try Data("keep".utf8).write(to: foreign)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled install succeeded") } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try Data(contentsOf: foreign), Data("keep".utf8))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: foreign.deletingLastPathComponent().path)
        XCTAssertEqual(remaining.sorted(), [".model.lock", "someone-else.part"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL(paths).path))
        let state = await models.status(); XCTAssertFalse(state["installing"].bool)
    }
    func testConcurrentInstallAndRemoveAreRejected() async throws {
        let paths = try fixture(), entered = WhisperTestSignal(), release = WhisperTestSignal(), data = bytes
        let models = NativeLocalWhisperModels(paths: paths, assets: descriptor(data), downloader: { _, handle, _, _ in
            await entered.signal(); await release.wait()
            try handle.write(contentsOf: data)
        })
        let task = Task { try await models.install(progress: progress) }
        await entered.wait()
        await assertFailure { try await models.install(progress: self.progress) }
        await assertFailure { try await models.remove() }
        await assertFailure { try await models.withModel { _ in () } }
        await release.signal(); try await task.value
        let state = await models.status(); XCTAssertTrue(state["available"].bool)
    }
    func testLeaseBlocksRemoveAndReleasesOnThrow() async throws {
        let paths = try fixture(), models = store(paths, data: bytes)
        try await models.install(progress: progress)
        let entered = WhisperTestSignal(), release = WhisperTestSignal()
        let lease = Task {
            try await models.withModel { _ -> Int in
                await entered.signal(); await release.wait()
                throw NativeFailure("Inference failed")
            }
        }
        await entered.wait()
        let state = await models.status(); XCTAssertTrue(state["inUse"].bool)
        await assertFailure { try await models.remove() }
        await release.signal()
        await assertFailure { _ = try await lease.value }
        try await models.remove()
        let after = await models.status(); XCTAssertFalse(after["inUse"].bool)
    }
    func testThrowingFinalProgressDoesNotPublish() async throws {
        let paths = try fixture(), models = store(paths, data: bytes)
        await assertFailure {
            try await models.install { fraction, _ in
                if fraction == 1 { throw CancellationError() }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL(paths).path))
        try assertNoPartials(paths)
    }
    func testUnsafeAndUnavailablePathsDoNotDownload() async throws {
        let paths = try fixture()
        try Data("not a directory".utf8).write(to: paths.data)
        let models = NativeLocalWhisperModels(paths: paths, assets: descriptor(bytes), downloader: { _, _, _, _ in
            XCTFail("Unsafe storage must not invoke downloader")
        })
        let state = await models.status(); XCTAssertFalse(state["available"].bool)
        await assertFailure { try await models.install(progress: self.progress) }
        await assertFailure { try await models.withModel { _ in () } }
        XCTAssertEqual(try Data(contentsOf: paths.data), Data("not a directory".utf8))
    }
    func testLinksAndPermissiveFilesAreRejected() async throws {
        let paths = try fixture(), models = store(paths, data: bytes)
        try await models.install(progress: progress)
        let final = modelURL(paths), other = paths.root.appendingPathComponent("other.bin")
        try FileManager.default.moveItem(at: final, to: other)
        try FileManager.default.createSymbolicLink(at: final, withDestinationURL: other)
        let linked = await models.status(); XCTAssertFalse(linked["available"].bool)
        await assertFailure { try await models.remove() }
        await assertFailure { try await models.install(progress: self.progress) }
        try FileManager.default.removeItem(at: final)
        XCTAssertEqual(link(other.path, final.path), 0)
        let hardlinked = await models.status(); XCTAssertFalse(hardlinked["available"].bool)
        await assertFailure { try await models.remove() }
        try FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: other, to: final)
        XCTAssertEqual(chmod(final.path, 0o644), 0)
        let permissive = await models.status(); XCTAssertFalse(permissive["available"].bool)
        await assertFailure { try await models.withModel { _ in () } }
    }
    func testLinkedDirectoryAndReadOnlyStorageAreRejected() async throws {
        let paths = try fixture(), target = paths.root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: paths.data, withDestinationURL: target)
        let models = store(paths, data: bytes)
        await assertFailure { try await models.install(progress: self.progress) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        let readOnly = NativePaths(root: paths.root, home: paths.root, readOnly: true)
        let preview = store(readOnly, data: bytes)
        await assertFailure { try await preview.install(progress: self.progress) }
        await assertFailure { try await preview.remove() }
    }
    func testExistingVerifiedModelDoesNotDownloadAgain() async throws {
        let paths = try fixture(), first = store(paths, data: bytes)
        try await first.install(progress: progress)
        let second = NativeLocalWhisperModels(paths: paths, assets: descriptor(bytes), downloader: { _, _, _, _ in
            XCTFail("Installed verified model must not be downloaded again")
        })
        try await second.install(progress: progress)
        try assertNoPartials(paths)
    }
    func testCorruptInstalledModelIsNotAcceptedOrOverwritten() async throws {
        let paths = try fixture(), models = store(paths, data: bytes)
        try await models.install(progress: progress)
        let invalid = Data(repeating: 120, count: bytes.count)
        let handle = try FileHandle(forWritingTo: modelURL(paths))
        try handle.write(contentsOf: invalid); try handle.close()
        let state = await models.status(); XCTAssertFalse(state["available"].bool)
        await assertFailure { try await models.install(progress: self.progress) }
        await assertFailure { try await models.withModel { _ in () } }
        XCTAssertEqual(try Data(contentsOf: modelURL(paths)), invalid)
        try await models.remove()
    }
    func testCancelledLeaseReleasesRemovalGuard() async throws {
        let paths = try fixture(), models = store(paths, data: bytes), entered = WhisperTestSignal()
        try await models.install(progress: progress)
        let lease = Task {
            try await models.withModel { _ in
                await entered.signal()
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        await entered.wait(); lease.cancel()
        await assertFailure { try await lease.value }
        try await models.remove()
        let state = await models.status(); XCTAssertFalse(state["inUse"].bool)
    }
    func testReplacedPartialIsPreservedAndNeverPromoted() async throws {
        let paths = try fixture(), data = bytes
        let directory = modelURL(paths).deletingLastPathComponent()
        let models = NativeLocalWhisperModels(paths: paths, assets: descriptor(data), downloader: { _, handle, _, _ in
            try handle.write(contentsOf: data)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let partial = directory.appendingPathComponent(try XCTUnwrap(names.first { $0.hasSuffix(".part") }))
            try FileManager.default.removeItem(at: partial)
            try Data("replacement".utf8).write(to: partial)
        })
        await assertFailure { try await models.install(progress: self.progress) }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0 != ".model.lock" }
        XCTAssertEqual(remaining.count, 1)
        let replacement = try XCTUnwrap(remaining.first)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(replacement)), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL(paths).path))
    }

    func testVerifiedFingerprintAvoidsRepeatedStatusAndLeaseHashes() async throws {
        let paths = try fixture(), models = store(paths, data: bytes)
        try await models.install(progress: progress)
        let first = await models.status(); XCTAssertTrue(first["available"].bool)
        let count = await models.verificationHashCount
        for _ in 0..<3 {
            let state = await models.status(); XCTAssertTrue(state["available"].bool)
            _ = try await models.withModel { try Data(contentsOf: $0) }
        }
        let after = await models.verificationHashCount
        XCTAssertEqual(after, count)
        // A separate store must independently verify; no persisted metadata grants trust.
        let fresh = store(paths, data: bytes)
        let freshState = await fresh.status(); XCTAssertTrue(freshState["available"].bool)
        let freshCount = await fresh.verificationHashCount; XCTAssertEqual(freshCount, 1)
    }

    func testSameSizeEditWithRestoredMtimeInvalidatesCachedHash() async throws {
        let paths = try fixture(), models = store(paths, data: bytes)
        try await models.install(progress: progress)
        let before = await models.status(); XCTAssertTrue(before["available"].bool)
        let count = await models.verificationHashCount
        let url = modelURL(paths)
        var original = stat(); XCTAssertEqual(lstat(url.path, &original), 0)
        let file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: Data(repeating: 120, count: bytes.count))
        // Deliberately defeat caches that compare only inode, length and mtime.
        var timestamps = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(timestamps.withUnsafeMutableBufferPointer {
            futimens(file.fileDescriptor, $0.baseAddress!)
        }, 0)
        try file.close()
        let after = await models.status(); XCTAssertFalse(after["available"].bool)
        let newCount = await models.verificationHashCount; XCTAssertGreaterThan(newCount, count)
        await assertFailure { try await models.withModel { _ in () } }
    }

    func testFingerprintIncludesNanosecondsAndOwnershipMetadata() {
        var original = stat()
        original.st_dev = 1; original.st_ino = 2; original.st_size = 3
        original.st_mode = mode_t(S_IFREG) | 0o600
        original.st_uid = geteuid(); original.st_gid = getegid(); original.st_nlink = 1
        original.st_mtimespec = timespec(tv_sec: 100, tv_nsec: 7)
        original.st_ctimespec = timespec(tv_sec: 101, tv_nsec: 9)
        let expected = WhisperModelFingerprint(original)
        let changes: [(inout stat) -> Void] = [
            { $0.st_dev += 1 }, { $0.st_ino += 1 }, { $0.st_size += 1 },
            { $0.st_mode = mode_t(S_IFREG) | 0o644 }, { $0.st_uid += 1 },
            { $0.st_gid += 1 }, { $0.st_nlink += 1 },
            { $0.st_mtimespec.tv_sec += 1 }, { $0.st_mtimespec.tv_nsec += 1 },
            { $0.st_ctimespec.tv_sec += 1 }, { $0.st_ctimespec.tv_nsec += 1 }
        ]
        for change in changes {
            var modified = original; change(&modified)
            XCTAssertNotEqual(WhisperModelFingerprint(modified), expected)
        }
    }

    func testReplacementPermissionsAndRemovalInvalidateCachedEvidence() async throws {
        let paths = try fixture(), models = store(paths, data: bytes)
        try await models.install(progress: progress)
        _ = await models.status()
        let firstCount = await models.verificationHashCount
        let final = modelURL(paths)
        let replacement = final.deletingLastPathComponent().appendingPathComponent("replacement")
        try NativeFile.writeAtomic(bytes, to: replacement)
        XCTAssertEqual(rename(replacement.path, final.path), 0)
        let replaced = await models.status(); XCTAssertTrue(replaced["available"].bool)
        let replacedCount = await models.verificationHashCount; XCTAssertGreaterThan(replacedCount, firstCount)
        XCTAssertEqual(chmod(final.path, 0o644), 0)
        let unsafe = await models.status(); XCTAssertFalse(unsafe["available"].bool)
        XCTAssertEqual(chmod(final.path, 0o600), 0)
        let restored = await models.status(); XCTAssertTrue(restored["available"].bool)
        let restoredCount = await models.verificationHashCount; XCTAssertGreaterThan(restoredCount, replacedCount)
        try await models.remove()
        let removed = await models.status(); XCTAssertFalse(removed["available"].bool)
        try await models.install(progress: progress)
        let reinstalled = await models.status(); XCTAssertTrue(reinstalled["available"].bool)
        let reinstalledCount = await models.verificationHashCount; XCTAssertGreaterThan(reinstalledCount, restoredCount)
    }

    func testCancellationBeforeStartupNeverResumesOrRequiresDelegateCompletion() {
        let lifecycle = WhisperDownloadLifecycle(), events = WhisperLifecycleEvents()
        lifecycle.cancel { events.append("cancel") }
        XCTAssertFalse(lifecycle.start { events.append("resume") })
        XCTAssertFalse(lifecycle.hasStarted)
        XCTAssertTrue(events.snapshot.isEmpty)
    }

    func testCancellationAfterStartupFollowsResumeAndIsIdempotent() {
        let lifecycle = WhisperDownloadLifecycle(), events = WhisperLifecycleEvents()
        XCTAssertTrue(lifecycle.start { events.append("resume") })
        lifecycle.cancel { events.append("cancel") }
        lifecycle.cancel { events.append("duplicate cancel") }
        XCTAssertFalse(lifecycle.start { events.append("duplicate resume") })
        XCTAssertTrue(lifecycle.hasStarted)
        XCTAssertEqual(events.snapshot, ["resume", "cancel"])
    }

    func testIndependentStoresLeaseBlocksRemoveAndInstallUntilReleased() async throws {
        let paths = try fixture(), first = store(paths, data: bytes), second = store(paths, data: bytes)
        try await first.install(progress: progress)
        let entered = WhisperTestSignal(), release = WhisperTestSignal()
        defer { Task { await release.signal() } }
        let lease = Task {
            try await first.withModel { _ in
                await entered.signal(); await release.wait()
            }
        }
        await entered.wait()
        // A different actor has no knowledge of first.leases; only real flock protects it.
        let shared = try await second.withModel { try Data(contentsOf: $0) }
        XCTAssertEqual(shared, bytes)
        do { try await second.remove(); XCTFail("Another store removed a leased model") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy")) }
        do { try await second.install(progress: progress); XCTFail("Another store installed while leased") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy")) }
        await release.signal(); try await lease.value
        try await second.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL(paths).path))
        let lock = modelURL(paths).deletingLastPathComponent().appendingPathComponent(".model.lock")
        var info = stat(); XCTAssertEqual(lstat(lock.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, mode_t(S_IFREG))
        XCTAssertEqual(info.st_mode & 0o777, mode_t(0o600))
        XCTAssertEqual(info.st_uid, geteuid()); XCTAssertEqual(info.st_nlink, 1)
    }

    func testIndependentStoreExclusiveInstallRejectsOtherStoreWithoutWaiting() async throws {
        let paths = try fixture(), entered = WhisperTestSignal(), release = WhisperTestSignal(), data = bytes
        defer { Task { await release.signal() } }
        let first = NativeLocalWhisperModels(paths: paths, assets: descriptor(data), downloader: { _, file, _, _ in
            await entered.signal(); await release.wait()
            try file.write(contentsOf: data)
        })
        let second = store(paths, data: data)
        let install = Task { try await first.install(progress: progress) }
        await entered.wait()
        let state = await second.status()
        XCTAssertFalse(state["available"].bool)
        XCTAssertTrue(state["message"].string.contains("busy"))
        do { try await second.remove(); XCTFail("Exclusive install allowed another remover") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy")) }
        do { try await second.install(progress: progress); XCTFail("Exclusive install allowed another installer") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy")) }
        do { try await second.withModel { _ in () }; XCTFail("Exclusive install allowed another lease") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy")) }
        await release.signal(); try await install.value
        let available = await second.status(); XCTAssertTrue(available["available"].bool)
        try await second.remove()
    }

    func testStatusDoesNotCreateLockAndUnsafeLockIsRejected() async throws {
        let paths = try fixture(), models = store(paths, data: bytes)
        try await models.install(progress: progress)
        let lock = modelURL(paths).deletingLastPathComponent().appendingPathComponent(".model.lock")
        // Simulate pre-lock-version storage with no active operation. Production never deletes this inode.
        try FileManager.default.removeItem(at: lock)
        let state = await models.status(); XCTAssertTrue(state["available"].bool)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
        let foreign = paths.root.appendingPathComponent("foreign-lock")
        try NativeFile.writeAtomic(Data("keep".utf8), to: foreign)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: foreign)
        let linked = await models.status(); XCTAssertFalse(linked["available"].bool)
        await assertFailure { try await models.remove() }
        await assertFailure { try await models.install(progress: self.progress) }
        await assertFailure { try await models.withModel { _ in () } }
        XCTAssertEqual(try Data(contentsOf: foreign), Data("keep".utf8))
        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(link(foreign.path, lock.path), 0)
        let hardlinked = await models.status(); XCTAssertFalse(hardlinked["available"].bool)
        await assertFailure { try await models.withModel { _ in () } }
        try FileManager.default.removeItem(at: lock)
        try NativeFile.writeAtomic(Data(), to: lock)
        XCTAssertEqual(chmod(lock.path, 0o644), 0)
        let permissive = await models.status(); XCTAssertFalse(permissive["available"].bool)
        await assertFailure { try await models.remove() }
    }

}
