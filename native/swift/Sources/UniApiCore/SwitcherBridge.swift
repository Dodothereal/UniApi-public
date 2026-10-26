import Foundation

public struct NativeSwitcherCommand: Sendable {
    public var executable: URL, arguments: [String]
    public init(_ executable: URL, _ arguments: [String] = []) { self.executable = executable; self.arguments = arguments }
}
public struct NativeSwitcherPlatform: Sendable {
    public var codex: URL?, bridge: NativeSwitcherCommand?, openCodex: NativeSwitcherCommand?, openBridge: NativeSwitcherCommand?, manifest: URL?, launcherState: URL
    public init(codex: URL? = nil, bridge: NativeSwitcherCommand? = nil, openCodex: NativeSwitcherCommand? = nil, openBridge: NativeSwitcherCommand? = nil, manifest: URL? = nil, launcherState: URL) { self.codex = codex; self.bridge = bridge; self.openCodex = openCodex; self.openBridge = openBridge; self.manifest = manifest; self.launcherState = launcherState }
    public static func production(_ runtime: NativeRuntime) -> Self {
        let paths = runtime.paths, environment = SwitcherDisk.env(paths), fm = FileManager.default
        let actualHome = paths.home.standardizedFileURL == fm.homeDirectoryForCurrentUser.standardizedFileURL
        func app(_ names: [String]) -> URL? {
            var candidates = names.map { paths.home.appendingPathComponent("Applications/" + $0) }
            if actualHome { candidates += names.map { URL(fileURLWithPath: "/Applications").appendingPathComponent($0) } }
            return candidates.first { fm.fileExists(atPath: $0.path) }
        }
        let bridgeApp = app(["Codex Web GPT.app"]), codexApp = app(["ChatGPT.app", "Codex.app"])
        let runtimeDirectory = bridgeApp?.appendingPathComponent("Contents/Resources/runtime")
        let bun = environment["UNIAPI_CODEX_BRIDGE_BUN"].map { URL(fileURLWithPath: $0) } ?? runtimeDirectory?.appendingPathComponent("runtime/bun")
        let cli = environment["UNIAPI_CODEX_BRIDGE_CLI"].map { URL(fileURLWithPath: $0) } ?? runtimeDirectory?.appendingPathComponent("app/cli.js")
        let bundled = codexApp?.appendingPathComponent("Contents/Resources/codex")
        let codex = bundled.flatMap { fm.isExecutableFile(atPath: $0.path) ? $0 : nil } ?? (actualHome ? runtime.process.which("codex") : nil)
        let open = actualHome ? runtime.process.which("open") : nil
        var bridge: NativeSwitcherCommand?
        if let bun, let cli, fm.isExecutableFile(atPath: bun.path), fm.fileExists(atPath: cli.path) { bridge = .init(bun, [cli.path]) }
        else if actualHome, let standalone = runtime.process.which("codex-chatgpt-web") { bridge = .init(standalone) }
        let launcher = environment["CODEX_WEB_GPT_LAUNCHER_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? paths.home.appendingPathComponent("Library/Application Support/Codex Web GPT")
        return .init(codex: codex, bridge: bridge, openCodex: open.flatMap { executable in codexApp.map { .init(executable, ["-a", $0.path]) } }, openBridge: open.flatMap { executable in bridgeApp.map { .init(executable, ["-a", $0.path]) } }, manifest: runtimeDirectory?.appendingPathComponent("manifest.json"), launcherState: launcher.appendingPathComponent("launcher-state.json"))
    }
}
public struct NativeSwitcherIO: Sendable {
    public var http: ShimDependencies
    public var platform: @Sendable (NativeRuntime) -> NativeSwitcherPlatform
    public var run: @Sendable (NativeSwitcherCommand, [String: String]) async throws -> String
    public var prove: @Sendable (NativeSwitcherCommand, [String: String], URL) async throws -> NativeProcessResult
    public var watchFiles: Bool
    public init(http: ShimDependencies, platform: @escaping @Sendable (NativeRuntime) -> NativeSwitcherPlatform,
                run: @escaping @Sendable (NativeSwitcherCommand, [String: String]) async throws -> String,
                prove: @escaping @Sendable (NativeSwitcherCommand, [String: String], URL) async throws -> NativeProcessResult, watchFiles: Bool = false) {
        self.http = http; self.platform = platform; self.run = run; self.prove = prove; self.watchFiles = watchFiles
    }
    public static func production(_ runtime: NativeRuntime) -> Self {
        .init(http: .init(), platform: { NativeSwitcherPlatform.production($0) }, run: { command, env in
            let result = try await runtime.process.run(command.executable, arguments: command.arguments, environment: env, timeout: 15)
            guard result.status == 0 else { throw NativeFailure("The bridge command failed; inspect Codex Web GPT diagnostics") }; return result.output
        }, prove: { command, env, directory in try await NativeCodexToolProof.execute(command, environment: env, directory: directory, process: runtime.process) }, watchFiles: true)
    }
}

actor NativeCodexBridgeClient {
    let paths: NativePaths, dependencies: ShimDependencies
    var home: URL { SwitcherDisk.bridgeHome(paths) }
    init(paths: NativePaths, dependencies: ShimDependencies) { self.paths = paths; self.dependencies = dependencies }
    func config() throws -> JSONValue { try SwitcherDisk.json(home.appendingPathComponent("config.json")) }
    func connection() throws -> (base: URL, config: JSONValue)? {
        let value = try config()
        guard value["host"] == "127.0.0.1", case .number = value["port"], value["port"].double == Double(value["port"].int), (1024...65535).contains(value["port"].int) else { return nil }
        return (URL(string: "http://127.0.0.1:\(value["port"].int)")!, value)
    }
    func request(_ endpoint: String, method: String = "GET") async -> JSONValue? {
        do {
            guard let connection = try connection() else { return nil }
            let admin = endpoint.hasPrefix("/admin/"), token = connection.config[admin ? "controlToken" : "uniapiInferenceToken"].string
            if (admin || endpoint.hasPrefix("/uniapi/")) && token.isEmpty { return nil }
            let request = ShimHTTPRequest(url: connection.base.appendingPathComponent(String(endpoint.dropFirst())), method: method, headers: token.isEmpty ? [:] : ["Authorization": "Bearer " + token], timeout: 1.8)
            let upstream = try await dependencies.transport.open(request); guard upstream.status == 200 else { upstream.cancel(); return nil }; return try JSONValue.decode(await upstream.body(limit: 8 * 1024 * 1024))
        } catch { return nil }
    }
    func state(config: JSONObject, platform: NativeSwitcherPlatform, stateDirectory: URL) async -> JSONValue {
        let settings = (try? self.config()) ?? [:], connection = try? connection(), health = await request("/healthz")
        let installed = platform.manifest.flatMap { try? SwitcherDisk.json($0)["appVersion"].string } ?? ""
        let version = settings["releaseVersion"].string.isEmpty ? installed : settings["releaseVersion"].string, mode = settings["mode"].string
        let running = health?["service"] == "codex-chatgpt-web" && health?["status"] == "ok" && health?["mode"] == .string(mode) && health?["version"] == .string(version)
        var busy: JSONValue = .null
        if running, let http = health?["active_http_turns"], let browser = health?["active_browser_turns"], case .number = http, case .number = browser { busy = .bool(http.int > 0 || browser.int > 0) }
        let launcher = (try? SwitcherDisk.json(platform.launcherState)) ?? [:], proof = (try? SwitcherDisk.json(stateDirectory.appendingPathComponent("web-verification.json"))) ?? [:]
        let hash = (try? SwitcherDisk.read(home.appendingPathComponent("config.json"))).map(SwitcherDisk.hash)
        let verified = mode == "full" && proof["version"] == 1 && proof["toolsVerified"] == true && proof["bridgeVersion"] == .string(version) && proof["configHash"].string == hash
        let base = connection?.base.absoluteString ?? ""
        return ["installed": .bool(platform.bridge != nil), "configured": .bool(connection != nil), "running": .bool(running), "integrated": .bool(!base.isEmpty && config["openai_base_url"] == .string(base + "/v1")), "signInChecked": .bool(launcher["browserSmokePassed"] == true && launcher["browserSmokeVersion"] == .string(version)), "toolsVerified": .bool(verified), "version": version.isEmpty ? .null : .string(version), "mode": ["full", "browser-only"].contains(mode) ? .string(mode) : .null, "busy": busy, "catalogSupported": .bool(running && health?["uniapi_catalog_version"] == 1 && health?["uniapi_catalog_protocol"] == "compatibility-v1"), "canStart": .bool(platform.openBridge != nil || platform.bridge != nil && connection != nil), "canStop": .bool(settings["browserHost"] != "launcher" && running && busy == false && platform.bridge != nil)]
    }
    func drained<T: Sendable>(_ action: @Sendable () async throws -> T, resumeOnSuccess: Bool = true) async throws -> T {
        let before = await request("/admin/drain", method: "POST")
        guard before?["accepting_turns"] == false, before?["active_http_turns"] == 0, before?["active_browser_turns"] == 0 else { _ = await request("/admin/resume", method: "POST"); throw NativeFailure("The bridge is busy or idleness could not be proven; finish active tasks first") }
        do {
            let result = try await action()
            if resumeOnSuccess { guard await request("/admin/resume", method: "POST")?["accepting_turns"] == true else { throw NativeFailure("The operation finished but the bridge could not resume; inspect its settings") } }
            return result
        } catch { _ = await request("/admin/resume", method: "POST"); throw error }
    }
}
