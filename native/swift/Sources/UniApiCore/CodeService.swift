import Foundation

/// Native operations mirror /api/code: routes, agents, agent.models/login/install,
/// projects, project.add/delete/git/diff, threads, thread.create/get/patch/delete,
/// send, interrupt, close, models, options, permission, pending and summary.
public actor NativeCodeService {
    public let runtime: NativeRuntime
    private static let pool = CodeServicePool()
    public nonisolated static func shared(runtime: NativeRuntime) -> NativeCodeService { pool.get(runtime) }
    private var store: CodeStore?, started = false
    private var drivers: [String: CodeDriver] = [:], permissions: [String: [String: JSONValue]] = [:], options: [String: JSONValue] = [:]
    private var streams: [String: CodeLiveState] = [:]
    private var probes: [UUID: CodeDriver] = [:], sends: [UUID: Task<Void, Never>] = [:]
    private var stopped = false, shutdownTask: Task<Void, Never>?
    private var interrupted = Set<String>()
    private var cumulativeCost: [String: Double] = [:], active = Set<String>()
    private var fixtureFactory: (@Sendable (JSONValue) throws -> any CodeChannel)?
    private var gitEnvironment: [String: String]?
    public init(runtime: NativeRuntime) { self.runtime = runtime }
    init(runtime: NativeRuntime, channelFactory: @escaping @Sendable (JSONValue) throws -> any CodeChannel) { self.runtime = runtime; fixtureFactory = channelFactory }
    init(runtime: NativeRuntime, gitEnvironment: [String: String]) { self.runtime = runtime; self.gitEnvironment = gitEnvironment }
    public func start() async throws {
        if stopped { guard store != nil else { throw NativeFailure("Code service is shut down") }; return }
        if store == nil { store = try CodeStore(runtime: runtime) }
        guard !started else { return }; started = true
        await runtime.jobs.register(kind: "code.agent.install", lane: "code.install", concurrency: 1, resumable: true) { [weak self] params, context in
            guard let self else { throw NativeFailure("Code service unavailable") }; return try await self.installAgent(params, context: context)
        }
        // Existing web threads may still own their CLI. Recovery therefore never
        // resets every row merely because a second native client starts.
    }
    /// Invoke only after the application has exclusive data ownership and the
    /// queue has recovered. Thread sessions are not jobs, so their interrupted
    /// rows need an independent pass; startup reads alone never reset them.
    public func reconcileAfterRecovery() async throws {
        guard !runtime.paths.readOnly else { return }
        guard !stopped else { throw NativeFailure("Code service is shut down") }
        try await start(); let store = store!
        for row in try store.threads() where ["starting", "running", "waiting"].contains(row["status"]?.string ?? "") && drivers[row["id"]!.string] == nil {
            let id = row["id"]!
            let updated = try runtime.db.transaction { () -> JSONObject in
                let value = try store.patch(id, ["status": "paused", "last_error": .null])
                _ = try store.event(id, type: "notice", payload: ["text": "The previous process ended during this turn. Its transcript and resume ID are preserved; send a message to continue."], transactional: false)
                return value
            }
            await runtime.events.publish("code.thread", publicThread(updated))
        }
    }
    /// Controlled application shutdown only. Closing the GUI keeps this service
    /// alive; logout/restart drains owned processes before leaving resumable IDs
    /// and interrupted thread rows for the next runtime.
    public func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        stopped = true
        if let store, let rows = try? store.threads() { interrupted = Set(rows.filter { ["starting", "running", "waiting"].contains($0["status"]?.string ?? "") }.compactMap { $0["id"]?.string }) }
        let task = Task { await self.finishShutdown() }; shutdownTask = task
        await task.value
    }
    private func finishShutdown() async {
        let owned = Array(drivers.values) + Array(probes.values), pendingSends = Array(sends.values)
        for task in pendingSends { task.cancel() }
        await withTaskGroup(of: Void.self) { group in for driver in owned { group.addTask { await driver.close() } }; await group.waitForAll() }
        for task in pendingSends { await task.value }
        drivers = [:]; probes = [:]; sends = [:]; permissions = [:]; streams = [:]; active = []
        guard let store, !runtime.paths.readOnly else { return }
        do {
            for row in try store.threads() where interrupted.contains(row["id"]?.string ?? "") || ["starting", "running", "waiting"].contains(row["status"]?.string ?? "") {
                let id = row["id"]!
                let updated = try store.patch(id, ["status": "paused", "last_error": .null])
                _ = try store.event(id, type: "notice", payload: ["text": "Session paused by application shutdown. Its resume ID and transcript are preserved."])
                await runtime.events.publish("code.thread", publicThread(updated))
            }
            await runtime.events.publish("code.shutdown", ["ok": true])
        } catch { await runtime.events.publish("runtime.error", .string("Could not record paused Code sessions: \(error.localizedDescription)")) }
    }
    private func publicThread(_ row: JSONObject) -> JSONValue { var value = JSONValue.object(row); value["alive"] = .bool(drivers[value["id"].string] != nil); value["pending"] = .number(Double(permissions[value["id"].string]?.count ?? 0)); return value }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        try await start(); let s = store!, b = JSONValue.object(input), id = b["id"].isNull ? b["threadId"] : b["id"]
        let reads = ["routes", "agents", "projects", "threads", "thread", "thread.get", "pending", "summary", "models", "options", "project.git", "project.diff"]
        if stopped && !reads.contains(operation) { throw NativeFailure("Code service is shut down; reopen in a new runtime") }
        if !reads.contains(operation) { try runtime.paths.assertWritable() }
        switch operation {
        case "routes": return ["routes": .array(CodeRoutes.list(runtime)), "permissionModes": .array(CodeRoutes.modes.map(JSONValue.string))]
        case "agents": let state = CodeRoutes.agentState(runtime); return .array(CodeRoutes.agents(runtime).map { $0.status(state: state[$0.id]) })
        case "agent.models", "agent.login": return try await probeAgent(b["agentId"].string.isEmpty ? id.string : b["agentId"].string, login: operation == "agent.login")
        case "agent.install":
            let agentID = b["agentId"].isNull ? id.string : b["agentId"].string
            guard let agent = CodeRoutes.agents(runtime).first(where: { $0.id == agentID }) else { throw NativeFailure("Unknown ACP agent") }
            guard agent.id == "antigravity", agent.install["kind"].string == "download", !agent.install["url"].string.isEmpty else { throw NativeFailure(agent.install["hint"].string.isEmpty ? "This agent requires manual installation" : agent.install["hint"].string) }
            guard agent.command == nil else { throw NativeFailure("\(agent.name) is already installed") }
            return .object(try await runtime.jobs.submit(kind: "code.agent.install", app: "code", title: "Install " + agent.name, params: ["agentId": .string(agentID)]))
        case "projects": return .array(try s.projects().map(JSONValue.object))
        case "project.add": let result = try s.addProject(b["path"].string.trimmingCharacters(in: .whitespacesAndNewlines)); await runtime.events.publish("code.projects", .array(try s.projects().map(JSONValue.object))); return .object(result)
        case "project.delete": for row in try s.threads(project: id) { await drivers[row["id"]!.string]?.close(); drivers[row["id"]!.string] = nil }; try s.removeProject(id); await runtime.events.publish("code.projects", .array(try s.projects().map(JSONValue.object))); return ["ok": true]
        case "project.git", "project.diff": return try await git(project: id, file: b["file"].isNull ? nil : b["file"].string, status: operation == "project.git")
        case "threads": return .array(try s.threads(project: b["project"].isNull ? Optional<JSONValue>.none : .some(b["project"])).map(publicThread))
        case "thread.create":
            guard let project = try s.project(b["projectId"]) else { throw NativeFailure("Choose a project") }
            let routeID = b["routeId"].string.isEmpty ? "subscription" : b["routeId"].string
            guard let route = CodeRoutes.list(runtime).first(where: { $0["id"].string == routeID }) else { throw NativeFailure("Unknown route") }
            if route["agent"]["auth"]["kind"].string == "browser" && !route["agent"]["auth"]["ready"].bool && fixtureFactory == nil { throw NativeFailure("Sign in to this agent explicitly first") }
            let permissionMode: JSONValue
            if b["permissionMode"].isNull { permissionMode = routeID.hasPrefix("agent:") ? "" : "acceptEdits" }
            else { permissionMode = b["permissionMode"] }
            try validateMode(permissionMode, route: routeID, options: CodeRoutes.cachedOptions(runtime, route: routeID))
            let title = b["title"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            let row = try s.create(["project_id": project["id"]!, "route_id": .string(routeID), "title": .string(title.isEmpty ? "New thread" : title), "model": b["model"].isNull ? route["defaultModel"] : b["model"], "effort": b["effort"], "permission_mode": permissionMode])
            let result = publicThread(row); await runtime.events.publish("code.thread", result); return result
        case "thread", "thread.get":
            guard let row = try s.thread(id) else { throw NativeFailure("Thread no longer exists") }
            let events = try s.events(id, after: b["after"].int)
            return ["thread": publicThread(row), "events": .array(events), "pending": .array(Array(permissions[id.string]?.values ?? [:].values)), "models": options[id.string]?["models"] ?? [], "options": options[id.string] ?? ["models": [], "efforts": [], "modes": []], "live": streams[id.string]?.json ?? .null, "more": .bool(events.count == 5000)]
        case "thread.patch":
            guard let old = try s.thread(id) else { throw NativeFailure("Thread no longer exists") }
            let source = b["patch"].isNull ? b : b["patch"]; var patch: JSONObject = [:]
            for field in ["title", "model", "effort", "permission_mode", "route_id"] where source.object[field] != nil { patch[field] = source[field] }
            let targetRoute = patch["route_id"]?.string ?? old["route_id"]?.string ?? "subscription"
            let routeChanged = patch["route_id"] != nil && patch["route_id"] != old["route_id"]
            let configurationChanged = ["model", "permission_mode", "effort"].contains { patch[$0] != nil }
            if patch["route_id"] != nil || configurationChanged { try CodeRoutes.assertAvailable(runtime, route: targetRoute) }
            let targetOptions = !routeChanged ? options[id.string] ?? CodeRoutes.cachedOptions(runtime, route: targetRoute) : CodeRoutes.cachedOptions(runtime, route: targetRoute)
            if let mode = patch["permission_mode"] { try validateMode(mode, route: targetRoute, options: targetOptions) }
            if let route = patch["route_id"], route != old["route_id"] {
                guard let chosen = CodeRoutes.list(runtime).first(where: { $0["id"] == route }) else { throw NativeFailure("Unknown route") }
                if chosen["agent"]["auth"]["kind"].string == "browser" && !chosen["agent"]["auth"]["ready"].bool && fixtureFactory == nil { throw NativeFailure("Sign in to this agent explicitly first") }
                await drivers[id.string]?.close(); drivers[id.string] = nil
                options[id.string] = nil; streams[id.string] = nil; permissions[id.string] = nil
                let oldACP = old["route_id"]?.string.hasPrefix("agent:") == true, newACP = route.string.hasPrefix("agent:")
                if oldACP || newACP { patch["claude_session_id"] = .null }
                if patch["model"] == nil { patch["model"] = chosen["defaultModel"] }
                if patch["permission_mode"] == nil { patch["permission_mode"] = newACP ? "" : "acceptEdits" }
                if patch["effort"] == nil { patch["effort"] = .null }
                // A fresh route must not claim the previous engine restored its
                // context; the visible transcript remains as user history.
                _ = try s.event(id, type: "notice", payload: ["text": .string(oldACP || newACP ? "Route changed to a different engine. A new session will start without the earlier engine's memory; the transcript remains visible." : "Claude route changed. The CLI will resume the saved session through the new route.")])
            } else if configurationChanged, let driver = drivers[id.string] {
                try await driver.configure(.object(patch))
                let current = await driver.currentOptions()["current"].object
                for field in ["model", "permission_mode", "effort"] where patch[field] != nil {
                    if let value = current[field] { patch[field] = value }
                }
            }
            let row = try s.patch(id, patch); await runtime.events.publish("code.thread", publicThread(row)); return publicThread(row)
        case "thread.delete": await drivers[id.string]?.close(); drivers[id.string] = nil; permissions[id.string] = nil; try s.removeThread(id); await runtime.events.publish("code.thread.deleted", ["id": id]); return ["ok": true]
        case "send":
            guard let row = try s.thread(id) else { throw NativeFailure("Thread no longer exists") }
            let text = b["text"].string.trimmingCharacters(in: .whitespacesAndNewlines), images = b["images"].array
            guard !text.isEmpty || !images.isEmpty, images.count <= 6 else { throw NativeFailure("Enter a message with at most six images") }
            var blocks: [JSONValue] = []
            for image in images { guard ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(image["media_type"].string), let data = Data(base64Encoded: image["data"].string), data.count <= 10 * 1024 * 1024 else { throw NativeFailure("Invalid or oversized image") }; blocks.append(["type": "image", "source": ["type": "base64", "media_type": image["media_type"], "data": image["data"]]]) }
            if !text.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
            let content: JSONValue = images.isEmpty ? .string(text) : .array(blocks)
            let driver = try runner(.object(row))
            if let event = try s.event(id, type: "user", payload: ["content": content], uuid: .string(UUID().uuidString)) { await runtime.events.publish("code.event", ["threadId": id, "event": event]) }
            var patch: JSONObject = ["status": "starting", "last_error": .null]
            if row["title"]?.string == "New thread" { patch["title"] = .string(text.isEmpty ? "Image" : String(text.prefix(72)).components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")) }
            active.insert(id.string); let next = try s.patch(id, patch); await runtime.events.publish("code.thread", publicThread(next))
            let sending = UUID()
            sends[sending] = Task { [weak self] in do { try Task.checkCancellation(); try await driver.send(content) } catch { await self?.receive(id.string, type: "error", payload: ["message": .string(error.localizedDescription)]) }; await self?.sendFinished(sending) }
            return ["ok": true]
        case "interrupt": try await drivers[id.string]?.interrupt(); return ["ok": true]
        case "close": await drivers[id.string]?.close(); drivers[id.string] = nil; return ["ok": true]
        case "models": return options[id.string]?["models"] ?? []
        case "options": return options[id.string] ?? ["models": [], "efforts": [], "modes": []]
        case "pending": return .array(permissions.values.flatMap { Array($0.values) }.sorted { $0["ts"].double < $1["ts"].double })
        case "permission":
            guard ["allow", "deny"].contains(b["behavior"].string), let driver = drivers[id.string] else { throw NativeFailure("No live pending permission") }
            try await driver.answer(b["requestId"].string, answer: b); await record(id.string, type: "permission.decision", payload: ["id": b["requestId"], "behavior": b["behavior"], "always": b["always"].isNull ? false : b["always"], "message": b["message"], "answers": b["updatedInput"]["answers"]]); return ["ok": true]
        case "summary": let threads = try s.threads(); return ["threads": .number(Double(threads.count)), "projects": .number(Double(try s.projects().count)), "activeThreads": .number(Double(drivers.count)), "pendingPermissions": .number(Double(permissions.values.reduce(0) { $0 + $1.count })), "lastTitle": threads.first?["title"] ?? .null]
        default: throw NativeFailure("Unknown Code operation: \(operation)")
        }
    }
    private func sendFinished(_ id: UUID) { sends[id] = nil }
    private func validateMode(_ mode: JSONValue, route: String, options: JSONValue) throws {
        guard case .string(let value) = mode else { throw NativeFailure("Permission mode must be a string") }
        if !route.hasPrefix("agent:") { guard CodeRoutes.modes.contains(value) else { throw NativeFailure("Unknown permission mode") }; return }
        let rows = options["modes"].array
        if value.isEmpty || rows.isEmpty && CodeRoutes.modes.contains(value) { return }
        guard rows.contains(where: { CodeModelChoices.sameID($0["value"].string, value) }) else { throw NativeFailure("The agent does not advertise this permission mode") }
    }
    private func runner(_ thread: JSONValue) throws -> CodeDriver {
        let id = thread["id"].string
        try CodeRoutes.assertAvailable(runtime, route: thread["route_id"].string)
        if let runner = drivers[id] { return runner }
        let admission = try CodeRoutes.admission(runtime, route: thread["route_id"].string)
        guard let project = try store!.project(thread["project_id"]), let raw = project["path"] else { throw NativeFailure("Project no longer exists") }
        let directory = URL(fileURLWithPath: raw.string), isACP = thread["route_id"].string.hasPrefix("agent:")
        let agent = isACP ? CodeRoutes.agents(runtime).first { $0.id == String(thread["route_id"].string.dropFirst(6)) } : nil
        let factory: @Sendable () throws -> any CodeChannel
        if let fixtureFactory { factory = { try fixtureFactory(thread) } }
        else if let agent { guard let executable = agent.command else { throw NativeFailure("Agent is not installed") }; factory = { CodeProcessChannel(try self.runtime.process.open(executable, arguments: agent.arguments, environment: agent.environment, directory: directory)) } }
        else {
            guard !isACP, let executable = runtime.process.which("claude") else { throw NativeFailure("Claude Code executable is unavailable") }
            let env = CodeRoutes.environment(runtime, claude: true)
            factory = {
                try admission()
                let settings = try CodeRoutes.settings(self.runtime, route: thread["route_id"].string, model: thread["model"].string)
                let args = try CodeDriver.claudeArguments(thread: thread, settings: settings)
                try admission()
                return CodeProcessChannel(try self.runtime.process.open(executable, arguments: args, environment: env, directory: directory))
            }
        }
        let driver = CodeDriver(runtime: runtime, directory: directory, thread: thread, wire: isACP ? .acp : .claude, agent: agent, admission: admission, channelFactory: factory, sink: { [weak self] type, payload in await self?.receive(id, type: type, payload: payload) }, permission: { [weak self] request in await self?.permission(id, request: request) })
        drivers[id] = driver; return driver
    }
    private func permission(_ id: String, request: JSONValue) async {
        guard !stopped else { return }
        permissions[id, default: [:]][request["id"].string] = request; await record(id, type: "permission", payload: request)
        if let row = try? store?.patch(.string(id), ["status": "waiting"]) { await runtime.events.publish("code.thread", publicThread(row)) }
        await runtime.events.publish("code.permission", request)
    }
    @discardableResult private func record(_ id: String, type: String, payload: JSONValue) async -> Bool {
        let body = JSONValue.object(payload.object.filter { $0.key != "_native_event_uuid" })
        do { if let e = try store?.event(.string(id), type: type, payload: body, uuid: payload["_native_event_uuid"]) { await runtime.events.publish("code.event", ["threadId": .string(id), "event": e]); return true } }
        catch { await runtime.events.publish("runtime.error", .string("Could not persist Code event: \(error.localizedDescription)")) }; return false
    }
    private func receive(_ id: String, type: String, payload: JSONValue) async {
        guard let s = store, let row = try? s.thread(.string(id)), !row.isEmpty else { return }
        if stopped {
            // A handshake already in flight may deliver its session identity
            // while shutdown closes transport. Keep that last resume ID, but
            // late callbacks must not overwrite the final paused state.
            if type == "init", !payload["session_id"].string.isEmpty { _ = try? s.patch(.string(id), ["claude_session_id": payload["session_id"]]) }
            if ["assistant", "tool_result", "compact", "notice", "system"].contains(type) { await record(id, type: type, payload: payload) }
            if type != "result" { return }
            if !payload["is_error"].bool && payload["subtype"].string == "success" { interrupted.remove(id) }
        }
        if type == "stream" {
            let frame = payload["event"].isNull ? payload : payload["event"]
            var stream = streams[id] ?? CodeLiveState(); stream.apply(frame, parent: payload["parent_tool_use_id"]); streams[id] = stream.active ? stream : nil
            await runtime.events.publish("code.stream", ["threadId": .string(id), "event": frame, "parent_tool_use_id": payload["parent_tool_use_id"]]); return
        }
        if ["result", "error", "closed", "process.closed"].contains(type) { streams[id] = nil }
        if type == "options" {
            options[id] = payload
            await runtime.events.publish("code.options", ["threadId": .string(id), "options": payload])
            if let route = row["route_id"]?.string, route.hasPrefix("agent:") {
                let agent = String(route.dropFirst(6)); var state = CodeRoutes.agentState(runtime); var value = state[agent]
                value["models"] = payload["models"]; value["options"] = payload; value["discoveredAt"] = CodeStore.now(); state[agent] = value
                do { try NativeFile.writeAtomic(try state.encoded(pretty: true), to: runtime.paths.data.appendingPathComponent("agents/state.json")) }
                catch { await runtime.events.publish("runtime.error", .string("Cannot cache ACP models: \(error.localizedDescription)")) }
            }
            return
        }
        if type == "configuration" {
            let patch = payload.object.filter { ["model", "effort", "permission_mode"].contains($0.key) }
            do { if !patch.isEmpty { let updated = try s.patch(.string(id), patch); await runtime.events.publish("code.thread", publicThread(updated)) } }
            catch { await runtime.events.publish("runtime.error", .string("Cannot persist ACP configuration: \(error.localizedDescription)")) }
            return
        }
        if type == "permission.resolved" { permissions[id]?[payload["id"].string] = nil; await runtime.events.publish("code.permission.resolved", .object(payload.object.merging(["threadId": .string(id)]) { _, new in new })); if permissions[id]?.isEmpty != false && active.contains(id) { _ = try? s.patch(.string(id), ["status": "running"]) }; return }
        if type == "process.closed" {
            drivers[id] = nil; permissions[id] = nil
            if active.remove(id) != nil { await record(id, type: "error", payload: payload); if let next = try? s.patch(.string(id), ["status": "error", "last_error": payload["message"]]) { await runtime.events.publish("code.thread", publicThread(next)) } }
            return
        }
        if type == "closed" { drivers[id] = nil; permissions[id] = nil; active.remove(id); if let next = try? s.patch(.string(id), ["status": "idle"]) { await runtime.events.publish("code.thread", publicThread(next)) }; return }
        if type == "idle" { active.remove(id); if row["status"]?.string != "error", let next = try? s.patch(.string(id), ["status": "idle"]) { await runtime.events.publish("code.thread", publicThread(next)) }; return }
        var patch: JSONObject = [:]
        if type == "init" { patch["claude_session_id"] = payload["session_id"]; patch["status"] = active.contains(id) ? "running" : "idle" }
        if type == "mode" { patch["permission_mode"] = payload["permission_mode"] }
        if type == "session_info", row["title"]?.string == "New thread", !payload["title"].string.isEmpty { patch["title"] = payload["title"] }
        if type == "error" { patch["status"] = "error"; patch["last_error"] = payload["message"]; active.remove(id) }
        if type == "result" {
            let u = payload["usage"], isError = payload["is_error"].bool || payload["subtype"].string != "success"
            let error = !payload["error"].isNull ? payload["error"] : payload["errors"].array.isEmpty ? payload["result"] : .string(payload["errors"].array.map(\.string).joined(separator: "; "))
            let isACP = row["route_id"]?.string.hasPrefix("agent:") == true, cost = payload["total_cost_usd"].double
            patch["cost_usd"] = .number(isACP ? (row["cost_usd"]?.double ?? 0) + cost : cost)
            patch["turns"] = .number(Double((row["turns"]?.int ?? 0) + 1)); patch["input_tokens"] = .number((row["input_tokens"]?.double ?? 0) + u["input_tokens"].double + u["cache_read_input_tokens"].double + u["cache_creation_input_tokens"].double); patch["output_tokens"] = .number((row["output_tokens"]?.double ?? 0) + u["output_tokens"].double)
            patch["last_error"] = isError ? error : .null; patch["status"] = payload["queued_turn_count"].int > 0 ? "running" : isError ? "error" : "idle"
            if payload["queued_turn_count"].int == 0 { active.remove(id) }
        }
        let recorded = await record(id, type: type, payload: payload)
        if type == "result" && !recorded { return }
        if !patch.isEmpty, let updated = try? s.patch(.string(id), patch) { await runtime.events.publish("code.thread", publicThread(updated)) }
    }
    private func git(project id: JSONValue, file: String?, status: Bool) async throws -> JSONValue {
        guard let project = try store?.project(id), let bin = runtime.process.which("git") else { throw NativeFailure("Git or project is unavailable") }
        let directory = URL(fileURLWithPath: project["path"]!.string), environment = CodeGitEnvironment.make(gitEnvironment ?? ProcessInfo.processInfo.environment)
        if status {
            let result = try await runtime.process.run(bin, arguments: ["status", "--porcelain=v1", "--branch"], environment: environment, directory: directory, timeout: 10)
            guard result.status == 0 else { return ["git": false] }
            let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            let stat = try await runtime.process.run(bin, arguments: ["diff", "--stat", "--no-color"], environment: environment, directory: directory, timeout: 10)
            return ["git": true, "branch": .string(lines.first?.replacingOccurrences(of: "## ", with: "") ?? ""), "files": .array(lines.dropFirst().map { ["status": .string(String($0.prefix(2)).trimmingCharacters(in: .whitespaces)), "path": .string(String($0.dropFirst(3)))] }), "diffStat": .string(String(decoding: stat.stdout, as: UTF8.self))]
        }
        var result = try await runtime.process.run(bin, arguments: ["diff", "--no-color", "--"] + (file.map { [$0] } ?? []), environment: environment, directory: directory, timeout: 10)
        if result.stdout.isEmpty, let file { result = try await runtime.process.run(bin, arguments: ["diff", "--no-color", "--no-index", "/dev/null", file], environment: environment, directory: directory, timeout: 10) }
        return ["diff": .string(String(String(decoding: result.stdout, as: UTF8.self).prefix(400000)))]
    }
    private func probeAgent(_ id: String, login: Bool) async throws -> JSONValue {
        guard let agent = CodeRoutes.agents(runtime).first(where: { $0.id == id }) else { throw NativeFailure("Unknown ACP agent") }
        if agent.authKind == "browser" && !login { return ["engine": .string(agent.name), "models": CodeRoutes.agentState(runtime)[id]["models"].isNull ? [] : CodeRoutes.agentState(runtime)[id]["models"], "needsLogin": true] }
        guard let executable = agent.command else { throw NativeFailure("Agent is not installed") }
        let directory = runtime.paths.tmp.appendingPathComponent("code-probe-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let thread: JSONValue = ["id": .string(UUID().uuidString), "permission_mode": "", "model": ""]
        let driver = CodeDriver(runtime: runtime, directory: directory, thread: thread, wire: .acp, agent: agent, clientFiles: false, channelFactory: { CodeProcessChannel(try self.runtime.process.open(executable, arguments: agent.arguments, environment: agent.environment, directory: directory)) }, sink: { _, _ in }, permission: { _ in })
        let probeID = UUID(); probes[probeID] = driver; defer { probes[probeID] = nil }
        do {
            try await driver.boot(); guard !stopped else { throw CancellationError() }; let discovered = await driver.currentOptions(), models = discovered["models"]; await driver.close()
            var state = CodeRoutes.agentState(runtime); var row = state[id]; row["models"] = models; row["options"] = discovered; row["discoveredAt"] = CodeStore.now(); if login { row["loggedIn"] = true; row["loggedInAt"] = CodeStore.now() }; state[id] = row
            try NativeFile.writeAtomic(try state.encoded(pretty: true), to: runtime.paths.data.appendingPathComponent("agents/state.json"))
            await runtime.events.publish("code.agents", .array(CodeRoutes.agents(runtime).map { $0.status(state: state[$0.id]) }))
            return ["ok": true, "engine": .string(agent.name), "models": models, "options": discovered, "needsLogin": false]
        } catch { await driver.close(); throw error }
    }
    private func installAgent(_ input: JSONValue, context: NativeJobContext) async throws -> JSONValue {
        guard input["agentId"].string == "antigravity" else { throw NativeFailure("Only Antigravity has a download recipe") }
        let directory = runtime.paths.data.appendingPathComponent("agents/antigravity"), executable = directory.appendingPathComponent("agy_acp_server.par")
        guard !FileManager.default.isExecutableFile(atPath: executable.path) else { throw NativeFailure("Antigravity is already installed") }
        let (download, response) = try await URLSession.shared.download(from: URL(string: CodeRoutes.antigravityURL)!)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw NativeFailure("Agent download failed") }
        try context.checkCancellation(); try await context.progress(0.9, text: "Validating archive")
        guard let unzip = runtime.process.which("unzip") else { throw NativeFailure("Archive extractor is unavailable") }
        let listing = try await runtime.process.run(unzip, arguments: ["-Z1", download.path], timeout: 30)
        let paths = String(decoding: listing.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        guard listing.status == 0, paths.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) else { throw NativeFailure("Unsafe agent archive paths") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = try await runtime.process.run(unzip, arguments: ["-o", "-q", download.path, "-d", directory.path], timeout: 600)
        guard result.status == 0, FileManager.default.fileExists(atPath: executable.path) else { throw NativeFailure("Agent unpacking failed") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try await context.progress(1, text: "Installed"); await runtime.events.publish("code.agents", .array(CodeRoutes.agents(runtime).map { $0.status(state: CodeRoutes.agentState(runtime)[$0.id]) }))
        return ["path": .string(executable.path)]
    }
}

private final class CodeServicePool: @unchecked Sendable {
    private final class Entry { weak var service: NativeCodeService?; init(_ service: NativeCodeService) { self.service = service } }
    private let lock = NSLock(); private var values: [ObjectIdentifier: Entry] = [:]
    func get(_ runtime: NativeRuntime) -> NativeCodeService { lock.lock(); defer { lock.unlock() }; values = values.filter { $0.value.service != nil }; let key = ObjectIdentifier(runtime); if let value = values[key]?.service { return value }; let value = NativeCodeService(runtime: runtime); values[key] = Entry(value); return value }
}
