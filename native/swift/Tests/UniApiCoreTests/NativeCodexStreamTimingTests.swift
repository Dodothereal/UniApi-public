import Foundation
import Darwin
import Network
import XCTest
@testable import UniApiCore

private final class TimingTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false, waiters: [CheckedContinuation<Void, Never>] = []
    var signalled: Bool { lock.withLock { opened } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if opened { return true }; waiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true; let pending = waiters; waiters.removeAll(); return pending
        }
        pending.forEach { $0.resume() }
    }
}
private final class TimingTestRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [NativeCodexStreamTimingObservation] = []
    func add(_ row: NativeCodexStreamTimingObservation) { lock.withLock { rows.append(row) } }
    var count: Int { lock.withLock { rows.count } }
}

private final class TimingHeldUpstream: ShimTransport, @unchecked Sendable {
    let tail = TimingTestGate(), drain = TimingTestGate()
    let frames: [Data]
    init(_ frames: [Data]) { self.frames = frames }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        guard request.url.host == "chatgpt.com", request.url.path == "/backend-api/codex/responses" else { throw NativeFailure("Unexpected fixture endpoint") }
        let stream = AsyncThrowingStream<Data, Error>.makeStream()
        let task = Task {
            do {
                for frame in frames {
                    try Task.checkCancellation(); stream.continuation.yield(frame)
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                await tail.wait(); try Task.checkCancellation()
                stream.continuation.yield(Data("data: [DONE]\n\n".utf8)); stream.continuation.finish()
            } catch { stream.continuation.finish(throwing: error) }
        }
        return .init(status: 200, headers: ["content-type": "text/event-stream"], chunks: stream.stream,
                     cancel: { task.cancel(); self.tail.signal() },
                     waitForCompletion: { await task.value; await self.drain.wait() })
    }
    func release() { tail.signal(); drain.signal() }
}

private enum TimingLoopbackClient {
    /// Read a complete Responses terminal, then close without waiting for DONE/EOF.
    static func completedThenClose(port: Int, token: String) throws -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeFailure("Fixture socket unavailable") }
        defer { close(fd) }
        var noPipe: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw NativeFailure("Fixture socket configuration failed") }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        func wait(_ events: Int16) throws {
            while ProcessInfo.processInfo.systemUptime < deadline {
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&descriptor, 1, 20)
                if result < 0 && errno == EINTR { continue }
                guard result >= 0, descriptor.revents & Int16(POLLERR | POLLNVAL) == 0 else { throw NativeFailure("Fixture socket poll failed") }
                if result > 0 { return }
            }
            throw NativeFailure("Fixture socket deadline")
        }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard connected == 0 || errno == EINPROGRESS else { throw NativeFailure("Fixture connect failed") }
        if connected != 0 {
            try wait(Int16(POLLOUT)); var code: Int32 = 0, length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &length) == 0, code == 0 else { throw NativeFailure("Fixture connect rejected") }
        }
        let body = try JSONValue.object(["model": "example-model", "stream": true, "input": "owned fixture"]).encoded()
        let request = Data("POST /_uniapi/codex/\(token)/v1/responses HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer fixture-only\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        try request.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(Int16(POLLOUT)); let count = Darwin.send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw NativeFailure("Fixture send failed") }; offset += count
            }
        }
        var received = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while received.count < 65_536 {
            try wait(Int16(POLLIN)); let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw NativeFailure("Fixture reply ended before completed") }
            received.append(contentsOf: buffer.prefix(count))
            if let boundary = received.range(of: Data("\r\n\r\n".utf8)) {
                let body = Data(received[boundary.upperBound...])
                guard let completeFrame = body.range(of: Data("\n\n".utf8), options: .backwards) else { continue }
                var parser = ShimSSEParser()
                let frames = try parser.feed(Data(body[..<completeFrame.upperBound]))
                if frames.contains(where: { $0.data["type"] == "response.completed" && $0.data["response"]["status"] == "completed" }) { return true }
            }
        }
        throw NativeFailure("Fixture reply exceeded its bound")
    }
}

final class NativeCodexStreamTimingTests: XCTestCase {
    private final class Clock: @unchecked Sendable { var now: Double = 0 }
    private func frame(_ value: JSONValue) throws -> Data {
        Data("event: \(value["type"].string)\ndata: ".utf8) + (try value.encoded()) + Data("\n\n".utf8)
    }
    private func created(_ id: String = "resp_1") -> JSONValue {
        ["type": "response.created", "response": ["id": .string(id)]]
    }
    private func delta(_ text: String = "a") -> JSONValue {
        ["type": "response.output_text.delta", "item_id": "msg_1", "delta": .string(text)]
    }
    private func completed(_ id: String = "resp_1", output: Int = 10, reasoning: JSONValue = 2, tool: Bool = false) -> JSONValue {
        var rows: [JSONValue] = [["id": "msg_1", "type": "message", "role": "assistant", "content": [["type": "output_text", "text": "firstsecond"]]]]
        if tool { rows.append(["id": "tool_1", "type": "function_call", "arguments": "private arguments"]) }
        return ["type": "response.completed", "response": ["id": .string(id), "status": "completed", "model": "example-model",
            "output": .array(rows), "usage": ["output_tokens": .number(Double(output)), "output_tokens_details": ["reasoning_tokens": reasoning]]]]
    }
    private func feed(_ value: JSONValue, _ observer: inout NativeCodexStreamTimingObserver) throws { observer.feedDelivered(try frame(value)) }
    private func sample(id: String = "resp_1", clock: Clock, reasoning: JSONValue = 2) throws -> NativeCodexStreamTimingObservation {
        var observer = NativeCodexStreamTimingObserver(requestedModel: "example-model", uptime: { clock.now })
        try feed(created(id), &observer); clock.now += 1
        let wire = try frame(delta("first")); for byte in wire { observer.feedDelivered(Data([byte])) }
        clock.now += 2; try feed(delta("second"), &observer); try feed(completed(id, reasoning: reasoning), &observer)
        return try XCTUnwrap(observer.finish(success: true, completedAt: 1234))
    }
    func testFragmentedFramesReasoningAndIndependentRequests() throws {
        let clock = Clock()
        let first = try sample(clock: clock)
        clock.now += 10
        let second = try sample(id: "resp_2", clock: clock)
        XCTAssertEqual(first.durationMs, 2000); XCTAssertEqual(second.durationMs, 2000)
        XCTAssertEqual(first.outputTokens, 10); XCTAssertEqual(first.reasoningTokens, 2); XCTAssertEqual(first.streamOutputTokens, 8)
        XCTAssertEqual(second.responseID, "resp_2"); XCTAssertEqual(first.timingSource, "uniapi-host-sse-clock")
    }
    func testRequestedNativeModelIsRetainedWhenTerminalUsesSnapshotName() throws {
        let clock = Clock()
        var observer = NativeCodexStreamTimingObserver(requestedModel: "native-selector", uptime: { clock.now })
        try feed(created(), &observer); try feed(delta("first"), &observer)
        clock.now = 1; try feed(delta("second"), &observer); try feed(completed(), &observer)
        let observation = try XCTUnwrap(observer.finish(success: true, completedAt: 1234))
        XCTAssertEqual(observation.model, "native-selector")
        XCTAssertEqual(observation.responseID, "resp_1")
    }
    func testMissingOrMismatchedTerminalAndCancellationAreRejected() throws {
        let clock = Clock()
        for terminal in [completed("other"), completed(reasoning: .null), completed(output: 2), completed(tool: true),
                         ["type": "response.failed"] as JSONValue, ["type": "response.incomplete"] as JSONValue] {
            var observer = NativeCodexStreamTimingObserver(requestedModel: "example-model", uptime: { clock.now })
            try feed(created(), &observer); clock.now += 1; try feed(delta(), &observer)
            clock.now += 1; try feed(delta(), &observer); try feed(terminal, &observer)
            XCTAssertNil(observer.finish(success: true, completedAt: 1234))
        }
        var observer = NativeCodexStreamTimingObserver(requestedModel: "example-model", uptime: { clock.now })
        try feed(created(), &observer); try feed(delta(), &observer); clock.now += 1; try feed(delta(), &observer)
        try feed(completed(), &observer)
        XCTAssertNil(observer.finish(success: false, completedAt: 1234))
    }
    func testMalformedFrameAndOneDeltaCannotProduceObservation() throws {
        let clock = Clock(); var observer = NativeCodexStreamTimingObserver(requestedModel: "example-model", uptime: { clock.now })
        try feed(created(), &observer); try feed(delta(), &observer)
        observer.feedDelivered(Data("data: {broken}\n\n".utf8)); clock.now += 1; try feed(delta(), &observer)
        try feed(completed(), &observer); XCTAssertNil(observer.finish(success: true, completedAt: 1234))
        var one = NativeCodexStreamTimingObserver(requestedModel: "example-model", uptime: { clock.now })
        try feed(created(), &one); try feed(delta(), &one); try feed(completed(), &one)
        XCTAssertNil(one.finish(success: true, completedAt: 1234))
        var coalesced = NativeCodexStreamTimingObserver(requestedModel: "example-model", uptime: { clock.now })
        try feed(created(), &coalesced)
        coalesced.feedDelivered(try frame(delta("first")) + frame(delta("second")))
        try feed(completed(), &coalesced)
        XCTAssertNil(coalesced.finish(success: true, completedAt: 1234))
    }
    func testFunctionAndCustomToolDeltasUseTerminalItemIdentityAndContentLength() throws {
        for kind in ["function_call", "custom_tool_call"] {
            let clock = Clock(); var observer = NativeCodexStreamTimingObserver(requestedModel: "example-model", uptime: { clock.now })
            let prefix = kind == "function_call" ? "response.function_call_arguments" : "response.custom_tool_call_input"
            let field = kind == "function_call" ? "arguments" : "input"
            try feed(created(), &observer)
            try feed(["type": .string(prefix + ".delta"), "item_id": "tool_1", "delta": "abc"], &observer)
            clock.now = 2
            try feed(["type": .string(prefix + ".delta"), "item_id": "tool_1", "delta": "def"], &observer)
            let row: JSONValue = ["id": "tool_1", "type": .string(kind), field: "abcdef"]
            let terminal: JSONValue = ["type": "response.completed", "response": ["id": "resp_1", "status": "completed", "model": "example-model", "output": [row], "usage": ["output_tokens": 10, "output_tokens_details": ["reasoning_tokens": 2]]]]
            try feed(terminal, &observer)
            let observation = try XCTUnwrap(observer.finish(success: true, completedAt: 1234))
            XCTAssertEqual(observation.durationMs, 2000); XCTAssertEqual(observation.streamOutputTokens, 8)
        }
    }
    func testExplicitProviderReasoningMustMatchTerminalTotal() throws {
        let clock = Clock(), counter = NativeCodexReasoningCounter()
        counter.observe(["completion_tokens": 10, "completion_tokens_details": ["reasoning_tokens": 3]])
        var observer = NativeCodexStreamTimingObserver(requestedModel: "example-model", uptime: { clock.now })
        try feed(created(), &observer); try feed(delta("first"), &observer)
        clock.now = 1; try feed(delta("second"), &observer); try feed(completed(reasoning: .null), &observer)
        XCTAssertNil(observer.finish(success: true, completedAt: 1234))
        XCTAssertEqual(observer.finish(success: true, completedAt: 1234, providerReasoning: counter.snapshot())?.streamOutputTokens, 7)
        counter.observe(["completion_tokens": 11, "completion_tokens_details": ["reasoning_tokens": 3]])
        XCTAssertNil(observer.finish(success: true, completedAt: 1234, providerReasoning: counter.snapshot()))
        counter.observe(["completion_tokens": 10])
        XCTAssertNil(counter.snapshot())
    }
    func testActualSendLoopPreservesBytesAndOnlyClocksCompletedSends() async throws {
        let clock = Clock()
        let chunks = try [frame(created()), frame(delta("first")), frame(delta("second")), frame(completed()), Data("data: [DONE]\n\n".utf8)]
        func response(observed: Bool) -> ShimClientResponse {
            var result = ShimClientResponse(status: 200, headers: ["content-type": "text/event-stream"], chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }; continuation.finish()
            })
            if observed { result.codexStreamTiming = .init(requestedModel: "example-model", uptime: { clock.now }, record: { _ in }) }
            return result
        }
        var observedBytes: [Data] = [], ordinaryBytes: [Data] = []
        let observation = try await ShimResponseTransmission.send(response(observed: true)) { data, _ in
            clock.now += 1; observedBytes.append(data)
        }
        _ = try await ShimResponseTransmission.send(response(observed: false)) { data, _ in ordinaryBytes.append(data) }
        XCTAssertEqual(observedBytes, ordinaryBytes)
        XCTAssertEqual(observation?.responseID, "resp_1"); XCTAssertEqual(observation?.durationMs, 1000)
        var sends = 0
        do {
            _ = try await ShimResponseTransmission.send(response(observed: true)) { _, _ in
                sends += 1; if sends == 4 { throw NativeFailure("send failed") }
            }
            XCTFail("Failed send returned an observation")
        } catch { XCTAssertEqual(sends, 4) }
        do {
            _ = try await ShimResponseTransmission.send(response(observed: true)) { _, _ in throw CancellationError() }
            XCTFail("Cancelled send returned an observation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testWrappedProviderUsesClientVisibleResponseIDAndSelectedModel() async throws {
        let clock = Clock()
        let wire = try frame(created()) + frame(delta("first")) + frame(delta("second")) + frame(completed()) + Data("data: [DONE]\n\n".utf8)
        let upstream = ShimClientResponse(status: 200, headers: ["content-type": "text/event-stream"], chunks: AsyncThrowingStream { continuation in
            for byte in wire { continuation.yield(Data([byte])) }; continuation.finish()
        })
        var wrapped = try await NativeCodexRouteResponses.wrap(upstream, alias: "uniapi/example/model")
        wrapped.codexStreamTiming = .init(requestedModel: "uniapi/example/model", uptime: { clock.now }, record: { _ in })
        var sent = Data(), index = 0
        let observation = try await ShimResponseTransmission.send(wrapped) { bytes, _ in
            index += 1; clock.now = Double(index); if index > 1 { sent.append(bytes) }
        }
        var parser = ShimSSEParser()
        let terminal = try XCTUnwrap(parser.feed(sent).first { $0.data["type"] == "response.completed" })
        XCTAssertEqual(observation?.responseID, terminal.data["response"]["id"].string)
        XCTAssertNotEqual(observation?.responseID, "resp_1")
        XCTAssertEqual(observation?.model, "uniapi/example/model")
    }
    func testSocketKeepsDeliveredCompletionWhileDrainingOrCancelling() async throws {
        for cancelled in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let paths = NativePaths(root: root), clock = Clock(), records = TimingTestRecords()
            let entered = TimingTestGate(), drain = TimingTestGate()
            let chunks = try [frame(created()), frame(delta("first")), frame(delta("second")), frame(completed())]
            var response = ShimClientResponse(status: 200, headers: ["content-type": "text/event-stream"], chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }; continuation.finish()
            }, cancel: { entered.signal() }, waitForCompletion: { await drain.wait() })
            response.codexStreamTiming = .init(requestedModel: "example-model", uptime: { clock.now }, record: { records.add($0) })
            let gateway = NativeShimGateway(providers: NativeProviderStore(paths: paths), dependencies: .init(), paths: paths)
            let socket = ShimSocket(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 1)!, using: .tcp), gateway: gateway, queue: DispatchQueue(label: "timing-test"), readTimeout: 1, ended: {})
            let task = Task { try await socket.transmit(response) { _, _ in clock.now += 1 } }
            await entered.wait()
            XCTAssertEqual(records.count, 1)
            if cancelled { task.cancel() }
            drain.signal(); try await task.value
            XCTAssertEqual(records.count, 1)
        }
    }
    func testSocketSendAndJournalFailuresNeverAdmitOrBreakTheReply() async throws {
        for failSend in [false, true] {
            let paths = NativePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let clock = Clock(), records = TimingTestRecords()
            let chunks = try [frame(created()), frame(delta("first")), frame(delta("second")), frame(completed())]
            var response = ShimClientResponse(status: 200, headers: ["content-type": "text/event-stream"], chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }; continuation.finish()
            })
            response.codexStreamTiming = .init(requestedModel: "example-model", uptime: { clock.now }, record: { row in
                records.add(row)
                try? NativeCodexStreamTimings.append(row, paths: paths) // The missing data root makes the writer fail.
            })
            let gateway = NativeShimGateway(providers: NativeProviderStore(paths: paths), dependencies: .init(), paths: paths)
            let socket = ShimSocket(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 1)!, using: .tcp), gateway: gateway, queue: DispatchQueue(label: "timing-failure-test"), readTimeout: 1, ended: {})
            var sent = 0
            do {
                try await socket.transmit(response) { _, _ in
                    sent += 1; clock.now += 1
                    if failSend && sent == 4 { throw NativeFailure("send failed") }
                }
                XCTAssertFalse(failSend)
            } catch { XCTAssertTrue(failSend) }
            XCTAssertEqual(records.count, failSend ? 0 : 1)
        }
    }
    func testSocketStreamFailureBeforeOrAfterDeliveredTerminal() async throws {
        for completedFirst in [false, true] {
        let paths = NativePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let clock = Clock(), records = TimingTestRecords()
        let chunks = try [frame(created()), frame(delta("first")), frame(delta("second")), frame(completed())]
        var response = ShimClientResponse(status: 200, headers: ["content-type": "text/event-stream"], chunks: AsyncThrowingStream { continuation in
            for chunk in completedFirst ? chunks : Array(chunks.dropLast()) { continuation.yield(chunk) }; continuation.finish(throwing: NativeFailure("upstream failure"))
        })
        response.codexStreamTiming = .init(requestedModel: "example-model", uptime: { clock.now }, record: { records.add($0) })
        let gateway = NativeShimGateway(providers: NativeProviderStore(paths: paths), dependencies: .init(), paths: paths)
        let socket = ShimSocket(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 1)!, using: .tcp), gateway: gateway, queue: DispatchQueue(label: "timing-stream-failure"), readTimeout: 1, ended: {})
        do {
            try await socket.transmit(response) { _, _ in clock.now += 1 }
            XCTFail("A failed upstream stream succeeded")
        } catch { XCTAssertEqual(records.count, completedFirst ? 1 : 0) }
        }
    }
    func testSocketDoesNotLoseDeliveredClockWhenDoneOrEOFFails() async throws {
        for failAtDone in [false, true] {
            let paths = NativePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let clock = Clock(), records = TimingTestRecords()
            let done = Data("data: [DONE]\n\n".utf8)
            let chunks = try [frame(created()), frame(delta("first")), frame(delta("second")), frame(completed()), done]
            var response = ShimClientResponse(status: 200, headers: ["content-type": "text/event-stream"], chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }; continuation.finish()
            })
            response.codexStreamTiming = .init(requestedModel: "example-model", uptime: { clock.now }, record: { records.add($0) })
            let gateway = NativeShimGateway(providers: NativeProviderStore(paths: paths), dependencies: .init(), paths: paths)
            let socket = ShimSocket(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 1)!, using: .tcp), gateway: gateway, queue: DispatchQueue(label: "timing-completed-close"), readTimeout: 1, ended: {})
            do {
                try await socket.transmit(response) { bytes, final in
                    clock.now += 1
                    if failAtDone ? bytes == done : final { throw NativeFailure("peer closed after completed") }
                }
                XCTFail("A failed send succeeded")
            } catch { XCTAssertEqual(records.count, 1) }
        }
    }
    func testSocketCancellationOrFailedSendBeforeTerminalHasNoClock() async throws {
        for cancelBeforeTerminal in [false, true] {
            let paths = NativePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let clock = Clock(), records = TimingTestRecords()
            let chunks = try [frame(created()), frame(delta("first")), frame(delta("second")), frame(completed())]
            var response = ShimClientResponse(status: 200, headers: ["content-type": "text/event-stream"], chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }; continuation.finish()
            })
            response.codexStreamTiming = .init(requestedModel: "example-model", uptime: { clock.now }, record: { records.add($0) })
            let gateway = NativeShimGateway(providers: NativeProviderStore(paths: paths), dependencies: .init(), paths: paths)
            let socket = ShimSocket(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 1)!, using: .tcp), gateway: gateway, queue: DispatchQueue(label: "timing-incomplete-close"), readTimeout: 1, ended: {})
            let task = Task {
                var count = 0
                try await socket.transmit(response) { _, _ in
                    count += 1; clock.now += 1
                    if cancelBeforeTerminal && count == 4 { withUnsafeCurrentTask { $0?.cancel() } }
                    if !cancelBeforeTerminal && count == 5 { throw NativeFailure("completed was not delivered") }
                }
            }
            do { try await task.value; XCTFail("An incomplete send succeeded") } catch {}
            XCTAssertEqual(records.count, 0)
        }
    }
    func testSocketRequiresTheCompleteTerminalEventDelimiter() async throws {
        for sendDelimiter in [false, true] {
            let paths = NativePaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            let clock = Clock(), records = TimingTestRecords(), delimiter = Data([10])
            let terminalWithoutDelimiter = try Data(frame(completed()).dropLast())
            let chunks = try [frame(created()), frame(delta("first")), frame(delta("second")), terminalWithoutDelimiter, delimiter]
            var response = ShimClientResponse(status: 200, headers: ["content-type": "text/event-stream"], chunks: AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }; continuation.finish()
            })
            response.codexStreamTiming = .init(requestedModel: "example-model", uptime: { clock.now }, record: { records.add($0) })
            let gateway = NativeShimGateway(providers: NativeProviderStore(paths: paths), dependencies: .init(), paths: paths)
            let socket = ShimSocket(connection: NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: 1)!, using: .tcp), gateway: gateway, queue: DispatchQueue(label: "timing-terminal-delimiter"), readTimeout: 1, ended: {})
            do {
                try await socket.transmit(response) { bytes, _ in
                    if bytes == delimiter {
                        XCTAssertEqual(records.count, 0, "A JSON data line is not yet a complete SSE event")
                        if !sendDelimiter { throw NativeFailure("terminal delimiter was not sent") }
                    }
                    clock.now += 1
                }
                XCTAssertTrue(sendDelimiter)
            } catch { XCTAssertFalse(sendDelimiter) }
            XCTAssertEqual(records.count, sendDelimiter ? 1 : 0)
        }
    }
    func testRealLoopbackClientClosingAtCompletedRetainsExactClock() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        try paths.ensureDirectories()
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: paths.providers)
        let upstream = TimingHeldUpstream(try [frame(created()), frame(delta("first")), frame(delta("second")), frame(completed())])
        let watchdog = DispatchWorkItem { upstream.release() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
        defer { watchdog.cancel(); upstream.release() }
        let server = try NativeShimServer(paths: paths, port: 0, dependencies: .init(transport: upstream))
        do {
            try await server.start()
            let port = try XCTUnwrap(server.listeningPort), token = try NativeCodexRoutingSecret.load(paths)
            let client = try await Task.detached { try TimingLoopbackClient.completedThenClose(port: port, token: token) }.value
            XCTAssertTrue(client)
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var observation: NativeCodexStreamTimingObservation?
            repeat {
                observation = NativeCodexStreamTimings.read(paths: paths)["codex:resp_1"]
                if observation != nil { break }
                try await Task.sleep(nanoseconds: 1_000_000)
            } while ProcessInfo.processInfo.systemUptime < deadline
            let value = try XCTUnwrap(observation)
            XCTAssertFalse(upstream.drain.signalled, "Clock must survive independently of upstream teardown")
            XCTAssertEqual(value.responseID, "resp_1"); XCTAssertEqual(value.model, "example-model")
            XCTAssertEqual(value.outputTokens, 10); XCTAssertEqual(value.reasoningTokens, 2); XCTAssertEqual(value.streamOutputTokens, 8)
            XCTAssertTrue(value.durationMs.isFinite && value.durationMs > 0)
            upstream.release(); await server.shutdown()
            XCTAssertEqual(NativeCodexStreamTimings.read(paths: paths).count, 1)
        } catch {
            upstream.release(); await server.shutdown(); throw error
        }
    }
    func testBoundedJournalAndUnsafeLinkAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = root.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let paths = NativePaths(root: root), clock = Clock(), observation = try sample(clock: clock)
        try NativeCodexStreamTimings.append(observation, paths: paths)
        XCTAssertEqual(NativeCodexStreamTimings.read(paths: paths)["codex:resp_1"], observation)
        let journal = data.appendingPathComponent("statistics/stream-timings.jsonl")
        let raw = try Data(contentsOf: journal)
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("firstsecond"))
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: root.appendingPathComponent("elsewhere"))
        XCTAssertTrue(NativeCodexStreamTimings.read(paths: paths).isEmpty)
        XCTAssertThrowsError(try NativeCodexStreamTimings.readSnapshot(paths: paths)) { error in
            XCTAssertEqual(error as? NativeCodexStreamTimings.SnapshotError, .unavailable)
        }
        XCTAssertThrowsError(try NativeCodexStreamTimings.append(observation, paths: paths))
    }
    func testSnapshotDistinguishesMissingAndContendedJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(root: root), clock = Clock()
        XCTAssertTrue(try NativeCodexStreamTimings.readSnapshot(paths: paths).isEmpty)
        try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)
        XCTAssertTrue(try NativeCodexStreamTimings.readSnapshot(paths: paths).isEmpty)
        let observation = try sample(clock: clock)
        try NativeCodexStreamTimings.append(observation, paths: paths)
        let journal = paths.data.appendingPathComponent("statistics/stream-timings.jsonl")
        let descriptor = open(journal.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try NativeCodexStreamTimings.readSnapshot(paths: paths)) { error in
            XCTAssertEqual(error as? NativeCodexStreamTimings.SnapshotError, .busy)
        }
        XCTAssertTrue(NativeCodexStreamTimings.read(paths: paths).isEmpty)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        XCTAssertEqual(try NativeCodexStreamTimings.readSnapshot(paths: paths)["codex:resp_1"], observation)
    }
    func testSnapshotRejectsTruncatedAndCorruptRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NativePaths(root: root)
        try FileManager.default.createDirectory(at: paths.data, withIntermediateDirectories: true)
        try NativeCodexStreamTimings.append(sample(clock: Clock()), paths: paths)
        let journal = paths.data.appendingPathComponent("statistics/stream-timings.jsonl")
        for bytes in [Data("{broken}".utf8), Data("{broken}\n".utf8)] {
            let handle = try FileHandle(forWritingTo: journal)
            try handle.truncate(atOffset: 0); try handle.write(contentsOf: bytes); try handle.close()
            XCTAssertThrowsError(try NativeCodexStreamTimings.readSnapshot(paths: paths)) { error in
                XCTAssertEqual(error as? NativeCodexStreamTimings.SnapshotError, .unavailable)
            }
        }
    }
}
