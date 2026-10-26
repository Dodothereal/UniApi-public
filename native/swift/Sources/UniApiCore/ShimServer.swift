import Foundation
import Network

/// Strict single-request HTTP framing; the connection closes after its reply.
/// Parsing is independently fixture-testable without binding a socket.
public struct ShimHTTPDecoder: Sendable {
    private var bytes = Data(), headerEnd: Int?, length = 0, method = "", path = "", version = "", headers: [String: String] = [:]
    public init() {}
    public mutating func feed(_ input: Data, peer: String = "127.0.0.1") throws -> ShimClientRequest? {
        bytes.append(input)
        if headerEnd == nil {
            guard let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) else { guard bytes.count <= 65536 else { throw NativeFailure("HTTP headers are too large") }; return nil }
            guard boundary.lowerBound <= 65536, let text = String(data: bytes[..<boundary.lowerBound], encoding: .utf8) else { throw NativeFailure("Invalid HTTP headers") }
            let lines = text.components(separatedBy: "\r\n"), first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
            guard first.count == 3, ["GET", "POST"].contains(String(first[0])), first[1].hasPrefix("/"), ["HTTP/1.0", "HTTP/1.1"].contains(String(first[2])) else { throw NativeFailure("Invalid HTTP request line") }
            method = String(first[0]); path = String(first[1]); version = String(first[2])
            for line in lines.dropFirst() {
                guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw NativeFailure("Invalid HTTP header") }
                let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, key.range(of: "^[a-z0-9!#$%&'*+.^_`|~-]+$", options: .regularExpression) != nil, headers[key] == nil, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw NativeFailure("Duplicate or invalid HTTP header") }
                headers[key] = value
            }
            try ShimSecurity.guardHeaders(version: version, headers: headers, peer: peer)
            guard headers["transfer-encoding"] == nil else { throw NativeFailure("Transfer-Encoding is unsupported") }
            if let raw = headers["content-length"] { guard raw.range(of: "^[0-9]+$", options: .regularExpression) != nil, let count = Int(raw), count <= ShimSecurity.maximumBody else { throw NativeFailure("Invalid or oversized Content-Length") }; length = count }
            headerEnd = boundary.upperBound
        }
        let end = headerEnd! + length
        guard bytes.count <= end else { throw NativeFailure("Pipelined or excessive request bytes are unsupported") }
        if bytes.count < end { return nil }
        return ShimClientRequest(method: method, path: path, version: version, headers: headers, body: Data(bytes[headerEnd!..<end]), peer: peer)
    }
}

/// No initializer binds a port. Only explicit start() opens the loopback
/// listener. shutdown() waits for owned request tasks after cancellation.
public final class NativeShimServer: @unchecked Sendable {
    public let port: Int
    private let paths: NativePaths
    private let gateway: NativeShimGateway, queue = DispatchQueue(label: "uniapi.native-shim"), lock = NSLock(), readTimeout: Double
    private var listener: NWListener?, listenerClosed: ShimListenerReady?, clients: [UUID: ShimSocket] = [:]
    private var generation: UUID?
    private var draining: Task<Void, Never>?
    public init(paths: NativePaths, port: Int = 8823, dependencies: ShimDependencies = .init(), readTimeout: Double = 120) throws {
        guard port == 0 || (1024...65535).contains(port), readTimeout.isFinite && readTimeout > 0 else { throw NativeFailure("Use an unprivileged shim port and positive read deadline") }
        self.paths = paths; self.port = port; self.readTimeout = readTimeout; gateway = NativeShimGateway(providers: NativeProviderStore(paths: paths), dependencies: dependencies, paths: paths)
    }
    public func start() async throws {
        let attempt = UUID()
        guard lock.withLock({ () -> Bool in guard generation == nil, draining == nil else { return false }; generation = attempt; return true }) else { throw NativeFailure("The native shim listener is already starting, active or draining") }
        var owned: NWListener?
        do {
        gateway.configureNativeControl(token: try NativeCodexControlSecret.load(paths, create: true))
        _ = try NativeCodexRoutingSecret.load(paths, create: true)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters)
        owned = listener
        let closed = ShimListenerReady()
        guard lock.withLock({ () -> Bool in guard generation == attempt else { return false }; self.listener = listener; listenerClosed = closed; return true }) else { throw CancellationError() }
        let readiness = ShimListenerReady()
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let id = UUID()
            let socket = ShimSocket(connection: connection, gateway: self.gateway, queue: self.queue, readTimeout: self.readTimeout, ended: { [weak self] in _ = self?.lock.withLock { self?.clients.removeValue(forKey: id) } })
            let accepted = self.lock.withLock { () -> Bool in guard self.generation == attempt, self.clients.count < 128 else { return false }; self.clients[id] = socket; return true }
            if accepted { socket.start() } else { connection.cancel() }
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: readiness.finish(nil)
            case .failed(let error): readiness.finish(error); closed.finish(nil); self?.clear(attempt)
            case .cancelled: readiness.finish(CancellationError()); closed.finish(nil); self?.clear(attempt)
            default: break
            }
        }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in readiness.install(continuation); listener.start(queue: queue) }
        }, onCancel: { listener.cancel() })
        guard lock.withLock({ generation == attempt && self.listener === listener }) else { throw CancellationError() }
        } catch { owned?.cancel(); clear(attempt); throw error }
    }
    private func clear(_ attempt: UUID) { lock.withLock { if generation == attempt { listener = nil; listenerClosed = nil; generation = nil } } }
    public var listeningPort: Int? { lock.withLock { listener?.port.map { Int($0.rawValue) } } }
    public func stop() {
        let owned = lock.withLock { () -> (NWListener?, [ShimSocket]) in let result = (listener, Array(clients.values)); listener = nil; listenerClosed = nil; generation = nil; return result }
        owned.0?.cancel(); owned.1.forEach { $0.cancel() }
    }
    public var activeConnections: Int { lock.withLock { clients.count } }
    public var activeRequests: Int { gateway.activeRequests }
    public func shutdown() async {
        let drain = lock.withLock { () -> Task<Void, Never> in
            if let draining { return draining }
            let owned = (listener, Array(clients.values), listenerClosed)
            listener = nil; listenerClosed = nil; generation = nil
            let task = Task {
                owned.0?.cancel()
                // Closing admission and capturing each task are one socket
                // lock operation. A read callback cannot slip past the census.
                let tasks = owned.1.compactMap { $0.cancelAndTask() }
                if let closed = owned.2 { try? await withCheckedThrowingContinuation { closed.install($0) } }
                for task in tasks { await task.value }
                self.lock.withLock { self.draining = nil }
            }
            draining = task; return task
        }
        await drain.value
    }
    deinit { stop() }
}
private final class ShimListenerReady: @unchecked Sendable {
    let lock = NSLock(); var continuation: CheckedContinuation<Void, Error>?, result: Result<Void, Error>?
    func install(_ continuation: CheckedContinuation<Void, Error>) { lock.lock(); if let result { lock.unlock(); continuation.resume(with: result) } else { self.continuation = continuation; lock.unlock() } }
    func finish(_ error: Error?) { lock.lock(); guard result == nil else { lock.unlock(); return }; let value: Result<Void, Error> = error.map(Result.failure) ?? .success(()); result = value; let continuation = continuation; self.continuation = nil; lock.unlock(); continuation?.resume(with: value) }
}
final class ShimSocket: @unchecked Sendable {
    let connection: NWConnection, gateway: NativeShimGateway, queue: DispatchQueue, ended: @Sendable () -> Void
    private let lock = NSLock(); private var task: Task<Void, Never>?, response: ShimClientResponse?, closed = false, endedSent = false, readDeadline: DispatchWorkItem?, readGeneration: UUID?, readStarted = false
    private let readTimeout: Double
    private var decoder = ShimHTTPDecoder()
    init(connection: NWConnection, gateway: NativeShimGateway, queue: DispatchQueue, readTimeout: Double, ended: @escaping @Sendable () -> Void) { self.connection = connection; self.gateway = gateway; self.queue = queue; self.readTimeout = readTimeout; self.ended = ended }
    func start() {
        let generation = UUID()
        let deadline = DispatchWorkItem { [weak self] in guard let self, self.lock.withLock({ self.readGeneration == generation && !self.closed }) else { return }; self.cancel() }
        lock.withLock { readDeadline = deadline; readGeneration = generation }; queue.asyncAfter(deadline: .now() + readTimeout, execute: deadline)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: let begin = self.lock.withLock { () -> Bool in guard !self.readStarted && !self.closed else { return false }; self.readStarted = true; return true }; if begin { self.read() }
            case .failed, .cancelled: self.cancel()
            default: break
            }
        }; connection.start(queue: queue)
    }
    func cancel() {
        _ = cancelAndTask()
    }
    func cancelAndTask() -> Task<Void, Never>? {
        lock.lock(); let task = task; if closed { lock.unlock(); return task }; closed = true; let response = response; readDeadline?.cancel(); readDeadline = nil; readGeneration = nil
        let end = task == nil && !endedSent; if end { endedSent = true }; lock.unlock()
        task?.cancel(); response?.cancel(); connection.cancel(); if end { ended() }
        return task
    }
    func pendingTask() -> Task<Void, Never>? { lock.withLock { task } }
    private func taskFinished() {
        let end = lock.withLock { () -> Bool in task = nil; response = nil; guard !endedSent else { return false }; endedSent = true; return true }
        if end { ended() }
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if error != nil { self.cancel(); return }
            do {
                let peer: String
                if case .hostPort(let host, _) = self.connection.endpoint { peer = String(describing: host) } else { peer = "unknown" }
                if let data, let request = try self.decoder.feed(data, peer: peer) { self.serve(request); return }
                if complete { self.cancel() } else { self.read() }
            } catch {
                let message = error.localizedDescription, status = message.contains("Host") || message.contains("Origin") || message.contains("loopback") ? 403 : message.contains("oversized") ? 413 : 400
                let response = try? ShimClientResponse.error(status, "Invalid HTTP request")
                self.serveResponse(response)
            }
        }
    }
    private func send(_ data: Data, final: Bool = false) async throws {
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(content: data, contentContext: .defaultStream, isComplete: final, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } })
            }
        }, onCancel: { self.connection.cancel() })
    }
    func serve(_ request: ShimClientRequest, observeDisconnect: Bool = true) {
        let ticket = gateway.beginRequest(request)
        lock.lock()
        guard !closed else { lock.unlock(); ticket?.finish(); return }
        readDeadline?.cancel(); readDeadline = nil; readGeneration = nil
        // Install under the lock so cancellation cannot miss a just-created
        // handler or retire the client before its upstream cleanup completes.
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.taskFinished() }
            do { let response = try await gateway.handle(request, ticket: ticket); try await transmit(response) }
            catch { cancel() }
        }
        lock.unlock()
        if observeDisconnect { monitorDisconnect() }
    }
    private func monitorDisconnect() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] data, _, complete, error in
            guard let self else { return }
            if complete || error != nil || data?.isEmpty == false { self.cancel() }
            else if !self.lock.withLock({ self.closed }) { self.monitorDisconnect() }
        }
    }
    private func serveResponse(_ response: ShimClientResponse?) {
        lock.lock(); guard !closed else { lock.unlock(); response?.cancel(); return }; readDeadline?.cancel(); readDeadline = nil; readGeneration = nil
        task = Task { [weak self] in guard let self else { return }; defer { self.taskFinished() }; guard let response else { self.cancel(); return }; do { try await transmit(response) } catch { cancel() } }
        lock.unlock()
    }
    private func transmit(_ response: ShimClientResponse) async throws {
        let stopped = lock.withLock { self.response = response; return closed }
        if stopped { response.cancel(); await response.waitForCompletion(); throw CancellationError() }
        do {
        var header = "HTTP/1.1 \(response.status) Response\r\nServer: uniapi-native-shim\r\nConnection: close\r\n"
        for (key, value) in response.headers.sorted(by: { $0.key < $1.key }) where key != "connection" { header += key + ": " + value + "\r\n" }; header += "\r\n"
        try await send(Data(header.utf8))
        for try await data in response.chunks { try await send(data) }
        try await send(Data(), final: true)
        } catch { response.cancel(); await response.waitForCompletion(); cancel(); throw error }
        response.cancel(); await response.waitForCompletion(); cancel()
    }
}
