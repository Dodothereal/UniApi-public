import Foundation

actor CodeDriver {
    typealias Sink = @Sendable (String, JSONValue) async -> Void
    typealias Permission = @Sendable (JSONValue) async -> Void
    typealias ExtensionRequest = @Sendable (JSONValue) async throws -> JSONValue
    let runtime: NativeRuntime, directory: URL, threadID: JSONValue
    let wire: CodeTransport.Wire
    private let sink: Sink, permission: Permission
    private let extensionRequest: ExtensionRequest?
    private let channelFactory: @Sendable () throws -> any CodeChannel
    private var transport: CodeTransport?, bootTask: Task<Void, Error>?, ready = false, loading = false
    private var model: String, mode: String, effort: String?, resumedID: String, session = ""
    private var agent: CodeAgent?, options: JSONValue = ["models": [], "efforts": [], "modes": []]
    private let admission: @Sendable () throws -> Void
    private var acpOptions = CodeACPOptions()
    private let clientFiles: Bool
    private var initialize: JSONValue, turn: CodeACPBlocks?, turnStart: Double = 0
    private var pending: [String: JSONValue] = [:], queue: [JSONValue] = [], pumping = false
    private var idle: Task<Void, Never>?, closed = false
    private var closeTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    init(runtime: NativeRuntime, directory: URL, thread: JSONValue, wire: CodeTransport.Wire, agent: CodeAgent? = nil, initialize: JSONValue = ["systemPromptSnapshot": true, "forwardSubagentText": false], clientFiles: Bool = true, admission: @escaping @Sendable () throws -> Void = {}, channelFactory: @escaping @Sendable () throws -> any CodeChannel, sink: @escaping Sink, permission: @escaping Permission, extensionRequest: ExtensionRequest? = nil) {
        self.runtime = runtime; self.directory = directory; self.threadID = thread["id"]; self.wire = wire; self.agent = agent
        model = thread["model"].string; mode = thread["permission_mode"].string; effort = thread["effort"].isNull ? nil : thread["effort"].string; resumedID = thread["claude_session_id"].string
        self.initialize = initialize; self.clientFiles = clientFiles; self.admission = admission; self.channelFactory = channelFactory; self.sink = sink; self.permission = permission; self.extensionRequest = extensionRequest
    }
    static func claudeArguments(thread: JSONValue, settings: JSONValue, additional: [String] = []) throws -> [String] {
        var args = ["--output-format", "stream-json", "--verbose", "--input-format", "stream-json", "--permission-prompt-tool", "stdio", "--include-partial-messages", "--permission-mode", thread["permission_mode"].string]
        if !thread["model"].string.isEmpty { args += ["--model", thread["model"].string] }
        if !thread["claude_session_id"].string.isEmpty { args += ["--resume=" + thread["claude_session_id"].string] }
        if thread["permission_mode"].string == "bypassPermissions" { args.append("--allow-dangerously-skip-permissions") }
        var s = settings; if !thread["effort"].isNull { s["effortLevel"] = thread["effort"] }
        args += ["--settings", String(decoding: try s.encoded(), as: UTF8.self)]
        return args + additional
    }
    func boot() async throws {
        guard !closed else { throw NativeFailure("Agent connection closed") }
        if ready { return }; if let bootTask { try await bootTask.value; return }
        let task = Task { try await self.connect() }; bootTask = task
        do { try await task.value; bootTask = nil } catch { bootTask = nil; await close(); throw error }
    }
    private func connect() async throws {
        try Task.checkCancellation(); guard !closed else { throw NativeFailure("Agent connection closed") }
        try checkAdmission()
        let transport = CodeTransport(channel: try channelFactory(), wire: wire); self.transport = transport
        await transport.start { [weak self] frame in await self?.receive(frame) }
        if wire == .claude {
            let response = try await transport.request("initialize", params: initialize)
            if !initialize["hooks"].isNull && !response["hooks_applied"].bool { throw NativeFailure("The CLI did not confirm its workspace guard hooks; the Arena turn was refused") }
            options["models"] = response["models"].isNull ? [] : response["models"]
            options["efforts"] = .array(["low", "medium", "high", "xhigh", "max"].map { ["value": .string($0), "displayName": .string($0)] })
            for request in response["pending_permission_requests"].array { await receive(["type": "control_request", "request_id": request["request_id"], "request": request]) }
        } else {
            let info = try await transport.request("initialize", params: ["protocolVersion": 1, "clientCapabilities": ["fs": ["readTextFile": .bool(clientFiles), "writeTextFile": .bool(clientFiles)], "terminal": false], "clientInfo": ["name": "uniapi", "version": "native"]])
            if let agent, !agent.auth.isEmpty, info["authMethods"].array.contains(where: { $0["id"].string == agent.auth }) {
                await sink("notice", ["text": .string("\(agent.name): checking configured sign-in")])
                _ = try await transport.request("authenticate", params: ["methodId": .string(agent.auth)], timeout: 300)
            }
            var response: JSONValue = .null
            if !resumedID.isEmpty && info["agentCapabilities"]["loadSession"].bool {
                loading = true
                do { response = try await transport.request("session/load", params: ["sessionId": .string(resumedID), "cwd": .string(directory.path), "mcpServers": []], timeout: 90); session = resumedID }
                catch {
                    if error.localizedDescription.range(of: "encrypted|checkpoint", options: [.regularExpression, .caseInsensitive]) != nil { throw NativeFailure("The agent refused to restore encrypted history; use a new thread with an explicit plain-context handoff. " + error.localizedDescription) }
                    await sink("notice", ["text": "The agent could not restore its earlier session. The turns above remain visible, but the new session does not remember them."])
                }
                loading = false
            }
            if response.isNull {
                if !resumedID.isEmpty && !info["agentCapabilities"]["loadSession"].bool { await sink("notice", ["text": "This agent cannot restore the earlier session. A new session will start without memory of the turns above."]) }
                response = try await transport.request("session/new", params: ["cwd": .string(directory.path), "mcpServers": []], timeout: 90); session = response["sessionId"].string
            }
            readOptions(response)
            // Publish advertised metadata even if a saved choice is no longer
            // supported, so the operator can repair it without a fake fallback.
            await sink("options", options)
            if !model.isEmpty { try await configureACP("model", value: .string(model)) }
            if !mode.isEmpty && !options["modes"].array.isEmpty { try await configureACP("permission_mode", value: .string(mode)) }
            if let effort, !effort.isEmpty { try await configureACP("effort", value: .string(effort)) }
            await publishACPOptions()
            await sink("init", ["session_id": .string(session), "model": .string(model), "cwd": .string(directory.path), "engine": info["agentInfo"], "agent": .string(agent?.id ?? "custom"), "permissionMode": .string(mode), "resumed": .bool(session == resumedID && !resumedID.isEmpty)])
        }
        try Task.checkCancellation(); guard !closed else { throw NativeFailure("Agent connection closed") }
        ready = true; await sink("options", options); if queue.isEmpty { touchIdle() }
    }
    private func readOptions(_ response: JSONValue) { acpOptions.read(response); options = acpOptions.json }
    private func checkAdmission() throws {
        do { try admission() } catch { queue.removeAll(); throw error }
    }
    private func configureACP(_ key: String, value: JSONValue) async throws {
        let request = try acpOptions.request(key, value: value, session: session)
        guard let transport else { throw NativeFailure("Agent connection closed") }
        let response = try await transport.request(request.method, params: request.params)
        acpOptions.selected(key, value: request.value); readOptions(response)
    }
    private func publishACPOptions() async {
        let patch = acpOptions.threadPatch
        if let value = patch["model"] { model = value.string }
        if let value = patch["permission_mode"] { mode = value.string }
        if let value = patch["effort"] { effort = value.string }
        options = acpOptions.json
        await sink("options", options)
        if !patch.isEmpty { await sink("configuration", .object(patch)) }
    }
    func send(_ content: JSONValue) async throws {
        guard !closed else { throw NativeFailure("Agent connection closed") }
        try checkAdmission()
        // Record arrival before the shared handshake suspends: completion of
        // several boot waiters must not reorder queued user messages.
        idle?.cancel(); queue.append(content); try await boot()
        // Another refused sender may have cleared the queue during the
        // handshake. An empty queue must not turn revoked admission into success.
        try checkAdmission()
        guard let transport, ready else { throw NativeFailure("Agent is unavailable") }
        if wire == .claude {
            guard !pumping else { return }; pumping = true; defer { pumping = false }
            while !queue.isEmpty && ready && !closed {
                try checkAdmission()
                let next = queue.removeFirst()
                try await transport.send(["type": "user", "message": ["role": "user", "content": next], "parent_tool_use_id": .null, "uuid": .string(UUID().uuidString), "session_id": .string(session)])
            }
            return
        }
        if !pumping, pumpTask == nil { pumpTask = Task { await self.pump(); self.pumpTask = nil } }
    }
    private func pump() async {
        guard !pumping else { return }; pumping = true
        while !queue.isEmpty && ready && !closed {
            do { try checkAdmission() } catch { await sink("error", ["message": .string(error.localizedDescription)]); break }
            let content = queue.removeFirst(); turn = CodeACPBlocks(); turnStart = Date().timeIntervalSince1970 * 1000
            await sink("stream", ["type": "message_start", "message": ["id": .string(turn!.messageID)]])
            let blocks = content.array.isEmpty ? [["type": "text", "text": content] as JSONValue] : content.array.map { b -> JSONValue in b["type"].string == "image" ? ["type": "image", "mimeType": b["source"]["media_type"], "data": b["source"]["data"]] : b }
            do { let response = try await transport!.request("session/prompt", params: ["sessionId": .string(session), "prompt": .array(blocks)], timeout: 24 * 3600); await finishACP(response) }
            catch { await finishACP(["stopReason": "cancelled", "error": .string(error.localizedDescription)]) }
        }
        pumping = false; await sink("idle", [:]); touchIdle()
    }
    private func finishACP(_ response: JSONValue) async {
        guard var turn else { return }; self.turn = nil
        for (type, payload) in turn.flush(all: true, aborted: response["stopReason"].string == "cancelled") { await sink(type, payload) }
        await sink("stream", ["type": "message_stop"])
        let u = response["usage"], error = response["error"].isNull ? response["stopReason"].string == "refusal" ? "The agent refused" : "" : response["error"].string
        await sink("result", ["subtype": .string(error.isEmpty ? "success" : "error"), "is_error": .bool(!error.isEmpty), "duration_ms": .number(Date().timeIntervalSince1970 * 1000 - turnStart), "num_turns": .number(Double(turn.toolCalls + 1)), "queued_turn_count": .number(Double(queue.count)), "usage": ["input_tokens": u["inputTokens"].isNull ? 0 : u["inputTokens"], "output_tokens": u["outputTokens"].isNull ? 0 : u["outputTokens"], "cache_read_input_tokens": u["cachedReadTokens"].isNull ? 0 : u["cachedReadTokens"], "cache_creation_input_tokens": u["cachedWriteTokens"].isNull ? 0 : u["cachedWriteTokens"]], "total_cost_usd": .number(turn.cost), "stop_reason": response["stopReason"], "error": error.isEmpty ? .null : .string(error)])
    }
    private func receive(_ frame: JSONValue) async {
        if frame["type"].string == "native.process.closed" {
            ready = false; closed = true; idle?.cancel(); queue.removeAll()
            if turn != nil { await finishACP(["stopReason": "cancelled", "error": frame["message"]]) }
            await sink("process.closed", ["message": frame["message"]]); return
        }
        if wire == .claude {
            let type = frame["type"].string
            if type == "control_request" {
                let req = frame["request"], subtype = req["subtype"].string
                if subtype == "can_use_tool" { pending[frame["request_id"].string] = frame; await permission(Self.permissionFrame(frame, threadID: threadID)); return }
                if let extensionRequest { do { try await transport?.respond(to: frame, result: try await extensionRequest(frame)) } catch { try? await transport?.respond(to: frame, error: error.localizedDescription) }; return }
                try? await transport?.respond(to: frame, error: "Unsupported client request"); return
            }
            if type == "control_cancel_request" { let id = frame["request_id"].string; pending[id] = nil; await sink("permission.resolved", ["id": .string(id), "behavior": "aborted"]); return }
            if type == "stream_event" { await sink("stream", frame); return }
            if type == "system" && frame["subtype"].string == "init" { session = frame["session_id"].string; var payload = frame; payload["resumed"] = .bool(!resumedID.isEmpty); await sink("init", payload); return }
            if type == "system" && frame["subtype"].string == "compact_boundary" { await sink("compact", frame); return }
            if type == "assistant" { await sink("assistant", ["message_id": frame["message"]["id"], "model": frame["message"]["model"], "content": frame["message"]["content"], "stop_reason": frame["message"]["stop_reason"], "usage": frame["message"]["usage"], "parent_tool_use_id": frame["parent_tool_use_id"], "error": frame["error"], "aborted": frame["aborted"], "_native_event_uuid": frame["uuid"]]); return }
            if type == "user" && frame["message"]["content"].array.contains(where: { $0["type"].string == "tool_result" }) { await sink("tool_result", ["content": frame["message"]["content"], "parent_tool_use_id": frame["parent_tool_use_id"], "tool_use_result": frame["tool_use_result"], "_native_event_uuid": frame["uuid"]]); return }
            if type == "result" { var payload = frame; payload["_native_event_uuid"] = frame["uuid"]; await sink("result", payload); touchIdle(); return }
            if type == "system" { await sink("system", frame) }
        } else {
            let method = frame["method"].string, p = frame["params"]
            if method == "session/update" {
                guard !loading, p["sessionId"].string == session else { return }; let u = p["update"]
                if u["sessionUpdate"].string == "config_option_update" { readOptions(u); await publishACPOptions() }
                else if u["sessionUpdate"].string == "current_mode_update" { if acpOptions.modeChanged(u["currentModeId"]) { await publishACPOptions() } }
                else if u["sessionUpdate"].string == "compaction_update" { await sink("compact", ["trigger": "agent"]) }
                else if u["sessionUpdate"].string == "session_info_update" { await sink("session_info", u) }
                else { if turn == nil { turn = CodeACPBlocks(); turnStart = Date().timeIntervalSince1970 * 1000; await sink("stream", ["type": "message_start", "message": ["id": .string(turn!.messageID)]]) }; let updates = turn!.update(u); for (type, payload) in updates { await sink(type, payload) } }
            } else if method == "session/request_permission" {
                if !clientFiles { try? await transport?.respond(to: frame, result: ["outcome": ["outcome": "cancelled"]]); return }
                let tool = CodeACPBlocks.shape(p["toolCall"]), kind = tool["kind"].string
                let allowed = mode == "bypassPermissions" || ["read", "search", "think"].contains(kind) || mode == "acceptEdits" && kind == "edit"
                if allowed { let option = p["options"].array.first { $0["kind"].string == "allow_once" } ?? p["options"].array.first { $0["kind"].string == "allow_always" }; try? await transport?.respond(to: frame, result: ["outcome": option.map { ["outcome": "selected", "optionId": $0["optionId"]] } ?? ["outcome": "cancelled"]]); return }
                pending[frame["id"].string] = frame
                await permission(["id": frame["id"], "threadId": threadID, "toolName": tool["name"], "input": tool["input"], "title": tool["title"], "suggestions": .array(p["options"].array.filter { $0["kind"].string == "allow_always" }), "ts": CodeStore.now()])
            } else if !frame["id"].isNull {
                do {
                    guard clientFiles else { throw NativeFailure("This probe does not expose filesystem access") }
                    let path = URL(fileURLWithPath: p["path"].string, relativeTo: directory).standardizedFileURL
                    if method == "fs/read_text_file" {
                        let text = try String(contentsOf: path, encoding: .utf8), lines = text.components(separatedBy: "\n"), from = max(0, p["line"].isNull ? 0 : p["line"].int - 1), end = p["limit"].isNull ? lines.count : min(lines.count, from + max(0, p["limit"].int))
                        try await transport?.respond(to: frame, result: ["content": .string(from >= lines.count ? "" : lines[from..<max(from, end)].joined(separator: "\n"))])
                    } else if method == "fs/write_text_file" { guard mode != "plan" else { throw NativeFailure("Plan mode does not permit file writes") }; try runtime.paths.assertWritable(); try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(p["content"].string.utf8).write(to: path); try await transport?.respond(to: frame) }
                    else { throw NativeFailure("Unsupported ACP client method") }
                } catch { try? await transport?.respond(to: frame, error: error.localizedDescription) }
            }
        }
    }
    static func permissionFrame(_ frame: JSONValue, threadID: JSONValue) -> JSONValue { let r = frame["request"]; return ["id": frame["request_id"], "threadId": threadID, "toolName": r["tool_name"], "input": r["input"], "title": r["title"], "description": r["description"], "displayName": r["display_name"], "suggestions": r["permission_suggestions"].isNull ? [] : r["permission_suggestions"], "toolUseID": r["tool_use_id"], "ts": CodeStore.now()] }
    func answer(_ id: String, answer: JSONValue) async throws {
        guard let frame = pending.removeValue(forKey: id) else { throw NativeFailure("No such pending permission") }
        let allow = answer["behavior"].string == "allow"
        if wire == .claude {
            var result: JSONValue = ["behavior": answer["behavior"], "toolUseID": frame["request"]["tool_use_id"], "decisionClassification": .string(allow ? answer["always"].bool ? "user_permanent" : "user_temporary" : "user_reject")]
            if allow { result["updatedInput"] = answer["updatedInput"].isNull ? frame["request"]["input"] : answer["updatedInput"]; if answer["always"].bool && !frame["request"]["permission_suggestions"].array.isEmpty { result["updatedPermissions"] = frame["request"]["permission_suggestions"] } }
            else { result["message"] = answer["message"].string.isEmpty ? "The user denied this action." : answer["message"] }
            try await transport?.respond(to: frame, result: result)
        } else {
            let kinds = allow ? answer["always"].bool ? ["allow_always", "allow_once"] : ["allow_once", "allow_always"] : ["reject_once", "reject_always"]
            let options = frame["params"]["options"].array, option = kinds.compactMap { k in options.first { $0["kind"].string == k } }.first
            try await transport?.respond(to: frame, result: ["outcome": option.map { ["outcome": "selected", "optionId": $0["optionId"]] } ?? ["outcome": "cancelled"]])
        }
        await sink("permission.resolved", ["id": .string(id), "behavior": answer["behavior"]])
    }
    func configure(_ patch: JSONValue) async throws {
        guard ["model", "permission_mode", "effort"].contains(where: { patch.object[$0] != nil }) else { return }
        try checkAdmission()
        if !ready, let bootTask { try await bootTask.value }
        guard let transport, ready else {
            if let value = patch.object["model"] { model = value.string }
            if let value = patch.object["permission_mode"] { mode = value.string }
            if let value = patch.object["effort"] { effort = value.isNull ? nil : value.string }
            return
        }
        for key in ["model", "permission_mode", "effort"] where patch.object[key] != nil {
            try checkAdmission()
            if wire == .claude {
                let method = key == "model" ? "set_model" : key == "permission_mode" ? "set_permission_mode" : "apply_flag_settings"
                let params: JSONValue = key == "model" ? ["model": patch[key].string.isEmpty ? .null : patch[key]] : key == "permission_mode" ? ["mode": patch[key]] : ["settings": ["effortLevel": patch[key]]]
                _ = try await transport.request(method, params: params)
            } else {
                if key == "permission_mode", options["modes"].array.isEmpty, patch[key] == "" || CodeRoutes.modes.contains(patch[key].string) {
                    // Older agents expose no mode endpoint. Preserve the local
                    // filesystem/permission guard without inventing an ACP RPC.
                    mode = patch[key].string; await sink("mode", ["permission_mode": patch[key]]); continue
                }
                // With no advertised control, an empty/default preference is
                // a no-op. A nonempty unsupported choice is an explicit error.
                let field = key == "model" ? "models" : key == "effort" ? "efforts" : "modes"
                if options[field].array.isEmpty && (patch[key].isNull || patch[key] == "") { continue }
                try await configureACP(key, value: patch[key])
                // Agent requests are not transactional. Persist each acknowledged
                // choice even if a later field in the same UI action is refused.
                await publishACPOptions()
                continue
            }
            if key == "model" { model = patch[key].string }; if key == "permission_mode" { mode = patch[key].string }; if key == "effort" { effort = patch[key].string }
        }
    }
    func interrupt() async throws {
        queue.removeAll(); guard let transport else { return }
        if wire == .claude { _ = try await transport.request("interrupt") } else { try await transport.notify("session/cancel", params: ["sessionId": .string(session)]) }
        for id in Array(pending.keys) { try? await answer(id, answer: ["behavior": "deny", "message": "Interrupted"]) }
    }
    func currentOptions() -> JSONValue { options }
    func control(_ request: JSONValue) async throws -> JSONValue { guard let transport else { throw NativeFailure("Agent connection closed") }; return try await transport.request(request["subtype"].string, params: request) }
    private func touchIdle() { guard !closed else { return }; idle?.cancel(); idle = Task { [weak self] in do { try await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000); await self?.close() } catch {} } }
    func close() async {
        if let closeTask { await closeTask.value; return }
        closed = true; ready = false; idle?.cancel(); queue.removeAll()
        let connecting = bootTask; connecting?.cancel()
        let task = Task { await self.finishClose(connecting) }; closeTask = task
        await task.value
    }
    private func finishClose(_ connecting: Task<Void, Error>?) async {
        for id in Array(pending.keys) { try? await answer(id, answer: ["behavior": "deny", "message": "Session closed"]) }
        await transport?.close(); transport = nil
        if let connecting { _ = try? await connecting.value }
        if let pumpTask { await pumpTask.value }
        await sink("closed", [:])
    }
}
