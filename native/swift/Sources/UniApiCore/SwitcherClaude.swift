import Foundation

public enum NativeClaudeTextProbe {
    public static func request(_ provider: NativeProviderInfo, model: String, port: Int = 8823, timeout: Double) throws -> ShimHTTPRequest {
        guard provider.enabled, !model.isEmpty else { throw NativeFailure("Enable this Claude route and choose a model first") }
        var base = provider.claudeURL(port: port).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        base += base.hasSuffix("/v1") ? "/messages" : "/v1/messages"
        guard let url = URL(string: base), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw NativeFailure("Invalid Claude route") }
        let payload: JSONValue = ["model": .string(model), "max_tokens": 8, "messages": [["role": "user", "content": "Say hi."]]]
        return .init(url: url, headers: ["Content-Type": "application/json", "x-api-key": provider.key.isEmpty ? "shim" : provider.key, "anthropic-version": "2023-06-01"], body: try payload.encoded(), timeout: timeout)
    }
}

public final class NativeClaudeSettingsStore: @unchecked Sendable {
    public static let efforts = ["low", "medium", "high", "xhigh", "max"]
    public let paths: NativePaths, file: URL
    public init(paths: NativePaths) { self.paths = paths; file = SwitcherDisk.claudeHome(paths).appendingPathComponent("settings.json") }
    public func read() throws -> JSONValue { let value = try SwitcherDisk.json(file); guard case .object = value else { throw NativeFailure("Claude settings must be a JSON object") }; return value }
    public func snapshot() throws -> JSONValue {
        let settings = try read(), env = settings["env"]
        return ["baseUrl": env["ANTHROPIC_BASE_URL"].string.isEmpty ? .null : env["ANTHROPIC_BASE_URL"], "model": settings["model"], "effort": settings["effort"], "apiKeySet": .bool(!env["ANTHROPIC_API_KEY"].string.isEmpty || !env["ANTHROPIC_AUTH_TOKEN"].string.isEmpty)]
    }
    public static func applying(_ settings: JSONValue, provider: NativeProviderInfo, port: Int = 8823) -> JSONValue {
        var settings = settings, env = settings["env"]
        env["ANTHROPIC_BASE_URL"] = .string(provider.claudeURL(port: port)); env["ANTHROPIC_API_KEY"] = .string(provider.key); env["ANTHROPIC_AUTH_TOKEN"] = .string(provider.key); env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        settings["env"] = env; if !provider.model.isEmpty { settings["model"] = .string(provider.model) }; return settings
    }
    public static func subscription(_ settings: JSONValue) -> JSONValue {
        var fields = settings.object, env = settings["env"].object
        for key in ["ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] { env.removeValue(forKey: key) }
        if env.isEmpty { fields.removeValue(forKey: "env") } else { fields["env"] = .object(env) }; fields.removeValue(forKey: "model"); return .object(fields)
    }
    private func mutate(_ body: (JSONValue) throws -> JSONValue) throws {
        try paths.assertWritable()
        try SwitcherDisk.locked(file) {
            let before = try SwitcherDisk.read(file), original = before.isEmpty ? JSONValue.object([:]) : try JSONValue.decode(before)
            guard case .object = original else { throw NativeFailure("Claude settings must be a JSON object") }
            let output = try body(original)
            let backup = paths.data.appendingPathComponent("switcher/claude-settings-" + UUID().uuidString + ".json")
            try SwitcherDisk.atomic(backup, before)
            try SwitcherDisk.atomic(file, try output.encoded(pretty: true), expected: before)
        }
    }
    public func apply(_ provider: NativeProviderInfo, port: Int = 8823) throws {
        guard provider.enabled else { throw NativeFailure("Enable this API provider first") }
        try mutate { settings in
            if settings["env"]["ANTHROPIC_BASE_URL"].string.isEmpty && !settings["model"].string.isEmpty {
                let state = paths.data.appendingPathComponent("switcher-state.json"); var value = try SwitcherDisk.json(state); value["subscriptionModel"] = settings["model"]; try SwitcherDisk.atomic(state, try value.encoded(pretty: true))
            }
            return Self.applying(settings, provider: provider, port: port)
        }
    }
    public func restore() throws {
        try mutate { settings in var output = Self.subscription(settings); let parked = try SwitcherDisk.json(paths.data.appendingPathComponent("switcher-state.json"))["subscriptionModel"]; if !parked.string.isEmpty { output["model"] = parked }; return output }
    }
    public func model(_ model: String) throws { guard SwitcherDisk.validLabel(.string(model), limit: 1024) else { throw NativeFailure("Invalid model") }; try mutate { value in var output = value; output["model"] = .string(model); return output } }
    public func effort(_ effort: String?) throws {
        guard effort == nil || Self.efforts.contains(effort!) else { throw NativeFailure("Unsupported Claude effort") }
        try mutate { value in var fields = value.object; if let effort { fields["effort"] = .string(effort) } else { fields.removeValue(forKey: "effort") }; return .object(fields) }
    }
    public static func current(_ url: String, providers: [NativeProviderInfo]) -> String? {
        let normalized = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let provider = providers.first(where: { !$0.direct.isEmpty && $0.direct.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalized }) { return provider.id }
        guard let parsed = URL(string: normalized), ["127.0.0.1", "localhost"].contains(parsed.host ?? "") else { return nil }
        let id = parsed.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
        return (providers.first { $0.id == id } ?? providers.first { $0.raw["proxy"]["aliases"].array.contains(.string(id)) })?.id
    }
}
