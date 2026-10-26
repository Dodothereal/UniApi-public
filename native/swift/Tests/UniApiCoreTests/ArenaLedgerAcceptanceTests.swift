import XCTest
import Foundation
@testable import UniApiCore

final class ArenaLedgerAcceptanceTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arena-ledger-offline-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func record(_ id: String, at ts: Int) -> JSONValue {
        ["v": 1, "id": .string(id), "ts": .number(Double(ts)), "mode": "random", "verdict": "ranked", "prompt": "Fixture", "voter": "fixture", "contestants": [["route": "fixture", "model": "a", "status": "done", "rank": 1], ["route": "fixture", "model": "b", "status": "done", "rank": 2]]]
    }
    private func clones(_ root: URL) async throws -> (NativeRuntime, NativeRuntime, URL) {
        let home = root.appendingPathComponent("home"), origin = root.appendingPathComponent("origin.git"), seed = root.appendingPathComponent("seed")
        try await CodeOfflineGit.checked(["init", "-q", "--bare", "-b", "main", origin.path], at: root, home: home)
        try await CodeOfflineGit.repository(seed, home: home)
        try await CodeOfflineGit.checked(["remote", "add", "origin", origin.path], at: seed, home: home)
        try await CodeOfflineGit.checked(["push", "-q", "origin", "HEAD:main"], at: seed, home: home)
        var runtimes: [NativeRuntime] = []
        for name in ["first", "second"] {
            let clone = root.appendingPathComponent(name)
            try await CodeOfflineGit.checked(["clone", "-q", "--local", origin.path, clone.path], at: root, home: home)
            try await CodeOfflineGit.checked(["config", "core.hooksPath", "/dev/null"], at: clone, home: home)
            runtimes.append(try NativeRuntime(paths: NativePaths(root: clone, home: home)))
        }
        return (runtimes[0], runtimes[1], origin)
    }
    func testPublishSyncBetweenOfflineClonesPreservesDirtyWorkingBranchAndExactIndex() async throws {
        let root = try fixture(), (a, b, _) = try await clones(root), ledger = CodeOfflineGit.ledger(a)
        let readme = a.paths.root.appendingPathComponent("README.md")
        try Data("staged\n".utf8).write(to: readme); try await CodeOfflineGit.checked(["add", "README.md"], at: a.paths.root, home: a.paths.home)
        try Data("staged\nunstaged\n".utf8).write(to: readme)
        let head = try await CodeOfflineGit.checked(["rev-parse", "HEAD"], at: a.paths.root, home: a.paths.home)
        let status = try await CodeOfflineGit.checked(["status", "--porcelain"], at: a.paths.root, home: a.paths.home)
        let index = try Data(contentsOf: a.paths.root.appendingPathComponent(".git/index")), bytes = try Data(contentsOf: readme)
        _ = try ledger.write(record("first", at: 1000)); _ = try ledger.write(record("second", at: 2000))
        let published = try await ledger.publish(voter: "fixture"); XCTAssertEqual(published["committed"], 2)
        let afterHead = try await CodeOfflineGit.checked(["rev-parse", "HEAD"], at: a.paths.root, home: a.paths.home)
        XCTAssertEqual(afterHead, head); XCTAssertEqual(try Data(contentsOf: a.paths.root.appendingPathComponent(".git/index")), index); XCTAssertEqual(try Data(contentsOf: readme), bytes)
        let afterStatus = try await CodeOfflineGit.checked(["status", "--porcelain"], at: a.paths.root, home: a.paths.home); XCTAssertEqual(afterStatus, status)
        let state = await ledger.status(); XCTAssertEqual(state["unpublished"], 0)
        let peer = CodeOfflineGit.ledger(b), synced = try await peer.sync(); XCTAssertEqual(synced["added"], 2)
        XCTAssertEqual(peer.records().map { $0["id"].string }, ["first", "second"])
        let again = try await ledger.publish(voter: "fixture"); XCTAssertEqual(again["committed"], 0)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: a.paths.tmp.path).contains { $0.hasPrefix("arena-index-") })
    }
    func testRejectedPushRetriesOnFreshParentAndDoesNotLosePeerVerdict() async throws {
        let root = try fixture(), (a, b, origin) = try await clones(root), peer = CodeOfflineGit.ledger(b), count = ArenaLedgerPushCount()
        _ = try peer.write(record("peer", at: 2000))
        let ledger = ArenaLedger(runtime: a, gitRunner: { args, env, input in
            if args.first == "push", await count.next() == 1 { _ = try await peer.publish(voter: "peer") }
            return try await CodeOfflineGit.run(args, at: a.paths.root, home: a.paths.home, extra: env, input: input)
        })
        _ = try ledger.write(record("own", at: 1000))
        let result = try await ledger.publish(voter: "own"); XCTAssertEqual(result["committed"], 1)
        let pushes = await count.value(); XCTAssertEqual(pushes, 2)
        let tree = try await CodeOfflineGit.checked(["--git-dir", origin.path, "ls-tree", "-r", "--name-only", "arena-results"], at: root, home: a.paths.home)
        XCTAssertTrue(tree.contains("-own.json")); XCTAssertTrue(tree.contains("-peer.json"))
        let synced = try await CodeOfflineGit.ledger(a).sync(); XCTAssertEqual(synced["added"], 1)
    }
    func testCredentialRefusalAndCancellationNeverPublishAndCleanPrivateIndex() async throws {
        let root = try fixture(), (a, _, origin) = try await clones(root)
        let ledger = CodeOfflineGit.ledger(a)
        var secret = record("secret", at: 1000); secret["prompt"] = .string(["sk", String(repeating: "Z", count: 32)].joined(separator: "-"))
        let file = try ledger.write(secret)
        do { _ = try await ledger.publish(voter: "fixture"); XCTFail("Credential was published") } catch { XCTAssertTrue(error.localizedDescription.contains("credential")) }
        let missing = try await CodeOfflineGit.run(["--git-dir", origin.path, "rev-parse", "--verify", "refs/heads/arena-results"], at: root, home: a.paths.home); XCTAssertNotEqual(missing.status, 0)
        try FileManager.default.removeItem(at: file); _ = try ledger.write(record("safe", at: 2000))
        let cancelled = ArenaLedger(runtime: a, gitRunner: { args, env, input in
            if args.first == "write-tree" { throw CancellationError() }
            return try await CodeOfflineGit.run(args, at: a.paths.root, home: a.paths.home, extra: env, input: input)
        })
        do { _ = try await cancelled.publish(voter: "fixture"); XCTFail("Cancelled publication succeeded") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: a.paths.tmp.path).contains { $0.hasPrefix("arena-index-") })
        XCTAssertEqual(ledger.records().map { $0["id"].string }, ["safe"])
    }
}
private actor ArenaLedgerPushCount { private var count = 0; func next() -> Int { count += 1; return count }; func value() -> Int { count } }
