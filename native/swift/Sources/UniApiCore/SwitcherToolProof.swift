import Foundation

enum NativeCodexToolProof {
    /// This Swift worker owns its deadline and private child. The job runner
    /// never places an outer kill deadline around the proof or its cleanup.
    static func execute(_ command: NativeSwitcherCommand, environment: [String: String], directory: URL, process: NativeProcess) async throws -> NativeProcessResult {
        let session = try process.open(command.executable, arguments: command.arguments, environment: environment, directory: directory)
        session.closeInput()
        return try await withTaskCancellationHandler(operation: {
            do {
                let stdout = try await withThrowingTaskGroup(of: Data.self) { tasks in
                    tasks.addTask { var bytes = Data(); for try await chunk in session.output { try Task.checkCancellation(); guard bytes.count + chunk.count <= 64 * 1024 * 1024 else { throw NativeFailure("Tool proof output exceeded its bound") }; bytes.append(chunk) }; return bytes }
                    tasks.addTask { try await Task.sleep(nanoseconds: 600_000_000_000); session.cancel(); throw NativeFailure("Tool verification timed out; no retry was submitted") }
                    defer { tasks.cancelAll() }; return try await tasks.next()!
                }
                var result = try await session.wait(); result.stdout = stdout; return result
            } catch { session.cancel(); _ = try? await session.wait(); throw error }
        }, onCancel: { session.cancel() })
    }
    static func verify(paths: NativePaths, platform: NativeSwitcherPlatform, io: NativeSwitcherIO) async throws -> JSONValue {
        guard let codex = platform.codex else { throw NativeFailure("Install Codex before verifying tools") }
        let home = SwitcherDisk.bridgeHome(paths), configPath = home.appendingPathComponent("config.json"), original = try SwitcherDisk.read(configPath, missing: false)
        let config = try JSONValue.decode(original)
        guard config["mode"] == "full", config["host"] == "127.0.0.1", (1024...65535).contains(config["port"].int), !config["releaseVersion"].string.isEmpty else { throw NativeFailure("Complete full-mode loopback bridge setup first") }
        let directory = paths.tmp.appendingPathComponent("codex-tool-proof-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), model = "chatgpt-web/high"
        let prompt = "Verify local coding tools. Use a shell tool to create uniapi-tool-check.txt in the current workspace containing exactly \(marker) and then use a shell tool to read it back. Do not change any other file, use the network, spawn agents, or use fallback models. Finish with TOOL_CHECK_OK and the value read back."
        let prefix = "model_providers.uniapi_web_verification."
        var args = ["exec", "--ephemeral", "--ignore-user-config", "--skip-git-repo-check", "--json", "--sandbox", "workspace-write", "-C", directory.path, "-m", model,
                    "-c", "approval_policy=\"never\"", "-c", "model_provider=\"uniapi_web_verification\"", "-c", prefix + "name=\"UniApi tool verification\"", "-c", prefix + "base_url=" + (try NativeTOML.quote("http://127.0.0.1:\(config["port"].int)/v1")), "-c", prefix + "wire_api=\"responses\"", "-c", prefix + "requires_openai_auth=true", "-c", prefix + "supports_websockets=false", "-c", prefix + "request_max_retries=0", "-c", prefix + "stream_max_retries=0"]
        args.append(prompt)
        var environment = SwitcherDisk.env(paths).filter { !$0.key.hasPrefix("ANTHROPIC_") && !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("_MESSAGING_") && !$0.key.hasPrefix("_EXECPATH") && !$0.key.hasPrefix("CODEX_") }
        environment["CODEX_HOME"] = SwitcherDisk.codexHome(paths).path; environment["CODEX_CHATGPT_WEB_HOME"] = home.path
        let result = try await io.prove(.init(codex, args), environment, directory); try Task.checkCancellation()
        let events = result.output.split(separator: "\n").compactMap { try? JSONValue.decode(Data($0.utf8)) }
        let target = directory.appendingPathComponent("uniapi-tool-check.txt")
        let file = (try? SwitcherDisk.text(target, missing: false).trimmingCharacters(in: .whitespacesAndNewlines)) == marker
        let completed = events.contains { $0["type"] == "turn.completed" }
        let acknowledged = events.contains { $0["type"] == "item.completed" && $0["item"]["type"] == "agent_message" && $0["item"]["text"].string.replacingOccurrences(of: "\\_", with: "_").contains("TOOL_CHECK_OK") && $0["item"]["text"].string.contains(marker) }
        let stateDirectory = paths.data.appendingPathComponent("codex")
        guard result.status == 0 && file && completed && acknowledged else {
            let diagnostic: JSONValue = ["returncode": .number(Double(result.status)), "fileValid": .bool(file), "turnCompleted": .bool(completed), "acknowledged": .bool(acknowledged), "eventCount": .number(Double(events.count))]
            try SwitcherDisk.atomic(stateDirectory.appendingPathComponent("web-verification-diagnostic.json"), try diagnostic.encoded(pretty: true))
            throw NativeFailure("Coding-tool verification failed; no readiness receipt was created")
        }
        guard try SwitcherDisk.read(configPath, missing: false) == original else { throw NativeFailure("Bridge configuration changed during verification; explicitly rerun the check") }
        let receipt: JSONValue = ["version": 1, "configHash": .string(SwitcherDisk.hash(original)), "bridgeVersion": config["releaseVersion"], "toolsVerified": true, "checkedAt": .string(ISO8601DateFormatter().string(from: io.http.now())), "model": .string(model)]
        try SwitcherDisk.atomic(stateDirectory.appendingPathComponent("web-verification.json"), try receipt.encoded(pretty: true)); return ["verified": true]
    }
}
