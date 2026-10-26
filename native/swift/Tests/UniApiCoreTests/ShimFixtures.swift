import Foundation
@testable import UniApiCore

actor ShimFixtureTransport: ShimTransport {
    enum Mode { case normal, vendorAnthropic, rateOnce, permanent, empty, truncated, partialError, anthropic, textOnlyProof }
    var mode: Mode, requests: [ShimHTTPRequest] = [], upstreamCount = 0, drainBusy = false, metadataAvailable = true, nativeShim = true
    var beforeModels: (@Sendable () throws -> Void)?
    init(_ mode: Mode = .normal, beforeModels: (@Sendable () throws -> Void)? = nil) { self.mode = mode; self.beforeModels = beforeModels }
    func configure(busy: Bool) { drainBusy = busy }
    func configure(nativeShim: Bool) { self.nativeShim = nativeShim }
    func captured() -> [ShimHTTPRequest] { requests }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        requests.append(request)
        func bytes(_ status: Int = 200, _ body: Data, headers: [String: String] = [:]) -> ShimUpstream { .init(status: status, headers: headers, chunks: AsyncThrowingStream { $0.yield(body); $0.finish() }) }
        func json(_ status: Int = 200, _ body: JSONValue) throws -> ShimUpstream { bytes(status, try body.encoded()) }
        if request.url.path == "/healthz" {
            if request.url.port == 8823 { return try json(200, ["service": "uniapi-shim", "runtime": nativeShim ? "swift" : "legacy", "ok": true, "providers": ["fixture"]]) }
            return try json(200, ["service": "codex-chatgpt-web", "status": "ok", "mode": "full", "version": "5.0.4", "active_http_turns": .number(drainBusy ? 1 : 0), "active_browser_turns": 0, "uniapi_catalog_version": 1, "uniapi_catalog_protocol": "compatibility-v1"])
        }
        if request.url.path == "/admin/drain" { return try json(200, ["accepting_turns": false, "active_http_turns": .number(drainBusy ? 1 : 0), "active_browser_turns": 0]) }
        if request.url.path == "/admin/resume" { return try json(200, ["accepting_turns": true]) }
        if request.url.path == "/uniapi/v1/models" { return try json(200, ["data": [["id": "chatgpt-web/high", "name": "High", "available": true], ["id": "chatgpt-web/pro", "available": false, "reason": "Fixture mode unavailable"]]]) }
        if request.method == "GET" && request.url.path.hasSuffix("/models") {
            try beforeModels?()
            let format: JSONValue = mode == .vendorAnthropic ? [] : ["openai"]
            return try json(200, ["data": [["id": "api-model", "supported_endpoint_types": format], ["id": "gpt-image", "tags": "Text"], ["id": "audio-tts", "tags": ["Text"]], ["id": "embedding-small"]]])
        }
        if mode == .vendorAnthropic && request.url.path == "/v1/messages" { return try json(404, ["type": "error", "error": ["code": "1113", "type": "rate_limit_error", "message": "Insufficient balance"]]) }
        if request.url.path.hasSuffix("/responses") {
            let body = try JSONValue.decode(request.body!), map = try ShimToolMap(body)
            var stream = ShimResponsesStream(model: body["model"].string, tools: map)
            let change: JSONValue = mode == .textOnlyProof ? ["content": "text response"] : ["tool_calls": [["index": 0, "id": "fixture-call", "function": ["name": "get_weather", "arguments": "{\"city\":\"Paris\"}"]]]]
            let frames = stream.feedOpenAI(["choices": [["delta": change, "finish_reason": "stop"]]]) + stream.finish()
            return bytes(200, try frames.reduce(into: Data()) { $0.append(try $1.encoded()) })
        }
        if request.url.path.hasSuffix("/messages") {
            if mode != .anthropic { return try json(200, ["content": [["type": "text", "text": "fixture reply"]]]) }
            let frames: [ShimSSEFrame] = [.init("ping", ["type": "ping"]), .init("message_start", ["type": "message_start", "message": ["usage": ["input_tokens": 1]]]), .init("content_block_start", ["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]), .init("content_block_delta", ["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "private"]])]
            return bytes(200, try frames.reduce(into: Data()) { $0.append(try $1.encoded()) })
        }
        upstreamCount += 1
        if mode == .rateOnce && upstreamCount == 1 { return bytes(429, try JSONValue.object(["error": ["message": "temporary limit"]]).encoded(), headers: ["retry-after": "2"]) }
        if mode == .permanent { return try json(503, ["error": ["code": "model_not_found", "message": "No channel"]]) }
        let start: JSONValue = ["choices": [["delta": ["content": "fixture text"]]]]
        let end: JSONValue = ["choices": [["delta": [:], "finish_reason": "stop"]], "usage": ["prompt_tokens": 2, "completion_tokens": 3]]
        let selected = mode == .empty ? [end] : mode == .truncated ? [start] : [start, end]
        var payload = try selected.reduce(into: Data()) { $0.append(Data(("data: " + String(decoding: try $1.encoded(), as: UTF8.self) + "\n\n").utf8)) }
        if mode == .partialError { payload.append(Data("data: {\"error\":{\"message\":\"fixture reset\"}}\n\n".utf8)) }
        if mode != .truncated { payload.append(Data("data: [DONE]\n\n".utf8)) }
        return bytes(200, payload)
    }
}

actor SwitcherFixtureCommands {
    var commands: [NativeSwitcherCommand] = [], proofCount = 0
    let proofWorks: Bool
    init(proofWorks: Bool = true) { self.proofWorks = proofWorks }
    func run(_ command: NativeSwitcherCommand, _ env: [String: String]) -> String { commands.append(command); return "fixture command" }
    func prove(_ command: NativeSwitcherCommand, _ env: [String: String], _ directory: URL) throws -> NativeProcessResult {
        proofCount += 1; commands.append(command)
        let prompt = command.arguments.last!, expression = try NSRegularExpression(pattern: "containing exactly ([a-f0-9]{32})")
        let match = expression.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt))!, marker = String(prompt[Range(match.range(at: 1), in: prompt)!])
        if proofWorks { try NativeFile.writeAtomic(Data(marker.utf8), to: directory.appendingPathComponent("uniapi-tool-check.txt")) }
        let events: [JSONValue] = [["type": "turn.completed"], ["type": "item.completed", "item": ["type": proofWorks ? "agent_message" : "command_execution", "text": .string("TOOL_CHECK_OK " + marker)]]]
        let stdout = try events.reduce(into: Data()) { $0.append(try $1.encoded()); $0.append(10) }
        return NativeProcessResult(status: 0, stdout: stdout, stderr: Data())
    }
    func captured() -> [NativeSwitcherCommand] { commands }
    func proofs() -> Int { proofCount }
}

enum SwitcherFixture {
    static func create(transport: ShimFixtureTransport = .init(), commands: SwitcherFixtureCommands = .init(), integrated: Bool = true) throws -> (URL, NativeRuntime, NativeSwitcherIO) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("switcher-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("fixture-home")))
        let row: JSONValue = ["id": "fixture", "name": "Fixture", "base_url": "https://fixture.invalid/v1", "api_key": "fixture-key", "proxy": ["format": "openai", "model": "api-model", "models": ["api-model"]], "codex": ["base_url": "http://127.0.0.1:8823/fixture/v1", "models": ["api-model"], "responses_verified": true, "tools_verified": true, "efforts": ["high"]]]
        try NativeFile.writeAtomic(try JSONValue.object(["providers": [row]]).encoded(), to: runtime.paths.providers)
        let codex = root.appendingPathComponent("fixture-home/.codex")
        var text = "model=\"native-anchor\"\nmodel_reasoning_effort=\"ultra\"\n"
        if integrated { text += "openai_base_url=\"http://127.0.0.1:17841/v1\"\n" }
        text += "[hooks]\ncommand=\"preserve\"\n"
        try NativeFile.writeAtomic(Data(text.utf8), to: codex.appendingPathComponent("config.toml"))
        let cache: JSONValue = ["models": [["slug": "native-anchor", "visibility": "list", "supported_in_api": true, "multi_agent_version": "v2", "priority": 0, "supported_reasoning_levels": [["effort": "ultra"]]], ["slug": "native-worker", "visibility": "list", "supported_in_api": true, "multi_agent_version": "v2", "priority": 1, "supported_reasoning_levels": [["effort": "max"]]], ["slug": "chatgpt-web/high", "visibility": "list"]]]
        try NativeFile.writeAtomic(try cache.encoded(), to: codex.appendingPathComponent("models_cache.json"))
        let bridge = root.appendingPathComponent("fixture-home/.codex-chatgpt-web")
        let config: JSONValue = ["host": "127.0.0.1", "port": 17841, "mode": "full", "releaseVersion": "5.0.4", "uniapiInferenceToken": .string(String(repeating: "private-fixture-inference-", count: 3)), "controlToken": .string(String(repeating: "private-fixture-control-", count: 3))]
        try NativeFile.writeAtomic(try config.encoded(), to: bridge.appendingPathComponent("config.json"))
        let launcher = root.appendingPathComponent("launcher-state.json"); try NativeFile.writeAtomic(try JSONValue.object(["browserSmokePassed": true, "browserSmokeVersion": "5.0.4"]).encoded(), to: launcher)
        try NativeFile.writeAtomic(try JSONValue.object(["model": "opus[1m]", "permissions": ["allow": ["Read"]], "env": ["UNRELATED": "keep"]]).encoded(), to: root.appendingPathComponent("fixture-home/.claude/settings.json"))
        let platform = NativeSwitcherPlatform(codex: root.appendingPathComponent("fake-codex"), bridge: .init(root.appendingPathComponent("fake-bridge")), openCodex: .init(root.appendingPathComponent("fake-open")), openBridge: .init(root.appendingPathComponent("fake-open")), launcherState: launcher)
        let dependencies = ShimDependencies(transport: transport, sleep: { _ in try Task.checkCancellation() }, heartbeatSeconds: 0)
        let io = NativeSwitcherIO(http: dependencies, platform: { _ in platform }, run: { command, env in await commands.run(command, env) }, prove: { command, env, directory in try await commands.prove(command, env, directory) })
        return (root, runtime, io)
    }
}
