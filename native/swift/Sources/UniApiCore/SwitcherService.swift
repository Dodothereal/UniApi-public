import Foundation

/// Startup: strongly retain shared(runtime:) in the app session, then await
/// start() BEFORE runtime.jobs.recover(). Both legacy Switcher job kinds are
/// registered as non-resumable; interrupted verification never submits itself.
/// Operations: status, codexStatus, apply(id), restore, model(id,model),
/// effort(effort?), provider(operation,...), key(id), probe(id,model?),
/// codexSelect(source,providerId?,model,effort?), catalog(providerIds,workerModels),
/// codexAction(action), verifyCodexTools, verifyProvider(id,model?),
/// startShim/stopShim (only this session's owned native listener).
public actor NativeSwitcherService {
    private static let pool = SwitcherServicePool()
    public nonisolated static func shared(runtime: NativeRuntime) -> NativeSwitcherService { pool.get(runtime) }
    public let runtime: NativeRuntime, codex: NativeCodexManager
    private let io: NativeSwitcherIO, claude: NativeClaudeSettingsStore, operations: NativeProviderOperations, port: Int
    private var registration: Task<Void, Error>?, watch: Task<Void, Never>?, ownedShim: NativeShimServer?, admission = false
    public init(runtime: NativeRuntime, io: NativeSwitcherIO? = nil, shimPort: Int = 8823) {
        self.runtime = runtime; let io = io ?? NativeSwitcherIO.production(runtime); self.io = io; port = shimPort
        claude = .init(paths: runtime.paths); operations = .init(store: runtime.providers, port: shimPort, dependencies: io.http); codex = .init(runtime: runtime, io: io, port: shimPort)
    }
    deinit { watch?.cancel(); ownedShim?.stop() }
    public func shutdown() async {
        let watcher = watch, listener = ownedShim; watch = nil; ownedShim = nil
        watcher?.cancel(); if let watcher { await watcher.value }; if let listener { await listener.shutdown() }
    }
    public func start() async throws {
        if let registration { return try await registration.value }
        let task = Task { try await self.register() }; registration = task; try await task.value
    }
    private func register() async throws {
        await runtime.jobs.register(kind: "switcher.codex.verify", lane: "switcher.codex.verify", concurrency: 1, resumable: false) { [weak self] _, context in
            guard let self else { throw NativeFailure("Switcher service is unavailable") }
            do {
                try context.checkCancellation(); try await context.progress(0.1, text: "Checking coding tools in a temporary workspace")
                try await context.log("Running one explicit ephemeral coding check; no automatic retry will be submitted.")
                let proof = try await self.codex.verifyTools(); try context.checkCancellation()
                try await context.progress(1, text: "Coding tools verified for the current bridge configuration"); await self.runtime.events.publish("switcher.codex.changed", [:]); return proof
            } catch { try context.checkCancellation(); throw NativeFailure("Coding-tool verification failed; inspect Codex Web GPT setup and explicitly retry. No readiness receipt was created.") }
        }
        await runtime.jobs.register(kind: "switcher.codex.provider", lane: "switcher.codex.provider", concurrency: 1, resumable: false) { [weak self] parameters, context in
            guard let self else { throw NativeFailure("Switcher service is unavailable") }
            do {
                try context.checkCancellation()
                guard let row = try self.runtime.providers.list().first(where: { $0["id"] == parameters["id"] }), row["transport"] != "chatgpt-web" else { throw NativeFailure("Provider was removed") }
                if row["proxy"]?["format"].isNull ?? true { _ = try await self.operations.handle("adopt", input: ["id": parameters["id"]]) }
                try context.checkCancellation(); try await context.progress(0.4, text: "Checking Responses streaming and a tool call")
                let result = try await self.operations.handle("registerResponses", input: parameters.object); try context.checkCancellation()
                guard result["responses_verified"] == true && result["tools_verified"] == true else { throw NativeFailure("Provider route check failed; reload its recorded response") }
                try await context.progress(1, text: "Responses and tool-call check passed; add this provider to Models in Codex")
                await self.runtime.events.publish("switcher.codex.changed", [:]); return ["providerId": parameters["id"], "verified": true]
            } catch { await self.runtime.events.publish("switcher.codex.changed", [:]); try context.checkCancellation(); throw NativeFailure("Provider route check failed; reload the provider response. No automatic retry was scheduled.") }
        }
        if io.watchFiles {
            watch = Task { [weak self] in
                var previous = ""
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
                    guard let service = self else { return }; let signature = await service.signature()
                    if signature != previous { previous = signature; await service.runtime.events.publish("switcher.changed", [:]) }
                }
            }
        }
    }
    private func signature() -> String {
        [claude.file, runtime.paths.providers, SwitcherDisk.codexHome(runtime.paths).appendingPathComponent("config.toml"), SwitcherDisk.bridgeHome(runtime.paths).appendingPathComponent("config.json")].map { file in
            let info = try? FileManager.default.attributesOfItem(atPath: file.path); return "\(info?[.modificationDate] ?? "missing"):\(info?[.size] ?? 0)"
        }.joined(separator: "|")
    }
    private func nativeShimHealth() async -> JSONValue {
        do { let upstream = try await io.http.transport.open(.init(url: URL(string: "http://127.0.0.1:\(port)/healthz")!, method: "GET", timeout: 1.5)); let value = try JSONValue.decode(await upstream.body(limit: 65536)); return ["ok": .bool(upstream.status == 200 && value["service"] == "uniapi-shim" && value["runtime"] == "swift" && value["ok"] == true), "providers": value["providers"], "owned": .bool(ownedShim != nil), "legacyPresent": .bool(value["service"] == "uniapi-shim" && value["runtime"] != "swift")] } catch { return ["ok": false, "owned": .bool(ownedShim != nil)] }
    }
    public func status() async throws -> JSONValue {
        let providers = try runtime.providers.list().map { NativeProviderInfo(.object($0)) }.filter { !$0.browser }, snapshot = try claude.snapshot()
        let current = NativeClaudeSettingsStore.current(snapshot["baseUrl"].string, providers: providers)
        return ["providers": .array(providers.map { $0.publicValue(port: port) }), "current": current.map(JSONValue.string) ?? .null, "currentName": .string(current.flatMap { id in providers.first { $0.id == id }?.name } ?? (snapshot["baseUrl"].string.isEmpty ? "Anthropic subscription" : "Unknown gateway")), "snapshot": snapshot, "efforts": .array(NativeClaudeSettingsStore.efforts.map(JSONValue.string)), "shim": await nativeShimHealth()]
    }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        if !["status", "codexStatus", "key"].contains(operation) { try runtime.paths.assertWritable() }
        let value = JSONValue.object(input)
        switch operation {
        case "status": return try await status()
        case "codexStatus": return try await codex.status()
        case "applyAndProbe", "modelAndProbe":
            if operation == "modelAndProbe" || !value["model"].string.isEmpty { _ = try await handle("model", input: input) }
            if operation == "applyAndProbe" { _ = try await handle("apply", input: ["id": value["id"]]) }
            let current = try await status()
            guard operation == "applyAndProbe" || current["current"] == value["id"] else { return ["saved": true, "message": "Saved this provider's model; press Use to switch.", "probe": .null] }
            let verdict = try await probe(value)
            return ["saved": true, "message": "Saved the Claude default for new sessions.", "probe": verdict]
        case "apply":
            guard let row = try runtime.providers.list().first(where: { $0["id"] == value["id"] }) else { throw NativeFailure("Unknown provider") }
            let provider = NativeProviderInfo(.object(row)); guard provider.enabled else { throw NativeFailure("Enable this provider for Claude first") }
            if provider.direct.isEmpty { guard await nativeShimHealth()["ok"] == true else { throw NativeFailure("Start the native Swift shim before selecting this route; an existing legacy shim was preserved") } }
            guard try runtime.providers.list().first(where: { $0["id"] == value["id"] }) == row else { throw NativeFailure("Provider configuration changed while checking readiness; reload before applying") }
            try claude.apply(provider, port: port); await runtime.events.publish("switcher.changed", [:]); return ["ok": true, "message": "Saved the Claude route for new sessions."]
        case "restore": try claude.restore(); await runtime.events.publish("switcher.changed", [:]); return ["ok": true]
        case "effort": try claude.effort(value["effort"].string.isEmpty ? nil : value["effort"].string); await runtime.events.publish("switcher.changed", [:]); return ["ok": true]
        case "model":
            let result = try await operations.handle("model", input: input), snapshot = try claude.snapshot(), providers = try runtime.providers.list().map { NativeProviderInfo(.object($0)) }
            if NativeClaudeSettingsStore.current(snapshot["baseUrl"].string, providers: providers) == value["id"].string { try claude.model(value["model"].string) }; await runtime.events.publish("switcher.changed", [:]); return result
        case "provider": try runtime.paths.assertWritable(); let result = try await operations.handle(value["operation"].string, input: input.filter { $0.key != "operation" }); await runtime.events.publish("switcher.changed", [:]); return result
        case "key": guard let row = try runtime.providers.list().first(where: { $0["id"] == value["id"] }), row["transport"] != "chatgpt-web" else { throw NativeFailure("Browser credentials cannot be copied") }; return ["key": row["api_key"] ?? .null]
        case "codexSelect": return try await codex.select(value)
        case "catalog": return try await codex.configureCatalog(value)
        case "codexAction": return try await codex.action(value["action"].string)
        case "verifyCodexTools", "verifyProvider":
            try runtime.paths.assertWritable(); guard !admission else { throw NativeFailure("A verification request is already being admitted") }; admission = true; defer { admission = false }
            try await start()
            let kind = operation == "verifyCodexTools" ? "switcher.codex.verify" : "switcher.codex.provider"
            guard try await runtime.jobs.list(app: "switcher", statuses: ["queued", "running"]).allSatisfy({ $0["kind"] != .string(kind) }) else { throw NativeFailure("A verification is already queued or running") }
            var params: JSONValue = [:]
            if operation == "verifyCodexTools" {
                guard input.isEmpty else { throw NativeFailure("Tool verification accepts an empty request only") }
                let status = try await codex.status(); guard status["installed"] == true, status["bridge"]["configured"] == true, status["bridge"]["running"] == true, status["bridge"]["mode"] == "full", status["bridge"]["signInChecked"] == true, status["bridge"]["busy"] == false else { throw NativeFailure("Complete an idle full-mode browser sign-in check first") }
            } else {
                guard Set(input.keys).isSubset(of: ["id", "model"]), SwitcherDisk.validLabel(value["id"], limit: 100), let row = try runtime.providers.list().first(where: { $0["id"] == value["id"] }), row["transport"] != "chatgpt-web" else { throw NativeFailure("Unknown API provider") }
                let provider = NativeProviderInfo(.object(row)); if !value["model"].isNull && !provider.models.contains(value["model"].string) && !provider.codexModels.contains(value["model"].string) { throw NativeFailure("Choose a current provider model") }
                guard await nativeShimHealth()["ok"] == true else { throw NativeFailure("The native Swift shim must be running for its route check") }; params = value
            }
            let job = try await runtime.jobs.submit(kind: kind, app: "switcher", title: operation == "verifyCodexTools" ? "Verify ChatGPT Web coding tools" : "Check Codex provider route", params: params); return ["job": .object(job)]
        case "probe": return try await probe(value)
        case "startShim":
            try runtime.paths.assertWritable(); guard ownedShim == nil else { return ["ok": true] }
            let server = try NativeShimServer(paths: runtime.paths, port: port, dependencies: io.http); try await server.start(); ownedShim = server; return ["ok": true]
        case "stopShim": try runtime.paths.assertWritable(); guard let server = ownedShim else { throw NativeFailure("This session does not own the running shim; shared services were preserved") }; guard server.activeConnections == 0 else { throw NativeFailure("Finish active shim requests before stopping its listener") }; await server.shutdown(); ownedShim = nil; return ["ok": true]
        default: throw NativeFailure("Unknown Switcher operation")
        }
    }
    private func probe(_ input: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        guard let row = try runtime.providers.list().first(where: { $0["id"] == input["id"] }) else { throw NativeFailure("Unknown provider") }
        let provider = NativeProviderInfo(.object(row)); guard provider.enabled else { throw NativeFailure("Enable this provider first") }
        let model = input["model"].string.isEmpty ? provider.model.isEmpty ? provider.models.first ?? "" : provider.model : input["model"].string
        guard !model.isEmpty else { return ["ok": false, "provider": .string(provider.id), "model": "", "message": "No model to try", "ms": 0, "empty": true, "toolsVerified": false] }
        let began = io.http.now()
        let request: ShimHTTPRequest
        let upstream: ShimUpstream, body: Data
        do { request = try NativeClaudeTextProbe.request(provider, model: model, port: port, timeout: 45); upstream = try await io.http.transport.open(request); body = try await upstream.body(); try Task.checkCancellation() }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return ["ok": false, "provider": .string(provider.id), "model": .string(model), "ms": .number(io.http.now().timeIntervalSince(began) * 1000), "message": "Route check could not complete; inspect the connection and retry explicitly.", "empty": false, "toolsVerified": false] }
        let value = (try? JSONValue.decode(body)) ?? [:], reply = ShimTranslation.text(value["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let note = upstream.status == 200 ? reply.isEmpty ? "Answered with an empty reply" : "Text request answered; coding tools were not checked" : NativeProviderInfo.tidyNote("route \(request.url.absoluteString) answered \(upstream.status): " + String(decoding: body, as: UTF8.self).replacingOccurrences(of: provider.key, with: provider.key.isEmpty ? "" : "<redacted>"))
        return ["ok": .bool(upstream.status == 200), "provider": .string(provider.id), "model": .string(model), "ms": .number(io.http.now().timeIntervalSince(began) * 1000), "message": .string(note), "empty": .bool(reply.isEmpty), "toolsVerified": false]
    }
}
private final class SwitcherServicePool: @unchecked Sendable {
    private final class Entry { weak var service: NativeSwitcherService?; init(_ service: NativeSwitcherService) { self.service = service } }
    private let lock = NSLock(); private var entries: [ObjectIdentifier: Entry] = [:]
    func get(_ runtime: NativeRuntime) -> NativeSwitcherService { lock.lock(); defer { lock.unlock() }; let key = ObjectIdentifier(runtime); if let service = entries[key]?.service { return service }; entries = entries.filter { $0.value.service != nil }; let service = NativeSwitcherService(runtime: runtime); entries[key] = Entry(service); return service }
}
