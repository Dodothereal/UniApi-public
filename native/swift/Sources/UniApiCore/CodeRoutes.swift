import Foundation

struct CodeAgent: Sendable {
    var id: String, name: String, vendor: String, command: URL?, arguments: [String], environment: [String: String], auth: String, authKind: String, install: JSONValue
    func status(state: JSONValue) -> JSONValue {
        let ready = authKind == "browser" ? state["loggedIn"].bool : authKind == "api-key" ? !(environment["GEMINI_API_KEY"] ?? "").isEmpty : true
        let hint = authKind == "browser" ? ready ? "Signed in; sign in again if the credential expires." : "Sign in explicitly; this opens the agent's browser login." : authKind == "api-key" ? ready ? "GEMINI_API_KEY set" : "Put the key in providers.json under agents.\(id).apiKey, or export GEMINI_API_KEY." : "Uses the agent's existing login"
        return ["id": .string(id), "name": .string(name), "vendor": .string(vendor), "installed": .bool(command != nil), "install": install, "auth": ["methodId": .string(auth), "kind": .string(authKind), "ready": .bool(ready), "label": .string(id == "antigravity" ? "Log in with Google" : "Sign in"), "hint": .string(hint)], "models": state["models"].isNull ? [] : state["models"], "options": state["options"].isNull ? [:] : state["options"]]
    }
}
enum CodeRoutes {
    static let modes = ["default", "acceptEdits", "plan", "bypassPermissions"]
    static let subscriptionModels = ["opus[1m]", "claude-fable-5-1[1m]", "sonnet", "haiku", "default"]
    static let antigravityURL = "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-agy_acp_server_20260818_01_RC01-darwin-arm64.zip"
    static func providers(_ runtime: NativeRuntime) -> [JSONValue] { ((try? runtime.providers.document())?["providers"] ?? []).array.filter { NativeProviderInfo($0).enabled } }
    static func agentState(_ runtime: NativeRuntime) -> JSONValue { (try? NativeFile.readJSON(runtime.paths.data.appendingPathComponent("agents/state.json"))) ?? [:] }
    static func agents(_ runtime: NativeRuntime) -> [CodeAgent] {
        let cfg = JSONValue.object((try? runtime.providers.document()) ?? [:])["agents"]
        let env = environment(runtime)
        let dir = runtime.paths.data.appendingPathComponent("agents/antigravity/agy_acp_server.par")
        let download: JSONValue = ["kind": "download", "hint": "Google macOS arm64 ACP server, about 315 MB", "url": .string(antigravityURL), "bytes": 314500221]
        let geminiKey = cfg["gemini"]["apiKey"].string.isEmpty ? env["GEMINI_API_KEY"] ?? "" : cfg["gemini"]["apiKey"].string
        var geminiEnv = env; if !geminiKey.isEmpty { geminiEnv["GEMINI_API_KEY"] = geminiKey }
        var agEnv = env; agEnv["GEMINI_HOME"] = runtime.paths.home.appendingPathComponent(".gemini").path
        var list: [CodeAgent] = [
            CodeAgent(id: "antigravity", name: "Google Antigravity", vendor: "Google", command: FileManager.default.isExecutableFile(atPath: dir.path) ? dir : nil, arguments: [], environment: agEnv, auth: "oauth-personal", authKind: "browser", install: download),
            CodeAgent(id: "gemini", name: "Gemini CLI", vendor: "Google", command: runtime.process.which("gemini"), arguments: ["--acp"], environment: geminiEnv, auth: "gemini-api-key", authKind: "api-key", install: ["kind": "npm", "hint": "npm install -g @google/gemini-cli"]),
            CodeAgent(id: "codex", name: "Codex", vendor: "OpenAI", command: runtime.process.which("codex") == nil ? nil : runtime.process.which("npx"), arguments: ["-y", "@agentclientprotocol/codex-acp@latest"], environment: env, auth: "", authKind: "none", install: ["kind": "npm", "hint": "npm install -g @openai/codex"]),
            CodeAgent(id: "opencode", name: "OpenCode", vendor: "SST", command: runtime.process.which("opencode"), arguments: ["acp"], environment: env, auth: "", authKind: "none", install: ["kind": "npm", "hint": "npm install -g opencode-ai"])
        ]
        for c in cfg["custom"].array where !c["id"].string.isEmpty && !c["command"].string.isEmpty {
            let command = c["command"].string
            let path = command.hasPrefix("/") ? URL(fileURLWithPath: command) : runtime.process.which(command)
            var customEnv = env; for (name, value) in c["env"].object { customEnv[name] = value.string }
            list.append(CodeAgent(id: c["id"].string, name: c["name"].string.isEmpty ? c["id"].string : c["name"].string, vendor: "custom", command: path, arguments: c["args"].array.map(\.string), environment: customEnv, auth: c["auth"].string, authKind: c["auth"].string.isEmpty ? "none" : "browser", install: ["kind": "custom", "hint": "Configured in providers.json agents.custom"]))
        }
        return list
    }
    static func list(_ runtime: NativeRuntime) -> [JSONValue] {
        var list: [JSONValue] = [["id": "subscription", "name": "Claude (subscription)", "kind": "subscription", "format": "anthropic", "models": .array(subscriptionModels.map(JSONValue.string)), "defaultModel": "opus[1m]", "contextTokens": .null]]
        for p in providers(runtime) {
            list.append(["id": p["id"], "name": p["name"].string.isEmpty ? p["id"] : p["name"], "kind": "provider", "format": p["proxy"]["format"], "models": p["proxy"]["models"].isNull ? [] : p["proxy"]["models"], "defaultModel": p["proxy"]["model"].string.isEmpty ? p["proxy"]["models"].array.first ?? "" : p["proxy"]["model"], "contextTokens": p["proxy"]["context_tokens"]])
        }
        let state = agentState(runtime)
        for a in agents(runtime) { let status = a.status(state: state[a.id]); list.append(["id": .string("agent:" + a.id), "name": .string(a.name), "kind": "agent", "format": .null, "models": .array(status["models"].array.map { $0["value"] }), "defaultModel": "", "contextTokens": .null, "agent": status]) }
        return list
    }
    /// Re-read the provider document for every new turn, including a cached
    /// direct-URL CLI. The shim cannot revoke a request that bypasses it.
    static func assertAvailable(_ runtime: NativeRuntime, route: String) throws {
        _ = try admissionIdentity(runtime, route: route)
    }
    private static func admissionIdentity(_ runtime: NativeRuntime, route: String) throws -> Data {
        if route == "subscription" { return Data(route.utf8) }
        if route.hasPrefix("agent:") {
            guard agents(runtime).contains(where: { Data($0.id.utf8) == Data(route.dropFirst(6).utf8) }) else { throw NativeFailure("The selected agent route was removed") }
            return Data(route.utf8)
        }
        guard let provider = providers(runtime).first(where: { Data($0["id"].string.utf8) == Data(route.utf8) }) else { throw NativeFailure("The selected Code route was removed or disabled") }
        // Catalog/name refreshes do not invalidate a warm process. Credential
        // or destination replacement must not keep using captured direct auth.
        let identity: JSONValue = ["id": provider["id"], "key": provider["api_key"], "base": provider["base_url"], "format": provider["proxy"]["format"], "direct": provider["proxy"]["direct_url"]]
        return try identity.encoded()
    }
    static func admission(_ runtime: NativeRuntime, route: String) throws -> @Sendable () throws -> Void {
        let admitted = try admissionIdentity(runtime, route: route)
        return { guard try admissionIdentity(runtime, route: route) == admitted else { throw NativeFailure("The route's credentials or destination changed; close this session before using the updated route") } }
    }
    static func cachedOptions(_ runtime: NativeRuntime, route: String) -> JSONValue {
        route.hasPrefix("agent:") ? agentState(runtime)[String(route.dropFirst(6))]["options"] : .null
    }
    static func settings(_ runtime: NativeRuntime, route: String, model: String) throws -> JSONValue {
        if route == "subscription" { return ["env": ["ANTHROPIC_BASE_URL": "", "ANTHROPIC_API_KEY": "", "ANTHROPIC_AUTH_TOKEN": ""]] }
        guard let p = providers(runtime).first(where: { Data($0["id"].string.utf8) == Data(route.utf8) }) else { throw NativeFailure("Claude route is unavailable") }
        let m = model.isEmpty ? p["proxy"]["model"].string : model
        let direct = p["proxy"]["direct_url"].string
        let encoded = route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? route
        let base = direct.isEmpty ? "http://127.0.0.1:8823/\(encoded)" : direct
        var env: JSONObject = ["ANTHROPIC_BASE_URL": .string(base), "ANTHROPIC_API_KEY": p["api_key"], "ANTHROPIC_AUTH_TOKEN": p["api_key"], "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]
        for slot in ["ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL"] { env[slot] = .string(m) }
        if p["proxy"]["context_tokens"].double > 0 { env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = .string(p["proxy"]["context_tokens"].string) }
        return ["env": .object(env)]
    }
    static func choices(_ options: JSONValue) -> [JSONValue] {
        options.array.flatMap { option -> [JSONValue] in
            if !option["options"].isNull { return choices(option["options"]) }
            return [["value": option["value"], "displayName": option["name"].isNull ? option["value"] : option["name"], "description": option["description"]]]
        }
    }
    static func environment(_ runtime: NativeRuntime, claude: Bool = false) -> [String: String] {
        var env = runtime.process.cleanAgentEnvironment(); env["NODE_OPTIONS"] = nil
        var paths = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        paths += [runtime.paths.home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let nvm = runtime.paths.home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) { paths += versions.sorted { $0.path > $1.path }.map { $0.appendingPathComponent("bin").path } }
        env["PATH"] = Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }.joined(separator: ":")
        if claude { env["CLAUDE_CODE_ENTRYPOINT"] = "sdk-ts"; env["CLAUDE_AGENT_SDK_CLIENT_APP"] = "uniapi/native" }
        return env
    }
}
