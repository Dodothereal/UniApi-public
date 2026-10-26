import XCTest
import Foundation
@testable import UniApiCore

final class CodeTests: XCTestCase {
    private func runtime() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("project"), withIntermediateDirectories: true)
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: root.appendingPathComponent("providers.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
    }
    func testStoreEventUUIDSequenceAndCascade() throws {
        let runtime = try runtime(), store = try CodeStore(runtime: runtime), p = try store.addProject(runtime.paths.root.appendingPathComponent("project").path)
        let t = try store.create(["project_id": p["id"]!]), id = t["id"]!
        let first = try store.event(id, type: "assistant", payload: ["content": []], uuid: "same")
        XCTAssertEqual(first?["seq"].int, 1); XCTAssertNil(try store.event(id, type: "assistant", payload: [:], uuid: "same"))
        XCTAssertEqual(try store.event(id, type: "result", payload: [:])?["seq"].int, 2)
        XCTAssertEqual(try store.events(id, after: 1).count, 1)
        try store.removeProject(p["id"]!); XCTAssertTrue(try store.threads().isEmpty); XCTAssertTrue(try runtime.db.query("SELECT * FROM code_events").isEmpty)
    }
    func testRoutesRedactKeysAndMapEveryProviderModelSlot() throws {
        let runtime = try runtime()
        let provider: JSONValue = ["id": "fixture", "name": "Fixture", "api_key": "fixture-value", "proxy": ["format": "openai", "model": "model", "models": ["model"], "context_tokens": 100000]]
        try NativeFile.writeAtomic(try JSONValue.object(["providers": .array([provider, ["id": "browser", "transport": "chatgpt-web", "models": ["web"]]])]).encoded(), to: runtime.paths.providers)
        let routes = JSONValue.array(CodeRoutes.list(runtime)), text = String(decoding: try routes.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("fixture-value")); XCTAssertFalse(routes.array.contains { $0["id"].string == "browser" })
        let settings = try CodeRoutes.settings(runtime, route: "fixture", model: "chosen")
        XCTAssertEqual(settings["env"]["ANTHROPIC_DEFAULT_FABLE_MODEL"].string, "chosen"); XCTAssertEqual(settings["env"]["ANTHROPIC_DEFAULT_HAIKU_MODEL"].string, "chosen")
        XCTAssertEqual(try CodeRoutes.settings(runtime, route: "subscription", model: "")["env"]["ANTHROPIC_AUTH_TOKEN"].string, "")
    }
    func testACPTextThinkingToolOrderingAndResults() throws {
        var turn = CodeACPBlocks()
        XCTAssertEqual(turn.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "before"]]).filter { $0.0 == "assistant" }.count, 0)
        let closed = turn.update(["sessionUpdate": "tool_call", "toolCallId": "tool", "kind": "execute", "title": "fixture", "rawInput": ["cmd": "fixture-only"]])
        XCTAssertEqual(closed.first { $0.0 == "assistant" }?.1["content"].array.first?["text"].string, "before")
        _ = turn.update(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "reason"]])
        let finished = turn.update(["sessionUpdate": "tool_call_update", "toolCallId": "tool", "status": "completed", "content": [["type": "content", "content": ["type": "text", "text": "ok"]]]])
        XCTAssertEqual(finished.first { $0.0 == "assistant" }?.1["content"].array.first?["name"].string, "Bash")
        XCTAssertEqual(finished.first { $0.0 == "tool_result" }?.1["content"].array.first?["tool_use_id"].string, "tool")
        XCTAssertEqual(turn.flush(all: true).first(where: { $0.0 == "assistant" })?.1["content"].array.first?["thinking"].string, "reason")
    }
    func testACPGroupedOptionsAndDiffNormalization() {
        let choices = CodeRoutes.choices([["name": "group", "options": [["value": "model", "name": "Model"]]]])
        XCTAssertEqual(choices.first?["displayName"].string, "Model")
        let write = CodeACPBlocks.shape(["toolCallId": "c", "kind": "edit", "content": [["type": "diff", "path": "fixture", "oldText": .null, "newText": "new"]]])
        XCTAssertEqual(write["name"].string, "Write"); XCTAssertEqual(write["input"]["content"].string, "new")
    }
    func testDuplexCorrelationSplitFramesAndPendingClose() async throws {
        let channel = CodeFixtureChannel { frame in [["jsonrpc": "2.0", "id": frame["id"], "result": ["echo": frame["params"]]]] }
        let transport = CodeTransport(channel: channel, wire: .acp); await transport.start { _ in }
        async let first = transport.request("one", params: ["value": 1])
        async let second = transport.request("two", params: ["value": 2])
        let results = try await [first, second]; XCTAssertEqual(results[0]["echo"]["value"].int, 1); XCTAssertEqual(results[1]["echo"]["value"].int, 2)
        await transport.close(); do { _ = try await transport.request("after-close"); XCTFail("Expected closed connection") } catch {}
        XCTAssertTrue(channel.didClose())
    }
    func testClaudeArgumentsUseFlagSettingsResumeAndScrubbedEnvironment() throws {
        let args = try CodeDriver.claudeArguments(thread: ["permission_mode": "bypassPermissions", "model": "chosen", "effort": "high", "claude_session_id": "saved"], settings: ["env": ["ANTHROPIC_BASE_URL": "fixture"]])
        XCTAssertTrue(args.contains("--permission-prompt-tool")); XCTAssertTrue(args.contains("stdio")); XCTAssertTrue(args.contains("--resume=saved")); XCTAssertTrue(args.contains("--allow-dangerously-skip-permissions"))
        let value = try JSONValue.decode(Data(args[args.firstIndex(of: "--settings")! + 1].utf8)); XCTAssertEqual(value["effortLevel"].string, "high")
        let environment = NativeProcess().cleanAgentEnvironment(["ANTHROPIC_API_KEY": "fixture", "CLAUDE_CODE_SESSION_ID": "fixture", "CODEX_SESSION_ID": "fixture", "_MESSAGING_TOKEN": "fixture", "CLAUDE_CONFIG_DIR": "fixture/config", "PATH": "fixture"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"]); XCTAssertNil(environment["CLAUDE_CODE_SESSION_ID"]); XCTAssertNil(environment["CODEX_SESSION_ID"]); XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "fixture/config")
    }
    func testClaudeDriverPermissionAlwaysAndEffortReset() async throws {
        let runtime = try runtime(), captured = CodeFixtureEvents()
        let channel = CodeFixtureChannel { frame in
            if frame["type"].string == "control_request" { return [["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": ["models": []]]]] }; return []
        }
        let driver = CodeDriver(runtime: runtime, directory: runtime.paths.root.appendingPathComponent("project"), thread: ["id": "thread", "permission_mode": "default", "model": "model"], wire: .claude, channelFactory: { channel }, sink: { type, value in await captured.add(type, value) }, permission: { value in await captured.add("permission", value) })
        try await driver.boot()
        channel.emit(["type": "control_request", "request_id": "permission", "request": ["subtype": "can_use_tool", "tool_name": "Write", "tool_use_id": "tool", "input": ["file_path": "fixture"], "permission_suggestions": [["type": "addRules"]]]])
        try await eventually { await captured.contains("permission") }
        try await driver.answer("permission", answer: ["behavior": "allow", "always": true, "updatedInput": ["file_path": "updated"]])
        let reply = try XCTUnwrap(channel.frames().first { $0["type"].string == "control_response" && $0["response"]["request_id"].string == "permission" })
        XCTAssertEqual(reply["response"]["response"]["updatedInput"]["file_path"].string, "updated"); XCTAssertEqual(reply["response"]["response"]["updatedPermissions"].array.count, 1)
        try await driver.configure(["effort": .null]); XCTAssertTrue(channel.frames().contains { $0["request"]["subtype"].string == "apply_flag_settings" && $0["request"]["settings"].object["effortLevel"] == .null })
        await driver.close()
    }
    func testServicePersistsTurnAccountingAndResumeWithoutExecutingAgent() async throws {
        let runtime = try runtime(), counter = CodeFixtureCounter(), frames = CodeFixtureThreads()
        let service = NativeCodeService(runtime: runtime, channelFactory: { thread in
            frames.add(thread)
            return CodeFixtureChannel { frame in
                if frame["type"].string == "control_request" { return [["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": ["models": []]]], ["type": "system", "subtype": "init", "session_id": "saved", "model": "fixture"]] }
                if frame["type"].string == "user" { let n = counter.next(); let result: JSONValue = ["type": "result", "uuid": .string("result-\(n)"), "subtype": "success", "is_error": false, "usage": ["input_tokens": 3, "output_tokens": 7, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 1], "total_cost_usd": .number(Double(n) * 0.25)]
                    return [["type": "assistant", "uuid": .string("assistant-\(n)"), "message": ["id": .string("m-\(n)"), "model": "fixture", "content": [["type": "text", "text": "fixture answer"]]]], result, result]
                }; return []
            }
        })
        let project = try await service.handle("project.add", input: ["path": .string(runtime.paths.root.appendingPathComponent("project").path)])
        let thread = try await service.handle("thread.create", input: ["projectId": project["id"], "routeId": "subscription", "model": "fixture"]), id = thread["id"]
        _ = try await service.handle("send", input: ["id": id, "text": "fixture first"])
        try await eventually { (try? await service.handle("thread", input: ["id": id])["thread"]["turns"].int) == 1 }
        let first = try await service.handle("thread", input: ["id": id]); XCTAssertEqual(first["thread"]["input_tokens"].int, 6); XCTAssertEqual(first["thread"]["output_tokens"].int, 7); XCTAssertEqual(first["events"].array.filter { $0["type"].string == "result" }.count, 1)
        _ = try await service.handle("close", input: ["id": id]); _ = try await service.handle("send", input: ["id": id, "text": "fixture resumed"])
        try await eventually { (try? await service.handle("thread", input: ["id": id])["thread"]["turns"].int) == 2 }
        XCTAssertEqual(frames.rows().last?["claude_session_id"].string, "saved")
        let second = try await service.handle("thread", input: ["id": id]); XCTAssertEqual(second["thread"]["cost_usd"].double, 0.5)
        _ = try await service.handle("thread.delete", input: ["id": id]); XCTAssertTrue(try runtime.db.query("SELECT * FROM code_events").isEmpty)
    }
    func testACPAuthenticatesEachProcessRestoresSessionAndStreamsUsage() async throws {
        let runtime = try runtime(), captured = CodeFixtureEvents()
        let channel = CodeFixtureChannel { frame in
            let method = frame["method"].string
            if method == "initialize" { return [Self.acpReply(frame, ["agentCapabilities": ["loadSession": true], "authMethods": [["id": "oauth-personal"]]])] }
            if method == "session/load" { return [Self.acpReply(frame, ["configOptions": [["id": "model", "category": "model", "type": "select", "currentValue": "model", "options": [["value": "model", "name": "Fixture model"]]]]])] }
            if method == "session/prompt" { return [["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "saved", "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Fixture ACP"]]]], ["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "saved", "update": ["sessionUpdate": "usage_update", "cost": ["amount": 0.2]]]], Self.acpReply(frame, ["stopReason": "end_turn", "usage": ["inputTokens": 2, "outputTokens": 4, "cachedReadTokens": 3]])] }
            if !frame["id"].isNull && !method.isEmpty { return [Self.acpReply(frame, [:])] }; return []
        }
        let agent = CodeAgent(id: "fixture", name: "Fixture", vendor: "fixture", command: nil, arguments: [], environment: [:], auth: "oauth-personal", authKind: "browser", install: [:])
        let driver = CodeDriver(runtime: runtime, directory: runtime.paths.root.appendingPathComponent("project"), thread: ["id": "fixture", "model": "model", "permission_mode": "default", "claude_session_id": "saved"], wire: .acp, agent: agent, channelFactory: { channel }, sink: { type, value in await captured.add(type, value) }, permission: { _ in })
        try await driver.send("Fixture"); try await eventually { await captured.contains("result") }
        let events = await captured.rows(), result = try XCTUnwrap(events.first { $0.0 == "result" }?.1)
        XCTAssertEqual(result["usage"]["cache_read_input_tokens"].int, 3); XCTAssertEqual(result["total_cost_usd"].double, 0.2)
        XCTAssertTrue(channel.frames().contains { $0["method"].string == "authenticate" }); XCTAssertTrue(channel.frames().contains { $0["method"].string == "session/load" }); XCTAssertFalse(channel.frames().contains { $0["method"].string == "session/new" })
        let stream = events.filter { $0.0 == "stream" }.map { $0.1["type"].string }
        XCTAssertEqual(stream, ["message_start", "content_block_start", "content_block_delta", "content_block_stop", "message_stop"])
        await driver.close()
    }
    func testACPEncryptedResumeRefusalDoesNotStartFreshSession() async throws {
        let runtime = try runtime()
        let channel = CodeFixtureChannel { frame in if frame["method"].string == "initialize" { return [Self.acpReply(frame, ["agentCapabilities": ["loadSession": true]])] }; if frame["method"].string == "session/load" { return [["jsonrpc": "2.0", "id": frame["id"], "error": ["code": -32000, "message": "Encrypted checkpoint is unavailable"]]] }; return [Self.acpReply(frame, ["sessionId": "fresh"])] }
        let driver = CodeDriver(runtime: runtime, directory: runtime.paths.root, thread: ["id": "fixture", "permission_mode": "default", "claude_session_id": "saved"], wire: .acp, channelFactory: { channel }, sink: { _,_ in }, permission: { _ in })
        do { try await driver.boot(); XCTFail("Encrypted restore refusal was bypassed") } catch { XCTAssertTrue(error.localizedDescription.contains("encrypted history")) }
        XCTAssertFalse(channel.frames().contains { $0["method"].string == "session/new" }); XCTAssertTrue(channel.didClose())
    }
    func testACPClientReadLineRangeAndPlanWriteRefusalAndPermissionResponse() async throws {
        let runtime = try runtime(), captured = CodeFixtureEvents(), file = runtime.paths.root.appendingPathComponent("fixture.txt")
        try Data("one\ntwo\nthree".utf8).write(to: file)
        let channel = CodeFixtureChannel { frame in if !frame["method"].isNull && !frame["id"].isNull { return [Self.acpReply(frame, frame["method"].string == "session/new" ? ["sessionId": "fixture"] : [:])] }; return [] }
        let driver = CodeDriver(runtime: runtime, directory: runtime.paths.root, thread: ["id": "thread", "permission_mode": "plan"], wire: .acp, channelFactory: { channel }, sink: { type, value in await captured.add(type, value) }, permission: { value in await captured.add("permission", value) })
        try await driver.boot()
        channel.emit(["jsonrpc": "2.0", "id": "read", "method": "fs/read_text_file", "params": ["path": .string(file.path), "line": 2, "limit": 1]])
        channel.emit(["jsonrpc": "2.0", "id": "write", "method": "fs/write_text_file", "params": ["path": .string(file.path), "content": "changed"]])
        channel.emit(["jsonrpc": "2.0", "id": "permission", "method": "session/request_permission", "params": ["sessionId": "fixture", "toolCall": ["toolCallId": "tool", "kind": "execute", "title": "Fixture"], "options": [["kind": "allow_once", "optionId": "once"], ["kind": "allow_always", "optionId": "always"], ["kind": "reject_once", "optionId": "reject"]]]])
        try await eventually { await captured.contains("permission") }; try await driver.answer("permission", answer: ["behavior": "allow", "always": true])
        XCTAssertEqual(channel.frames().first { $0["id"].string == "read" && $0["method"].isNull }?["result"]["content"].string, "two")
        XCTAssertTrue(channel.frames().first { $0["id"].string == "write" && $0["method"].isNull }?["error"]["message"].string.contains("Plan mode") == true)
        XCTAssertEqual(channel.frames().first { $0["id"].string == "permission" && $0["method"].isNull }?["result"]["outcome"]["optionId"].string, "always")
        XCTAssertEqual(try String(contentsOf: file), "one\ntwo\nthree"); await driver.close()
    }
    func testSameClaudeRouteChangePreservesSessionButDifferentEngineClearsIt() async throws {
        let runtime = try runtime(), store = try CodeStore(runtime: runtime)
        try NativeFile.writeAtomic(try JSONValue.object(["providers": [["id": "fixture", "api_key": "fixture-value", "proxy": ["format": "anthropic", "models": ["fixture-model"]]]]]).encoded(), to: runtime.paths.providers)
        let project = try store.addProject(runtime.paths.root.appendingPathComponent("project").path), thread = try store.create(["project_id": project["id"]!, "claude_session_id": "saved"])
        _ = try store.patch(thread["id"]!, ["claude_session_id": "saved"])
        let service = NativeCodeService(runtime: runtime)
        let changed = try await service.handle("thread.patch", input: ["id": thread["id"]!, "patch": ["route_id": "fixture"]])
        XCTAssertEqual(changed["claude_session_id"].string, "saved")
        let other = try await service.handle("thread.patch", input: ["id": thread["id"]!, "patch": ["route_id": "agent:opencode"]])
        XCTAssertTrue(other["claude_session_id"].isNull); XCTAssertEqual(try store.events(thread["id"]!, after: 0).filter { $0["type"].string == "notice" }.count, 2)
    }
    private static func acpReply(_ frame: JSONValue, _ result: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": frame["id"], "result": result] }
    func testQuestionAnswersMatchCLIStringContractAndRequireCompleteness() throws {
        let questions: [JSONValue] = [["question": "Many", "multiSelect": true], ["question": "One"]]
        let answers = try CodeQuestionAnswers.build(questions: questions, single: ["One": "A"], multiple: ["Many": ["C", "B"]], other: ["Many": " D "])
        XCTAssertEqual(answers["Many"]?.string, "B, C, D"); XCTAssertEqual(answers["One"]?.string, "A")
        XCTAssertThrowsError(try CodeQuestionAnswers.build(questions: questions, single: [:], multiple: [:], other: [:]))
    }
    func testOpeningThreadMidTurnReturnsRichLiveSnapshotWithoutRescanning() async throws {
        let runtime = try runtime()
        let channel = CodeFixtureChannel { frame in
            if frame["type"].string == "control_request" { return [["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": [:]]]] }
            if frame["type"].string == "user" { return [["type": "stream_event", "event": ["type": "message_start", "message": ["id": "live"]]], ["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "fixture reason"]]], ["type": "stream_event", "event": ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "tool", "name": "Read"]]], ["type": "stream_event", "event": ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"file_path\":\"fixture\"}"]]]] }; return []
        }
        let service = NativeCodeService(runtime: runtime, channelFactory: { _ in channel }), project = try await service.handle("project.add", input: ["path": .string(runtime.paths.root.appendingPathComponent("project").path)])
        let thread = try await service.handle("thread.create", input: ["projectId": project["id"]])
        _ = try await service.handle("send", input: ["id": thread["id"], "text": "Fixture"])
        try await eventually { (try? await service.handle("thread", input: ["id": thread["id"]])["live"]["blocks"].array.count) == 2 }
        let snapshot = try await service.handle("thread", input: ["id": thread["id"]]), live = CodeLiveState(json: snapshot["live"])
        XCTAssertEqual(live.blocks[0]?.text, "fixture reason"); XCTAssertEqual(live.blocks[1]?.input["file_path"].string, "fixture")
        _ = try await service.handle("close", input: ["id": thread["id"]]); let closed = try await service.handle("thread", input: ["id": thread["id"]]); XCTAssertTrue(closed["live"].isNull)
    }
    func testShutdownWaitsForEveryDriverClearsTransientStateAndPreservesResumeIDs() async throws {
        let runtime = try runtime(), gate = CodeShutdownGate(), counter = CodeFixtureCounter()
        let service = NativeCodeService(runtime: runtime, channelFactory: { thread in
            _ = counter.next()
            return CodeShutdownChannel(gate: gate, script: { frame in
                if frame["type"].string == "control_request" { return [["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": [:]]], ["type": "system", "subtype": "init", "session_id": .string("resume-" + thread["id"].string)]] }
                if frame["type"].string == "user" { return [["type": "stream_event", "event": ["type": "message_start", "message": ["id": "live"]]], ["type": "stream_event", "event": ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "fixture"]]], ["type": "control_request", "request_id": .string("permission-" + thread["id"].string), "request": ["subtype": "can_use_tool", "tool_name": "Write", "tool_use_id": "tool", "input": [:]]]] }; return []
            })
        })
        let project = try await service.handle("project.add", input: ["path": .string(runtime.paths.root.appendingPathComponent("project").path)])
        var ids: [JSONValue] = []
        for _ in 0..<2 { let thread = try await service.handle("thread.create", input: ["projectId": project["id"]]); ids.append(thread["id"]); _ = try await service.handle("send", input: ["id": thread["id"], "text": "Fixture"] ) }
        try await eventually { (try? await service.handle("pending").array.count) == 2 }
        let store = try CodeStore(runtime: runtime), stale = try store.create(["project_id": project["id"]]); _ = try store.patch(stale["id"]!, ["status": "running", "claude_session_id": "stale-resume"])
        let first = Task { await service.shutdown() }, second = Task { await service.shutdown() }
        try await eventually { await gate.count() == 2 }
        let pending = try await service.handle("summary"); XCTAssertEqual(pending["activeThreads"].int, 2)
        await gate.release(); await first.value; await second.value
        let summary = try await service.handle("summary"); XCTAssertEqual(summary["activeThreads"].int, 0); XCTAssertEqual(summary["pendingPermissions"].int, 0)
        for id in ids { let row = try await service.handle("thread", input: ["id": id]); XCTAssertEqual(row["thread"]["status"].string, "paused"); XCTAssertEqual(row["thread"]["claude_session_id"].string, "resume-" + id.string); XCTAssertTrue(row["pending"].array.isEmpty); XCTAssertTrue(row["live"].isNull); XCTAssertFalse(row["thread"]["alive"].bool) }
        XCTAssertEqual(try store.thread(stale["id"]!)?["status"]?.string, "paused"); XCTAssertEqual(try store.thread(stale["id"]!)?["claude_session_id"]?.string, "stale-resume")
        do { _ = try await service.handle("send", input: ["id": ids[0], "text": "After shutdown"]); XCTFail("Shutdown service accepted a new send") } catch {}
        let closed = await gate.count(); XCTAssertEqual(closed, 2); XCTAssertEqual(counter.next(), 3)
    }
    func testShutdownDuringInitializeDoesNotLaunchPromptOrOverwritePausedStatus() async throws {
        let runtime = try runtime(), gate = CodeShutdownGate(), channel = CodeShutdownChannel(gate: gate, script: { _ in [] })
        let service = NativeCodeService(runtime: runtime, channelFactory: { _ in channel })
        let project = try await service.handle("project.add", input: ["path": .string(runtime.paths.root.appendingPathComponent("project").path)]), thread = try await service.handle("thread.create", input: ["projectId": project["id"]])
        let store = try CodeStore(runtime: runtime); _ = try store.patch(thread["id"], ["claude_session_id": "existing-resume"])
        _ = try await service.handle("send", input: ["id": thread["id"], "text": "Fixture"])
        try await eventually { channel.frames().contains { $0["request"]["subtype"].string == "initialize" } }
        let shutdown = Task { await service.shutdown() }; try await eventually { await gate.count() == 1 }; await gate.release(); await shutdown.value
        await service.shutdown(); await Task.yield()
        let result = try await service.handle("thread", input: ["id": thread["id"]]); XCTAssertEqual(result["thread"]["status"].string, "paused"); XCTAssertEqual(result["thread"]["claude_session_id"].string, "existing-resume"); XCTAssertFalse(channel.frames().contains { $0["type"].string == "user" }); XCTAssertTrue(result["thread"]["last_error"].isNull)
    }
    func testShutdownFlushesPartialACPAssistantBeforeReturning() async throws {
        let runtime = try runtime(), gate = CodeShutdownGate()
        let channel = CodeShutdownChannel(gate: gate, script: { frame in
            if frame["method"].string == "initialize" { return [["jsonrpc": "2.0", "id": frame["id"], "result": [:]]] }
            if frame["method"].string == "session/new" { return [["jsonrpc": "2.0", "id": frame["id"], "result": ["sessionId": "acp-resume"]]] }
            if frame["method"].string == "session/prompt" { return [["jsonrpc": "2.0", "method": "session/update", "params": ["sessionId": "acp-resume", "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Preserve this partial assistant"]]]]] }; return []
        })
        let service = NativeCodeService(runtime: runtime, channelFactory: { _ in channel }), project = try await service.handle("project.add", input: ["path": .string(runtime.paths.root.appendingPathComponent("project").path)])
        let thread = try await service.handle("thread.create", input: ["projectId": project["id"], "routeId": "agent:opencode"])
        _ = try await service.handle("send", input: ["id": thread["id"], "text": "Fixture"])
        try await eventually { (try? await service.handle("thread", input: ["id": thread["id"]])["live"]["blocks"].array.first?["text"].string) == "Preserve this partial assistant" }
        let shutdown = Task { await service.shutdown() }; try await eventually { await gate.count() == 1 }; await gate.release(); await shutdown.value
        let result = try await service.handle("thread", input: ["id": thread["id"]]); XCTAssertEqual(result["thread"]["status"].string, "paused"); XCTAssertEqual(result["thread"]["claude_session_id"].string, "acp-resume")
        XCTAssertTrue(result["events"].array.contains { $0["type"].string == "assistant" && $0["payload"]["content"].array.first?["text"].string == "Preserve this partial assistant" })
    }
    func testPostRecoveryPausesInterruptedRowsPreservingSessionsAndAccounting() async throws {
        let runtime = try runtime(), store = try CodeStore(runtime: runtime), project = try store.addProject(runtime.paths.root.appendingPathComponent("project").path)
        var ids: [JSONValue] = []
        for status in ["running", "starting", "waiting", "idle", "error"] { let row = try store.create(["project_id": project["id"]!]); ids.append(row["id"]!); _ = try store.patch(row["id"]!, ["status": .string(status), "claude_session_id": .string("resume-" + status), "cost_usd": 2.5, "input_tokens": 10, "output_tokens": 5]) }
        let service = NativeCodeService(runtime: runtime); try await service.start()
        XCTAssertEqual(try store.thread(ids[0])?["status"]?.string, "running")
        try await runtime.jobs.recover(); try await service.reconcileAfterRecovery()
        for id in ids.prefix(3) { let row = try XCTUnwrap(store.thread(id)); XCTAssertEqual(row["status"]?.string, "paused"); XCTAssertEqual(row["cost_usd"], 2.5); XCTAssertEqual(row["input_tokens"], 10); XCTAssertEqual(row["output_tokens"], 5); XCTAssertTrue(row["claude_session_id"]?.string.hasPrefix("resume-") == true); XCTAssertEqual(try store.events(id, after: 0).count, 1) }
        XCTAssertEqual(try store.thread(ids[3])?["status"]?.string, "idle"); XCTAssertEqual(try store.thread(ids[4])?["status"]?.string, "error")
        try await service.reconcileAfterRecovery(); XCTAssertEqual(try store.events(ids[0], after: 0).count, 1)
        let before = try runtime.db.query("SELECT * FROM code_threads ORDER BY id"), events = try runtime.db.query("SELECT * FROM code_events ORDER BY id")
        let readOnly = try NativeRuntime(paths: NativePaths(root: runtime.paths.root, home: runtime.paths.home, readOnly: true)), reader = NativeCodeService(runtime: readOnly)
        try await reader.reconcileAfterRecovery(); let state = try await reader.handle("thread", input: ["id": ids[0]]); XCTAssertEqual(state["thread"]["claude_session_id"].string, "resume-running")
        XCTAssertEqual(try runtime.db.query("SELECT * FROM code_threads ORDER BY id"), before); XCTAssertEqual(try runtime.db.query("SELECT * FROM code_events ORDER BY id"), events)
    }
    private func eventually(_ condition: @escaping () async -> Bool) async throws { for _ in 0..<200 { if await condition() { return }; try await Task.sleep(nanoseconds: 1_000_000) }; XCTFail("Fixture operation did not settle") }
}

final class CodeFixtureChannel: CodeChannel, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock(), script: @Sendable (JSONValue) -> [JSONValue]
    private var sent: [JSONValue] = [], closed = false
    init(script: @escaping @Sendable (JSONValue) -> [JSONValue]) {
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        output = AsyncThrowingStream { continuation = $0 }; self.continuation = continuation; self.script = script
    }
    private func save(_ value: JSONValue) { lock.lock(); sent.append(value); lock.unlock() }
    func write(_ value: JSONValue) async throws { save(value); for reply in script(value) { emit(reply) } }
    func emit(_ value: JSONValue) { lock.lock(); defer { lock.unlock() }; var data = (try? value.encoded()) ?? Data(); data.append(10); let split = max(1, data.count / 2); continuation.yield(Data(data.prefix(split))); continuation.yield(Data(data.dropFirst(split))) }
    func close() async { finish() }
    private func finish() { lock.lock(); closed = true; lock.unlock(); continuation.finish() }
    func wait() async throws -> Int32 { 0 }
    func frames() -> [JSONValue] { lock.lock(); defer { lock.unlock() }; return sent }
    func didClose() -> Bool { lock.lock(); defer { lock.unlock() }; return closed }
}
private actor CodeFixtureEvents { var values: [(String, JSONValue)] = []; func add(_ type: String, _ value: JSONValue) { values.append((type, value)) }; func contains(_ type: String) -> Bool { values.contains { $0.0 == type } }; func rows() -> [(String, JSONValue)] { values } }
private final class CodeFixtureCounter: @unchecked Sendable { let lock = NSLock(); var n = 0; func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n } }
private final class CodeFixtureThreads: @unchecked Sendable { let lock = NSLock(); var values: [JSONValue] = []; func add(_ v: JSONValue) { lock.lock(); values.append(v); lock.unlock() }; func rows() -> [JSONValue] { lock.lock(); defer { lock.unlock() }; return values } }
private actor CodeShutdownGate {
    private var began = 0, released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func begin() async { began += 1; if !released { await withCheckedContinuation { waiters.append($0) } } }
    func count() -> Int { began }
    func release() { released = true; let pending = waiters; waiters = []; for waiter in pending { waiter.resume() } }
}
private final class CodeShutdownChannel: CodeChannel, @unchecked Sendable {
    private let base: CodeFixtureChannel, gate: CodeShutdownGate
    var output: AsyncThrowingStream<Data, Error> { base.output }
    init(gate: CodeShutdownGate, script: @escaping @Sendable (JSONValue) -> [JSONValue]) { self.gate = gate; base = CodeFixtureChannel(script: script) }
    func write(_ value: JSONValue) async throws { try await base.write(value) }
    func close() async { await gate.begin(); await base.close() }
    func wait() async throws -> Int32 { try await base.wait() }
    func frames() -> [JSONValue] { base.frames() }
}
