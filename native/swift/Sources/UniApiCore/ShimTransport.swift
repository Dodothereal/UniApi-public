import Foundation

public struct ShimHTTPRequest: Sendable {
    public var url: URL, method: String, headers: [String: String], body: Data?, timeout: Double
    /// Bypass system HTTP, HTTPS, SOCKS and automatic proxy settings for this request.
    public var bypassSystemProxy: Bool
    public init(url: URL, method: String = "POST", headers: [String: String] = [:], body: Data? = nil, timeout: Double = 600, bypassSystemProxy: Bool = false) {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.timeout = timeout; self.bypassSystemProxy = bypassSystemProxy
    }
}
public struct ShimUpstream: Sendable {
    public let status: Int, headers: [String: String], chunks: AsyncThrowingStream<Data, Error>
    public let cancel: @Sendable () -> Void
    public let waitForCompletion: @Sendable () async -> Void
    public init(status: Int, headers: [String: String] = [:], chunks: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void = {}, waitForCompletion: @escaping @Sendable () async -> Void = {}) { self.status = status; self.headers = headers; self.chunks = chunks; self.cancel = cancel; self.waitForCompletion = waitForCompletion }
    public func body(limit: Int = 64 * 1024 * 1024) async throws -> Data {
        do {
        let result = try await withTaskCancellationHandler(operation: {
            defer { cancel() }; try Task.checkCancellation(); var body = Data()
            for try await chunk in chunks { try Task.checkCancellation(); guard body.count + chunk.count <= limit else { throw NativeFailure("Upstream response exceeded its bound") }; body.append(chunk) }
            // Async streams may end quietly when their consumer is cancelled.
            // End-of-stream alone must not turn cancellation into empty success.
            try Task.checkCancellation(); return body
        }, onCancel: { cancel() })
        await waitForCompletion(); try Task.checkCancellation(); return result
        } catch { cancel(); await waitForCompletion(); throw error }
    }
}
public protocol ShimTransport: Sendable { func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream }

/// Ephemeral native HTTP. No cookie jar, credential storage, cache, redirects,
/// or shared session lets a private loopback capability escape to another host.
public struct ShimURLSessionTransport: ShimTransport {
    public init() {}
    static func configuration(for request: ShimHTTPRequest) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = request.timeout; config.timeoutIntervalForResource = request.timeout
        if request.bypassSystemProxy || ["127.0.0.1", "localhost", "::1", "[::1]"].contains(request.url.host ?? "") {
            // Automatic proxy selection must not route a direct request through a proxy either.
            config.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                                "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        }
        return config
    }
    public func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        guard ["http", "https"].contains(request.url.scheme ?? ""), request.url.host != nil, request.url.user == nil, request.url.password == nil, request.timeout.isFinite && request.timeout > 0 else { throw NativeFailure("Invalid upstream endpoint") }
        let exchange = ShimURLSessionExchange()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            do {
                let upstream = try await withCheckedThrowingContinuation { continuation in exchange.start(request, response: continuation) }
                try Task.checkCancellation(); return upstream
            }
            catch { exchange.cancel(); await exchange.waitForCompletion(); throw error }
        }, onCancel: { exchange.cancel() })
    }
}

private final class ShimTransportCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false, waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { await withCheckedContinuation { continuation in let ready = lock.withLock { if finished { return true }; waiters.append(continuation); return false }; if ready { continuation.resume() } } }
    func finish() { let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in guard !finished else { return [] }; finished = true; let result = waiters; waiters.removeAll(); return result }; pending.forEach { $0.resume() } }
}

private final class ShimURLSessionExchange: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let completion = ShimTransportCompletion()
    private var response: CheckedContinuation<ShimUpstream, Error>?, session: URLSession?, task: URLSessionDataTask?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation!, stream: AsyncThrowingStream<Data, Error>!
    private var cancelled = false, started = false, bytes = 0
    func waitForCompletion() async { await completion.wait() }
    func start(_ request: ShimHTTPRequest, response: CheckedContinuation<ShimUpstream, Error>) {
        let config = ShimURLSessionTransport.configuration(for: request)
        var urlRequest = URLRequest(url: request.url); urlRequest.httpMethod = request.method; urlRequest.httpBody = request.body
        for (key, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: key) }
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        lock.lock()
        if cancelled { lock.unlock(); response.resume(throwing: CancellationError()); completion.finish(); return }
        self.response = response
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(512)) { self.continuation = $0 }
        continuation.onTermination = { [weak self] termination in if case .cancelled = termination { self?.cancel() } }
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue); self.session = session; started = true
        let task = session.dataTask(with: urlRequest); self.task = task; lock.unlock(); task.resume()
    }
    func cancel() {
        lock.lock(); cancelled = true; let pending = response; response = nil; let task = task, session = session, stream = continuation, began = started; lock.unlock()
        pending?.resume(throwing: CancellationError()); stream?.finish(throwing: CancellationError()); task?.cancel(); session?.invalidateAndCancel()
        if !began { completion.finish() }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        lock.lock(); let pending = self.response; self.response = nil; let cancelled = cancelled, chunks = stream!; lock.unlock()
        guard !cancelled else { completionHandler(.cancel); pending?.resume(throwing: CancellationError()); return }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key).lowercased()] = String(describing: $1.value) }
        pending?.resume(returning: ShimUpstream(status: http.statusCode, headers: headers, chunks: chunks, cancel: { self.cancel() }, waitForCompletion: { await self.waitForCompletion() })); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); bytes += data.count; let oversized = bytes > 64 * 1024 * 1024, stream = continuation!; lock.unlock()
        if oversized { stream.finish(throwing: NativeFailure("Upstream response exceeded its bound")); dataTask.cancel(); return }
        if case .dropped = stream.yield(data) { stream.finish(throwing: NativeFailure("Upstream output exceeded its bounded buffer; no frames were silently dropped")); dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let pending = response; response = nil; let stream = continuation, cancelled = cancelled; self.session = nil; self.task = nil; lock.unlock()
        if let error { pending?.resume(throwing: error); stream?.finish(throwing: error) }
        else if cancelled { pending?.resume(throwing: CancellationError()); stream?.finish(throwing: CancellationError()) }
        else { pending?.resume(throwing: NativeFailure("Upstream sent no HTTP response")); stream?.finish() }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) { completion.finish() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct ShimDependencies: Sendable {
    public var transport: any ShimTransport
    public var sleep: @Sendable (Double) async throws -> Void
    public var now: @Sendable () -> Date
    public var retryBackoff: [Double]
    public var heartbeatSeconds: Double
    public init(transport: any ShimTransport = ShimURLSessionTransport(), sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, min(600, seconds)) * 1_000_000_000)) }, now: @escaping @Sendable () -> Date = { Date() }, retryBackoff: [Double] = [1.5, 4], heartbeatSeconds: Double = 10) { self.transport = transport; self.sleep = sleep; self.now = now; self.retryBackoff = retryBackoff; self.heartbeatSeconds = heartbeatSeconds }
}
