import XCTest
import Darwin
@testable import UniApiCore

final class CoreTests: XCTestCase {
    func testConfiguredStorageLocationsPreserveDataAndProviderOwnership() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths.discover(environment: ["UNIAPI_ROOT": root.appendingPathComponent("repo").path, "UNIAPI_NATIVE_HOME": root.appendingPathComponent("home").path, "UNIAPI_DATA": root.appendingPathComponent("kept-data").path, "UNIAPI_PROVIDERS": root.appendingPathComponent("kept-config/routes.json").path])
        let runtime = try NativeRuntime(paths: paths)
        XCTAssertEqual(runtime.paths.database, root.appendingPathComponent("kept-data/uniapi.sqlite"))
        XCTAssertEqual(runtime.paths.providers, root.appendingPathComponent("kept-config/routes.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.paths.providers.path + ".lock"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("repo/providers.json").path))
        XCTAssertEqual(try runtime.providers.document()["providers"], [])
    }
    func testManagedStorageRejectsLinkedChildrenBeforeCreatingFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("data"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: repo.appendingPathComponent("data/logs"), withDestinationURL: outside)
        XCTAssertThrowsError(try NativePaths(root: repo).ensureDirectories())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repo.appendingPathComponent("data/bench").path))
    }
    func testJSONRoundTripAndBooleanIdentity() throws {
        let json: JSONValue = ["enabled": true, "tokens": 42, "missing": nil, "parts": ["a", 1.25]]
        XCTAssertEqual(try JSONValue.decode(json.encoded()), json)
        XCTAssertEqual(JSONValue(any: NSNumber(value: true)), .bool(true))
        XCTAssertEqual(JSONValue(any: NSNumber(value: 1)), .number(1))
        XCTAssertTrue(json["unknown"].isNull)
        XCTAssertEqual(try JSONValue.decode(JSONValue.number(.infinity).encoded()), .null)
    }
    func testDatabaseBoundValuesAndTransactionRollback() throws {
        let db = try NativeDatabase()
        try db.migrate("fixture", sql: "CREATE TABLE fixture(id TEXT PRIMARY KEY, value INTEGER)")
        try db.migrate("fixture", sql: "INVALID SQL MUST NOT EXECUTE")
        let hostile = "x'); DROP TABLE fixture; --"
        try db.execute("INSERT INTO fixture VALUES (?,?)", [.string(hostile), 17])
        XCTAssertEqual(try db.query("SELECT * FROM fixture").first?["id"], .string(hostile))
        XCTAssertThrowsError(try db.transaction {
            try db.execute("INSERT INTO fixture VALUES (?,?)", ["rollback", 99])
            throw NativeFailure("rollback fixture")
        })
        XCTAssertEqual(try db.query("SELECT * FROM fixture").count, 1)
        XCTAssertThrowsError(try db.query("SELECT * FROM fixture WHERE id=?"))
    }
    func testOwnershipAdmissionUsesOnlyAnIsolatedFixtureListener() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        XCTAssertEqual(bound, 0); XCTAssertEqual(listen(fd, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        XCTAssertEqual(named, 0)
        XCTAssertThrowsError(try NativeOwnership.assertLegacyServerAbsent(port: UInt16(bigEndian: address.sin_port)))
        // Port zero asks the kernel for a private unused fixture port.
        XCTAssertNoThrow(try NativeOwnership.assertLegacyServerAbsent(port: 0))
    }
    func testOwnershipLeaseExcludesASecondWriterUntilReleased() throws {
        var lease: NativeOwnershipLease? = try NativeOwnership.claim(port: 0)
        let port = lease!.port
        XCTAssertThrowsError(try NativeOwnership.claim(port: port))
        lease = nil
        XCTAssertNoThrow(try NativeOwnership.claim(port: port))
    }
    func testFirstRunSeedsValidatedExamplePrivatelyWithoutReplacingUserConfig() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let example = root.appendingPathComponent("providers.example.json")
        try NativeFile.writeAtomic(try JSONValue.object(["providers": [["id": "fixture", "api_key": ""]], "settings": ["custom": true]]).encoded(), to: example)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        XCTAssertEqual(try runtime.providers.list().first?["id"], "fixture")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: runtime.paths.providers.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let original = try Data(contentsOf: runtime.paths.providers)
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: example)
        try runtime.providers.seedIfAbsent(example: example)
        XCTAssertEqual(try Data(contentsOf: runtime.paths.providers), original)
        let readOnly = NativeProviderStore(paths: NativePaths(root: root.appendingPathComponent("absent"), readOnly: true))
        XCTAssertNoThrow(try readOnly.seedIfAbsent(example: example))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent/providers.json").path))
    }
    func testStreamingRowsPreserveValuesAndFinalizeAfterCallbackFailure() throws {
        let db = try NativeDatabase()
        try db.executeScript("CREATE TABLE stream_fixture(id INTEGER,value TEXT); INSERT INTO stream_fixture VALUES(1,'first'),(2,'second')")
        var rows: [JSONObject] = []
        try db.forEachRow("SELECT * FROM stream_fixture ORDER BY id") { rows.append($0) }
        XCTAssertEqual(rows, try db.query("SELECT * FROM stream_fixture ORDER BY id"))
        XCTAssertThrowsError(try db.forEachRow("SELECT * FROM stream_fixture") { _ in throw NativeFailure("fixture interruption") })
        XCTAssertEqual(try db.query("SELECT COUNT(*) AS n FROM stream_fixture").first?["n"], 2)
    }
    func testChildrenResetIgnoredParentTerminationSignals() async throws {
        let prior = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, prior) }
        let process = NativeProcess()
        let single = try await process.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "kill -TERM $$; printf unexpected"])
        XCTAssertNotEqual(single.status, 0); XCTAssertTrue(single.stdout.isEmpty)
        let duplex = try process.open(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "kill -TERM $$; printf unexpected"])
        let result = try await duplex.wait()
        XCTAssertNotEqual(result.status, 0); XCTAssertTrue(result.stdout.isEmpty)
    }
    func testAtomicProviderMutationPreservesUnownedFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(root: root, home: root)
        try paths.ensureDirectories()
        let initial: JSONValue = ["settings": ["request_delay_s": 2], "providers": [["id": "fixture", "name": "Before", "api_key": "test-fixture"]], "unowned": ["keep": true]]
        try NativeFile.writeAtomic(try initial.encoded(), to: paths.providers)
        let store = NativeProviderStore(paths: paths)
        try store.mutate { d in var p = d["providers"]!.array; p[0]["name"] = "After"; d["providers"] = .array(p) }
        XCTAssertEqual(try store.document()["unowned"], initial["unowned"])
        XCTAssertEqual(try store.list().first?["name"], "After")
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.providers.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try store.mutate { $0["providers"] = [["id": "same"], ["id": "same"]] })
        XCTAssertThrowsError(try store.mutate { $0["providers"] = [["id": "browser", "transport": "chatgpt-web", "api_key": "forbidden-fixture"]] })
        for malformed: JSONValue in [[], ["providers": "bad"], ["providers": [42]], ["providers": [["id": 42]]]] {
            try NativeFile.writeAtomic(try malformed.encoded(), to: paths.providers)
            let before = try Data(contentsOf: paths.providers)
            XCTAssertThrowsError(try store.mutate { $0["providers"] = [] })
            XCTAssertEqual(try Data(contentsOf: paths.providers), before)
        }
    }
    func testContainedFilesRejectTraversalAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(root: root)
        try paths.ensureDirectories()
        XCTAssertThrowsError(try paths.containedFile("../escape", in: paths.tmp))
        try FileManager.default.createSymbolicLink(at: paths.tmp.appendingPathComponent("escape"), withDestinationURL: root)
        XCTAssertThrowsError(try paths.containedFile("escape/file", in: paths.tmp))
        XCTAssertEqual(try paths.containedFile("safe/file.txt", in: paths.tmp), paths.tmp.appendingPathComponent("safe/file.txt"))
    }
    func testProviderMutationHonorsTheExistingInteropLock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(root: root, home: root)
        try paths.ensureDirectories()
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: paths.providers)
        let fd = open(paths.providers.appendingPathExtension("lock").path, O_CREAT | O_RDWR, mode_t(0o600))
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let flag = NativeSynchronousFixtureFlag()
        let store = NativeProviderStore(paths: paths)
        let writer = Task.detached { try store.mutate { document in flag.set(); document["fixture"] = true } }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(flag.value)
        flock(fd, LOCK_UN)
        try await writer.value
        XCTAssertTrue(flag.value)
        XCTAssertEqual(try store.document()["fixture"], true)
    }
    func testProcessDrainsBothPipesWithoutDeadlock() async throws {
        let runner = NativeProcess()
        let shell = try XCTUnwrap(runner.which("sh"))
        let result = try await runner.run(shell, arguments: ["-c", "i=0; while [ $i -lt 3000 ]; do echo stdout-fixture; echo stderr-fixture >&2; i=$((i+1)); done"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.split(separator: "\n").count, 3000)
        XCTAssertEqual(result.errorOutput.split(separator: "\n").count, 3000)
    }
    func testEnvironmentScrubsDesktopAndAuthVariables() {
        let env = NativeProcess().cleanAgentEnvironment(["CLAUDE_CODE_SESSION_ID": "fixture", "ANTHROPIC_AUTH_TOKEN": "fixture", "_MESSAGING_TOKEN": "fixture", "CLAUDE_CONFIG_DIR": "keep", "CODEX_HOME": "keep", "PATH": "keep"])
        XCTAssertEqual(env, ["CLAUDE_CONFIG_DIR": "keep", "CODEX_HOME": "keep", "PATH": "keep"])
    }
    func testCancellationClosesDescendantStreamsAndEscalates() async throws {
        let runner = NativeProcess()
        let shell = try XCTUnwrap(runner.which("sh"))
        let began = expectation(description: "child began")
        let task = Task {
            try await runner.runStreaming(shell, arguments: ["-c", "trap '' TERM; echo ready; (trap '' TERM; sleep 60) & wait"], onOutput: { data in
                if String(decoding: data, as: UTF8.self).contains("ready") { began.fulfill() }
            })
        }
        await fulfillment(of: [began], timeout: 5)
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled process succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }
    func testDuplexSessionAcceptsMultipleFramesAndClosesCleanly() async throws {
        let runner = NativeProcess()
        let shell = try XCTUnwrap(runner.which("sh"))
        let session = try runner.open(shell, arguments: ["-c", "while IFS= read -r line; do echo \"$line\"; done"])
        let reader = Task { var data = Data(); for try await bytes in session.output { data.append(bytes) }; return data }
        try await session.write(JSONValue.object(["id": "first"]))
        try await session.write(JSONValue.object(["id": "second"]))
        session.closeInput()
        let result = try await session.wait()
        let lines = try await reader.value.split(separator: 10).map { try JSONValue.decode(Data($0)) }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(lines.map { $0["id"] }, ["first", "second"])
    }
    func testDuplexBlockedInputCancellationReturnsImmediately() async throws {
        let runner = NativeProcess(), shell = try XCTUnwrap(NativeProcess().which("sh"))
        let session = try runner.open(shell, arguments: ["-c", "trap '' TERM; sleep 60"])
        let writer = Task { try await session.write(Data(repeating: 65, count: 8 * 1024 * 1024)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let start = Date(); session.cancel()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        do { try await writer.value; XCTFail("Cancelled writer succeeded") } catch {}
        do { _ = try await session.wait(); XCTFail("Cancelled session succeeded") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testDuplexStderrRetainsABoundedDiagnosticTail() async throws {
        let runner = NativeProcess(), shell = try XCTUnwrap(NativeProcess().which("sh"))
        let session = try runner.open(shell, arguments: ["-c", "head -c 2097152 /dev/zero >&2"])
        session.closeInput()
        let result = try await session.wait()
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(result.stderr.count, 1_049_000)
        XCTAssertTrue(result.errorOutput.hasPrefix("[Earlier stderr omitted"))
    }
    func testCacheInvalidationCannotResurrectAnOldPayload() async throws {
        let cache = NativePayloadCache(capacity: 2), gate = NativeCacheFixtureGate()
        let old = Task { try await cache.read("fixture") { await gate.wait(); return 1 } }
        for _ in 0..<100 { if await gate.entered { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        await cache.invalidate("fixture")
        let current = try await cache.read("fixture") { 2 }
        XCTAssertEqual(current, 2)
        await gate.release()
        do { _ = try await old.value; XCTFail("Invalidated payload returned") } catch { XCTAssertTrue(error is CancellationError) }
        let stored = await cache.peek("fixture")
        XCTAssertEqual(stored, 2)
        _ = try await cache.read("second") { 3 }
        _ = try await cache.read("third") { 4 }
        let evicted = await cache.peek("fixture")
        XCTAssertNil(evicted)
    }
    func testPersistentQueueRunsAndCancelsWithoutRewritingOtherRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        await runtime.jobs.register(kind: "fixture", concurrency: 1) { params, context in
            try await context.progress(0.5, text: "half")
            try await context.log("fixture log")
            if params["wait"].bool { try await Task.sleep(nanoseconds: 30_000_000_000) }
            return ["answer": 42]
        }
        let first = try await runtime.jobs.submit(kind: "fixture", app: "fixture", title: "Completes", params: [:])
        let id = first["id"]!.string
        var done: JSONObject?
        for _ in 0..<100 {
            done = try await runtime.jobs.get(id)
            if done?["status"]?.string == "done" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(done?["status"], "done")
        XCTAssertEqual(done?["result"]?["answer"], 42)
        XCTAssertEqual(done?["log"]?.array, ["fixture log"])
        let second = try await runtime.jobs.submit(kind: "fixture", app: "fixture", title: "Cancel", params: ["wait": true])
        let cancelledID = second["id"]!.string
        let cancelled = try await runtime.jobs.cancel(cancelledID)
        XCTAssertTrue(cancelled)
        for _ in 0..<100 {
            if try await runtime.jobs.get(cancelledID)?["status"]?.string == "cancelled" { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let cancelledRow = try await runtime.jobs.get(cancelledID)
        XCTAssertEqual(cancelledRow?["status"], "cancelled")
        let firstRow = try await runtime.jobs.get(id)
        XCTAssertEqual(firstRow?["status"], "done")
    }
    func testShutdownDrainsOwnedWorkAndPreservesOnlyRestartableRows() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(root: root, home: root), runtime = try NativeRuntime(paths: paths)
        await runtime.jobs.register(kind: "fixture", concurrency: 2) { _, context in
            try await context.progress(0.5)
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return [:]
        }
        let first = try await runtime.jobs.submit(kind: "fixture", app: "fixture", title: "Explicit cancel", params: [:])
        let second = try await runtime.jobs.submit(kind: "fixture", app: "fixture", title: "Resume", params: [:])
        let third = try await runtime.jobs.submit(kind: "fixture", app: "fixture", title: "Queued", params: [:])
        let cancelled = try await runtime.jobs.cancel(first["id"]!.string); XCTAssertTrue(cancelled)
        await runtime.jobs.suspendForShutdown()
        let cancelledRow = try await runtime.jobs.get(first["id"]!.string), suspendedRow = try await runtime.jobs.get(second["id"]!.string), queuedRow = try await runtime.jobs.get(third["id"]!.string)
        XCTAssertEqual(cancelledRow?["status"], "cancelled")
        XCTAssertEqual(suspendedRow?["status"], "running")
        XCTAssertTrue(["queued", "running"].contains(queuedRow?["status"]?.string ?? ""))
        do { _ = try await runtime.jobs.submit(kind: "fixture", app: "fixture", title: "Rejected", params: [:]); XCTFail("New work admitted after shutdown") } catch {}
        let next = try NativeRuntime(paths: paths)
        await next.jobs.register(kind: "fixture") { _, _ in ["resumed": true] }
        try await next.jobs.recover()
        for _ in 0..<100 {
            if try await next.jobs.list(statuses: ["queued", "running"]).isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let rows = try await next.jobs.list()
        XCTAssertEqual(rows.filter { $0["status"] == "done" }.count, 2)
        XCTAssertEqual(rows.filter { $0["status"] == "cancelled" }.count, 1)
    }
}

private actor NativeCacheFixtureGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { entered = true; continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class NativeSynchronousFixtureFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
    func set() { lock.lock(); stored = true; lock.unlock() }
}
