import Foundation

public struct BenchmarkTier: Sendable {
    public var latency: Int, throughput: Int, output: Int, contexts: [Int], maxOutput: Int, probe: Bool
    public static let names = ["quick", "standard", "deep"]
    public static let configurations: [String: BenchmarkTier] = [
        "quick": .init(latency: 1, throughput: 1, output: 512, contexts: [64, 4096, 16384], maxOutput: 0, probe: false),
        "standard": .init(latency: 3, throughput: 1, output: 1024, contexts: [64, 4096, 16384, 32768, 65536], maxOutput: 4096, probe: false),
        "deep": .init(latency: 5, throughput: 2, output: 2048, contexts: [64, 4096, 16384, 32768, 65536, 131072], maxOutput: 32768, probe: true),
    ]
    public func units(browser: Bool, vision: Bool) -> Int {
        latency + throughput + contexts.count + (maxOutput > 0 && !browser ? 1 : 0) + (probe ? 1 : 0) + (vision && !browser ? 1 : 0)
    }
}

public struct BenchmarkConnection: Sendable {
    public var baseURL: URL, key: String
    public init(baseURL: URL, key: String) { self.baseURL = baseURL; self.key = key }
}
public struct BenchmarkRequest: Sendable {
    public var url: URL, headers: [String: String], body: Data?, timeout: Double
    public init(url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: Double = 60) {
        self.url = url; self.headers = headers; self.body = body; self.timeout = timeout
    }
}
public struct BenchmarkChunk: Sendable {
    public var milliseconds: Double, data: Data
    public init(milliseconds: Double, data: Data) { self.milliseconds = milliseconds; self.data = data }
}
public struct BenchmarkResponse: Sendable {
    public var status: Int, exitCode: Int32, headers: [String: String], chunks: [BenchmarkChunk], timing: JSONValue, error: String
    public init(status: Int = 200, exitCode: Int32 = 0, headers: [String: String] = [:], chunks: [BenchmarkChunk] = [], timing: JSONValue = [:], error: String = "") {
        self.status = status; self.exitCode = exitCode; self.headers = headers; self.chunks = chunks; self.timing = timing; self.error = error
    }
    public var data: Data { chunks.reduce(into: Data()) { $0.append($1.data) } }
    public var text: String { String(decoding: data, as: UTF8.self) }
}
public protocol BenchmarkTransport: Sendable {
    func execute(_ request: BenchmarkRequest) async throws -> BenchmarkResponse
}

/// All clocks, sleeps, transports and private credential lookup have fixture
/// seams. Default construction performs no request, process launch or auth read.
public struct BenchmarkDependencies: Sendable {
    public var transport: any BenchmarkTransport
    public var now: @Sendable () -> Date
    public var sleep: @Sendable (Double) async throws -> Void
    public var bridge: @Sendable (NativePaths) throws -> BenchmarkConnection
    public var legacySelection: @Sendable (NativePaths) -> JSONValue?
    public var notify: @Sendable (String, NativePaths) async throws -> Void
    public var schedulingEnabled: Bool
    public init(transport: any BenchmarkTransport, now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
                    try await Task.sleep(nanoseconds: UInt64((seconds.isFinite ? min(600, max(0, seconds)) : 0) * 1_000_000_000))
                }, bridge: (@Sendable (NativePaths) throws -> BenchmarkConnection)? = nil,
                legacySelection: (@Sendable (NativePaths) -> JSONValue?)? = nil,
                notify: (@Sendable (String, NativePaths) async throws -> Void)? = nil,
                schedulingEnabled: Bool = true) {
        self.transport = transport; self.now = now; self.sleep = sleep
        self.bridge = bridge ?? { paths in try BenchmarkPrivateBridge.resolve(paths) }
        self.legacySelection = legacySelection ?? { paths in BenchmarkLegacySelection.read(paths) }
        self.notify = notify ?? { text, paths in
            guard paths.home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL else { return }
            try await NativeNotifications.send(text, home: paths.home)
        }
        self.schedulingEnabled = schedulingEnabled
    }
}

enum BenchmarkLegacySelection {
    static func read(_ paths: NativePaths) -> JSONValue? {
        guard paths.home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL,
              let data = UserDefaults(suiteName: "app.devved.uniapi")?.data(forKey: "uniapi-sel-v1") else { return nil }
        return try? JSONValue.decode(data)
    }
}

public enum BenchmarkPrivateBridge {
    public static func resolve(_ paths: NativePaths) throws -> BenchmarkConnection {
        let environment = paths.home.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL ? ProcessInfo.processInfo.environment : [:]
        let home = environment["CODEX_CHATGPT_WEB_HOME"].map { URL(fileURLWithPath: $0) } ?? paths.home.appendingPathComponent(".codex-chatgpt-web")
        let file = home.appendingPathComponent("config.json")
        let info = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? 0) <= 8 * 1024 * 1024 else { throw NativeFailure("Browser bridge configuration is unavailable") }
        let value = try BenchmarkDisk.json(file, limit: 8 * 1024 * 1024), port = value["port"].int, key = value["uniapiInferenceToken"].string
        guard value["host"] == "127.0.0.1", (1024...65535).contains(port),
              key.range(of: "^[A-Za-z0-9_-]{40,}$", options: .regularExpression) != nil else { throw NativeFailure("Complete ChatGPT Web setup before benchmarking browser modes") }
        // Provider-editable URLs can never redirect this capability elsewhere.
        return BenchmarkConnection(baseURL: URL(string: "http://127.0.0.1:\(port)/uniapi/v1")!, key: key)
    }
}

public enum BenchmarkMath {
    public static let browserNote = "Browser first-visible-text timing and estimated visible-update rates. Buffering can inflate speed; compare first response and total completion time. Input acceptance is not verified model context. Output cap, prefill and vision probes are unavailable."
    public static func number(_ value: JSONValue) -> Double? { if case .number(let n) = value, n.isFinite { return n }; return nil }
    public static func optional(_ value: Double?) -> JSONValue { value.map(JSONValue.number) ?? .null }
    public static func iso(_ date: Date) -> String { BenchmarkClock.shared.iso(date) }
    public static func timestamp(_ text: String) -> Double {
        BenchmarkClock.shared.timestamp(text)
    }
    public static func percentile(_ values: [Double], _ percentile: Double) -> Double? {
        let values = values.filter(\.isFinite).sorted(); guard !values.isEmpty else { return nil }
        let index = Int((Double(values.count - 1) * max(0, min(100, percentile)) / 100).rounded(.toNearestOrEven))
        return values[index]
    }
    public static func family(_ model: String) -> String {
        var tail = model.split(separator: "/").last.map(String.init)?.lowercased() ?? model.lowercased()
        while true {
            let next = tail.replacingOccurrences(of: "[-_.](free|exp|preview|latest|[0-9]{4}|[0-9]{8})$", with: "", options: .regularExpression)
            if next == tail { break }; tail = next
        }
        return tail.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    static func redact(_ value: JSONValue, key: String) -> JSONValue {
        guard !key.isEmpty else { return value }
        switch value {
        case .string(let text): return .string(text.replacingOccurrences(of: key, with: "<redacted>"))
        case .array(let values): return .array(values.map { redact($0, key: key) })
        case .object(let fields): return .object(fields.mapValues { redact($0, key: key) })
        default: return value
        }
    }
    public static func error(status: Int, body: String, exitCode: Int32 = 0, quota429: Bool = false) -> String {
        let text = body.lowercased()
        if exitCode == 28 || text.contains("timed out") || text.contains("timeout was reached") { return "timeout" }
        if exitCode != 0 && status == 0 { return "network" }
        if status == 402 || ["insufficient", "balance", "credit", "quota"].contains(where: text.contains) { return "quota" }
        if status == 401 || status == 403 { return "auth" }
        if status == 404 && ["model", "not found", "no such", "not exist"].contains(where: text.contains) { return "model_not_found" }
        if status == 429 { return quota429 ? "quota" : "rate_limited" }
        if [400, 413, 422].contains(status), text.range(of: "context|too (long|large|many)|length|maximum.{0,50}token|token.{0,50}(limit|exceed)|exceed|payload", options: .regularExpression) != nil { return "ctx_limit" }
        if (400..<500).contains(status) { return "bad_request" }; if status >= 500 { return "server_error" }; return "unknown"
    }
    public static func freeOutcome(status: Int, text: String) -> String {
        if status == 429 || status == 402 {
            return text.range(of: "requires?[ _-]purchase|locked|buy credits?|insufficient|balance|top ?up|upgrade your plan", options: [.regularExpression, .caseInsensitive]) != nil ? "denied" : "limited"
        }
        if status == 401 || status == 403 { return "denied" }
        if status == 404 || text.range(of: "model.*(not found|does not exist|unknown)", options: [.regularExpression, .caseInsensitive]) != nil { return "missing" }
        if text.range(of: "abort|timed? ?out|ETIMEDOUT|ECONNRESET", options: [.regularExpression, .caseInsensitive]) != nil { return "timeout" }
        return "failed"
    }
}
