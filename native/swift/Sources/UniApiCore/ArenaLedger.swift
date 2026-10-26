import Foundation
import CryptoKit
import Darwin

typealias ArenaGitRunner = @Sendable ([String], [String: String], Data?) async throws -> NativeProcessResult
struct ArenaLedger {
    let runtime: NativeRuntime
    private let gitRunner: ArenaGitRunner?
    init(runtime: NativeRuntime, gitRunner: ArenaGitRunner? = nil) { self.runtime = runtime; self.gitRunner = gitRunner }
    var directory: URL { runtime.paths.root.appendingPathComponent("arena/results") }
    static let branch = "arena-results", reference = "refs/remotes/origin/arena-results"
    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func name(_ record: JSONValue) -> String {
        let f = ISO8601DateFormatter(); let stamp = String(f.string(from: Date(timeIntervalSince1970: record["ts"].double / 1000)).replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "T", with: "_").prefix(19))
        let id = record["id"].string.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return stamp + "-" + id + ".json"
    }
    func files() -> [String] { ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey])) ?? []).filter { url in guard url.pathExtension == "json", let info = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]) else { return false }; return info.isRegularFile == true && info.isSymbolicLink != true }.map(\.lastPathComponent).sorted() }
    func records() -> [JSONValue] {
        var seen = Set<String>(), out: [JSONValue] = []
        for name in files() { guard let url = try? runtime.paths.containedFile(name, in: directory), let value = try? NativeFile.readJSON(url), ArenaRanking.valid(value), seen.insert(value["id"].string).inserted else { continue }; out.append(value) }
        return out
    }
    func write(_ record: JSONValue) throws -> URL {
        try runtime.paths.assertWritable(); guard ArenaRanking.valid(record) else { throw NativeFailure("Invalid Arena ledger record") }
        if let existing = records().first(where: { $0["id"] == record["id"] }) {
            guard existing == record else { throw NativeFailure("A verdict already exists for this match; immutable records cannot be replaced") }
            return directory.appendingPathComponent(Self.name(existing))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = try runtime.paths.containedFile(Self.name(record), in: directory)
        if FileManager.default.fileExists(atPath: url.path) { guard try NativeFile.readJSON(url) == record else { throw NativeFailure("A conflicting immutable ledger record already exists") }; return url }
        try writeExclusive(try record.encoded(pretty: true), to: url); return url
    }
    private func writeExclusive(_ data: Data, to url: URL) throws {
        let temporary = directory.appendingPathComponent(".verdict-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try NativeFile.writeAtomic(data, to: temporary)
        // Linking the completed private file makes publication atomic without
        // replacing a verdict written concurrently by another runtime.
        guard link(temporary.path, url.path) == 0 else { throw NativeFailure("The immutable verdict destination already exists or is unavailable") }
    }
    static func record(match: JSONValue, slots: [JSONValue], ranking: [Int]?, voter: JSONValue, at: JSONValue) -> JSONValue {
        let allBad = ranking == nil
        return ["v": 1, "id": match["id"], "ts": at, "mode": match["mode"], "preset": match["preset_id"], "category": match["category"], "prompt": .string(String(match["prompt"].string.prefix(300))), "prompt_sha": .string(sha(match["prompt"].string)), "voter": voter, "verdict": .string(allBad ? "all_bad" : "ranked"), "contestants": .array(slots.map { slot in
            let done = slot["status"].string == "done", position = ranking?.firstIndex(of: slot["idx"].int)
            return ["route": slot["route"], "model": slot["model"], "status": .string(done ? "done" : "failed"), "rank": done && !allBad ? position.map { .number(Double($0 + 1)) } ?? .null : .null, "duration_ms": slot["duration_ms"], "turns": slot["turns"].int == 0 ? .null : slot["turns"], "output_tokens": slot["output_tokens"].double == 0 ? .null : slot["output_tokens"], "cost_usd": slot["cost_usd"].double == 0 ? .null : slot["cost_usd"]]
        })]
    }
    func git(_ args: [String], env extra: [String: String] = [:], input: Data? = nil) async throws -> NativeProcessResult {
        if let gitRunner { return try await gitRunner(args, extra, input) }
        guard let executable = runtime.process.which("git") else { throw NativeFailure("Git is unavailable") }
        var env = CodeGitEnvironment.make(); for (k, v) in extra { env[k] = v }
        return try await runtime.process.run(executable, arguments: args, environment: env, input: input, directory: runtime.paths.root, timeout: 120)
    }
    private func remoteFiles() async throws -> [String] {
        let result = try await git(["ls-tree", "-r", "--name-only", Self.reference, "--", "arena/results"])
        return result.status == 0 ? String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map { URL(fileURLWithPath: String($0)).lastPathComponent } : []
    }
    func status() async -> JSONValue {
        let local = files()
        do {
            let inside = try await git(["rev-parse", "--is-inside-work-tree"])
            guard inside.status == 0 else { return ["dir": .string(directory.path), "files": .number(Double(local.count)), "git": false, "remote": .null, "unpublished": 0, "behind": 0] }
            let remote = try await git(["remote", "get-url", "origin"]), known = Set(try await remoteFiles())
            return ["dir": .string(directory.path), "files": .number(Double(local.count)), "git": true, "remote": remote.status == 0 ? .string(String(decoding: remote.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) : .null, "unpublished": .number(Double(local.filter { !known.contains($0) }.count)), "behind": .number(Double(known.filter { !local.contains($0) }.count))]
        } catch { return ["dir": .string(directory.path), "files": .number(Double(local.count)), "git": false, "remote": .null, "unpublished": 0, "behind": 0, "error": .string(error.localizedDescription)] }
    }
    private func fetch() async throws -> Bool {
        let result = try await git(["fetch", "-q", "origin", "+refs/heads/\(Self.branch):\(Self.reference)"])
        if result.status == 0 { return true }
        let error = String(decoding: result.stderr, as: UTF8.self)
        if error.range(of: "couldn't find remote ref|no such ref|Remote branch .* not found", options: .regularExpression) != nil { return false }
        throw NativeFailure("Could not fetch Arena results: " + String(error.suffix(500)))
    }
    func sync() async throws -> JSONValue {
        try runtime.paths.assertWritable(); guard try await fetch() else { return ["ok": true, "added": 0, "output": "No shared results branch yet"] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var added = 0
        for name in try await remoteFiles() where !files().contains(name) {
            guard name.hasSuffix(".json"), !name.contains("/"), !name.contains("..") else { throw NativeFailure("Invalid remote ledger filename") }
            let result = try await git(["show", Self.reference + ":arena/results/" + name])
            guard result.status == 0, let record = try? JSONValue.decode(result.stdout), ArenaRanking.valid(record) else { continue }
            let url = try runtime.paths.containedFile(name, in: directory)
            if FileManager.default.fileExists(atPath: url.path) { continue }
            try writeExclusive(try record.encoded(pretty: true), to: url); added += 1
        }
        return ["ok": true, "added": .number(Double(added)), "output": .string("Synced \(added) verdicts")]
    }
    func publish(voter: JSONValue) async throws -> JSONValue {
        try runtime.paths.assertWritable()
        let index = runtime.paths.tmp.appendingPathComponent("arena-index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: index) }
        let env = ["GIT_INDEX_FILE": index.path, "GIT_AUTHOR_NAME": "UniApi Arena", "GIT_AUTHOR_EMAIL": "arena@uniapi.local", "GIT_COMMITTER_NAME": "UniApi Arena", "GIT_COMMITTER_EMAIL": "arena@uniapi.local"]
        for attempt in 0..<3 {
            try Task.checkCancellation(); let exists = try await fetch(), known = Set(try await remoteFiles()), fresh = files().filter { !known.contains($0) }
            guard !fresh.isEmpty else { return ["ok": true, "committed": 0, "output": "All local verdicts are published"] }
            var inputs: [(String, Data)] = []
            for name in fresh {
                let url = try runtime.paths.containedFile(name, in: directory), data = try Data(contentsOf: url)
                guard let record = try? JSONValue.decode(data), ArenaRanking.valid(record), !ArenaSecretScan.hasSecret(String(decoding: data, as: UTF8.self)) else { throw NativeFailure("A ledger record is malformed or contains a credential; Publish refused") }
                inputs.append((name, data))
            }
            let baseResult = exists ? try await git(["rev-parse", Self.reference]) : NativeProcessResult(status: 0, stdout: Data(), stderr: Data())
            let base = String(decoding: baseResult.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let tree = try await git(exists ? ["read-tree", base] : ["read-tree", "--empty"], env: env)
            guard tree.status == 0 else { throw NativeFailure("Cannot construct the private Arena index") }
            for (name, data) in inputs {
                let hash = try await git(["hash-object", "-w", "--stdin"], input: data)
                guard hash.status == 0 else { throw NativeFailure("Cannot stage Arena verdict") }
                let blob = String(decoding: hash.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let added = try await git(["update-index", "--add", "--cacheinfo", "100644", blob, "arena/results/" + name], env: env)
                guard added.status == 0 else { throw NativeFailure("Cannot stage Arena verdict") }
            }
            let written = try await git(["write-tree"], env: env), treeID = String(decoding: written.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard written.status == 0 else { throw NativeFailure("Cannot write Arena tree") }
            let commit = try await git(["commit-tree", treeID] + (base.isEmpty ? [] : ["-p", base]), env: env, input: Data("Arena results from \(voter.string)\n\nAdd \(fresh.count) immutable verdict files.\n".utf8))
            guard commit.status == 0 else { throw NativeFailure("Cannot commit the isolated Arena results tree") }
            let commitID = String(decoding: commit.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let pushed = try await git(["push", "--no-verify", "origin", commitID + ":refs/heads/" + Self.branch])
            if pushed.status == 0 { return ["ok": true, "committed": .number(Double(fresh.count)), "output": .string("Published \(fresh.count) verdicts") ] }
            if attempt == 2 { throw NativeFailure("Arena results push failed after three fresh-fetch attempts") }
        }
        throw NativeFailure("Arena publication did not finish")
    }
}

/// Native counterpart of tools/scan_secrets.py. Scan every byte, including long
/// lines; errors refuse publication rather than silently skipping a data file.
enum ArenaSecretScan {
    static let patterns = [
        #"sk-ant-[A-Za-z0-9_\-]{20,}"#, #"\bsk-(?!ant-)[A-Za-z0-9_\-]{24,}"#, #"\bnvapi-[A-Za-z0-9_\-]{20,}"#, #"\bdvd_[A-Za-z0-9_\-]{20,}"#,
        #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"#, #"\bgithub_pat_[A-Za-z0-9_]{50,}"#, #"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#, #"\bAIza[A-Za-z0-9_\-]{35}"#,
        #"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"#, #"\b\d{8,12}:AA[A-Za-z0-9_\-]{30,}"#, #"-----BEGIN (?:RSA |EC |OPENSSH |PGP )?PRIVATE KEY-----"#,
        #"(?i)\bserpapi[_-]?key["'\s:=]+[0-9a-f]{40,}"#, #"(?i)\bwispr[_-]?(?:session|auth)[_-]?token["'\s:=]+\S{20,}"#,
        #"(?i)\b(?:api[_-]?key|auth[_-]?token|access[_-]?token|client[_-]?secret|password|passwd)\s*[:=]\s*["']([A-Za-z0-9_\-\.+/=]{24,})["']"#
    ]
    static let allowed = ["REDACTED", "PLACEHOLDER", "EXAMPLE", "your-key", "your_key", "xxxxx", "CHANGEME", "changeme", "sk-xxx", "<key>", "dummy", "FAKE", "fake-", "sk-ant-[A-Za-z0-9", "nvapi-[A-Za-z0-9", "dvd_[A-Za-z0-9"]
    static func hasSecret(_ text: String) -> Bool {
        let string = text as NSString
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return true }
            for hit in expression.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                let range = hit.numberOfRanges > 1 ? hit.range(at: 1) : hit.range, value = string.substring(with: range)
                if !allowed.contains(where: { value.contains($0) }) { return true }
            }
        }
        return false
    }
}
