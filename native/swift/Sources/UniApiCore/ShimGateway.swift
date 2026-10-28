import Foundation

public struct ShimClientRequest: Sendable {
    public var method: String, path: String, version: String, headers: [String: String], body: Data, peer: String
    public init(method: String, path: String, version: String = "HTTP/1.1", headers: [String: String] = [:], body: Data = Data(), peer: String = "127.0.0.1") {
        self.method = method; self.path = path; self.version = version; self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }; self.body = body; self.peer = peer
    }
}
public struct ShimClientResponse: Sendable {
    public var status: Int, headers: [String: String], chunks: AsyncThrowingStream<Data, Error>
    public let cancel: @Sendable () -> Void
    public let waitForCompletion: @Sendable () async -> Void
    var codexStreamTiming: NativeCodexStreamTimingContext? = nil
    var codexProviderReasoning: NativeCodexReasoningCounter? = nil
    public init(status: Int, headers: [String: String] = [:], chunks: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void = {}, waitForCompletion: @escaping @Sendable () async -> Void = {}) { self.status = status; self.headers = headers; self.chunks = chunks; self.cancel = cancel; self.waitForCompletion = waitForCompletion }
    public func body() async throws -> Data { try await ShimUpstream(status: status, headers: headers, chunks: chunks, cancel: cancel, waitForCompletion: waitForCompletion).body() }
    static func bytes(_ status: Int, _ body: Data, type: String = "application/json") -> Self {
        .init(status: status, headers: ["content-type": type, "content-length": String(body.count)], chunks: AsyncThrowingStream { $0.yield(body); $0.finish() })
    }
    static func json(_ status: Int, _ body: JSONValue) throws -> Self { .bytes(status, try body.encoded()) }
    static func error(_ status: Int, _ message: String) throws -> Self { try .json(status, ["type": "error", "error": ["type": "api_error", "message": .string(message)]]) }
}

/// A response returning (or a cancelled socket) does not prove the request is
/// idle. Tickets keep one request counted until every owned phase has drained.
final class ShimRequestActivity: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: @Sendable () -> Double
    private var count = 0
    private var controlToken: String?, lease: String?, leaseDeadline: Double?
    private var retiredLeases: [String: Double] = [:]
    private var acquisitionsBlockedUntil = 0.0
    init(clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }
    var active: Int { lock.withLock { count } }
    func configure(token: String) { lock.withLock { controlToken = token; lease = nil; leaseDeadline = nil; retiredLeases = [:]; acquisitionsBlockedUntil = 0 } }
    func begin() -> ShimRequestTicket? {
        guard lock.withLock({ () -> Bool in guard lease == nil else { return false }; count += 1; return true }) else { return nil }
        return ShimRequestTicket(ShimRequestLifetime { [self] in lock.withLock { count -= 1 } })
    }
    func control(_ request: ShimClientRequest, operation: String) throws -> ShimClientResponse {
        try lock.withLock {
            let supplied = request.headers["authorization"] ?? "", expected = controlToken.map { "Bearer " + $0 } ?? ""
            let a = Array(supplied.utf8), b = Array(expected.utf8)
            var difference = a.count ^ b.count
            for i in 0..<max(a.count, b.count) { difference |= Int(i < a.count ? a[i] : 0) ^ Int(i < b.count ? b[i] : 0) }
            guard !expected.isEmpty, difference == 0 else { return try .error(401, "Native Codex control authorization required") }
            guard request.body.count <= 1024 else { return try .error(413, "Control body is too large") }
            guard request.method == (operation == "status" ? "GET" : "POST") else { return try .error(405, "Method not allowed") }
            let now = clock()
            retiredLeases = retiredLeases.filter { $0.value > now }
            func identity() throws -> (String, Double) {
                let value = try JSONValue.decode(request.body), id = value["lease"].string
                guard case .object = value, Set(value.object.keys) == ["lease", "deadline"], UUID(uuidString: id)?.uuidString == id,
                      case .number(let deadline) = value["deadline"], deadline.isFinite, deadline > 0, deadline <= now + 10 else { throw NativeFailure("Invalid routing admission lease") }
                return (id, deadline)
            }
            var acquired: String?
            if operation == "drain" {
                let (requested, deadline) = try identity()
                guard deadline > now, now >= acquisitionsBlockedUntil, retiredLeases[requested] == nil, retiredLeases.count < 4096 else { return try .error(409, "Routing admission acquisition expired or was retired") }
                guard lease == nil || (lease == requested && leaseDeadline == deadline) else { return try .error(409, "Another routing operation owns admission") }
                acquired = requested; lease = requested; leaseDeadline = deadline
            } else if operation == "resume" {
                let (requested, deadline) = try identity()
                if deadline > now {
                    if retiredLeases[requested] != nil || retiredLeases.count < 4096 {
                        retiredLeases[requested] = max(retiredLeases[requested] ?? 0, deadline)
                    } else {
                        // Saturation must not make a cancelled, unrecorded
                        // acquisition valid once an older ledger entry expires.
                        acquisitionsBlockedUntil = max(acquisitionsBlockedUntil, deadline)
                    }
                }
                // Retire A even while B owns admission. Refusing to release B
                // must not leave a delayed acquire(A) valid after B finishes.
                guard lease == nil || (lease == requested && leaseDeadline == deadline) else { return try .error(409, "Routing admission lease does not match") }
                // Remember release until acquisition expiry, including release
                // arriving BEFORE a delayed acquisition on another connection.
                self.lease = nil; leaseDeadline = nil
            } else if operation != "status" { return try .error(404, "Unknown control operation") }
            var value: JSONValue = ["service": "uniapi-shim", "runtime": "swift", "nativeVersion": 1,
                                    "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)), "instance": .string(NativeHealth.instance),
                                    "accepting": .bool(lease == nil), "activeRequests": .number(Double(count))]
            if let acquired { value["lease"] = .string(acquired) }
            return try .json(200, value)
        }
    }
}
private final class ShimRequestLifetime: @unchecked Sendable {
    private let lock = NSLock(), ended: @Sendable () -> Void
    private var owners = 1
    init(_ ended: @escaping @Sendable () -> Void) { self.ended = ended }
    func retain() { lock.withLock { precondition(owners > 0); owners += 1 } }
    func release() { if lock.withLock({ owners -= 1; return owners == 0 }) { ended() } }
}
final class ShimRequestTicket: @unchecked Sendable {
    private let lock = NSLock(), lifetime: ShimRequestLifetime
    private var finished = false
    fileprivate init(_ lifetime: ShimRequestLifetime) { self.lifetime = lifetime }
    func fork() -> ShimRequestTicket { lifetime.retain(); return ShimRequestTicket(lifetime) }
    func finish() { if lock.withLock({ guard !finished else { return false }; finished = true; return true }) { lifetime.release() } }
    deinit { finish() }
}

public enum ShimSecurity {
    public static let maximumBody = 64 * 1024 * 1024
    public static func guardHeaders(version: String, headers: [String: String], peer: String) throws {
        guard ["127.0.0.1", "::1", "[::1]"].contains(peer) else { throw NativeFailure("Non-loopback peer") }
        let host = (headers["host"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if host.isEmpty { guard version == "HTTP/1.0" else { throw NativeFailure("A local Host is required") } }
        else {
            let name: String
            if host.hasPrefix("[") { guard let end = host.firstIndex(of: "]") else { throw NativeFailure("Host not allowed") }; name = String(host[...end]); let rest = String(host[host.index(after: end)...]); guard rest.isEmpty || rest.range(of: "^:[0-9]{1,5}$", options: .regularExpression) != nil else { throw NativeFailure("Host not allowed") } }
            else { let parts = host.split(separator: ":", omittingEmptySubsequences: false); guard parts.count <= 2, parts.count == 1 || parts[1].allSatisfy(\.isNumber) && !parts[1].isEmpty else { throw NativeFailure("Host not allowed") }; name = String(parts[0]) }
            guard ["127.0.0.1", "localhost", "[::1]"].contains(name) else { throw NativeFailure("Host not allowed") }
        }
        if let origin = headers["origin"] {
            guard let url = URL(string: origin), ["http", "https"].contains(url.scheme ?? ""), ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? "") else { throw NativeFailure("Origin not allowed") }
        }
    }
    public static func guardRequest(_ request: ShimClientRequest, provider: NativeProviderInfo? = nil, requireKey: Bool = false) throws {
        try guardHeaders(version: request.version, headers: request.headers, peer: request.peer)
        guard request.headers["transfer-encoding"] == nil else { throw NativeFailure("Chunked request bodies are unsupported") }
        if let length = request.headers["content-length"] { guard length.range(of: "^[0-9]+$", options: .regularExpression) != nil, let count = Int(length), count == request.body.count, count <= maximumBody else { throw NativeFailure("Invalid Content-Length") } }
        guard request.body.count <= maximumBody else { throw NativeFailure("Request body is too large") }
        if requireKey, let provider, !provider.key.isEmpty {
            let authorization = request.headers["authorization"] ?? ""
            let supplied = request.headers["x-api-key"] ?? (authorization.lowercased().hasPrefix("bearer ") ? String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces) : "")
            let a = Array(supplied.utf8), b = Array(provider.key.utf8); var difference = a.count ^ b.count
            for index in 0..<max(a.count, b.count) { difference |= Int(index < a.count ? a[index] : 0) ^ Int(index < b.count ? b[index] : 0) }
            guard difference == 0 else { throw NativeFailure("Invalid client key") }
        }
    }
}

/// The standalone listener and fixtures both enter through this handler.
/// Provider edits are read for each request; no credential-bearing route cache.
public actor NativeShimGateway {
    public let providers: NativeProviderStore
    private let dependencies: ShimDependencies
    private let nativeCodex: NativeCodexRouter?
    private nonisolated let activity = ShimRequestActivity()
    public init(providers: NativeProviderStore, dependencies: ShimDependencies = .init(), paths: NativePaths? = nil) {
        self.providers = providers; self.dependencies = dependencies
        nativeCodex = paths.map { NativeCodexRouter(paths: $0, providers: providers, dependencies: dependencies) }
    }
    public nonisolated var activeRequests: Int { activity.active }
    nonisolated func configureNativeControl(token: String) { activity.configure(token: token) }
    private nonisolated func counted(_ request: ShimClientRequest) -> Bool {
        let route = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        return !(request.method == "GET" && ["/health", "/healthz"].contains(route)) && !route.hasPrefix("/_uniapi/codex/control/")
    }
    nonisolated func beginRequest(_ request: ShimClientRequest) -> ShimRequestTicket? {
        counted(request) ? activity.begin() : nil
    }
    public func handle(_ request: ShimClientRequest) async throws -> ShimClientResponse { try await handle(request, ticket: beginRequest(request)) }
    func handle(_ request: ShimClientRequest, ticket: ShimRequestTicket?) async throws -> ShimClientResponse {
        defer { ticket?.finish() }
        if counted(request), ticket == nil { return try .error(503, "Codex routing is being updated; retry when admission resumes") }
        let response = try await route(request, ticket: ticket)
        guard let client = ticket?.fork() else { return response }
        var countedResponse = ShimClientResponse(status: response.status, headers: response.headers, chunks: response.chunks,
                     cancel: { response.cancel(); client.finish() }, waitForCompletion: response.waitForCompletion)
        countedResponse.codexStreamTiming = response.codexStreamTiming
        return countedResponse
    }
    private func route(_ request: ShimClientRequest, ticket: ShimRequestTicket?, trackCodexReasoning: Bool = false) async throws -> ShimClientResponse {
        do { try ShimSecurity.guardRequest(request) }
        catch {
            let message = error.localizedDescription
            let status = request.body.count > ShimSecurity.maximumBody || (Int(request.headers["content-length"] ?? "") ?? 0) > ShimSecurity.maximumBody ? 413 : message.contains("Content-Length") || message.contains("Chunked") ? 400 : 403
            return try .error(status, message)
        }
        let route = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
        if route.hasPrefix("/_uniapi/codex/control/") {
            return try activity.control(request, operation: String(route.dropFirst("/_uniapi/codex/control/".count)))
        }
        if let nativeCodex, NativeCodexRouter.matches(request.path) {
            return try await nativeCodex.handle(request, ticket: ticket) { request in try await self.route(request, ticket: ticket, trackCodexReasoning: true) }
        }
        let document = try providers.document()
        let allRows = document["providers"]!.array.map(NativeProviderInfo.init), rows = allRows.filter(\.enabled)
        if request.method == "GET" && ["/health", "/healthz"].contains(route) { return try .json(200, ["ok": true, "service": "uniapi-shim", "runtime": "swift", "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)), "instance": .string(NativeHealth.instance), "activeRequests": .number(Double(activeRequests)), "providers": .array(rows.map { .string($0.id) }.sorted { $0.string < $1.string }), "codexNativeVersion": nativeCodex == nil ? .null : 1]) }
        let parts = route.split(separator: "/").map(String.init)
        guard let encoded = parts.first, let id = encoded.removingPercentEncoding,
              let provider = allRows.first(where: { $0.id == id }) ?? rows.first(where: { $0.raw["proxy"]["aliases"].array.contains(.string(id)) }),
              provider.enabled else { return try .error(404, "Unknown provider") }
        do { try ShimSecurity.guardRequest(request, provider: provider, requireKey: document["requireClientKey"]?.bool == true) }
        catch { return try .error(401, error.localizedDescription) }
        let path = "/" + parts.dropFirst().joined(separator: "/")
        if request.method == "GET" && ["/models", "/v1/models"].contains(path) {
            let operations = NativeProviderOperations(store: providers, dependencies: dependencies)
            do { let catalog = try await operations.discover(base: provider.direct.isEmpty ? provider.base : provider.direct, key: provider.key); return try .json(200, ["object": "list", "data": .array(catalog["ids"].array.map { ["id": $0, "object": "model"] })]) }
            catch is CancellationError { throw CancellationError() }
            catch { return try .error(502, "Model discovery failed") }
        }
        guard request.method == "POST" else { return try .error(405, "Method not allowed") }
        guard let decoded = try? JSONValue.decode(request.body), case .object = decoded else { return try .error(400, "Expected a JSON object") }
        var body = decoded
        if ["/messages/count_tokens", "/v1/messages/count_tokens"].contains(path) {
            let characters = ShimTranslation.text(body["system"]).unicodeScalars.count + body["messages"].array.reduce(0) { $0 + ShimTranslation.text($1["content"]).unicodeScalars.count }
            return try .json(200, ["input_tokens": .number(Double(max(1, characters / 4)))])
        }
        let responses = ["/responses", "/v1/responses"].contains(path)
        guard responses || ["/messages", "/v1/messages"].contains(path) else { return try .error(404, "Route not found") }
        if responses { guard !ShimTranslation.inputItems(body).filter({ $0["type"] != "reasoning" }).isEmpty, !(body["input"].array.isEmpty && body["input"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return try .error(400, "Input must contain a message") } }
        else { guard !body["messages"].array.isEmpty else { return try .error(400, "Messages must be a nonempty array") } }
        let model = ShimTranslation.effectiveModel(body["model"].string, fallback: provider.model, format: provider.format), stream = body["stream"].bool
        let toolMap: ShimToolMap
        do { toolMap = try ShimToolMap(responses ? body : [:]); if responses { body = try ShimTranslation.responsesToAnthropic(body, model: model, tools: toolMap) } }
        catch { return try .error(400, error.localizedDescription) }
        if responses && body["messages"].array.isEmpty { return try .error(400, "Input has no translatable conversation") }
        let defaultCap = body["_uniapi_default_max_tokens"].bool; body = .object(body.object.filter { $0.key != "_uniapi_default_max_tokens" }); body["model"] = .string(model)
        if !responses && request.body.count <= 32768 && (ShimTranslation.text(body["system"]).contains("insufficient evidence in transcript") || body["messages"].array.contains { ShimTranslation.text($0["content"]).contains("insufficient evidence in transcript") }) {
            body["thinking"] = ["type": "disabled"]; if body["max_tokens"].int < 2048 { body["max_tokens"] = 2048 }
        }
        var payload: JSONValue
        if provider.format == "anthropic" { payload = body } else { payload = try ShimTranslation.anthropicToOpenAI(body, model: model) }
        do { try NativeProviderReasoning.apply(request: decoded, responses: responses, provider: provider, model: model, payload: &payload) }
        catch { return try .error(400, error.localizedDescription) }
        if defaultCap && provider.format != "anthropic" { payload = .object(payload.object.filter { $0.key != "max_tokens" }) }
        let upstreamPath = provider.format == "anthropic" ? "/v1/messages" : "/v1/chat/completions"
        var headers = ["Content-Type": "application/json", "User-Agent": "Mozilla/5.0 uniapi-native", "Authorization": "Bearer " + provider.key, "Accept": stream ? "text/event-stream" : "*/*"]
        if provider.format == "anthropic" { headers["x-api-key"] = provider.key; headers["anthropic-version"] = "2023-06-01" }
        let upstreamRequest = ShimHTTPRequest(url: try NativeProviderOperations.endpoint(provider.direct.isEmpty ? provider.base : provider.direct, upstreamPath), headers: headers, body: try payload.encoded())
        let upstream: ShimUpstream
        do { upstream = try await openRetrying(upstreamRequest) }
        catch is CancellationError { throw CancellationError() }
        catch { return try .error(502, "Upstream was unavailable") }
        if upstream.status != 200 {
            let bytes = try await upstream.body(), value = (try? JSONValue.decode(bytes)) ?? .null
            if provider.format == "anthropic" { return .bytes(upstream.status, bytes) }
            let message = value["error"]["message"].string.isEmpty ? value["message"].string.isEmpty ? String(String(decoding: bytes, as: UTF8.self).prefix(300)) : value["message"].string : value["error"]["message"].string
            return try .error(upstream.status, message.replacingOccurrences(of: provider.key, with: provider.key.isEmpty ? "" : "<redacted>"))
        }
        if !stream {
            let bytes = try await upstream.body()
            if !responses && provider.format == "anthropic" { return .bytes(200, bytes) }
            guard let value = try? JSONValue.decode(bytes) else { return try .error(502, "Upstream returned invalid JSON") }
            let message = provider.format == "anthropic" ? value : try ShimTranslation.openAIToAnthropic(value, model: model)
            return try .json(200, responses ? ShimResponsesStream.nonstream(message, model: model, tools: toolMap) : message)
        }
        return streamResponse(upstream, model: model, format: provider.format, responses: responses, tools: toolMap, ticket: ticket, trackCodexReasoning: trackCodexReasoning)
    }
    private func openRetrying(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let upstream: ShimUpstream
            do { upstream = try await dependencies.transport.open(request) }
            catch is CancellationError { throw CancellationError() }
            catch { guard attempt < dependencies.retryBackoff.count else { throw error }; try await dependencies.sleep(dependencies.retryBackoff[attempt]); attempt += 1; continue }
            guard [408, 409, 425, 429, 500, 502, 503, 504, 529].contains(upstream.status) else { return upstream }
            let data = try await upstream.body(), decoded = (try? JSONValue.decode(data)) ?? .null
            let permanent = ["model_not_found": 404, "invalid_api_key": 401, "insufficient_quota": 402, "insufficient_user_quota": 402, "billing_not_active": 402][decoded["error"]["code"].string]
            if let permanent { return .init(status: permanent, headers: upstream.headers, chunks: AsyncThrowingStream { $0.yield(data); $0.finish() }) }
            if attempt >= dependencies.retryBackoff.count { return .init(status: upstream.status, headers: upstream.headers, chunks: AsyncThrowingStream { $0.yield(data); $0.finish() }) }
            let advised = Double(upstream.headers["retry-after"] ?? ""), delay = advised.flatMap { $0.isFinite && $0 > 0 && $0 <= 30 ? $0 : nil } ?? dependencies.retryBackoff[attempt]
            try await dependencies.sleep(delay); attempt += 1
        }
    }
    private func streamResponse(_ upstream: ShimUpstream, model: String, format: String, responses: Bool, tools: ShimToolMap, ticket: ShimRequestTicket?, trackCodexReasoning: Bool) -> ShimClientResponse {
        let control = ShimStreamControl(), dependencies = dependencies
        let reasoning = trackCodexReasoning && responses && format == "openai" ? NativeCodexReasoningCounter() : nil
        let producer = ticket?.fork()
        let output = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let writer = ShimStreamWriter(continuation: continuation, model: model, format: format, responses: responses, tools: tools, now: dependencies.now(), reasoning: reasoning)
            let task = Task {
                let heartbeat = Task {
                    guard dependencies.heartbeatSeconds.isFinite && dependencies.heartbeatSeconds > 0 else { return }
                    while !Task.isCancelled { do { try await Task.sleep(nanoseconds: UInt64(min(600, dependencies.heartbeatSeconds) * 1_000_000_000)); try await writer.heartbeat(now: dependencies.now()) } catch { return } }
                }
                do {
                    var parser = ShimSSEParser()
                    for try await chunk in upstream.chunks {
                        try Task.checkCancellation()
                        if !responses && format == "anthropic" { try await writer.feedNative(chunk, now: dependencies.now()) }
                        else { for frame in try parser.feed(chunk) { try await writer.feed(frame, now: dependencies.now()) } }
                    }
                    if !responses && format == "anthropic" { try await writer.feedNative(Data(), now: dependencies.now(), final: true) }
                    else { for frame in try parser.feed(Data(), final: true) { try await writer.feed(frame, now: dependencies.now()) } }
                    try await writer.finish(error: nil)
                } catch is CancellationError { await writer.cancel() }
                catch { do { try await writer.finish(error: "Upstream stream failed; reply truncated") } catch { await writer.cancel() } }
                heartbeat.cancel(); upstream.cancel()
                await heartbeat.value
                await upstream.waitForCompletion()
                producer?.finish()
            }
            control.install(task, cancel: upstream.cancel)
            continuation.onTermination = { reason in if case .cancelled = reason { control.cancel() } }
        }
        var response = ShimClientResponse(status: 200, headers: ["content-type": "text/event-stream", "cache-control": "no-cache", "connection": "close"], chunks: output, cancel: { control.cancel() }, waitForCompletion: { await control.wait() })
        response.codexProviderReasoning = reasoning
        return response
    }
}

private final class ShimStreamControl: @unchecked Sendable {
    private let lock = NSLock(); private var task: Task<Void, Never>?, abort: (@Sendable () -> Void)?, cancelled = false
    func install(_ task: Task<Void, Never>, cancel: @escaping @Sendable () -> Void) { lock.lock(); self.task = task; abort = cancel; let stopped = cancelled; lock.unlock(); if stopped { task.cancel(); cancel() } }
    func cancel() { lock.lock(); cancelled = true; let task = task, abort = abort; lock.unlock(); task?.cancel(); abort?() }
    func wait() async { let task = lock.withLock { task }; await task?.value }
}

private actor ShimStreamWriter {
    let continuation: AsyncThrowingStream<Data, Error>.Continuation, format: String, responses: Bool, began: Date
    let reasoning: NativeCodexReasoningCounter?
    var response: ShimResponsesStream, anthropic: ShimAnthropicStream, relay = ShimRelayState(), held: [ShimSSEFrame] = [], raw = Data(), heldNative = Data(), holding = true, finished = false, sawDone = false, upstreamError = false, byteCount = 0
    init(continuation: AsyncThrowingStream<Data, Error>.Continuation, model: String, format: String, responses: Bool, tools: ShimToolMap, now: Date, reasoning: NativeCodexReasoningCounter?) {
        self.continuation = continuation; self.format = format; self.responses = responses; began = now; self.reasoning = reasoning; response = .init(model: model, tools: tools, now: now); anthropic = .init(model: model)
        // Silent upstreams still need a valid envelope before the first ping.
        // Native Anthropic passthrough waits for its own message identity.
        if responses { held = response.start() } else if format != "anthropic" { held = anthropic.start() }
    }
    func write(_ frames: [ShimSSEFrame]) throws {
        for frame in frames { try writeBytes(frame.encoded()) }
    }
    func writeBytes(_ bytes: Data) throws { guard !bytes.isEmpty else { return }; byteCount += bytes.count; guard byteCount <= 64 * 1024 * 1024 else { throw NativeFailure("Translated stream exceeded its bound") }; if case .dropped = continuation.yield(bytes) { throw NativeFailure("Client stream exceeded its bounded buffer") } }
    func release() throws { if holding { holding = false; let frames = held, bytes = heldNative; held.removeAll(); heldNative.removeAll(); try write(frames); try writeBytes(bytes) } }
    func feedNative(_ chunk: Data, now: Date, final: Bool = false) throws {
        raw.append(chunk); guard raw.count <= 8 * 1024 * 1024 else { throw NativeFailure("Native SSE frame exceeded its bound") }
        while true {
            let lf = raw.range(of: Data("\n\n".utf8)), crlf = raw.range(of: Data("\r\n\r\n".utf8))
            let boundary = [lf, crlf].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
            guard let boundary else { break }
            let event = Data(raw[..<boundary.upperBound]); raw = Data(raw[boundary.upperBound...])
            var parser = ShimSSEParser(); let frames = try parser.feed(event, final: true)
            if !relay.started && frames.contains(where: { $0.data["type"] == "ping" }) { continue }
            for frame in frames { relay.observe(frame.data); if frame.data["type"] == "error" { upstreamError = true } }
            if holding { heldNative.append(event); guard heldNative.count <= 8 * 1024 * 1024 else { throw NativeFailure("Native SSE opening buffer exceeded its bound") } }
            else { try writeBytes(event) }
            if relay.started && (relay.contentCount > 0 || relay.sawTool || now.timeIntervalSince(began) >= 5) { try release() }
        }
        if final && !raw.isEmpty {
            var parser = ShimSSEParser(); for frame in try parser.feed(raw, final: true) { relay.observe(frame.data) }
            if holding { heldNative.append(raw) } else { try writeBytes(raw) }
            // Seal an interrupted partial event before the repair frames.
            if holding { heldNative.append(Data("\n\n".utf8)) } else { try writeBytes(Data("\n\n".utf8)) }; raw.removeAll()
        }
    }
    func feed(_ frame: ShimSSEFrame, now: Date) throws {
        guard !finished else { return }; if frame.event == "done" { sawDone = true; return }
        reasoning?.observe(frame.data["usage"])
        if !frame.data["error"].isNull || frame.data["type"] == "error" { upstreamError = true }
        var frames: [ShimSSEFrame]
        if responses { frames = format == "anthropic" ? response.feedAnthropic(frame.data) : response.feedOpenAI(frame.data) }
        else if format == "anthropic" { if frame.data["type"] == "ping" && !relay.started { return }; relay.observe(frame.data); frames = [frame] }
        else { frames = anthropic.feed(frame.data) }
        if holding { held += frames } else { try write(frames) }
        let real = responses ? response.contentCount > 0 || response.sawTool : format == "anthropic" ? relay.contentCount > 0 || relay.sawTool : anthropic.contentCount > 0 || anthropic.sawTool
        if real || now.timeIntervalSince(began) >= 5 || held.count >= 512 { try release() }
    }
    func heartbeat(now: Date) throws {
        guard !finished else { return }; if now.timeIntervalSince(began) >= 5 && (responses || format != "anthropic" || relay.started) { try release() }; guard !holding else { return }
        if responses { try write(response.heartbeat()) }
        else if format == "anthropic" { if relay.started && !relay.done { try write([.init("ping", ["type": "ping"])]) } }
        else { try write(anthropic.heartbeat()) }
    }
    func finish(error: String?) throws {
        guard !finished else { return }; try release()
        if responses { let truncated = error ?? (upstreamError ? "Upstream reported an error; reply truncated" : !sawDone && response.stopReason == nil ? "Upstream ended without a finish reason; reply truncated" : nil); try write(response.finish(truncated: truncated)) }
        else if format == "anthropic" {
            if !relay.started { try write([.init("error", ["type": "error", "error": ["type": "api_error", "message": "Upstream stream had no message envelope"]])]) }
            else if !relay.done { try write(relay.finish(note: error ?? "Upstream ended without message_stop; reply truncated")) }
        }
        else { let truncated = error ?? (upstreamError ? "Upstream reported an error; reply truncated" : !sawDone && anthropic.stopReason == nil ? "Upstream ended without a finish reason; reply truncated" : nil); try write(anthropic.finish(truncated: truncated)) }
        finished = true; continuation.finish()
    }
    func cancel() { finished = true; continuation.finish(throwing: CancellationError()) }
}

/// Repairs native passthrough closure without reinterpreting successful bytes.
private struct ShimRelayState: Sendable {
    var started = false, done = false, contentCount = 0, sawTool = false, maximum = -1, open: [Int: String] = [:], signatures = Set<Int>(), outputTokens = 0
    mutating func observe(_ value: JSONValue) {
        switch value["type"].string {
        case "message_start": started = true
        case "message_stop": done = true
        case "content_block_start": let index = value["index"].int; maximum = max(maximum, index); open[index] = value["content_block"]["type"].string; if open[index] == "tool_use" { sawTool = true }; contentCount += value["content_block"]["text"].string.count
        case "content_block_stop": open.removeValue(forKey: value["index"].int)
        case "content_block_delta": contentCount += value["delta"]["text"].string.count; if value["delta"]["type"] == "signature_delta" { signatures.insert(value["index"].int) }
        case "message_delta": outputTokens = value["usage"]["output_tokens"].int
        default: break
        }
    }
    mutating func finish(note: String) -> [ShimSSEFrame] {
        guard started && !done else { return [] }; var frames: [ShimSSEFrame] = []
        for index in open.keys.sorted() { if open[index] == "thinking" && !signatures.contains(index) { frames.append(.init("content_block_delta", ["type": "content_block_delta", "index": .number(Double(index)), "delta": ["type": "signature_delta", "signature": ""]])) }; frames.append(.init("content_block_stop", ["type": "content_block_stop", "index": .number(Double(index))])) }
        maximum += 1
        frames.append(.init("content_block_start", ["type": "content_block_start", "index": .number(Double(maximum)), "content_block": ["type": "text", "text": ""]]))
        frames.append(.init("content_block_delta", ["type": "content_block_delta", "index": .number(Double(maximum)), "delta": ["type": "text_delta", "text": .string("\n\n[uniapi-shim: " + note + "]")]]))
        frames.append(.init("content_block_stop", ["type": "content_block_stop", "index": .number(Double(maximum))]))
        frames.append(.init("message_delta", ["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": .null], "usage": ["output_tokens": .number(Double(outputTokens))]])); frames.append(.init("message_stop", ["type": "message_stop"])); done = true; return frames
    }
}
