import XCTest
import Foundation
@testable import UniApiCore

final class CodeAcceptanceTests: XCTestCase {
    func testAgentSetupDistinguishesDownloadManualKeyAndReauthentication() {
        let download: JSONValue = ["installed": false, "install": ["kind": "download", "hint": "download"], "auth": ["kind": "browser", "ready": false]]
        XCTAssertTrue(CodeAgentSetup(download).canDownload); XCTAssertFalse(CodeAgentSetup(download).canSignIn)
        for kind in ["npm", "path", "custom"] {
            let setup = CodeAgentSetup(["installed": false, "install": ["kind": .string(kind), "hint": "fixture instructions"], "auth": ["kind": "none", "ready": true]])
            XCTAssertFalse(setup.canDownload); XCTAssertFalse(setup.canDiscover); XCTAssertEqual(setup.installHint, "fixture instructions")
        }
        let signedIn = CodeAgentSetup(["installed": true, "auth": ["kind": "browser", "ready": true]])
        XCTAssertTrue(signedIn.canSignIn); XCTAssertTrue(signedIn.canDiscover); XCTAssertEqual(signedIn.signInLabel, "Sign in again")
        let keyAgent = CodeAgent(id: "gemini", name: "Gemini", vendor: "fixture", command: URL(fileURLWithPath: "/fixture/not-executed"), arguments: [], environment: [:], auth: "gemini-api-key", authKind: "api-key", install: [:])
        let keySetup = CodeAgentSetup(keyAgent.status(state: [:]))
        XCTAssertFalse(keySetup.canDiscover); XCTAssertFalse(keySetup.canSignIn); XCTAssertTrue(keySetup.authHint.contains("agents.gemini.apiKey"))
    }
    func testUnsupportedInstallsRefuseBeforeCreatingAnyJob() async throws {
        let runtime = try fixtureRuntime(), service = NativeCodeService(runtime: runtime)
        for id in ["gemini", "codex", "opencode", "missing"] {
            do { _ = try await service.handle("agent.install", input: ["agentId": .string(id)]); XCTFail("Unsupported install was queued") }
            catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        let jobs = try await runtime.jobs.list(app: "code"); XCTAssertTrue(jobs.isEmpty)
    }
    func testSearchMatchesAllWordsAcrossIDsNamesDescriptionsAndKeepsCustomAPIs() {
        let route: JSONValue = ["kind": "provider", "models": ["alpha", "beta", "alpha"]]
        let options: JSONValue = ["models": [["value": "alpha", "displayName": "Fast Alpha", "description": "long context"], ["value": "beta", "displayName": "Beta"]]]
        let choices = CodeModelChoices.choices(route: route, options: options)
        XCTAssertEqual(choices.map { $0["value"].string }, ["alpha", "beta"])
        XCTAssertEqual(CodeModelChoices.filter(choices, query: "FAST context").map { $0["value"].string }, ["alpha"])
        XCTAssertTrue(CodeModelChoices.filter(choices, query: "fast beta").isEmpty)
        XCTAssertEqual(CodeModelChoices.customModel(query: " custom/api ", route: route, choices: choices), "custom/api")
        XCTAssertNil(CodeModelChoices.customModel(query: "alpha", route: route, choices: choices))
        let agent: JSONValue = ["kind": "agent", "models": ["alpha"]]
        XCTAssertNil(CodeModelChoices.customModel(query: "unadvertised", route: agent, choices: choices))
        XCTAssertEqual(CodeModelChoices.choices(route: agent, options: [:]).first?["value"].string, "")
        let composed = "m-\u{00e9}", decomposed = "m-e\u{0301}"
        let unicode = CodeModelChoices.choices(route: ["kind": "provider", "models": [.string(composed), .string(decomposed)]], options: [:])
        XCTAssertEqual(unicode.count, 2); XCTAssertFalse(CodeModelChoices.sameID(composed, decomposed))
        XCTAssertEqual(CodeModelChoices.customModel(query: decomposed, route: route, choices: [["value": .string(composed)]]), decomposed)
    }
    func testRemovedOrDifferentDataRootProjectFallsBackWithoutDestroyingValidSelection() {
        let projects: [JSONValue] = [["id": "recent"], ["id": "other"]]
        XCTAssertEqual(CodeProjectSelection.resolve("deleted", projects: projects), "recent")
        XCTAssertEqual(CodeProjectSelection.resolve("", projects: projects), "recent")
        XCTAssertEqual(CodeProjectSelection.resolve("other", projects: projects), "other")
        XCTAssertEqual(CodeProjectSelection.resolve("previous-data-root", projects: []), "")
    }
    func testGitReadGenerationRejectsOldProjectFileAndRefreshResponses() {
        var state = CodeGitSelection()
        let first = CodeGitContext(project: "a", thread: "one"), second = CodeGitContext(project: "b", thread: "two")
        XCTAssertTrue(state.configure(first)); state.select("old.txt"); let old = state.begin()
        XCTAssertTrue(state.accepts(old)); XCTAssertTrue(state.configure(second)); XCTAssertNil(state.file); XCTAssertFalse(state.accepts(old))
        state.select("new.txt"); let reading = state.begin(), refreshing = state.begin()
        XCTAssertFalse(state.accepts(reading)); XCTAssertTrue(state.accepts(refreshing)); XCTAssertFalse(state.configure(second)); XCTAssertEqual(state.file, "new.txt")
        state.select(nil); XCTAssertFalse(state.accepts(refreshing))
    }
    func testACPAllRawEditAliasesEmptyBeforeAndPartialMetadataSurvive() {
        for (old, new) in [("old_string", "new_string"), ("oldString", "newString"), ("old_text", "new_text"), ("oldText", "newText")] {
            let tool = CodeACPBlocks.shape(["toolCallId": "tool", "kind": "edit", "rawInput": .object(["path": "a", old: "", new: "after"])])
            XCTAssertEqual(tool["input"]["old_string"], ""); XCTAssertEqual(tool["input"]["new_string"], "after"); XCTAssertEqual(tool["input"]["file_path"], "a")
        }
        let original = CodeACPBlocks.shape(["toolCallId": "tool", "kind": "edit", "rawInput": ["file_path": "a", "content": "before"], "_meta": ["claudeCode": ["toolName": "NotebookEdit"]]])
        let partial = CodeACPBlocks.shape(["toolCallId": "tool", "status": "completed"], previous: original)
        XCTAssertEqual(partial["name"], "NotebookEdit"); XCTAssertEqual(partial["input"]["content"], "before")
        let malformed = CodeACPBlocks.shape(["toolCallId": "tool", "rawInput": "not-an-object"], previous: original)
        XCTAssertEqual(malformed["input"]["content"], "before")
        let diff = CodeACPBlocks.shape(["toolCallId": "tool", "kind": "edit", "content": [["type": "diff", "path": "a", "oldText": "old", "newText": "new"]]])
        XCTAssertEqual(diff["name"], "Edit"); XCTAssertEqual(diff["input"]["new_string"], "new")
    }
    func testACPIncrementalNamesFollowKindAndInputWithoutLosingMetadataOrEmptyValues() throws {
        var untyped = CodeACPBlocks()
        _ = untyped.update(["sessionUpdate": "tool_call", "toolCallId": "t", "title": "Working"])
        XCTAssertEqual(untyped.blocks.first?.content["name"], "Tool")
        let completed = untyped.update(["sessionUpdate": "tool_call_update", "toolCallId": "t", "kind": "edit", "status": "completed", "rawInput": ["path": "a.txt", "old_string": "before", "new_string": "after"]])
        let persisted = try XCTUnwrap(completed.first { $0.0 == "assistant" }?.1["content"].array.first)
        XCTAssertEqual(persisted["name"], "Edit"); XCTAssertEqual(persisted["input"]["old_string"], "before"); XCTAssertEqual(persisted["input"]["new_string"], "after")
        XCTAssertTrue(completed.contains { $0.0 == "stream" && $0.1["type"] == "content_block_start" && $0.1["content_block"]["name"] == "Edit" })

        for (kind, name) in [("read", "Read"), ("execute", "Bash"), ("search", "Grep"), ("fetch", "WebFetch"), ("delete", "Delete"), ("move", "Move"), ("think", "Think"), ("switch_mode", "SwitchMode")] {
            var turn = CodeACPBlocks()
            _ = turn.update(["sessionUpdate": "tool_call", "toolCallId": "kind", "title": "Working"])
            _ = turn.update(["sessionUpdate": "tool_call_update", "toolCallId": "kind", "kind": .string(kind), "rawInput": ["path": "a", "cmd": "echo fixture", "query": "needle", "url": "https://fixture.invalid"]])
            XCTAssertEqual(turn.blocks.first?.content["name"], .string(name), kind)
        }

        var writing = CodeACPBlocks()
        _ = writing.update(["sessionUpdate": "tool_call", "toolCallId": "write", "kind": "edit", "rawInput": ["path": "a", "content": ""]])
        XCTAssertEqual(writing.blocks.first?.content["name"], "Write")
        _ = writing.update(["sessionUpdate": "tool_call_update", "toolCallId": "write", "title": "Still writing"])
        XCTAssertEqual(writing.blocks.first?.content["input"]["content"], ""); XCTAssertEqual(writing.blocks.first?.content["name"], "Write")
        _ = writing.update(["sessionUpdate": "tool_call_update", "toolCallId": "write", "rawInput": ["path": "a", "old_text": "", "new_text": "after"]])
        XCTAssertEqual(writing.blocks.first?.content["name"], "Edit"); XCTAssertEqual(writing.blocks.first?.content["input"]["old_string"], "")
        let priorInput = try XCTUnwrap(writing.blocks.first?.content["input"])
        let renamed = writing.update(["sessionUpdate": "tool_call_update", "toolCallId": "write", "_meta": ["claudeCode": ["toolName": "NotebookEdit"]]])
        XCTAssertEqual(writing.blocks.first?.content["name"], "NotebookEdit"); XCTAssertEqual(writing.blocks.first?.content["input"], priorInput)
        XCTAssertTrue(renamed.contains { $0.0 == "stream" && $0.1["type"] == "content_block_start" && $0.1["content_block"]["name"] == "NotebookEdit" })
        _ = writing.update(["sessionUpdate": "tool_call_update", "toolCallId": "write", "rawInput": "malformed", "status": "in_progress"])
        XCTAssertEqual(writing.blocks.first?.content["name"], "NotebookEdit"); XCTAssertEqual(writing.blocks.first?.content["input"], priorInput)
        _ = writing.update(["sessionUpdate": "tool_call_update", "toolCallId": "write", "kind": "execute", "rawInput": ["cmd": "fixture"]])
        XCTAssertEqual(writing.blocks.first?.content["name"], "NotebookEdit")

        var partial = CodeACPBlocks()
        _ = partial.update(["sessionUpdate": "tool_call", "toolCallId": "partial", "kind": "edit", "rawInput": ["path": "a", "old_string": ""]])
        let partialInput = try XCTUnwrap(partial.blocks.first?.content["input"])
        _ = partial.update(["sessionUpdate": "tool_call_update", "toolCallId": "partial", "_meta": ["claudeCode": ["toolName": "CustomEdit"]]])
        XCTAssertEqual(partial.blocks.first?.content["input"], partialInput); XCTAssertEqual(partial.blocks.first?.content["input"]["old_string"], "")

        var diff = CodeACPBlocks()
        _ = diff.update(["sessionUpdate": "tool_call", "toolCallId": "diff", "content": [["type": "diff", "path": "a", "newText": ""]]])
        _ = diff.update(["sessionUpdate": "tool_call_update", "toolCallId": "diff", "title": "Still writing"])
        XCTAssertEqual(diff.blocks.first?.content["name"], "Write"); XCTAssertEqual(diff.blocks.first?.content["input"]["content"], "")
    }
    func testHistoricalDiagnosticsAndPerTurnUsageDoNotDependOnCurrentThreadError() {
        let failed: JSONValue = ["subtype": "error_during_execution", "is_error": true, "errors": ["fixture refusal", ["message": "second explanation"]], "usage": ["input_tokens": 2, "cache_read_input_tokens": 3, "cache_creation_input_tokens": 4, "output_tokens": 5]]
        XCTAssertEqual(CodeEventPresentation.resultError(failed), "fixture refusal; second explanation")
        XCTAssertEqual(CodeEventPresentation.inputTokens(failed), 9)
        XCTAssertEqual(CodeEventPresentation.errorText(["message": "assistant fault"]), "assistant fault")
        XCTAssertNil(CodeEventPresentation.resultError(["subtype": "success", "is_error": false]))
        XCTAssertEqual(CodeEventPresentation.resultError(failed), "fixture refusal; second explanation")
        var turn = CodeACPBlocks(); _ = turn.update(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "partial"]])
        XCTAssertEqual(turn.flush(all: true, aborted: true).first { $0.0 == "assistant" }?.1["aborted"], true)
    }
    func testGitEnvironmentDropsHookRepositoryStateButKeepsCredentialTransport() {
        let env = CodeGitEnvironment.make(["GIT_DIR": "foreign", "GIT_INDEX_FILE": "foreign-index", "GIT_WORK_TREE": "foreign-tree", "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.worktree", "GIT_CONFIG_VALUE_0": "foreign", "SSH_AUTH_SOCK": "fixture-auth", "GIT_SSH_COMMAND": "fixture-transport", "HOME": "fixture-home"])
        XCTAssertNil(env["GIT_DIR"]); XCTAssertNil(env["GIT_INDEX_FILE"]); XCTAssertNil(env["GIT_CONFIG_VALUE_0"])
        XCTAssertEqual(env["SSH_AUTH_SOCK"], "fixture-auth"); XCTAssertEqual(env["GIT_SSH_COMMAND"], "fixture-transport"); XCTAssertEqual(env["HOME"], "fixture-home")
    }
    private func fixtureRuntime() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-acceptance-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        addTeardownBlock { await runtime.jobs.suspendForShutdown(); try? FileManager.default.removeItem(at: root) }; return runtime
    }
}
