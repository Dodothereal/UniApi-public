import Foundation
import Darwin

/// A headless adapter to the existing routing owner, never a second config writer.
public enum NativeCodexRoutingCommand {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let json: JSONValue
    }

    struct Options: Equatable, Sendable {
        enum Operation: String, Sendable { case status, connect, restore }
        let operation: Operation
        let waitSeconds: Int?

        static func parse(_ arguments: [String]) throws -> Options {
            guard arguments.count >= 2, arguments[0] == "--codex-routing",
                  let operation = Operation(rawValue: arguments[1]) else { throw NativeFailure("Invalid routing command") }
            if arguments.count == 2 { return .init(operation: operation, waitSeconds: nil) }
            guard operation == .connect, arguments.count == 4, arguments[2] == "--wait-for-idle",
                  !arguments[3].isEmpty, arguments[3].utf8.allSatisfy({ (48...57).contains($0) }),
                  let seconds = Int(arguments[3]), (1...600).contains(seconds) else { throw NativeFailure("Invalid routing wait") }
            return .init(operation: operation, waitSeconds: seconds)
        }
    }

    // These dependencies keep command policy testable without starting services,
    // contacting real transports, sleeping, or changing an operator's files.
    struct IO: Sendable {
        var status: @Sendable () async throws -> JSONValue
        var action: @Sendable (String) async throws -> JSONValue
        var fingerprint: @Sendable () throws -> Fingerprint
        var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    }

    struct Fingerprint: Equatable, Sendable {
        let config: String?, providers: String?, bridgeConfig: String?, bridgeCatalog: String?, nativeCatalog: String?

        static func capture(paths: NativePaths) throws -> Fingerprint {
            func digest(_ file: URL, limit: Int = 8 * 1024 * 1024) throws -> String? {
                var info = stat()
                if lstat(file.path, &info) != 0 {
                    guard errno == ENOENT else { throw NativeFailure("Routing intent could not be inspected") }
                    return nil
                }
                // Missing and empty are different intent. The bounded no-follow
                // reader also rejects links, directories and concurrent removal.
                return SwitcherDisk.hash(try SwitcherDisk.read(file, missing: false, limit: limit))
            }
            return try .init(
                config: digest(SwitcherDisk.codexHome(paths).appendingPathComponent("config.toml")),
                providers: digest(paths.providers),
                bridgeConfig: digest(SwitcherDisk.bridgeHome(paths).appendingPathComponent("config.json")),
                bridgeCatalog: digest(NativeCodexCatalogStore(bridgeHome: SwitcherDisk.bridgeHome(paths), providersFile: paths.providers).file, limit: 65536),
                nativeCatalog: digest(NativeCodexRouteStore(paths: paths).catalog.file, limit: 65536))
        }
    }

    public static func run(_ arguments: [String]) async -> Result {
        await run(arguments, makeIO: { options in
            let discovered = NativePaths.discover()
            // Status must not create directories, seed providers or migrate the
            // database. Mutations use the normal writable runtime and manager.
            let paths = options.operation == .status
                ? NativePaths(root: discovered.root, home: discovered.home, readOnly: true, dataRoot: discovered.data, providersFile: discovered.providers)
                : discovered
            let runtime = try NativeRuntime(paths: paths)
            let manager = NativeCodexManager(runtime: runtime, io: .production(runtime))
            return IO(status: { try await manager.status() }, action: { try await manager.action($0) },
                      fingerprint: { try Fingerprint.capture(paths: paths) })
        })
    }

    static func run(_ arguments: [String], makeIO: @Sendable (Options) throws -> IO) async -> Result {
        let options: Options
        do { options = try Options.parse(arguments) }
        catch {
            return .init(exitCode: 64, json: ["ok": false, "outcome": "usage",
                "usage": "--codex-routing status|connect|restore; connect [--wait-for-idle SECONDS] (1...600)"])
        }
        var latest: JSONValue = .null
        func result(_ outcome: String, _ code: Int32, reload: Bool = false) -> Result {
            .init(exitCode: code, json: ["ok": .bool(code == 0), "command": .string(options.operation.rawValue),
                "outcome": .string(outcome), "reloadRequired": .bool(reload), "status": latest])
        }
        do {
            try Task.checkCancellation()
            let io = try makeIO(options)
            let deadline = options.waitSeconds.map { io.now() + Double($0) }
            let initial = options.waitSeconds == nil ? nil : try io.fingerprint()
            while true {
                try Task.checkCancellation()
                if let deadline, io.now() >= deadline { return result("timed_out", 2) }
                let status = try await io.status()
                try Task.checkCancellation()
                latest = summary(status)
                if options.operation == .status { return result("status", 0) }
                // Check after every observation, including the final idle read.
                // models_cache.json is deliberately excluded: Codex refreshes it.
                if let initial, try io.fingerprint() != initial { return result("intent_changed", 2) }
                let readiness = readiness(status, operation: options.operation)
                if readiness == .unhealthy { return result("unhealthy", 2) }
                if let deadline, io.now() >= deadline { return result("timed_out", 2) }
                if readiness == .idle {
                    try Task.checkCancellation()
                    let response = try await io.action(options.operation == .connect ? "nativeConnect" : "restore")
                    latest = summary(response["status"])
                    guard response["ok"] == true else { return result("failed", 1) }
                    // Acknowledgement alone cannot prove the requested owner
                    // survived a concurrent writer or an uncertain handoff.
                    guard completed(response["status"], operation: options.operation) else { return result("uncertain", 1) }
                    return result("completed", 0, reload: response["reloadRequired"] == true)
                }
                // A connected route has no handoff to wait for. Keep the
                // existing action's idle guard without waiting on its traffic.
                guard let deadline, !(options.operation == .connect && status["native"]["connected"] == true) else { return result("busy", 2) }
                try await io.sleep(min(1, max(0, deadline - io.now())))
            }
        } catch is CancellationError { return result("cancelled", 130) }
        catch {
            // Underlying errors can embed paths or capability-bearing URLs.
            // Never send them, manager messages, or raw status to CLI output.
            return result(Task.isCancelled ? "cancelled" : "failed", Task.isCancelled ? 130 : 1)
        }
    }

    private enum Readiness { case idle, busy, unhealthy }
    private static func completed(_ status: JSONValue, operation: Options.Operation) -> Bool {
        // Require explicit clean error fields; absent/malformed status cannot
        // establish a postcondition. Disconnected native health is not needed
        // to prove restore released both route owners.
        guard status.object["configError"] == JSONValue.null,
              status["native"].object["error"] == JSONValue.null,
              status["catalog"].object["error"] == JSONValue.null,
              status["bridge"]["integrated"] == false else { return false }
        switch operation {
        case .connect: return status["native"]["connected"] == true
        case .restore: return status["native"]["connected"] == false
        case .status: return false
        }
    }
    private static func readiness(_ status: JSONValue, operation: Options.Operation) -> Readiness {
        guard status["configError"].isNull, status["native"]["error"].isNull, status["catalog"]["error"].isNull,
              case .bool(let nativeConnected) = status["native"]["connected"],
              case .bool(let webIntegrated) = status["bridge"]["integrated"] else { return .unhealthy }
        var busy = false
        if operation == .connect || nativeConnected {
            guard status["native"]["running"] == true, status["native"]["accepting"] == true,
                  status["native"]["healthError"].isNull,
                  case .number(let active) = count(status["native"]["activeRequests"]) else { return .unhealthy }
            busy = active > 0
        }
        // An optional, disconnected Web installation is not a native dependency.
        if webIntegrated {
            guard status["bridge"]["running"] == true, case .bool(let webBusy) = status["bridge"]["busy"] else { return .unhealthy }
            busy = busy || webBusy
        }
        return busy ? .busy : .idle
    }

    private static func boolean(_ value: JSONValue) -> JSONValue {
        if case .bool = value { return value }; return .null
    }
    private static func count(_ value: JSONValue) -> JSONValue {
        guard case .number(let number) = value, number.isFinite, number >= 0, number.rounded() == number else { return .null }
        return value
    }
    static func summary(_ value: JSONValue) -> JSONValue {
        guard case .object = value else { return .null }
        // Reconstruct every field with a type check; even an allowlisted key
        // could otherwise carry a private string from a malformed response.
        return ["configurationError": .bool(!value["configError"].isNull), "catalogError": .bool(!value["catalog"]["error"].isNull),
            "restoreAvailable": boolean(value["restoreAvailable"]),
            "native": ["connected": boolean(value["native"]["connected"]), "running": boolean(value["native"]["running"]),
                "accepting": boolean(value["native"]["accepting"]), "activeRequests": count(value["native"]["activeRequests"]),
                "ownershipError": .bool(!value["native"]["error"].isNull), "healthError": .bool(!value["native"]["healthError"].isNull)],
            "bridge": ["integrated": boolean(value["bridge"]["integrated"]), "running": boolean(value["bridge"]["running"]),
                "busy": boolean(value["bridge"]["busy"])]]
    }
}
