import Foundation
import Darwin

public final class NativeProviderStore: @unchecked Sendable {
    private let paths: NativePaths
    private let lock = NSLock()
    public init(paths: NativePaths) { self.paths = paths }
    public func seedIfAbsent(example: URL? = nil) throws {
        guard !paths.readOnly else { return }
        lock.lock(); defer { lock.unlock() }
        let lockURL = paths.providers.appendingPathExtension("lock")
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw NativeFailure("Provider file lock unavailable") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw NativeFailure("Cannot lock provider initialization") }
        var info = stat()
        if lstat(paths.providers.path, &info) == 0 { _ = try document(); return }
        guard errno == ENOENT else { throw NativeFailure("Provider configuration could not be inspected") }
        let value = try example.map { try NativeFile.readJSON($0) } ?? JSONValue.object(["providers": []])
        guard case .object(let document) = value else { throw NativeFailure("Provider example must be a JSON object") }
        try Self.validate(document)
        let directory = paths.providers.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".providers-seed-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try NativeFile.writeAtomic(try value.encoded(pretty: true), to: temporary)
        // link publishes a complete file only if no other writer won the path;
        // unlike rename it cannot replace a newly-created user configuration.
        if link(temporary.path, paths.providers.path) != 0 && errno != EEXIST { throw NativeFailure("Provider configuration could not be initialized") }
        try FileManager.default.removeItem(at: temporary)
        let folder = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if folder >= 0 { _ = fsync(folder); close(folder) }
        _ = try self.document()
    }
    public func document() throws -> JSONObject {
        let value = try NativeFile.readJSON(paths.providers)
        guard case .object(let document) = value else { throw NativeFailure("Provider configuration must be a JSON object") }
        try Self.validate(document)
        return document
    }
    public func list() throws -> [JSONObject] { try document()["providers"]!.array.map(\.object) }
    public func mutate(_ body: (inout JSONObject) throws -> Void) throws {
        try paths.assertWritable()
        lock.lock(); defer { lock.unlock() }
        let lockURL = paths.providers.appendingPathExtension("lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw NativeFailure("Provider file lock unavailable") }
        defer { flock(fd, LOCK_UN); close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NativeFailure("Cannot lock provider file") }
        let original = try Data(contentsOf: paths.providers)
        let decoded = try JSONValue.decode(original)
        guard case .object(var d) = decoded else { throw NativeFailure("Provider configuration must be a JSON object") }
        try Self.validate(d)
        try body(&d)
        try Self.validate(d)
        guard try Data(contentsOf: paths.providers) == original else { throw NativeFailure("Provider configuration changed externally; reload before saving") }
        try NativeFile.writeAtomic(try JSONValue.object(d).encoded(pretty: true), to: paths.providers)
    }
    private static func validate(_ document: JSONObject) throws {
        guard let value = document["providers"], case .array(let rows) = value else { throw NativeFailure("Provider configuration must contain a providers array") }
        var identifiers = Set<String>()
        for row in rows {
            guard case .object = row, case .string(let id) = row["id"], !id.isEmpty, identifiers.insert(id).inserted else { throw NativeFailure("Provider identifiers must be nonempty unique strings") }
            if row["transport"].string == "chatgpt-web" {
                guard row["api_key"].isNull, row["proxy"].isNull, row["codex"].isNull else { throw NativeFailure("Browser providers must contain credential references only") }
            }
        }
    }
}
