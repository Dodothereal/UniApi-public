import Foundation

/// API routing belongs to the existing Swift shim, independently of the Web
/// browser launcher. Native authority and provider authority never share a builder.
actor NativeCodexRouter {
    static let path = "/_uniapi/codex"
    enum Endpoint: String { case models, responses, compact = "responses/compact", search = "alpha/search" }
    private let paths: NativePaths, providers: NativeProviderStore, dependencies: ShimDependencies
    init(paths: NativePaths, providers: NativeProviderStore, dependencies: ShimDependencies) { self.paths = paths; self.providers = providers; self.dependencies = dependencies }
    static func matches(_ path: String) -> Bool { path == Self.path || path.hasPrefix(Self.path + "/") || path.hasPrefix(Self.path + "?") }
    private func choices() throws -> JSONValue {
        try NativeCodexCatalogStore(bridgeHome: paths.data.appendingPathComponent("codex/native-route"), providersFile: paths.providers).read()
    }
    func handle(_ request: ShimClientRequest, ticket: ShimRequestTicket?, forwardProvider: @escaping @Sendable (ShimClientRequest) async throws -> ShimClientResponse) async throws -> ShimClientResponse {
        do {
            try Self.guardBrowserRequest(request)
            let token = try NativeCodexRoutingSecret.load(paths)
            let (endpoint, incoming) = try Self.endpoint(request, token: token)
            let selection = try choices(), document = JSONValue.object(try providers.document())
            if endpoint == .models {
                guard Self.authorized(request) else { return try .error(401, "Native Codex requires incoming authorization") }
                let upstream = try await dependencies.transport.open(Self.nativeRequest(request, incoming: incoming, endpoint: endpoint, body: nil))
                guard upstream.status == 200 else { return relay(upstream, ticket: ticket) }
                let native = try JSONValue.decode(await upstream.body())
                let catalog = try NativeCodexRouteCatalog.augment(native, providers: document, choices: selection)
                return try .json(200, catalog)
            }
            let decoded = try NativeCodexRequestBody.decode(request.body, encoding: request.headers["content-encoding"])
            let raw = try JSONValue.decode(decoded)
            guard case .object = raw else { return try .error(400, "Codex expects a JSON object") }
            let model = raw["model"].string
            if model.hasPrefix("chatgpt-web/") { return try .error(400, "Browser models require the optional Web launcher; select an API or native model") }
            if model.hasPrefix(NativeCodexRouteCatalog.prefix) {
                guard endpoint != .search, NativeCodexCatalogStore.parseID(model) != nil,
                      let route = try NativeCodexRouteCatalog.routes(providers: document, choices: selection).first(where: { $0.alias == model }) else {
                    return try .error(400, "This UniApi model is unavailable, disabled or unverified")
                }
                if raw["input"].array.contains(where: { $0["type"] == "agent_message" && $0["content"].array.contains(where: { $0["type"] == "encrypted_content" }) }) {
                    return try .error(400, "A provider worker needs a Compatibility V1 task with plain context")
                }
                var body = try NativeCodexRouteHistory.providerInput(raw)
                let compact = endpoint == .compact || raw["input"].array.contains { $0["type"] == "compaction_trigger" }
                if compact {
                    let prompt = """
                    You are performing a CONTEXT CHECKPOINT COMPACTION. Create a handoff summary for another LLM that will resume the task.

                    Include:
                    - Current progress and key decisions made
                    - Important context, constraints, or user preferences
                    - What remains to be done (clear next steps)
                    - Any critical data, examples, or references needed to continue

                    Be concise, structured, and focused on helping the next LLM seamlessly continue the work.
                    """
                    var input = body["input"].array
                    if case .string(let text) = body["input"] { input = [["role": "user", "content": .string(text)]] }
                    input.removeAll { $0["type"] == "additional_tools" }
                    if !raw["instructions"].string.isEmpty { input.insert(["role": "developer", "content": raw["instructions"]], at: 0) }
                    input.append(["role": "user", "content": .string(prompt)])
                    body = ["model": .string(route.model), "stream": true, "store": false, "tools": [], "tool_choice": "none", "max_output_tokens": .number(Double(min(8192, max(256, route.context / 10)))), "instructions": .string(prompt), "input": .array(input)]
                } else { body["model"] = .string(route.model) }
                var headers = ["content-type": "application/json", "accept": "text/event-stream"]
                if !route.provider.key.isEmpty { headers["authorization"] = "Bearer " + route.provider.key }
                let providerRequest = ShimClientRequest(method: "POST", path: "/" + NativeProviderInfo.encoded(route.provider.id) + "/v1/responses", version: "HTTP/1.0", headers: headers, body: try body.encoded())
                let response = try await forwardProvider(providerRequest)
                if compact { return try await NativeCodexRouteResponses.compact(response, raw: raw, unary: endpoint == .compact, context: route.context) }
                return try await NativeCodexRouteResponses.wrap(response, alias: model, ticket: ticket)
            }
            let clean = try NativeCodexRouteHistory.nativeInput(raw)
            guard Self.authorized(request) else { return try .error(401, "Native Codex requires incoming authorization") }
            var native = try Self.nativeRequest(request, incoming: incoming, endpoint: endpoint, body: clean.changed ? try clean.value.encoded() : request.body)
            if clean.changed { native.headers.removeValue(forKey: "content-encoding") }
            return relay(try await dependencies.transport.open(native), ticket: ticket)
        } catch is CancellationError { throw CancellationError() }
        catch is NativeFailure { return try .error(400, "Native Codex routing refused an invalid request or configuration; no fallback was submitted") }
        catch { return try .error(502, "Native Codex transport failed; no fallback was submitted") }
    }
    private static func authorized(_ request: ShimClientRequest) -> Bool { (request.headers["authorization"] ?? "").hasPrefix("Bearer ") && (request.headers["authorization"] ?? "").utf8.count > 7 }
    static func endpoint(_ request: ShimClientRequest, token: String) throws -> (Endpoint, URLComponents) {
        guard NativeCodexRoutingSecret.valid(token) else { throw NativeFailure("Native Codex routing authorization is unavailable") }
        guard request.path.utf8.count <= 16384, let parts = URLComponents(string: "http://127.0.0.1" + request.path), parts.host == "127.0.0.1", parts.fragment == nil,
              parts.percentEncodedPath.hasPrefix(path + "/") else { throw NativeFailure("Unsupported native Codex endpoint") }
        let components = String(parts.percentEncodedPath.dropFirst(path.count + 1)).components(separatedBy: "/")
        guard components.count >= 3, NativeCodexRoutingSecret.valid(components[0]), components[1] == "v1" else { throw NativeFailure("Native Codex routing authorization required") }
        let supplied = Array(components[0].utf8), expected = Array(token.utf8)
        var difference: UInt8 = 0
        for i in expected.indices { difference |= supplied[i] ^ expected[i] }
        guard difference == 0, let endpoint = Endpoint(rawValue: components.dropFirst(2).joined(separator: "/")),
              request.method == (endpoint == .models ? "GET" : "POST") else { throw NativeFailure("Unsupported native Codex endpoint") }
        return (endpoint, parts)
    }
    private static func guardBrowserRequest(_ request: ShimClientRequest) throws {
        if let origin = request.headers["origin"] {
            let host = request.headers["host"] ?? ""
            guard !host.isEmpty, origin == "http://" + host.lowercased() else { throw NativeFailure("Native Codex requires an exact local origin") }
        }
        if let site = request.headers["sec-fetch-site"], !["none", "same-origin"].contains(site) { throw NativeFailure("Cross-origin native Codex requests are refused") }
        if request.headers["sec-fetch-mode"] == "no-cors" { throw NativeFailure("Opaque native Codex requests are refused") }
    }
    static func nativeRequest(_ request: ShimClientRequest, incoming: URLComponents, endpoint: Endpoint, body: Data?) throws -> ShimHTTPRequest {
        let authorization = request.headers["authorization"] ?? ""
        guard authorization.hasPrefix("Bearer "), authorization.utf8.count > 7 else { throw NativeFailure("Native Codex requires incoming authorization") }
        var target = URLComponents(string: "https://chatgpt.com/backend-api/codex/" + endpoint.rawValue)!
        target.percentEncodedQuery = incoming.percentEncodedQuery
        if endpoint == .models, !(target.queryItems ?? []).contains(where: { $0.name == "client_version" }), let version = clientVersion(request.headers["user-agent"] ?? "") {
            target.queryItems = (target.queryItems ?? []) + [URLQueryItem(name: "client_version", value: version)]
        }
        let nominated = Set((request.headers["connection"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        let exact: Set<String> = ["authorization", "accept", "content-type", "content-encoding", "user-agent", "originator", "chatgpt-account-id", "openai-beta", "openai-organization", "openai-project", "client-version", "session-id"]
        var headers: [String: String] = [:]
        for (key, value) in request.headers where !nominated.contains(key) && (exact.contains(key) || key.hasPrefix("x-codex-") || key.hasPrefix("x-openai-")) {
            guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw NativeFailure("Invalid native Codex header") }
            headers[key] = value
        }
        guard headers["authorization"] == authorization else { throw NativeFailure("Conflicting native authorization header") }
        return .init(url: target.url!, method: endpoint == .models ? "GET" : "POST", headers: headers, body: body, timeout: 600, bypassSystemProxy: true)
    }
    private static func clientVersion(_ agent: String) -> String? {
        guard let slash = agent.firstIndex(of: "/") else { return nil }
        let origin = String(agent[..<slash]), accepted: Set<String> = ["codex_cli_rs", "codex-tui", "codex_vscode", "codex_atlas", "codex_chatgpt_desktop"]
        guard accepted.contains(origin) || origin.range(of: "^Codex [A-Za-z0-9][A-Za-z0-9._ -]{0,63}$", options: .regularExpression) != nil else { return nil }
        let tail = String(agent[agent.index(after: slash)...])
        guard let range = tail.range(of: "^[0-9]{1,6}\\.[0-9]{1,6}\\.[0-9]{1,6}(?=[-+ ]|$)", options: .regularExpression) else { return nil }
        return String(tail[range])
    }
    private func relay(_ upstream: ShimUpstream, ticket: ShimRequestTicket?) -> ShimClientResponse {
        let control = NativeCodexRelayControl(), producer = ticket?.fork()
        let eventStream = (upstream.headers["content-type"] ?? "").lowercased().contains("text/event-stream")
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let task = Task {
                var terminator = NativeCodexTerminator(), localFailure = false
                do {
                    for try await bytes in upstream.chunks {
                        try Task.checkCancellation(); if eventStream { terminator.feed(bytes) }
                        if case .dropped = continuation.yield(bytes) { localFailure = true; throw NativeFailure("Native Codex client exceeded its bounded buffer") }
                    }
                    try Task.checkCancellation(); continuation.finish()
                } catch {
                    terminator.finish()
                    if eventStream && terminator.completed && !Task.isCancelled && !localFailure { continuation.finish() } else { continuation.finish(throwing: error) }
                }
                upstream.cancel(); await upstream.waitForCompletion(); producer?.finish()
            }
            control.install(task, cancel: upstream.cancel)
            continuation.onTermination = { reason in if case .cancelled = reason { control.cancel() } }
        }
        let allowed: Set<String> = ["content-type", "retry-after", "x-request-id"]
        let headers = upstream.headers.filter { key, value in
            (allowed.contains(key) || key.hasPrefix("x-codex-") || key.hasPrefix("x-ratelimit-")) && !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
        }
        return .init(status: upstream.status, headers: headers, chunks: stream, cancel: { control.cancel() }, waitForCompletion: { await control.wait() })
    }
}

private final class NativeCodexRelayControl: @unchecked Sendable {
    private let lock = NSLock(); private var task: Task<Void, Never>?, abort: (@Sendable () -> Void)?, stopped = false
    func install(_ task: Task<Void, Never>, cancel: @escaping @Sendable () -> Void) { let cancelled = lock.withLock { self.task = task; abort = cancel; return stopped }; if cancelled { task.cancel(); cancel() } }
    func cancel() { let owned = lock.withLock { stopped = true; return (task, abort) }; owned.0?.cancel(); owned.1?() }
    func wait() async { let task = lock.withLock { task }; await task?.value }
}

struct NativeCodexTerminator {
    private var line: [UInt8] = [], oversized = false
    private(set) var completed = false
    mutating func feed(_ bytes: Data) {
        for byte in bytes {
            if byte == 10 { seal(); line.removeAll(keepingCapacity: true); oversized = false }
            else if line.count < 32 { line.append(byte) } else { oversized = true }
        }
    }
    // Only EOF/error makes an unterminated line final. A chunk boundary cannot
    // turn a matching prefix into authoritative completion.
    mutating func finish() { seal() }
    private mutating func seal() {
        var bytes = line; if bytes.last == 13 { bytes.removeLast() }
        if !oversized && bytes == Array("data: [DONE]".utf8) { completed = true }
    }
}
