import Foundation
import Darwin

/// curl keeps the original provider TLS/UA behavior and phase timings. Auth
/// lives on private stdin config, never argv; no redirect forwards a capability.
public struct BenchmarkCurlTransport: BenchmarkTransport {
    public typealias Executor = @Sendable (URL, [String], Data, URL, @escaping @Sendable (Data) throws -> Void) async throws -> NativeProcessResult
    let runtime: NativeRuntime
    private let executable: URL?
    private let executor: Executor
    private let maximumResponseBytes: Int
    public init(runtime: NativeRuntime, executable: URL? = nil, maximumResponseBytes: Int = 16 * 1024 * 1024, executor: Executor? = nil) {
        self.runtime = runtime; self.executable = executable
        self.maximumResponseBytes = max(256, maximumResponseBytes)
        self.executor = executor ?? { executable, arguments, input, directory, output in
            let session = try runtime.process.open(executable, arguments: arguments, environment: runtime.process.cleanAgentEnvironment(), directory: directory)
            return try await withTaskCancellationHandler(operation: {
                do {
                    try await session.write(input); session.closeInput()
                    for try await chunk in session.output { try Task.checkCancellation(); try output(chunk) }
                    return try await session.wait()
                } catch {
                    session.cancel(); _ = try? await session.wait(); throw error
                }
            }, onCancel: { session.cancel() })
        }
    }
    public func execute(_ request: BenchmarkRequest) async throws -> BenchmarkResponse {
        try Task.checkCancellation(); try runtime.paths.assertWritable()
        guard ["http", "https"].contains(request.url.scheme ?? ""), request.url.user == nil, request.url.password == nil,
              request.timeout.isFinite, let curl = executable ?? runtime.process.which("curl") else { throw NativeFailure("A valid HTTP endpoint and curl are required") }
        let directory = runtime.paths.tmp.appendingPathComponent("benchmark-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let headerFile = directory.appendingPathComponent("headers"), bodyFile = directory.appendingPathComponent("request.json")
        func quote(_ text: String) throws -> String {
            guard !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw NativeFailure("Invalid transport setting") }
            return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // Ambient proxy settings must not forward a loopback browser capability.
        var config = "url = " + (try quote(request.url.absoluteString)) + "\nmax-time = \(max(1, min(900, request.timeout)))\nsilent\nshow-error\nno-buffer\nnoproxy = \"127.0.0.1,localhost,::1\"\n"
        config += "dump-header = " + (try quote(headerFile.path)) + "\n"
        for (key, value) in request.headers.sorted(by: { $0.key < $1.key }) { config += "header = " + (try quote(key + ": " + value)) + "\n" }
        if let body = request.body { try NativeFile.writeAtomic(body, to: bodyFile); config += "request = \"POST\"\ndata-binary = " + (try quote("@" + bodyFile.path)) + "\n" }
        let marker = "\n\u{1e}{\"http_code\":%{http_code},\"t_dns\":%{time_namelookup},\"t_connect\":%{time_connect},\"t_tls\":%{time_appconnect},\"t_starttransfer\":%{time_starttransfer},\"t_total\":%{time_total}}"
        let collector = BenchmarkChunkCollector(maximumBytes: maximumResponseBytes)
        let began = ProcessInfo.processInfo.systemUptime
        // --disable must be first: ~/.curlrc could otherwise enable redirects.
        let result = try await executor(curl, ["--disable", "--config", "-", "--write-out", marker], Data(config.utf8), directory,
            { try collector.append(.init(milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000, data: $0)) })
        var chunks = collector.chunks, timing: JSONValue = [:]
        let bytes = chunks.reduce(into: Data()) { $0.append($1.data) }
        if let markerIndex = bytes.lastIndex(of: 0x1e), let metrics = try? JSONValue.decode(Data(bytes[bytes.index(after: markerIndex)...])) {
            timing = metrics
            var remaining = markerIndex
            chunks = chunks.compactMap { chunk in
                guard remaining > 0 else { return nil }; let count = min(remaining, chunk.data.count); remaining -= count
                return BenchmarkChunk(milliseconds: chunk.milliseconds, data: Data(chunk.data.prefix(count)))
            }
        }
        var headers: [String: String] = [:]
        if let data = try? Data(contentsOf: headerFile) {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if key.contains("ratelimit") || key.contains("request-id") || ["retry-after", "server", "content-type", "cf-ray", "date"].contains(key) { headers[key] = value }
            }
        }
        return BenchmarkResponse(status: timing["http_code"].int, exitCode: result.status, headers: headers, chunks: chunks, timing: timing, error: result.errorOutput)
    }
}

private final class BenchmarkChunkCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BenchmarkChunk] = []
    private var bytes = 0
    private let maximumBytes: Int
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
    func append(_ chunk: BenchmarkChunk) throws {
        lock.lock(); defer { lock.unlock() }
        guard chunk.data.count <= maximumBytes - bytes else { throw NativeFailure("Benchmark response exceeds the transport memory limit") }
        bytes += chunk.data.count; values.append(chunk)
    }
    var chunks: [BenchmarkChunk] { lock.lock(); defer { lock.unlock() }; return values }
}

struct BenchmarkAnalysis: Sendable {
    var events = 0, content = "", contentCharacters = 0, reasoningCharacters = 0
    var first: Double?, firstContent: Double?, last: Double?, finish: String?
    var usage: JSONValue = [:], metadata: JSONValue = [:]
    var done = false, nonStream = false, streamError = false
    var curve: [(Double, Int)] = [], gaps: [Double] = []
    static func analyze(_ response: BenchmarkResponse) -> BenchmarkAnalysis {
        var result = BenchmarkAnalysis(), buffered = Data(), eventLines: [String] = []
        func consume(_ text: String, _ at: Double) {
            if text == "[DONE]" { result.done = true; return }
            guard let event = try? JSONValue.decode(Data(text.utf8)), case .object = event else { return }
            result.events += 1
            if !event["error"].isNull { result.streamError = true }
            if !event["uniapi"].isNull { result.metadata = event["uniapi"] }
            if !event["usage"].object.isEmpty { result.usage = event["usage"] }
            var piece = "", reasoning = ""
            if event["type"] == "message_start" { result.usage = event["message"]["usage"] }
            if event["type"] == "message_delta" {
                result.usage = .object(result.usage.object.merging(event["usage"].object) { _, new in new }); result.finish = event["delta"]["stop_reason"].string
            }
            if event["type"] == "message_stop" { result.done = true }
            if event["type"] == "content_block_delta" { piece = event["delta"]["text"].string; reasoning = event["delta"]["thinking"].string }
            if let choice = event["choices"].array.first {
                piece += choice["delta"]["content"].string
                reasoning += choice["delta"]["reasoning_content"].string.isEmpty ? choice["delta"]["reasoning"].string : choice["delta"]["reasoning_content"].string
                if !choice["finish_reason"].isNull { result.finish = choice["finish_reason"].string }
            }
            guard !piece.isEmpty || !reasoning.isEmpty else { return }
            if result.first == nil { result.first = at }
            if result.firstContent == nil && !piece.isEmpty { result.firstContent = at }
            if let previous = result.last { result.gaps.append(at - previous) }
            result.last = at; result.contentCharacters += piece.unicodeScalars.count
            if result.content.unicodeScalars.count < 160 { result.content += String(piece.unicodeScalars.prefix(160 - result.content.unicodeScalars.count)) }
            result.reasoningCharacters += reasoning.unicodeScalars.count
            result.curve.append((at, result.contentCharacters + result.reasoningCharacters))
        }
        for chunk in response.chunks {
            buffered.append(chunk.data)
            while let newline = buffered.firstIndex(of: 10) {
                let text = String(decoding: buffered[..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
                buffered = Data(buffered[buffered.index(after: newline)...])
                if text.isEmpty { if !eventLines.isEmpty { consume(eventLines.joined(separator: "\n"), chunk.milliseconds); eventLines.removeAll() } }
                else if text.hasPrefix("data:") {
                    let payload = String(text.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                    // Several supported routers omit blank SSE separators. A
                    // complete JSON data line still has a measurable arrival.
                    if eventLines.isEmpty && (payload == "[DONE]" || (try? JSONValue.decode(Data(payload.utf8))) != nil) { consume(payload, chunk.milliseconds) }
                    else { eventLines.append(payload) }
                }
            }
        }
        let at = response.chunks.last?.milliseconds ?? response.timing["t_total"].double * 1000
        if !buffered.isEmpty {
            let text = String(decoding: buffered, as: UTF8.self)
            if text.hasPrefix("data:") { eventLines.append(String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        if !eventLines.isEmpty { consume(eventLines.joined(separator: "\n"), at) }
        if result.events == 0, response.status == 200, let value = try? JSONValue.decode(response.data) {
            result.nonStream = true; result.usage = value["usage"]
            if let choice = value["choices"].array.first { result.content = choice["message"]["content"].string; result.reasoningCharacters = choice["message"]["reasoning_content"].string.unicodeScalars.count; result.finish = choice["finish_reason"].string }
            else { result.content = value["content"].array.map { $0["text"].string }.joined(); result.finish = value["stop_reason"].string }
            result.contentCharacters = result.content.unicodeScalars.count; result.content = String(result.content.unicodeScalars.prefix(160))
            if !result.content.isEmpty || result.reasoningCharacters > 0 { result.first = at; result.last = at; if !result.content.isEmpty { result.firstContent = at } }
        }
        return result
    }
}
