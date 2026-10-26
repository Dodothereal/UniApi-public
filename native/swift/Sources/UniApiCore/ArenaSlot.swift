import Foundation

typealias ArenaChannelFactory = @Sendable (JSONValue, URL, JSONValue, [String], [String: String]) throws -> any CodeChannel

actor ArenaSlotRunner {
    let runtime: NativeRuntime, slot: JSONValue, match: JSONValue
    let onEvent: @Sendable (String, JSONValue) async -> Void
    let onLive: @Sendable (JSONValue) async -> Void
    private let factory: ArenaChannelFactory?
    private var driver: CodeDriver?, presentations: [JSONValue] = [], finalText = "", session: JSONValue = .null
    private var result: JSONValue = .null, failure: String?, blocked = 0, toolCalls = 0, lastLive: Double = 0, liveText = "", liveTool: JSONValue = .null
    private var live = CodeLiveState()
    private var liveFlush: Task<Void, Never>?
    private let latch = ArenaResultLatch()
    init(runtime: NativeRuntime, slot: JSONValue, match: JSONValue, factory: ArenaChannelFactory?, onEvent: @escaping @Sendable (String, JSONValue) async -> Void, onLive: @escaping @Sendable (JSONValue) async -> Void) {
        self.runtime = runtime; self.slot = slot; self.match = match; self.factory = factory; self.onEvent = onEvent; self.onLive = onLive
    }
    func run() async -> JSONValue {
        let started = Date().timeIntervalSince1970 * 1000, workspace = URL(fileURLWithPath: slot["workdir"].string)
        var deadline: Task<Void, Never>?
        do {
            let admission = try CodeRoutes.admission(runtime, route: slot["route"].string)
            try runtime.paths.assertWritable(); try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            let (settings, env) = try ArenaSandbox.settings(runtime, workspace: workspace, route: slot["route"].string, model: slot["model"].string)
            let thread: JSONValue = ["id": slot["id"], "model": slot["model"], "permission_mode": "acceptEdits"]
            let mcp: JSONValue = ["mcpServers": ["arena": ["type": "sdk", "name": "arena"]]]
            let additional = ["--setting-sources=", "--no-session-persistence", "--strict-mcp-config", "--mcp-config", String(decoding: try mcp.encoded(), as: UTF8.self), "--allowedTools", "mcp__arena__present", "--disallowedTools", ArenaSandbox.disallowed.joined(separator: ","), "--max-turns", match["max_turns"].string]
            let args = try CodeDriver.claudeArguments(thread: thread, settings: settings, additional: additional)
            let launch: @Sendable () throws -> any CodeChannel
            if let factory { launch = { try factory(self.slot, workspace, settings, args, env) } }
            else { guard let executable = runtime.process.which("claude") else { throw NativeFailure("Claude Code is not installed") }; launch = { CodeProcessChannel(try self.runtime.process.open(executable, arguments: args, environment: env, directory: workspace)) } }
            var initialize = ArenaSandbox.initialization
            initialize["appendSystemPrompt"] = .string("You are a contestant in a blind comparison. Work alone inside \(workspace.path). The OS sandbox and filesystem guard confine your tools; your home is invisible. Do not ask the user questions or enter worktrees. You have \(match["timeout_s"].int / 60) minutes and \(match["max_turns"].int) steps. Before finishing, call mcp__arena__present with the workspace file, HTTP(S) URL or text the judge should see.")
            let runner = CodeDriver(runtime: runtime, directory: workspace, thread: thread, wire: .claude, initialize: initialize, admission: admission, channelFactory: launch, sink: { [weak self] type, payload in await self?.event(type, payload) }, permission: { [weak self] request in await self?.permission(request) }, extensionRequest: { [weak self] frame in guard let self else { throw NativeFailure("Contestant closed") }; return try await self.control(frame, workspace: workspace) })
            driver = runner
            let seconds = max(1, match["timeout_s"].double)
            deadline = Task { [weak self] in do { try await Task.sleep(nanoseconds: UInt64(min(seconds, 7200) * 1_000_000_000)); await self?.timeout() } catch {} }
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation(); try await runner.send(match["prompt"])
                _ = try await latch.wait()
            }, onCancel: { Task { await self.cancel() } })
        } catch { if failure == nil { failure = error is CancellationError ? "cancelled" : error.localizedDescription }; await onEvent("error", ["message": .string(failure ?? "Contestant failed")]) }
        deadline?.cancel(); liveFlush?.cancel(); liveFlush = nil; await flushLive(); await driver?.close(); driver = nil
        if presentations.isEmpty {
            for name in ["index.html", "README.md"] {
                if let p = try? ArenaSandbox.present(["kind": "file", "title": .string(name), "path": .string(name), "note": "Not presented explicitly; found at the top of the workspace."], workspace: workspace, home: runtime.paths.home) { presentations.append(p); break }
            }
        }
        let isError = result["is_error"].bool || (!result.isNull && result["subtype"].string != "success")
        // Match the existing fold: artifacts remain judgeable after errors or
        // timeout, failed auth text is not an answer, and an otherwise clean
        // successful completion retains its original done classification.
        let done = !presentations.isEmpty || (!isError && failure != "cancelled" && (failure == nil || !finalText.isEmpty))
        let usage = result["usage"]
        return ["status": .string(done ? "done" : "failed"), "error": failure.map(JSONValue.string) ?? .null, "final_text": .string(finalText), "presents": .array(presentations), "session_id": session, "duration_ms": result["duration_ms"].double > 0 ? result["duration_ms"] : .number(Date().timeIntervalSince1970 * 1000 - started), "turns": result["num_turns"].isNull ? 0 : result["num_turns"], "input_tokens": .number(usage["input_tokens"].double + usage["cache_read_input_tokens"].double + usage["cache_creation_input_tokens"].double), "output_tokens": .number(usage["output_tokens"].double), "cost_usd": .number(result["total_cost_usd"].double), "tool_calls": .number(Double(toolCalls)), "blocked": .number(Double(blocked))]
    }
    private func event(_ type: String, _ payload: JSONValue) async {
        if type == "stream" {
            guard payload["parent_tool_use_id"].isNull else { return }
            let frame = payload["event"].isNull ? payload : payload["event"]
            live.apply(frame)
            if frame["type"].string == "message_start" { liveText = ""; liveTool = .null }
            if frame["content_block"]["type"].string == "tool_use" { liveTool = frame["content_block"]["name"] }
            if frame["delta"]["type"].string == "text_delta" { liveText += frame["delta"]["text"].string }
            let now = Date().timeIntervalSince1970 * 1000
            if now - lastLive >= 250 { await flushLive() }
            else if liveFlush == nil { liveFlush = Task { [weak self] in do { try await Task.sleep(nanoseconds: 250_000_000); await self?.flushLive() } catch {} } }; return
        }
        if type == "options" || type == "idle" || type == "closed" || type == "permission.resolved" { return }
        if type == "process.closed" { if result.isNull { failure = payload["message"].string; await latch.resolve(.null) }; return }
        if type == "init" { session = payload["session_id"] }
        if type == "assistant" {
            toolCalls += payload["content"].array.filter { $0["type"].string == "tool_use" }.count
            if payload["parent_tool_use_id"].isNull { let text = payload["content"].array.filter { $0["type"].string == "text" }.map { $0["text"].string }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines); if !text.isEmpty { finalText = text } }
        }
        if type == "result" {
            result = payload
            if payload["is_error"].bool || payload["subtype"].string != "success" { failure = payload["error"].string.isEmpty ? payload["errors"].array.isEmpty ? payload["result"].string.isEmpty ? payload["subtype"].string : payload["result"].string : payload["errors"].array.map(\.string).joined(separator: "; ") : payload["error"].string }
        }
        await onEvent(type, JSONValue.object(payload.object.filter { $0.key != "_native_event_uuid" }))
        if type == "result" { await latch.resolve(payload) }
        if type == "error" { failure = payload["message"].string; await latch.resolve(.null) }
    }
    private func flushLive() async {
        liveFlush?.cancel(); liveFlush = nil; lastLive = Date().timeIntervalSince1970 * 1000
        var value = live.json; value["text"] = .string(String(liveText.suffix(2000))); value["tool"] = liveTool
        await onLive(value)
    }
    private func permission(_ request: JSONValue) async {
        let name = request["toolName"].string, workspace = URL(fileURLWithPath: slot["workdir"].string)
        let outside = ArenaSandbox.offendingPath(name, input: request["input"], workspace: workspace, home: runtime.paths.home)
        let deny = ArenaSandbox.disallowed.contains(name) || outside != nil
        if let outside { blocked += 1; await onEvent("blocked", ["tool": .string(name), "path": .string(outside)]) }
        try? await driver?.answer(request["id"].string, answer: deny ? ["behavior": "deny", "message": "There is no user here; stay inside your workspace and continue autonomously."] : ["behavior": "allow", "updatedInput": request["input"]])
    }
    private func control(_ frame: JSONValue, workspace: URL) async throws -> JSONValue {
        let request = frame["request"]
        if request["subtype"].string == "hook_callback" {
            guard request["callback_id"].string == "arena-path-guard" else { throw NativeFailure("Unknown Arena hook callback") }
            let input = request["input"], name = input["tool_name"].string
            if let path = ArenaSandbox.offendingPath(name, input: input["tool_input"], workspace: workspace, home: runtime.paths.home) {
                blocked += 1; await onEvent("blocked", ["tool": .string(name), "path": .string(path)])
                return ["hookSpecificOutput": ["hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": .string("Refused outside-workspace path: " + path)]]
            }; return [:]
        }
        guard request["subtype"].string == "mcp_message", request["server_name"].string == "arena" else { throw NativeFailure("Unsupported Arena control request") }
        let message = request["message"]
        if message["id"].isNull { return [:] }
        let response: JSONValue
        switch message["method"].string {
        case "initialize": response = ["protocolVersion": message["params"]["protocolVersion"].isNull ? "2024-11-05" : message["params"]["protocolVersion"], "capabilities": ["tools": [:]], "serverInfo": ["name": "arena", "version": "1.0.0"], "instructions": "Call present when your work is finished."]
        case "tools/list": response = ["tools": [ArenaSandbox.presentTool]]
        case "tools/call":
            guard message["params"]["name"].string == "present" else { throw NativeFailure("Unknown Arena MCP tool") }
            do { let value = try ArenaSandbox.present(message["params"]["arguments"], workspace: workspace, home: runtime.paths.home); presentations.append(value); await onEvent("present", value); response = ["content": [["type": "text", "text": "Presented to the judge."]]] }
            catch { response = ["isError": true, "content": [["type": "text", "text": .string(error.localizedDescription)]]] }
        case "ping": response = [:]
        default: return ["mcp_response": ["jsonrpc": "2.0", "id": message["id"], "error": ["code": -32601, "message": "Unsupported Arena MCP method"]]]
        }
        return ["mcp_response": ["jsonrpc": "2.0", "id": message["id"], "result": response]]
    }
    private func timeout() async { failure = "Hit the \(match["timeout_s"].int / 60) minute time limit"; await latch.resolve(.null); await driver?.close() }
    private func cancel() async { failure = "cancelled"; await latch.cancel(); await driver?.close() }
}

actor ArenaResultLatch {
    private var value: JSONValue?, cancelled = false, waiter: CheckedContinuation<JSONValue, Error>?
    func wait() async throws -> JSONValue { if cancelled { throw CancellationError() }; if let value { return value }; return try await withCheckedThrowingContinuation { waiter = $0 } }
    func resolve(_ value: JSONValue) { guard self.value == nil, !cancelled else { return }; self.value = value; waiter?.resume(returning: value); waiter = nil }
    func cancel() { guard value == nil else { return }; cancelled = true; waiter?.resume(throwing: CancellationError()); waiter = nil }
}
