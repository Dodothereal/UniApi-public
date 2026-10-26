import XCTest
import Darwin
@testable import UniApiCore

private final class UpdateHealthSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false, waiters: [CheckedContinuation<Void, Never>] = []
    var signalled: Bool { lock.withLock { value } }
    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in value = true; let result = waiters; waiters.removeAll(); return result }
        pending.forEach { $0.resume() }
    }
    func wait() async { await withCheckedContinuation { continuation in let ready = lock.withLock { if value { return true }; waiters.append(continuation); return false }; if ready { continuation.resume() } } }
}
private func updateHealthAwait(_ signal: UpdateHealthSignal) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while !signal.signalled {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFailure("Private health fixture signal deadline") }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
private final class UpdateHealthClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Double = 100
    func read() -> Double { lock.withLock { value } }
    func set(_ value: Double) { lock.withLock { self.value = value } }
}
private final class UpdateHealthTransport: ShimTransport, @unchecked Sendable {
    let opened = UpdateHealthSignal(), cancelled = UpdateHealthSignal(), drained = UpdateHealthSignal()
    private let lock = NSLock()
    private var requests: [ShimHTTPRequest] = [], cancellations = 0
    private let stream: AsyncThrowingStream<Data, Error>, continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let status: Int, headers: [String: String], onOpen: @Sendable () -> Void
    private var watchdog: DispatchWorkItem?
    init(status: Int = 200, headers: [String: String] = [:], bytes: Data = Data("{\"ok\":true}".utf8),
         finish: Bool = true, holdDrain: Bool = false, onOpen: @escaping @Sendable () -> Void = {}) {
        self.status = status; self.headers = headers; self.onOpen = onOpen
        let pair = AsyncThrowingStream<Data, Error>.makeStream(); stream = pair.stream; continuation = pair.continuation
        if !bytes.isEmpty { continuation.yield(bytes) }; if finish { continuation.finish() }
        if !holdDrain { drained.signal() }
        // Regression watchdog only: tests still assert the held boundary before
        // release. A broken cleanup path must not hang the combined gate.
        let fallback = DispatchWorkItem { [weak self] in self?.close() }
        watchdog = fallback; DispatchQueue.global().asyncAfter(deadline: .now() + 6, execute: fallback)
    }
    var captured: [ShimHTTPRequest] { lock.withLock { requests } }
    var cancelCount: Int { lock.withLock { cancellations } }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        lock.withLock { requests.append(request) }; onOpen(); opened.signal()
        return .init(status: status, headers: headers, chunks: stream, cancel: { self.cancel() }, waitForCompletion: { await self.drained.wait() })
    }
    func cancel() { lock.withLock { cancellations += 1 }; continuation.finish(throwing: CancellationError()); cancelled.signal() }
    func close() { watchdog?.cancel(); cancel(); drained.signal() }
}

/// Independent BSD server deliberately sends a complete Content-Length response
/// while withholding its FIN. Only the tested client can cause normal closure.
private final class UpdateHealthOldServer: @unchecked Sendable {
    let port: UInt16, done = UpdateHealthSignal()
    private let lock = NSLock()
    private var listener: Int32, client: Int32 = -1, stopped = false
    private var failure: String?, closure = "", request = Data()
    private let body = Data("{\"ok\":true,\"service\":\"uniapi-shim\"}".utf8)
    var observation: (String?, String, Data) { lock.withLock { (failure, closure, request) } }
    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeFailure("Private health listener allocation") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 1) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { close(fd); throw NativeFailure("Private health listener bind") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0 else { close(fd); throw NativeFailure("Private health listener port") }
        listener = fd; port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global().async { self.run(fd) }
    }
    func stop() { lock.withLock { stopped = true; if listener >= 0 { _ = shutdown(listener, SHUT_RDWR) }; if client >= 0 { _ = shutdown(client, SHUT_RDWR) } } }
    private func run(_ listening: Int32) {
        defer { lock.withLock { if client >= 0 { close(client); client = -1 }; if listener >= 0 { close(listener); listener = -1 } }; done.signal() }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        func wait(_ fd: Int32, _ events: Int16) throws {
            while true {
                guard ProcessInfo.processInfo.systemUptime < deadline, !lock.withLock({ stopped }) else { throw NativeFailure("Private health socket deadline") }
                var p = pollfd(fd: fd, events: events, revents: 0)
                let n = poll(&p, 1, 20)
                if n < 0 && errno == EINTR { continue }
                guard n >= 0, p.revents & Int16(POLLNVAL) == 0 else { throw NativeFailure("Private health socket poll") }
                if n > 0 { return }
            }
        }
        do {
            var accepted: Int32 = -1
            while accepted < 0 {
                try wait(listening, Int16(POLLIN)); accepted = accept(listening, nil, nil)
                if accepted < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard accepted >= 0 else { throw NativeFailure("Private health accept") }
            }
            lock.withLock { client = accepted }
            var noPipe: Int32 = 1
            guard fcntl(accepted, F_SETFL, O_NONBLOCK) == 0, setsockopt(accepted, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw NativeFailure("Private health socket setup") }
            var input = Data(), block = [UInt8](repeating: 0, count: 4096)
            while input.range(of: Data("\r\n\r\n".utf8)) == nil {
                try wait(accepted, Int16(POLLIN)); let n = recv(accepted, &block, block.count, 0)
                if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard n > 0, input.count + n <= 65536 else { throw NativeFailure("Private health request read") }
                input.append(contentsOf: block.prefix(n))
            }
            lock.withLock { request = input }
            let wire = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
            try wire.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try wait(accepted, Int16(POLLOUT)); let n = send(accepted, bytes.baseAddress!.advanced(by: offset), bytes.count-offset, 0)
                    if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                    guard n > 0 else { throw NativeFailure("Private health response send") }; offset += n
                }
            }
            while true {
                try wait(accepted, Int16(POLLIN)); let n = recv(accepted, &block, block.count, 0)
                if n < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                if n == 0 { lock.withLock { closure = "EOF" }; break }
                if n < 0 && errno == ECONNRESET { lock.withLock { closure = "reset" }; break }
                throw NativeFailure("Private health unexpected extra request")
            }
        } catch { lock.withLock { failure = error.localizedDescription } }
    }
}
private struct UpdateHealthPrivatePort: ShimTransport {
    let port: UInt16
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        guard request.url.absoluteString == "http://127.0.0.1:8823/healthz", request.method == "GET", request.body == nil,
              request.headers["Connection"] == "close", request.headers["Accept-Encoding"] == "identity" else { throw NativeFailure("Health request escaped its fixed production contract") }
        var local = request; local.url = URL(string: "http://127.0.0.1:\(port)/healthz")!
        return try await ShimURLSessionTransport().open(local)
    }
}

final class NativeUpdateHealthProbeTests: XCTestCase {
    func testOldStyleLengthResponseWithoutServerFINIsDrainedAndClientClosed() async throws {
        let server = try UpdateHealthOldServer(); defer { server.stop() }
        do {
        XCTAssertNotEqual(server.port, 8823); XCTAssertNotEqual(server.port, 8780)
        let value = try await NativeUpdateHealthProbe.get(timeout: 2, transport: UpdateHealthPrivatePort(port: server.port))
        XCTAssertEqual(value["ok"], true); XCTAssertEqual(value["service"], "uniapi-shim")
        try await updateHealthAwait(server.done)
        let (error, closure, request) = server.observation
        XCTAssertNil(error); XCTAssertTrue(["EOF", "reset"].contains(closure))
        let text = String(decoding: request, as: UTF8.self).lowercased()
        XCTAssertTrue(text.hasPrefix("get /healthz http/1.1\r\n")); XCTAssertTrue(text.contains("connection: close"))
        } catch {
            server.stop(); try? await updateHealthAwait(server.done)
            XCTAssertTrue(server.done.signalled, "Private health server outlived failure cleanup")
            throw error
        }
    }
    func testCompletedHealthBodyCannotSucceedBeforeHeldTransportDrain() async throws {
        let http = UpdateHealthTransport(holdDrain: true), finished = UpdateHealthSignal(); defer { http.close() }
        let task = Task { defer { finished.signal() }; return try await NativeUpdateHealthProbe.get(timeout: 2, transport: http) }
        try await updateHealthAwait(http.cancelled); XCTAssertFalse(finished.signalled)
        http.drained.signal(); let value = try await task.value
        XCTAssertEqual(value["ok"], true); XCTAssertGreaterThanOrEqual(http.cancelCount, 1)
        let request = try XCTUnwrap(http.captured.first)
        XCTAssertEqual(request.url.absoluteString, "http://127.0.0.1:8823/healthz"); XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.headers["Accept-Encoding"], "identity"); XCTAssertEqual(request.headers["Connection"], "close")
    }
    func testCancellationDuringBodyOrHeldDrainWaitsForCleanupAndNeverSucceeds() async throws {
        for afterEOF in [false, true] {
            let http = UpdateHealthTransport(bytes: afterEOF ? Data("{\"ok\":true}".utf8) : Data(), finish: afterEOF, holdDrain: true)
            let finished = UpdateHealthSignal(); defer { http.close() }
            let task = Task { defer { finished.signal() }; return try await NativeUpdateHealthProbe.get(timeout: 2, transport: http) }
            if afterEOF { try await updateHealthAwait(http.cancelled) }
            else { try await updateHealthAwait(http.opened) }
            task.cancel(); try await updateHealthAwait(http.cancelled)
            XCTAssertFalse(finished.signalled); http.drained.signal()
            do { _ = try await task.value; XCTFail("Cancelled health succeeded") } catch { XCTAssertTrue(error is CancellationError) }
        }
    }
    func testStatusAndEncodingRejectionStillCancelAndAwaitTransportDrain() async throws {
        for (status, headers) in [(503, [String:String]()), (200, ["content-encoding":"gzip"]), (200, ["Content-Encoding":"identity", "content-encoding":"identity"])] {
            let http = UpdateHealthTransport(status: status, headers: headers, holdDrain: true), finished = UpdateHealthSignal(); defer { http.close() }
            let task = Task { defer { finished.signal() }; return try await NativeUpdateHealthProbe.get(timeout: 2, transport: http) }
            try await updateHealthAwait(http.cancelled); XCTAssertFalse(finished.signalled); http.drained.signal()
            do { _ = try await task.value; XCTFail("Rejected header succeeded") } catch { XCTAssertTrue(error.localizedDescription.contains(status == 503 ? "not successful" : "encoding")) }
        }
    }
    func testBodyLimitAndMalformedJSONRejectAfterCleanupButExactLimitIdentitySucceeds() async throws {
        var exact = Data("{\"ok\":true}".utf8); exact.append(Data(repeating: 32, count: 65536-exact.count))
        let positive = UpdateHealthTransport(headers: ["content-encoding":"identity"], bytes: exact); defer { positive.close() }
        let value = try await NativeUpdateHealthProbe.get(timeout: 2, transport: positive)
        XCTAssertEqual(value["ok"], true); XCTAssertGreaterThan(positive.cancelCount, 0)
        for bytes in [exact + Data([32]), Data("not-json".utf8)] {
            let http = UpdateHealthTransport(bytes: bytes, holdDrain: true), finished = UpdateHealthSignal(); defer { http.close() }
            let task = Task { defer { finished.signal() }; return try await NativeUpdateHealthProbe.get(timeout: 2, transport: http) }
            try await updateHealthAwait(http.cancelled); XCTAssertFalse(finished.signalled); http.drained.signal()
            do { _ = try await task.value; XCTFail("Invalid or oversized body succeeded") } catch {}
            XCTAssertGreaterThan(http.cancelCount, 0)
        }
    }
    func testOriginalDeadlineIsRecheckedAfterHeldDrainWithoutResettingBudget() async throws {
        let clock = UpdateHealthClock(), http = UpdateHealthTransport(holdDrain: true, onOpen: { clock.set(100.25) })
        defer { http.close() }
        let task = Task { try await NativeUpdateHealthProbe.get(timeout: 1, transport: http, clock: { clock.read() }) }
        try await updateHealthAwait(http.cancelled); clock.set(101.1); http.drained.signal()
        do { _ = try await task.value; XCTFail("Drain after original deadline succeeded") } catch { XCTAssertTrue(error.localizedDescription.contains("deadline expired")) }
        XCTAssertEqual(http.captured.first?.timeout, 1)
    }
    func testInvalidTimeoutsNeverOpenAndExpiryAfterOpenStillDrains() async throws {
        for timeout in [0, -1, Double.nan, Double.infinity, 30.001] {
            let http = UpdateHealthTransport(); defer { http.close() }
            do { _ = try await NativeUpdateHealthProbe.get(timeout: timeout, transport: http); XCTFail("Invalid timeout admitted") } catch {}
            XCTAssertTrue(http.captured.isEmpty)
        }
        let clock = UpdateHealthClock(), http = UpdateHealthTransport(onOpen: { clock.set(101.1) }); defer { http.close() }
        do { _ = try await NativeUpdateHealthProbe.get(timeout: 1, transport: http, clock: { clock.read() }); XCTFail("Expired header admission succeeded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("deadline expired")) }
        XCTAssertGreaterThan(http.cancelCount, 0)
    }
}
