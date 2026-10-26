import Foundation
import CoreFoundation
import Darwin
import CNativeSystem

public struct NativeBatteryPreferenceIO: Sendable {
    public var read: @Sendable (String, String, String) throws -> JSONValue
    public var write: @Sendable (String, String, String, JSONValue) throws -> Void
    public var synchronize: @Sendable (String, String) throws -> Void
    public var notify: @Sendable () throws -> Void
    public var nativeLimit: @Sendable () throws -> Int
    public init(read: @escaping @Sendable (String, String, String) throws -> JSONValue, write: @escaping @Sendable (String, String, String, JSONValue) throws -> Void, synchronize: @escaping @Sendable (String, String) throws -> Void, notify: @escaping @Sendable () throws -> Void, nativeLimit: @escaping @Sendable () throws -> Int) {
        self.read = read; self.write = write; self.synchronize = synchronize; self.notify = notify; self.nativeLimit = nativeLimit
    }
    public static func production() -> NativeBatteryPreferenceIO {
        let domain = "com.apple.smartcharging.topoffprotection" as CFString
        let user: @Sendable (String) -> CFString = { $0 == "any" ? kCFPreferencesAnyUser : kCFPreferencesCurrentUser }
        let host: @Sendable (String) -> CFString = { $0 == "current" ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost }
        return .init(read: { key, u, h in JSONValue(any: CFPreferencesCopyValue(key as CFString, domain, user(u), host(h))) }, write: { key, u, h, value in
            CFPreferencesSetValue(key as CFString, value.isNull ? nil : value.any as CFPropertyList, domain, user(u), host(h))
        }, synchronize: { u, h in guard CFPreferencesSynchronize(domain, user(u), host(h)) else { throw NativeFailure("Native charging preferences could not synchronize") } }, notify: {
            guard notify_post("com.apple.smartcharging.defaultschanged") == NOTIFY_STATUS_OK else { throw NativeFailure("The native charging service could not be notified") }
        }, nativeLimit: { try NativePowerUIClient().state()["limit"].int })
    }
}

/// The journal is published before a preference write. Only values that still
/// equal the helper's installed values or original values can be restored.
public final class NativeBatteryPreferences: @unchecked Sendable {
    private let directory: URL
    private let io: NativeBatteryPreferenceIO
    private let lock = NSLock()
    public private(set) var pending = false
    private let keys = ["mclLimitValue", "MCLFeatureState"]
    private var journalURL: URL { directory.appendingPathComponent("preferences.plist") }
    public init(directory: URL, io: NativeBatteryPreferenceIO) { self.directory = directory; self.io = io }
    private func load() throws -> JSONValue? {
        let fd = open(journalURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }; throw NativeFailure("Native charging restoration journal could not be opened")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 16384 else { throw NativeFailure("Native charging restoration journal has unsafe ownership or shape") }
        errno = 0
        let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), aclCode = errno
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl == nil, aclCode == ENOENT else { throw NativeFailure("Native charging restoration journal has an extended ACL") }
        let data = try handle.read(upToCount: 16385) ?? Data()
        var after = stat(), path = stat()
        guard data.count == info.st_size, fstat(fd, &after) == 0, lstat(journalURL.path, &path) == 0,
              NativeBatteryHandoffFile.stable(info, after), NativeBatteryHandoffFile.stable(info, path) else { throw NativeFailure("Native charging restoration journal changed while reading") }
        let raw = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let value = JSONValue(any: raw)
        guard case .object = value["old"], ["any", "current"].contains(value["user"].string), ["any", "current"].contains(value["host"].string), let target = NativeHardwarePolicies.number(value["target"]), target.rounded() == target, (25...95).contains(target), let original = NativeHardwarePolicies.number(value["nativeLimit"]), original.rounded() == original, (1...100).contains(original) else { throw NativeFailure("Native charging restoration journal is invalid") }
        return value
    }
    private func save(_ value: JSONValue) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: value.any, format: .binary, options: 0)
        try NativeFile.writeAtomic(data, to: journalURL)
    }
    private func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if a.isNull || b.isNull { return a.isNull && b.isNull }
        return (a.any as? NSObject)?.isEqual(b.any) == true
    }
    /// Startup only observes the previous lease; it does not acquire or retire it.
    func existingTarget() throws -> Int? { try lock.withLock { try load()?["target"].int } }
    /// Admission for an executable-only controller handoff. It deliberately
    /// never restores, writes or retires the current native transaction.
    public func validateHandoff(target: Int) throws -> JSONValue {
        try lock.withLock {
            guard target == 0 || (25...95).contains(target) else { throw NativeFailure("Invalid charging handoff target") }
            let journal = try load()
            if target == 0 {
                guard journal == nil else { throw NativeFailure("Charging restoration must finish before an off-target handoff") }
                return ["compatible": true, "target": 0, "journal": false]
            }
            guard let journal, journal["target"].int == target,
                  equal(try io.read("mclLimitValue", journal["user"].string, journal["host"].string), .number(Double(target))),
                  equal(try io.read("MCLFeatureState", journal["user"].string, journal["host"].string), 1),
                  try io.nativeLimit() == target else { throw NativeFailure("Charging target and journal are not a confirmed compatible transaction; controller preserved") }
            return ["compatible": true, "target": .number(Double(target)), "journal": true, "nativeLimit": .number(Double(target))]
        }
    }
    private func restore(_ journal: JSONValue) throws {
        let u = journal["user"].string, h = journal["host"].string
        var changed = false
        for key in keys {
            let current = try io.read(key, u, h), old = journal["old"][key]
            let owned = key == "mclLimitValue" ? journal["target"] : JSONValue.number(1)
            let original = equal(current, old)
            guard equal(current, owned) || original else { throw NativeFailure("Another charging utility changed the native preferences; its edit will be preserved") }
            changed = changed || !original
        }
        if changed { for key in keys { try io.write(key, u, h, journal["old"][key]) } }
        try io.synchronize(u, h)
        let currentLimit = try io.nativeLimit()
        if changed || currentLimit != journal["nativeLimit"].int { try io.notify() }
        guard try io.nativeLimit() == journal["nativeLimit"].int else { pending = true; throw NativeFailure("Waiting for native charging restoration acknowledgment") }
        try FileManager.default.removeItem(at: journalURL)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
    }
    public func apply(_ target: Int) throws {
        lock.lock(); defer { lock.unlock() }
        pending = false
        guard target == 0 || (25...95).contains(target) else { throw NativeFailure("Invalid native charging target") }
        let journal = try load()
        if target == 0 { if let journal { try restore(journal) }; return }
        if let journal {
            let u = journal["user"].string, h = journal["host"].string
            if journal["target"].int == target, equal(try io.read("mclLimitValue", u, h), .number(Double(target))), equal(try io.read("MCLFeatureState", u, h), 1) {
                if try io.nativeLimit() != target { try io.notify() }; return
            }
            try restore(journal)
        }
        var selected: JSONValue?
        for u in ["current", "any"] {
            for h in ["any", "current"] {
                guard let level = NativeHardwarePolicies.number(try io.read("mclLimitValue", u, h)), level.rounded() == level, (25...100).contains(level) else { continue }
                var old: JSONObject = [:]
                for key in keys { let value = try io.read(key, u, h); if !value.isNull { old[key] = value } }
                selected = ["user": .string(u), "host": .string(h), "target": .number(Double(target)), "old": .object(old)]
                break
            }
            if selected != nil { break }
        }
        guard var selected else { throw NativeFailure("No recognized native MCL preference store was found") }
        let original = try io.nativeLimit()
        guard (1...100).contains(original) else { throw NativeFailure("The original native charge limit is unavailable") }
        selected["nativeLimit"] = .number(Double(original))
        try save(selected)
        let u = selected["user"].string, h = selected["host"].string
        try io.write("mclLimitValue", u, h, .number(Double(target)))
        try io.write("MCLFeatureState", u, h, 1)
        do { try io.synchronize(u, h) } catch { try? restore(selected); throw error }
        try io.notify()
    }
}
