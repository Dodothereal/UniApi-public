import Foundation

/// Responses boundary ported from uniapi-responses.ts and responses/compaction.ts.
/// Frame limits are bytes; retained text budgets are UTF-16 units, as in JavaScript.
enum NativeCodexRouteResponses {
    private static let frameLimit = 8 * 1024 * 1024, jsonLimit = 16 * 1024 * 1024
    private static let streamLimit = 64 * 1024 * 1024
    private static let failure = "UniApi compaction failed; history was not replaced"
    private static let summaryPrefix = "Another language model started to solve this problem and produced a summary of its thinking process. You also have access to the state of the tools that were used by that language model. Use this to build on the work that has already been done and avoid duplicating work. Here is the summary produced by the other language model, use the information in this summary to assist with your own analysis:"

    static func wrap(_ response: ShimClientResponse, alias: String, ticket: ShimRequestTicket? = nil) async throws -> ShimClientResponse {
        if Task.isCancelled { response.cancel(); await response.waitForCompletion(); throw CancellationError() }
        let producer = ticket?.fork()
        guard isSSE(response) else {
            defer { producer?.finish() }
            let bytes = try await collect(response, limit: jsonLimit)
            if !(200..<300).contains(response.status) { return .bytes(response.status, bytes, type: contentType(response)) }
            let value = try strictJSON(bytes)
            return try boundedJSON(response.status, NativeCodexRouteHistory.mark(value, alias: alias))
        }
        let control = NativeCodexResponseTask()
        let chunks = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(512)) { continuation in
            let task = Task {
                var error: Error?
                do {
                    try await withTaskCancellationHandler(operation: {
                        var decoder = Frames(), total = 0
                        func emit(_ bytes: Data) throws {
                            try Task.checkCancellation()
                            switch continuation.yield(bytes) {
                            case .enqueued: break
                            case .dropped: throw NativeFailure("Responses output exceeded its bounded buffer")
                            case .terminated: throw CancellationError()
                            @unknown default: throw NativeFailure("Responses output buffer failed")
                            }
                        }
                        for try await chunk in response.chunks {
                            try Task.checkCancellation()
                            guard chunk.count <= streamLimit - total else { throw NativeFailure("Responses stream exceeded its byte bound") }
                            total += chunk.count
                            try decoder.feed(chunk) { frame in
                                try emit(try rewrite(frame, alias: alias, success: (200..<300).contains(response.status))); return false
                            }
                        }
                        try decoder.feed(Data(), final: true) { frame in
                            try emit(try rewrite(frame, alias: alias, success: (200..<300).contains(response.status))); return false
                        }
                        try Task.checkCancellation()
                    }, onCancel: { response.cancel() })
                } catch let caught { error = caught }
                response.cancel()
                await response.waitForCompletion()
                producer?.finish()
                if Task.isCancelled { continuation.finish(throwing: CancellationError()) }
                else if error != nil { continuation.finish(throwing: NativeFailure("Invalid UniApi response stream")) }
                else { continuation.finish() }
            }
            control.install(task, cancel: response.cancel)
            continuation.onTermination = { reason in if case .cancelled = reason { control.cancel() } }
        }
        if Task.isCancelled { control.cancel(); await control.wait(); throw CancellationError() }
        return .init(status: response.status, headers: ["content-type": "text/event-stream", "cache-control": "no-store"],
                     chunks: chunks, cancel: { control.cancel() }, waitForCompletion: { await control.wait() })
    }

    /// Invalid summaries throw a fixed error only AFTER upstream cancellation/drain.
    /// A successful response is never constructed from deltas or partial output.
    static func compact(_ response: ShimClientResponse, raw: JSONValue, unary: Bool, context: Int) async throws -> ShimClientResponse {
        do {
            let text = try await summary(response, context: context)
            try Task.checkCancellation()
            if unary { return try boundedJSON(200, ["output": .array(replacement(raw["input"], summary: text, context: context))]) }
            let model = raw["model"].string
            let item: JSONValue = ["type": "compaction", "id": .string("cmp_" + UUID().uuidString),
                                   "encrypted_content": .string("ocx1:" + Data(text.utf8).base64EncodedString())]
            let value: JSONValue = ["id": .string("resp_" + UUID().uuidString), "object": "response", "status": "completed",
                                    "created_at": .number(Date().timeIntervalSince1970.rounded(.down)), "model": .string(model),
                                    "end_turn": true, "output": [item], "usage": ["input_tokens": 0, "output_tokens": 0, "total_tokens": 0]]
            if raw["stream"] == false { return try boundedJSON(200, NativeCodexRouteHistory.mark(value, alias: model)) }
            var opening = value; opening["status"] = "in_progress"; opening["output"] = []; opening["usage"] = .null
            let events: [JSONValue] = [
                ["type": "response.created", "sequence_number": 0, "response": opening],
                ["type": "response.output_item.done", "sequence_number": 1, "output_index": 0, "item": item],
                ["type": "response.completed", "sequence_number": 2, "response": value]
            ]
            var bytes = Data()
            for event in events { bytes.append(try encodeEvent(NativeCodexRouteHistory.mark(event, alias: model))) }
            bytes.append(Data("data: [DONE]\n\n".utf8))
            return .bytes(200, bytes, type: "text/event-stream")
        } catch is CancellationError { throw CancellationError() }
        catch { throw NativeFailure(failure) }
    }

    private static func summary(_ response: ShimClientResponse, context: Int) async throws -> String {
        // The outer handler owns admission/tickets while this awaited collector drains.
        do {
            let text = try await withTaskCancellationHandler(operation: {
                guard context > 0, context <= 9_007_199_254_740_991, (200..<300).contains(response.status) else { throw NativeFailure(failure) }
                var terminal: JSONValue?
                if isSSE(response) {
                    var frames = Frames(), total = 0
                    func inspect(_ bytes: Data) throws -> Bool {
                        let frame = try parseFrame(bytes)
                        if frame.data.isEmpty || frame.data == "[DONE]" { return false }
                        let event = try strictJSON(Data(frame.data.utf8))
                        guard case .object = event else { throw NativeFailure(failure) }
                        let type = event["type"].string
                        if ["response.failed", "response.incomplete", "error"].contains(type) || !event["error"].isNull ||
                            type.contains("function_call") || type.contains("custom_tool_call") || type.contains("tool_search_call") { throw NativeFailure(failure) }
                        if case .object = event["item"], !["message", "reasoning"].contains(event["item"]["type"].string) { throw NativeFailure(failure) }
                        if type == "response.completed" { terminal = event["response"]; return true }
                        return false
                    }
                    var found = false
                    for try await chunk in response.chunks {
                        try Task.checkCancellation()
                        guard chunk.count <= streamLimit - total else { throw NativeFailure(failure) }; total += chunk.count
                        found = try frames.feed(chunk, visit: inspect)
                        if found { break }
                    }
                    if !found { try frames.feed(Data(), final: true, visit: inspect) }
                } else {
                    terminal = try strictJSON(await read(response, limit: jsonLimit))
                }
                guard let terminal, terminal["status"] == "completed", terminal["error"].isNull,
                      terminal["last_error"].isNull, terminal["incomplete_details"].isNull,
                      case .array(let output) = terminal["output"] else { throw NativeFailure(failure) }
                var parts: [String] = []
                for item in output {
                    guard ["message", "reasoning"].contains(item["type"].string), item["error"].isNull,
                          item["status"].isNull || item["status"] == "completed" else { throw NativeFailure(failure) }
                    guard item["type"] == "message", item["role"] == "assistant" else { continue }
                    guard case .array(let content) = item["content"] else { throw NativeFailure(failure) }
                    for part in content {
                        guard part["type"] == "output_text", case .string(let text) = part["text"] else { throw NativeFailure(failure) }
                        parts.append(text)
                    }
                }
                let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                let limit = min(256 * 1024, context)
                guard !text.isEmpty, text.utf16.count <= limit, text.utf8.count <= limit else { throw NativeFailure(failure) }
                return text
            }, onCancel: { response.cancel() })
            response.cancel(); await response.waitForCompletion(); try Task.checkCancellation(); return text
        } catch {
            response.cancel(); await response.waitForCompletion()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw NativeFailure(failure)
        }
    }

    private static func contentType(_ response: ShimClientResponse) -> String {
        response.headers.first { $0.key.lowercased() == "content-type" }?.value ?? "application/json"
    }
    private static func isSSE(_ response: ShimClientResponse) -> Bool { contentType(response).lowercased().contains("text/event-stream") }
    private static func read(_ response: ShimClientResponse, limit: Int) async throws -> Data {
        var bytes = Data()
        for try await chunk in response.chunks {
            try Task.checkCancellation()
            guard chunk.count <= limit - bytes.count else { throw NativeFailure("Responses JSON exceeded its byte bound") }
            bytes.append(chunk)
        }
        try Task.checkCancellation(); return bytes
    }
    private static func collect(_ response: ShimClientResponse, limit: Int) async throws -> Data {
        do {
            let bytes = try await withTaskCancellationHandler(operation: { try await read(response, limit: limit) }, onCancel: { response.cancel() })
            response.cancel(); await response.waitForCompletion(); try Task.checkCancellation(); return bytes
        } catch {
            response.cancel(); await response.waitForCompletion()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw NativeFailure("Invalid UniApi response body")
        }
    }
    private static func boundedJSON(_ status: Int, _ value: JSONValue) throws -> ShimClientResponse {
        let bytes = try value.encoded()
        guard bytes.count <= jsonLimit else { throw NativeFailure("Responses JSON exceeded its byte bound") }
        return .bytes(status, bytes)
    }
    private static func strictJSON(_ data: Data) throws -> JSONValue {
        guard data.count <= jsonLimit else { throw NativeFailure("Responses JSON exceeded its byte bound") }
        let text = String(decoding: data, as: UTF8.self)
        guard text.utf8.elementsEqual(data), let value = try? JSONValue.decode(data) else { throw NativeFailure("Invalid Responses JSON or UTF-8") }
        return value
    }
    private static func encodeEvent(_ value: JSONValue) throws -> Data {
        Data(("event: " + value["type"].string + "\ndata: " + String(decoding: try value.encoded(), as: UTF8.self) + "\n\n").utf8)
    }
    private struct Frame { var metadata: [String], data: String }
    private static func parseFrame(_ bytes: Data) throws -> Frame {
        let text = String(decoding: bytes, as: UTF8.self)
        guard text.utf8.elementsEqual(bytes) else { throw NativeFailure("Invalid Responses SSE UTF-8") }
        var metadata: [String] = [], values: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("data:") {
                let value = String(line.dropFirst(5)); values.append(value.hasPrefix(" ") ? String(value.dropFirst()) : value)
            } else if !line.isEmpty { metadata.append(line) }
        }
        return Frame(metadata: metadata, data: values.joined(separator: "\n"))
    }
    private static func rewrite(_ bytes: Data, alias: String, success: Bool) throws -> Data {
        let frame = try parseFrame(bytes)
        var lines = frame.metadata
        if !frame.data.isEmpty {
            if frame.data == "[DONE]" || !success { lines += frame.data.components(separatedBy: "\n").map { "data: " + $0 } }
            else { lines.append("data: " + String(decoding: try NativeCodexRouteHistory.mark(strictJSON(Data(frame.data.utf8)), alias: alias).encoded(), as: UTF8.self)) }
        }
        let output = Data((lines.joined(separator: "\n") + "\n\n").utf8)
        guard output.count <= frameLimit else { throw NativeFailure("Responses SSE output exceeded its byte bound") }
        return output
    }

    /// Byte framing survives arbitrary UTF-8/chunk splits; no invalid frame is silently skipped.
    private struct Frames {
        var pending = Data(), cursor = 0, lineStart = 0, first = true
        @discardableResult
        mutating func feed(_ chunk: Data, final: Bool = false, visit: (Data) throws -> Bool) throws -> Bool {
            pending.append(chunk)
            var consumed = 0
            while cursor < pending.count {
                if pending[cursor] == 10 {
                    let end = cursor > lineStart && pending[cursor - 1] == 13 ? cursor - 1 : cursor
                    if end == lineStart {
                        guard lineStart - consumed <= NativeCodexRouteResponses.frameLimit else { throw NativeFailure("Responses SSE frame exceeded its byte bound") }
                        let frame = take(Data(pending[consumed..<lineStart]))
                        if try visit(frame) { pending = Data(); cursor = 0; lineStart = 0; return true }
                        consumed = cursor + 1
                    }
                    lineStart = cursor + 1
                }
                cursor += 1
            }
            if consumed > 0 { pending = Data(pending.dropFirst(consumed)); cursor -= consumed; lineStart -= consumed }
            guard pending.count <= NativeCodexRouteResponses.frameLimit else { throw NativeFailure("Responses SSE frame exceeded its byte bound") }
            if final && !pending.isEmpty {
                let frame = take(pending); pending = Data(); cursor = 0; lineStart = 0
                return try visit(frame)
            }
            return false
        }
        private mutating func take(_ frame: Data) -> Data {
            defer { first = false }
            return first && frame.starts(with: [0xef, 0xbb, 0xbf]) ? Data(frame.dropFirst(3)) : frame
        }
    }

    private static func blocks(_ item: JSONValue) -> [JSONValue] {
        if case .string = item["content"] { return [["type": "input_text", "text": item["content"]]] }
        return item["content"].array.filter { if case .object = $0 { return true }; return false }
    }
    private static func textBlock(_ block: JSONValue) -> String? {
        guard ["text", "input_text"].contains(block["type"].string), case .string(let text) = block["text"] else { return nil }; return text
    }
    private static func replacement(_ input: JSONValue, summary: String, context: Int) -> [JSONValue] {
        let users = input.array.filter { item in
            guard item.object["type"] == nil || item["type"] == "message", item["role"] == "user" else { return false }
            let texts = blocks(item).compactMap(textBlock)
            if texts.joined().hasPrefix(summaryPrefix + "\n") { return false }
            return !texts.contains { text in
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.range(of: "(?s)^<codex_internal_context source=\"[a-z][a-z0-9_]*\">.*</codex_internal_context>$", options: .regularExpression) != nil ||
                    text.range(of: "(?s)^<goal_context>.*</goal_context>$", options: .regularExpression) != nil
            }
        }
        var remaining = min(20_000, context / 4) * 4, selected: [JSONValue] = []
        for original in users.reversed() where remaining > 0 {
            var kept: [JSONValue] = []
            for block in blocks(original).reversed() where remaining > 0 {
                guard let text = textBlock(block) else { continue } // Provider compaction retains zero images.
                var row = block, units = Array(text.utf16.suffix(remaining))
                if let first = units.first, (0xdc00...0xdfff).contains(first) { units.removeFirst() }
                row["type"] = "input_text"; row["text"] = .string(String(decoding: units, as: UTF16.self))
                remaining = text.utf16.count > remaining ? 0 : remaining - text.utf16.count
                kept.append(row)
            }
            if !kept.isEmpty { var message = original; message["type"] = "message"; message["role"] = "user"; message["content"] = .array(Array(kept.reversed())); selected.append(message) }
        }
        selected.reverse()
        selected.append(["type": "message", "role": "user", "content": [["type": "input_text", "text": .string(summaryPrefix + "\n" + summary)]]])
        return selected
    }
}

private final class NativeCodexResponseTask: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?, abort: (@Sendable () -> Void)?, cancelled = false
    func install(_ task: Task<Void, Never>, cancel: @escaping @Sendable () -> Void) {
        lock.lock(); self.task = task; abort = cancel; let stopped = cancelled; lock.unlock()
        if stopped { task.cancel(); cancel() }
    }
    func cancel() { lock.lock(); cancelled = true; let task = task, abort = abort; lock.unlock(); task?.cancel(); abort?() }
    func wait() async { let task = lock.withLock { task }; await task?.value }
}
