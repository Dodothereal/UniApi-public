import Foundation
import Darwin
import AppKit

public struct NativeTransferCheck: Sendable {
    public var legacyPresent: Bool
    public var activeJobs: Int
    public var activeCode: Int
    public var legacyWindowRunning: Bool
    public var shimPresent = false
    public var activeShim: Int?
    public var canPrepare: Bool { !legacyWindowRunning && activeJobs == 0 && activeCode == 0 && (activeShim ?? 0) == 0 }
    // An idle snapshot cannot freeze the next submission. Existing owners
    // need coordinated admission/drain before the installer may stop them.
    public var canTransfer: Bool { !legacyWindowRunning && !legacyPresent && !shimPresent }
    public var json: JSONValue { ["legacyPresent": .bool(legacyPresent), "activeJobs": .number(Double(activeJobs)), "activeCode": .number(Double(activeCode)), "shimPresent": .bool(shimPresent), "activeShim": activeShim.map { .number(Double($0)) } ?? .null, "legacyWindowRunning": .bool(legacyWindowRunning), "requiresCoordinatedDrain": .bool(legacyPresent || shimPresent), "canPrepare": .bool(canPrepare), "canTransfer": .bool(canTransfer)] }
    public static func inspect(port: UInt16 = 8780, shimPort: UInt16 = 8823, get: (@Sendable (String) async throws -> JSONValue)? = nil, shimGet: (@Sendable () async throws -> JSONValue)? = nil, legacyUI: (@Sendable () async -> Bool)? = nil) async throws -> NativeTransferCheck {
        let get = get ?? read
        let window = await (legacyUI ?? oldWindow)()
        var shimPresent = false, activeShim: Int?
        do { try NativeOwnership.assertLegacyServerAbsent(port: shimPort) }
        catch {
            let health: JSONValue
            if let shimGet { health = try await shimGet() } else { health = try await read("/healthz", port: Int(shimPort)) }
            guard health["ok"].bool, health["service"] == "uniapi-shim" else { throw NativeFailure("The existing shim listener is unverified; transfer refused") }
            shimPresent = true
            if case .number(let value) = health["activeRequests"], (0...1_000_000).contains(value), value.rounded() == value { activeShim = Int(value) }
        }
        do { try NativeOwnership.assertLegacyServerAbsent(port: port); return .init(legacyPresent: false, activeJobs: 0, activeCode: 0, legacyWindowRunning: window, shimPresent: shimPresent, activeShim: activeShim) }
        catch {
            // A listener alone is insufficient evidence that it is our hub.
            let health = try await get("/api/health")
            guard health["ok"].bool, health["apps"].array.contains("code") else { throw NativeFailure("The existing listener is not a verified UniApi hub; transfer refused") }
            let jobs = try await get("/api/jobs?status=running,queued")
            let code = try await get("/api/code/threads")
            guard case .array(let jobRows) = jobs, case .array(let threadRows) = code else { throw NativeFailure("Cannot establish whether background work is idle; transfer refused") }
            let active = threadRows.filter { ["starting", "running", "waiting"].contains($0["status"].string) || $0["running"].bool }
            return .init(legacyPresent: true, activeJobs: jobRows.count, activeCode: active.count, legacyWindowRunning: window, shimPresent: shimPresent, activeShim: activeShim)
        }
    }
    private static func oldWindow() async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "app.devved.uniapi.hub" && $0.executableURL?.lastPathComponent != "UniApiNative" }
        }
    }
    public static func legacyHealth(service: String) async throws {
        let isShim = service == "app.devved.uniapi-shim"
        guard isShim || service == "app.devved.uniapi-server" else { throw NativeFailure("Unknown restored service") }
        let value = try await read(isShim ? "/healthz" : "/api/health", port: isShim ? 8823 : 8780)
        guard value["ok"].bool, isShim ? value["service"] == "uniapi-shim" : value["apps"].array.contains("code") else { throw NativeFailure("Restored service is not ready") }
    }
    private static func read(_ path: String) async throws -> JSONValue {
        try await read(path, port: 8780)
    }
    private static func read(_ path: String, port: Int) async throws -> JSONValue {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)" + path)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 16 * 1024 * 1024 else { throw NativeFailure("Existing hub state could not be inspected") }
        return try JSONValue.decode(data)
    }
}
