import Foundation
import XCTest
@testable import UniApiCore

enum CodeOfflineGit {
    static func environment(home: URL) -> [String: String] {
        var env = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        env["HOME"] = home.path; env["XDG_CONFIG_HOME"] = home.appendingPathComponent("config").path
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"; env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_ALLOW_PROTOCOL"] = "file"; env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_AUTHOR_NAME"] = "Fixture"; env["GIT_AUTHOR_EMAIL"] = "fixture@example.invalid"
        env["GIT_COMMITTER_NAME"] = "Fixture"; env["GIT_COMMITTER_EMAIL"] = "fixture@example.invalid"
        env["GIT_SSH_COMMAND"] = nil; env["SSH_ASKPASS"] = nil; env["GIT_ASKPASS"] = nil
        return env
    }
    static func run(_ args: [String], at directory: URL, home: URL, extra: [String: String] = [:], input: Data? = nil) async throws -> NativeProcessResult {
        let process = NativeProcess()
        guard let executable = process.which("git") else { throw XCTSkip("Offline Git fixture requires Git") }
        var env = environment(home: home); for (key, value) in extra { env[key] = value }
        return try await process.run(executable, arguments: args, environment: env, input: input, directory: directory, timeout: 10)
    }
    @discardableResult static func checked(_ args: [String], at directory: URL, home: URL) async throws -> String {
        let result = try await run(args, at: directory, home: home)
        guard result.status == 0 else { throw NativeFailure("Offline Git fixture failed: " + String(decoding: result.stderr, as: UTF8.self)) }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func repository(_ directory: URL, home: URL) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await checked(["init", "-q", "-b", "main"], at: directory, home: home)
        try await checked(["config", "core.hooksPath", "/dev/null"], at: directory, home: home)
        try Data("data/\nproviders.json\narena/results/*.json\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
        try Data("before\n".utf8).write(to: directory.appendingPathComponent("README.md"))
        try await checked(["add", ".gitignore", "README.md"], at: directory, home: home)
        try await checked(["commit", "-qm", "Fixture initial commit"], at: directory, home: home)
    }
    static func ledger(_ runtime: NativeRuntime) -> ArenaLedger {
        ArenaLedger(runtime: runtime, gitRunner: { args, env, input in try await run(args, at: runtime.paths.root, home: runtime.paths.home, extra: env, input: input) })
    }
}

func codeFixtureEventually(_ condition: @escaping () async throws -> Bool) async throws {
    for _ in 0..<1000 { if try await condition() { return }; try await Task.sleep(nanoseconds: 1_000_000) }
    XCTFail("Injected Code/Arena fixture did not settle")
}
