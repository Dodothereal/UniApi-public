import Foundation
import Darwin
import UniApiCore

/// Standalone Swift shim. No launchd or app lifecycle is changed by building it.
@main enum NativeShimCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
    private static func run(_ original: [String]) async throws {
        var arguments = original, paths = NativePaths.discover(), port = 8823
        func option(_ key: String) throws -> String? {
            guard let index = arguments.firstIndex(of: key) else { return nil }
            guard index + 1 < arguments.count else { throw NativeFailure("Missing option value") }
            let result = arguments[index + 1]; arguments.removeSubrange(index...index + 1); return result
        }
        let root = try option("--root"), home = try option("--home")
        if root != nil || home != nil {
            let env = ProcessInfo.processInfo.environment
            paths = NativePaths(root: root.map { URL(fileURLWithPath: $0) } ?? paths.root,
                                home: home.map { URL(fileURLWithPath: $0) } ?? paths.home, readOnly: paths.readOnly,
                                dataRoot: env["UNIAPI_DATA"] == nil ? nil : paths.data,
                                providersFile: env["UNIAPI_PROVIDERS"] == nil ? nil : paths.providers)
        }
        if let value = try option("--port") { guard let parsed = Int(value), (1024...65535).contains(parsed) else { throw NativeFailure("Invalid shim port") }; port = parsed }
        let store = NativeProviderStore(paths: paths), operations = NativeProviderOperations(store: store, port: port)
        var result: JSONValue?
        if arguments.first == "--list" { result = .array(try store.list().map { NativeProviderInfo(.object($0)).publicValue(port: port) }) }
        else if arguments.first == "--register-web" { guard arguments.count == 1 else { throw NativeFailure("Unexpected arguments") }; result = try await operations.handle("registerWeb") }
        else if arguments.first == "--add" { guard arguments.count == 4 else { throw NativeFailure("Use --add name URL key") }; result = try await operations.handle("add", input: ["name": .string(arguments[1]), "url": .string(arguments[2]), "key": .string(arguments[3])]) }
        else if let first = arguments.first, ["--adopt", "--refresh", "--remove", "--unregister-codex"].contains(first) { guard arguments.count == 2 else { throw NativeFailure("Provide one provider ID") }; let operation = first == "--unregister-codex" ? "unregisterResponses" : String(first.dropFirst(2)); result = try await operations.handle(operation, input: ["id": .string(arguments[1])]) }
        else if arguments.first == "--set-model" { guard arguments.count == 3 else { throw NativeFailure("Use --set-model provider model") }; result = try await operations.handle("model", input: ["id": .string(arguments[1]), "model": .string(arguments[2])]) }
        else if arguments.first == "--register-codex" { guard arguments.count == 2 || arguments.count == 3 else { throw NativeFailure("Use --register-codex provider [model]") }; var input: JSONObject = ["id": .string(arguments[1])]; if arguments.count == 3 { input["model"] = .string(arguments[2]) }; result = try await operations.handle("registerResponses", input: input) }
        else if arguments.first == "--detect" { guard arguments.count == 3 else { throw NativeFailure("Use --detect URL key") }; result = try await operations.detect(base: arguments[1], key: arguments[2]) }
        else {
            guard arguments.isEmpty || arguments == ["--serve"] else { throw NativeFailure("Unknown shim command") }
            let server = try NativeShimServer(paths: paths, port: port); try await server.start()
            print("Native Swift shim listening on 127.0.0.1:\(port)")
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main), terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = ShimCLIStop(continuation)
                interrupt.setEventHandler { once.finish() }; terminate.setEventHandler { once.finish() }; interrupt.resume(); terminate.resume()
            }
            interrupt.cancel(); terminate.cancel(); await server.shutdown(); return
        }
        if let result { FileHandle.standardOutput.write(try result.encoded(pretty: true) + Data("\n".utf8)) }
    }
}
private final class ShimCLIStop: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func finish() { lock.lock(); let continuation = continuation; self.continuation = nil; lock.unlock(); continuation?.resume() }
}
