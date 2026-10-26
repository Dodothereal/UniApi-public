import Foundation
import Darwin

public enum NativeHealth {
    public static let instance = ProcessInfo.processInfo.environment["UNIAPI_NATIVE_INSTALL_NONCE"].flatMap(UUID.init(uuidString:))?.uuidString ?? UUID().uuidString
    public static func write(paths: NativePaths, ready: Bool, error: String? = nil, instance: String = NativeHealth.instance) throws {
        try paths.assertWritable()
        guard UUID(uuidString: instance) != nil else { throw NativeFailure("Invalid native startup identity") }
        let value: JSONValue = ["schema": 2, "runtime": "swift", "instance": .string(instance), "pid": .number(Double(getpid())), "ready": .bool(ready), "updatedAt": .number(Date().timeIntervalSince1970 * 1000), "error": error.map { .string(String($0.prefix(500))) } ?? .null]
        try NativeFile.writeAtomic(try value.encoded(), to: paths.data.appendingPathComponent("native-status.json"))
    }
    public static func read(paths: NativePaths, expectedPID: Int32, expectedInstance: String) throws -> JSONValue {
        guard expectedPID > 1, UUID(uuidString: expectedInstance) != nil else { throw NativeFailure("Invalid native background identity") }
        let value = try JSONValue.decode(SwitcherDisk.read(paths.data.appendingPathComponent("native-status.json"), limit: 65536))
        guard value["schema"] == 2, value["runtime"] == "swift", value["instance"].string == expectedInstance, value["pid"].int == Int(expectedPID), value["ready"].bool, kill(expectedPID, 0) == 0 else { throw NativeFailure("Native background startup is not confirmed") }
        return value
    }
    public static func shim(expectedPID: Int32, expectedInstance: String, get: (@Sendable () async throws -> JSONValue)? = nil) async throws -> JSONValue {
        guard expectedPID > 1, UUID(uuidString: expectedInstance) != nil else { throw NativeFailure("Invalid native shim identity") }
        let value: JSONValue
        if let get { value = try await get() }
        else {
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 2
            config.httpCookieStorage = nil; config.urlCredentialStorage = nil
            let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:8823/healthz")!)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536 else { throw NativeFailure("Native shim startup is not confirmed") }
            value = try JSONValue.decode(data)
        }
        guard value["ok"].bool, value["service"] == "uniapi-shim", value["runtime"] == "swift", value["instance"].string == expectedInstance, value["pid"].int == Int(expectedPID), kill(expectedPID, 0) == 0 else { throw NativeFailure("Native shim startup is not confirmed") }
        return value
    }
}
