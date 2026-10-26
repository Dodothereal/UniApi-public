import Foundation
import IOKit
import Darwin
import CNativeSystem

public enum NativeBatteryDaemonPolicy {
    public static func target(_ data: Data) -> Int {
        guard !data.isEmpty, data.count <= 16, !data.contains(0) else { return 0 }
        var bytes = Array(data)
        while let last = bytes.last, last == 10 || last == 13 { bytes.removeLast() }
        guard bytes.count == 2, bytes.allSatisfy({ (48...57).contains($0) }) else { return 0 }
        let value = Int(bytes[0] - 48) * 10 + Int(bytes[1] - 48)
        return (25...95).contains(value) ? value : 0
    }
    public static func phase(target: Int, nativeLimit: Int, battery: JSONValue, accepted: Bool, restoring: Bool) -> String {
        if !accepted { return restoring ? "pending" : "write-refused" }
        if target == 0 { return "off" }
        if nativeLimit != target { return "pending" }
        if battery.isNull { return "telemetry-unavailable" }
        if !battery["externalConnected"].bool { return "on-battery" }
        return battery["percent"].int >= target ? "inhibiting" : "charging"
    }
}

public struct NativeBatteryDaemonIO: Sendable {
    public var target: @Sendable () throws -> Data
    public var apply: @Sendable (Int) throws -> Void
    public var pending: @Sendable () -> Bool
    public var nativeLimit: @Sendable () throws -> Int
    public var battery: @Sendable () throws -> JSONValue
    public var report: @Sendable (JSONValue) throws -> Void
    public var now: @Sendable () -> Double
    public init(target: @escaping @Sendable () throws -> Data, apply: @escaping @Sendable (Int) throws -> Void, pending: @escaping @Sendable () -> Bool, nativeLimit: @escaping @Sendable () throws -> Int, battery: @escaping @Sendable () throws -> JSONValue, report: @escaping @Sendable (JSONValue) throws -> Void, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) {
        self.target = target; self.apply = apply; self.pending = pending; self.nativeLimit = nativeLimit; self.battery = battery; self.report = report; self.now = now
    }
}

public final class NativeBatteryDaemon: @unchecked Sendable {
    private let io: NativeBatteryDaemonIO
    private let diagnostics: JSONValue
    private let binaryIdentity: String?
    private let processStartedAtMicros: UInt64?, instanceID: String
    private let handoffInProgress: @Sendable () -> Bool
    private var awaitingAdoptionReport: Bool
    public init(io: NativeBatteryDaemonIO, diagnostics: JSONValue = [], binaryIdentity: String? = nil,
                processStartedAtMicros: UInt64? = nil, instanceID: String = UUID().uuidString,
                adoptingExistingPolicy: Bool = false, handoffInProgress: @escaping @Sendable () -> Bool = { false }) {
        self.io = io; self.diagnostics = diagnostics; self.binaryIdentity = binaryIdentity
        self.processStartedAtMicros = processStartedAtMicros; self.instanceID = instanceID
        awaitingAdoptionReport = adoptingExistingPolicy; self.handoffInProgress = handoffInProgress
    }
    @discardableResult public func tick() throws -> JSONValue {
        // Only the explicit off command can retire a lease. A missing, changing
        // or malformed target is an observation failure, including before the
        // replacement has published its first readiness report.
        let target = try NativeBatteryUpgrade.target(io.target())
        let battery = (try? io.battery()) ?? .null
        var accepted = false, failure: JSONValue = .null
        do { try io.apply(target); accepted = true } catch { failure = .string(error.localizedDescription) }
        let native = target == 0 ? 0 : (try? io.nativeLimit()) ?? -1
        let phase = NativeBatteryDaemonPolicy.phase(target: target, nativeLimit: native, battery: battery, accepted: accepted, restoring: io.pending())
        var state: JSONValue = ["version": 2, "pid": .number(Double(getpid())), "updatedAt": .number(io.now().rounded(.down)), "target": .number(Double(target)), "floor": 0, "state": .string(phase), "backend": "PowerUI preferences", "nativeLimit": .number(Double(native)), "diagnostics": diagnostics]
        state["runtime"] = "swift"
        state["instanceID"] = .string(instanceID)
        if let processStartedAtMicros { state["processStartedAtMicros"] = .number(Double(processStartedAtMicros)) }
        if let binaryIdentity { state["binarySHA256"] = .string(binaryIdentity) }
        if !failure.isNull { state["error"] = failure }
        if !battery.isNull { var b = battery; b["external"] = b["externalConnected"]; state["battery"] = b }
        do {
            try io.report(state)
            // Publishing a pending/refused report is not acknowledgement of the
            // adopted native policy. Keep that lease protected until ready.
            if accepted && (target == 0 || native == target) { awaitingAdoptionReport = false }
        }
        catch {
            // A replacement has not acquired the old transaction merely by
            // starting. Failed readiness must leave its adopted baseline and
            // journal intact for executable-only rollback.
            if !awaitingAdoptionReport && !handoffInProgress() { try? io.apply(0) }
            throw error
        }
        return state
    }
    public func restore() throws {
        var accepted = false, failure: JSONValue = .null
        do { try io.apply(0); accepted = true } catch { failure = .string(error.localizedDescription) }
        var result: JSONValue = ["version": 2, "pid": .number(Double(getpid())), "updatedAt": .number(io.now().rounded(.down)), "target": 0, "floor": 0, "state": .string(accepted ? "off" : io.pending() ? "pending" : "write-refused")]
        result["runtime"] = "swift"; result["instanceID"] = .string(instanceID)
        if let binaryIdentity { result["binarySHA256"] = .string(binaryIdentity) }
        if let processStartedAtMicros { result["processStartedAtMicros"] = .number(Double(processStartedAtMicros)) }
        if !failure.isNull { result["error"] = failure }
        try io.report(result)
        if !accepted { throw NativeFailure("Native charging restoration remains pending; journal retained") }
    }
    public static func production(directory: URL) throws -> NativeBatteryDaemon {
        guard geteuid() == 0 else { throw NativeFailure("The charging daemon requires administrator ownership") }
        try validateRootDirectory(directory)
        let preferences = NativeBatteryPreferences(directory: directory, io: .production())
        let target = directory.appendingPathComponent("target"), state = directory.appendingPathComponent("state.json")
        let adoption = try preferences.existingTarget() != nil
        return NativeBatteryDaemon(io: .init(target: {
            let fd = open(target.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw NativeFailure("Charging target is unavailable; existing policy preserved") }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size > 0, info.st_size <= 16, info.st_mode & 0o077 == 0, info.st_uid == 0 || info.st_uid >= 500 else { throw NativeFailure("Charging target has unsafe ownership or shape; existing policy preserved") }
            errno = 0; let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), code = errno
            if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl == nil, code == ENOENT else { throw NativeFailure("Charging target has an extended ACL; existing policy preserved") }
            var bytes = [UInt8](repeating: 0, count: 17)
            let length = read(fd, &bytes, bytes.count)
            var after = stat(), path = stat()
            guard length == info.st_size, fstat(fd, &after) == 0, lstat(target.path, &path) == 0,
                  NativeBatteryHandoffFile.stable(info, after), NativeBatteryHandoffFile.stable(info, path) else { throw NativeFailure("Charging target changed while reading; existing policy preserved") }
            return Data(bytes.prefix(length))
        }, apply: { try preferences.apply($0) }, pending: { preferences.pending }, nativeLimit: { try NativePowerUIClient().state()["limit"].int }, battery: { try NativeBatterySystem.snapshot() }, report: { try NativeFile.writeAtomic(try $0.encoded(), to: state, permissions: 0o644) }), diagnostics: NativeBatteryDiagnostics.read(), binaryIdentity: try NativeBatteryExecutable.identity(), processStartedAtMicros: try NativeBatteryHandoffProcess.info(getpid()).birthMicros, adoptingExistingPolicy: adoption, handoffInProgress: {
            let marker = directory.appendingPathComponent(".upgrade-lock")
            var info = stat()
            guard lstat(marker.path, &info) == 0 else { return errno != ENOENT }
            // A malformed root transaction marker also preserves policy on
            // report failure; it cannot justify retiring somebody else's lease.
            return true
        })
    }
    static func validateRootDirectory(_ directory: URL) throws {
        var path = directory.standardizedFileURL
        while path.path != "/" {
            var info = stat()
            guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == 0, info.st_mode & 0o022 == 0 else { throw NativeFailure("Charging state ancestry must be root-owned without links or group/world write") }
            let fd = open(path.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NativeFailure("Charging state directory could not be opened") }
            errno = 0
            let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), code = errno
            if let acl { acl_free(UnsafeMutableRawPointer(acl)) }; close(fd)
            guard acl == nil, code == ENOENT else { throw NativeFailure("Charging state ancestry must have no extended ACL") }
            path.deleteLastPathComponent()
        }
    }
}

public enum NativeBatteryDiagnostics {
    /// Read-only SMC diagnostics use explicit byte offsets of the 80-byte
    /// kernel ABI. No diagnostic path exposes a write opcode or arbitrary key.
    public static func read() -> JSONValue {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return [] }
        defer { IOServiceClose(connection) }
        let keys = [("bfD0", 4), ("bfE0", 4), ("bfF0", 1), ("CH0B", 1), ("CH0C", 1), ("CHTE", 4), ("CHIE", 1)]
        return .array(keys.map { key, count in
            var result: JSONValue = ["key": .string(key)]
            for (name, opcode) in [("metadata", UInt8(9)), ("read", UInt8(5))] {
                var input = [UInt8](repeating: 0, count: 80), output = [UInt8](repeating: 0, count: 80), size = 80
                var code = key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }.littleEndian
                withUnsafeBytes(of: &code) { input.replaceSubrange(0..<4, with: $0) }
                var length = UInt32(count).littleEndian
                withUnsafeBytes(of: &length) { input.replaceSubrange(28..<32, with: $0) }
                input[42] = opcode
                let kr = input.withUnsafeBytes { source in output.withUnsafeMutableBytes { dest in IOConnectCallStructMethod(connection, 2, source.baseAddress, 80, dest.baseAddress, &size) } }
                result[name + "Result"] = .number(Double(kr)); result[name + "SMCResult"] = .number(Double(output[40]))
                if opcode == 5, kr == KERN_SUCCESS, output[40] == 0 { result["bytes"] = .array(output[48..<(48 + count)].map { .number(Double($0)) }) }
            }
            return result
        })
    }
}
