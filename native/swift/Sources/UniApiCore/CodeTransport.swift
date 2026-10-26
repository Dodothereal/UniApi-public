import Foundation

protocol CodeChannel: Sendable {
    var output: AsyncThrowingStream<Data, Error> { get }
    func write(_ value: JSONValue) async throws
    func close() async
    func wait() async throws -> Int32
}
final class CodeProcessChannel: CodeChannel, @unchecked Sendable {
    let process: NativeProcessSession
    var output: AsyncThrowingStream<Data, Error> { process.output }
    init(_ process: NativeProcessSession) { self.process = process }
    func write(_ value: JSONValue) async throws { try await process.write(value) }
    func close() async { process.cancel(); _ = try? await process.wait() }
    func wait() async throws -> Int32 { try await process.wait().status }
}

/// Strict bounded NDJSON, correlated requests and cancellation. Notifications
/// and client requests are delivered independently so a prompt may wait while
/// permissions and file requests continue flowing in the other direction.
actor CodeTransport {
    enum Wire: Sendable { case claude, acp }
    let channel: any CodeChannel, wire: Wire
    private var reader: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<JSONValue, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private var handler: (@Sendable (JSONValue) async -> Void)?
    private var stopped = false
    init(channel: any CodeChannel, wire: Wire) { self.channel = channel; self.wire = wire }
    func start(handler: @escaping @Sendable (JSONValue) async -> Void) {
        guard reader == nil else { return }; self.handler = handler
        reader = Task { [weak self, channel] in
            var buffered = Data()
            do {
                for try await chunk in channel.output {
                    buffered.append(chunk)
                    guard buffered.count <= 16 * 1024 * 1024 else { throw NativeFailure("Agent frame exceeded 16 MiB") }
                    while let end = buffered.firstIndex(of: 10) {
                        let line = Data(buffered[..<end]); buffered.removeSubrange(...end)
                        if line.isEmpty { continue }
                        let value = try JSONValue.decode(line)
                        await self?.receive(value)
                    }
                }
                if !buffered.isEmpty { await self?.receive(try JSONValue.decode(buffered)) }
                let status = try await channel.wait()
                await self?.ended(NativeFailure("Agent process exited (\(status))"))
            } catch { await self?.ended(error) }
        }
    }
    private func receive(_ value: JSONValue) async {
        let response = wire == .claude ? value["response"] : value
        let id = wire == .claude ? response["request_id"].string : response["id"].string
        let isResponse = wire == .claude ? value["type"].string == "control_response" : !value["id"].isNull && value["method"].isNull
        if isResponse, let continuation = pending.removeValue(forKey: id) {
            deadlines.removeValue(forKey: id)?.cancel()
            if response["subtype"].string == "error" || !response["error"].isNull {
                let message = response["error"]["message"].string.isEmpty ? response["error"].string : response["error"]["message"].string
                continuation.resume(throwing: NativeFailure(message.isEmpty ? "Agent request failed" : message))
            } else { continuation.resume(returning: wire == .claude ? response["response"] : response["result"]) }
        } else if let handler {
            // Handlers enqueue pending permissions and return immediately;
            // they must not wait for user input or send a correlated request.
            // Awaiting that bounded handler preserves transcript frame order.
            await handler(value)
        }
    }
    func request(_ method: String, params: JSONValue = [:], timeout: UInt64 = 120) async throws -> JSONValue {
        guard !stopped else { throw NativeFailure("Agent connection closed") }
        let id = UUID().uuidString
        var body = params
        if wire == .claude { body["subtype"] = .string(method) }
        let frame: JSONValue = wire == .claude ? ["type": "control_request", "request_id": .string(id), "request": body] : ["jsonrpc": "2.0", "id": .string(id), "method": .string(method), "params": params]
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self] in do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000); await self?.reject(id, message: "\(method) timed out") } catch {} }
                Task { do { try await channel.write(frame) } catch { self.reject(id, message: error.localizedDescription) } }
            }
        }, onCancel: { Task { await self.reject(id, message: "Request cancelled") } })
    }
    func notify(_ method: String, params: JSONValue) async throws {
        try await channel.write(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }
    func send(_ value: JSONValue) async throws { guard !stopped else { throw NativeFailure("Agent connection closed") }; try await channel.write(value) }
    func respond(to frame: JSONValue, result: JSONValue = [:], error: String? = nil) async throws {
        let id = wire == .claude ? frame["request_id"] : frame["id"]
        if wire == .claude {
            var response: JSONValue = ["subtype": .string(error == nil ? "success" : "error"), "request_id": id]
            if let error { response["error"] = .string(error) } else { response["response"] = result }
            try await channel.write(["type": "control_response", "response": response])
        } else {
            var response: JSONValue = ["jsonrpc": "2.0", "id": id]
            if let error { response["error"] = ["code": -32603, "message": .string(error)] } else { response["result"] = result }
            try await channel.write(response)
        }
    }
    private func reject(_ id: String, message: String) { deadlines.removeValue(forKey: id)?.cancel(); pending.removeValue(forKey: id)?.resume(throwing: NativeFailure(message)) }
    private func ended(_ error: Error) async {
        guard !stopped else { return }; stopped = true
        for id in Array(pending.keys) { reject(id, message: error.localizedDescription) }
        if let handler { await handler(["type": "native.process.closed", "message": .string(error.localizedDescription)]) }
    }
    func close() async { stopped = true; reader?.cancel(); for id in Array(pending.keys) { reject(id, message: "Agent connection closed") }; await channel.close(); if let reader { await reader.value } }
}
