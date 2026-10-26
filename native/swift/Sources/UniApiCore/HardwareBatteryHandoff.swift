import Foundation
import Darwin
import CryptoKit
import CNativeSystem

struct NativeBatteryHandoffFileMetadata {
    var regular: Bool, links: UInt64, owner: UInt32, mode: UInt16, size: Int64, hasACL: Bool
}

enum NativeBatteryHandoffFileRole {
    case executable, plist, journal, report, target(UInt32)
    var limit: Int64 {
        switch self { case .executable: return 256 << 20; case .plist, .journal: return 16 << 10; case .report: return 1 << 20; case .target: return 16 }
    }
    func validate(_ value: NativeBatteryHandoffFileMetadata) throws {
        let uid: UInt32, forbidden: UInt16
        switch self { case .target(let owner): uid = owner; forbidden = 0o077; case .journal: uid = 0; forbidden = 0o077; default: uid = 0; forbidden = 0o022 }
        guard value.regular, value.links == 1, value.owner == uid, value.mode & forbidden == 0,
              !value.hasACL, value.size > 0, value.size <= limit else { throw NativeFailure("Charging handoff file has unsafe ownership, permissions or shape") }
        if case .executable = self { guard value.mode & 0o111 != 0 else { throw NativeFailure("Charging handoff executable is not executable") } }
    }
}

struct NativeBatteryHandoffFile {
    let data: Data, hash: String, stamp: String
    static func read(_ url: URL, role: NativeBatteryHandoffFileRole, optional: Bool = false) throws -> Self? {
        guard url.isFileURL, url.path == url.standardizedFileURL.path, !url.path.contains("\n"), !url.path.contains("\0") else { throw NativeFailure("Invalid charging handoff file path") }
        try NativeBatteryDaemon.validateRootDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if optional && errno == ENOENT { return nil }; throw NativeFailure("Charging handoff file is unavailable") }
        defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0 else { throw NativeFailure("Charging handoff file cannot be inspected") }
        errno = 0; let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), aclCode = errno
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
        try role.validate(.init(regular: before.st_mode & S_IFMT == S_IFREG, links: UInt64(before.st_nlink), owner: before.st_uid, mode: UInt16(before.st_mode & 0o7777), size: before.st_size, hasACL: acl != nil || aclCode != ENOENT))
        var hash = SHA256(), bytes = [UInt8](repeating: 0, count: 65536), total: Int64 = 0, data = Data()
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }; if count == 0 { break }
            guard count > 0, total + Int64(count) <= before.st_size else { throw NativeFailure("Charging handoff file changed while reading") }
            let block = Data(bytes.prefix(count)); hash.update(data: block)
            if case .executable = role {} else { data.append(block) }
            total += Int64(count)
        }
        var after = stat(), path = stat()
        guard total == before.st_size, fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
              stable(before, after), stable(before, path) else { throw NativeFailure("Charging handoff file changed while reading") }
        let digest = NativeHex.encode(hash.finalize())
        let stamp = "\(before.st_dev):\(before.st_ino):\(before.st_uid):\(before.st_mode):\(before.st_size):\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec):\(before.st_ctimespec.tv_sec):\(before.st_ctimespec.tv_nsec):\(digest)"
        return .init(data: data, hash: digest, stamp: stamp)
    }
    static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}

struct NativeBatteryHandoffProcessIdentity: Equatable {
    let pid: Int32, uid: UInt32, birthMicros: UInt64, executable: String
    var token: String { "\(pid):\(uid):\(birthMicros)" }
    var json: JSONValue { ["pid": .number(Double(pid)), "birthMicros": .number(Double(birthMicros)), "instance": .string(token)] }
}

enum NativeBatteryHandoffProcess {
    static func info(_ pid: Int32) throws -> NativeBatteryHandoffProcessIdentity {
        guard pid > 1 else { throw NativeFailure("Invalid charging controller PID") }
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == 0,
              info.pbi_flags & UInt32(PROC_FLAG_SYSTEM) == 0 else { throw NativeFailure("Charging controller root process identity is unavailable") }
        var path = [UInt8](repeating: 0, count: Int(NativeProcPathBufferSize))
        let length = proc_pidpath(pid, &path, UInt32(path.count))
        let executable = length > 0 ? String(data: Data(path.prefix(while: { $0 != 0 })), encoding: .utf8) ?? "" : ""
        return .init(pid: pid, uid: info.pbi_uid, birthMicros: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec, executable: executable)
    }
    static func inspect(_ pid: Int32, binary: URL, directory: URL, admittedInstance: String? = nil) throws -> NativeBatteryHandoffProcessIdentity {
        let first = try info(pid), expected = [binary.path, "daemon", directory.appendingPathComponent("target").path]
        // An overwritten image vnode can lose its path. Only an already admitted
        // PID/birth may use that case; a fresh or unknown process must prove its path.
        guard first.executable == binary.path || first.executable.isEmpty && first.token == admittedInstance else { throw NativeFailure("The loaded charging controller executable is unexpected") }
        var query: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid], length = 0
        guard sysctl(&query, UInt32(query.count), nil, &length, nil, 0) == 0, length > 4, length <= 2 << 20 else { throw NativeFailure("Charging controller arguments are unavailable") }
        var data = [UInt8](repeating: 0, count: length)
        guard sysctl(&query, UInt32(query.count), &data, &length, nil, 0) == 0, length <= data.count else { throw NativeFailure("Charging controller arguments changed") }
        try validateArguments(Data(data.prefix(length)), expected: expected)
        let last = try info(pid)
        guard first == last else { throw NativeFailure("Charging controller instance changed during inspection") }
        return first
    }
    static func validateArguments(_ data: Data, expected: [String]) throws {
        guard data.count > 4 else { throw NativeFailure("Charging controller arguments are invalid") }
        let bytes = Array(data), count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count == expected.count else { throw NativeFailure("Charging controller argument count is unexpected") }
        var cursor = 4
        while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 }
        // Compare each bounded field before exposing anything. Empty argv[0]
        // cannot slide ordinary environment fields into an accepted service argv.
        for value in expected {
            let start = cursor
            while cursor < bytes.count, bytes[cursor] != 0 { cursor += 1 }
            guard cursor < bytes.count, Array(bytes[start..<cursor]) == Array(value.utf8) else { throw NativeFailure("Charging controller arguments are unexpected") }
            cursor += 1
        }
    }
}

public enum NativeBatteryHandoff {
    static func requireRoot() throws { guard geteuid() == 0 else { throw NativeFailure("Charging handoff inspection requires administrator ownership") } }
    public static func clock() -> JSONValue {
        var time = timeval(); gettimeofday(&time, nil)
        return ["micros": .number(Double(UInt64(time.tv_sec) * 1_000_000 + UInt64(time.tv_usec)))]
    }
    public static func files(directory: URL, binary: URL, plist: URL, label: String, owner: UInt32) throws -> JSONValue {
        try requireRoot(); guard owner >= 500 else { throw NativeFailure("Invalid charging target owner") }
        let executable = try NativeBatteryHandoffFile.read(binary, role: .executable)!
        let job = try NativeBatteryHandoffFile.read(plist, role: .plist)!
        let value = JSONValue(any: try PropertyListSerialization.propertyList(from: job.data, options: [], format: nil))
        try validatePlist(value, binary: binary.path, target: directory.appendingPathComponent("target").path, label: label)
        let target = try NativeBatteryHandoffFile.read(directory.appendingPathComponent("target"), role: .target(owner))!
        _ = try NativeBatteryUpgrade.target(target.data)
        let journal = try NativeBatteryHandoffFile.read(directory.appendingPathComponent("preferences.plist"), role: .journal, optional: true)
        _ = try NativeBatteryHandoffFile.read(directory.appendingPathComponent("state.json"), role: .report, optional: true)
        return ["protocol": 2, "binary": .string(executable.stamp), "binarySHA256": .string(executable.hash), "target": .string(target.stamp), "journal": .string(journal?.stamp ?? "absent"), "plist": .string(job.stamp)]
    }
    static func validatePlist(_ value: JSONValue, binary: String, target: String, label: String) throws {
        let allowed: Set<String> = ["Label", "ProgramArguments", "RunAtLoad", "KeepAlive", "ProcessType", "StandardErrorPath"]
        guard Set(value.object.keys).isSubset(of: allowed), value["Label"] == .string(label), value["ProgramArguments"] == .array([binary, "daemon", target].map(JSONValue.string)),
              value["KeepAlive"] == true, value["RunAtLoad"].isNull || value["RunAtLoad"] == true,
              value["ProcessType"].isNull || value["ProcessType"] == "Background" else { throw NativeFailure("The charging launchd definition is not a compatible protected controller job") }
    }
    static func loadedPID(_ text: String, binary: String, target: String, label: String) throws -> Int32 {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first(where: { !$0.isEmpty }) == "system/\(label) = {" else { throw NativeFailure("The loaded charging job label is unexpected") }
        var depth = 0, program: String?, pid: Int32?, args: [String] = [], inArguments = false, argumentBlockSeen = false
        for line in lines {
            if depth == 1 {
                if line.hasPrefix("program = ") { guard program == nil else { throw NativeFailure("The loaded charging job is ambiguous") }; program = String(line.dropFirst(10)) }
                if line.hasPrefix("pid = ") { guard pid == nil, let value = Int32(line.dropFirst(6)), value > 1 else { throw NativeFailure("The loaded charging job has no stable PID") }; pid = value }
                if line == "arguments = {" { guard !argumentBlockSeen else { throw NativeFailure("The loaded charging arguments are ambiguous") }; argumentBlockSeen = true; inArguments = true }
            } else if depth == 2 && inArguments && line != "}" { args.append(line) }
            if depth == 2 && inArguments && line == "}" { inArguments = false }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            guard depth >= 0 else { throw NativeFailure("The loaded charging job format is unsupported") }
        }
        guard depth == 0, program == binary, args == [binary, "daemon", target] else { throw NativeFailure("The loaded charging job executable or arguments are unexpected") }
        return pid ?? 0
    }
    public static func loaded(_ text: String, directory: URL, binary: URL, label: String, admittedInstance: String? = nil) throws -> JSONValue {
        try requireRoot(); try NativeBatteryDaemon.validateRootDirectory(directory)
        let pid = try loadedPID(text, binary: binary.path, target: directory.appendingPathComponent("target").path, label: label)
        if pid == 0 { return ["pid": 0, "birthMicros": 0, "instance": "absent"] }
        return try NativeBatteryHandoffProcess.inspect(pid, binary: binary, directory: directory, admittedInstance: admittedInstance).json
    }
    static func report(_ value: JSONValue, identity: NativeBatteryHandoffProcessIdentity, minimumBirth: UInt64, hash: String, target: Int, legacy: Bool, nowMicros: UInt64) throws {
        func integer(_ value: JSONValue) -> UInt64? { guard case .number(let n) = value, n.isFinite, n >= 0, n.rounded() == n, n < 9_007_199_254_740_992 else { return nil }; return UInt64(n) }
        guard target == 0 || (25...95).contains(target), identity.pid > 1, identity.uid == 0, identity.birthMicros >= minimumBirth,
              integer(value["version"]) == 2, integer(value["pid"]) == UInt64(identity.pid), integer(value["target"]) == UInt64(target),
              let updated = integer(value["updatedAt"]), updated <= nowMicros / 1000 + 1000, value["error"].isNull else { throw NativeFailure("Charging controller acknowledgement is not a fresh owned instance") }
        let floor = legacy && value["runtime"].isNull ? (max(identity.birthMicros, minimumBirth) + 999_999) / 1_000_000 * 1000 : (max(identity.birthMicros, minimumBirth) + 999) / 1000
        guard updated >= floor else { throw NativeFailure("Charging controller acknowledgement predates its instance") }
        if !legacy || !value["runtime"].isNull {
            guard value["runtime"] == "swift", value["binarySHA256"] == .string(hash), UUID(uuidString: value["instanceID"].string) != nil,
                  integer(value["processStartedAtMicros"]) == identity.birthMicros else { throw NativeFailure("Charging controller startup identity is not the expected executable") }
        }
        if target == 0 { guard value["state"] == "off" else { throw NativeFailure("Charging off acknowledgement is incomplete") } }
        else { guard integer(value["nativeLimit"]) == UInt64(target), ["inhibiting", "charging", "on-battery", "telemetry-unavailable"].contains(value["state"].string) else { throw NativeFailure("Native charging policy was not acknowledged") } }
    }
    public static func acknowledgement(directory: URL, binary: URL, pid: Int32, minimumBirth: UInt64, hash: String, target: Int, legacy: Bool) throws -> JSONValue {
        try requireRoot(); let before = try NativeBatteryHandoffProcess.inspect(pid, binary: binary, directory: directory)
        let snapshot = try NativeBatteryHandoffFile.read(directory.appendingPathComponent("state.json"), role: .report)!
        let value = try JSONValue.decode(snapshot.data)
        try report(value, identity: before, minimumBirth: minimumBirth, hash: hash, target: target, legacy: legacy, nowMicros: UInt64(clock()["micros"].double))
        guard before == (try NativeBatteryHandoffProcess.inspect(pid, binary: binary, directory: directory)) else { throw NativeFailure("Charging controller changed while acknowledging") }
        return before.json
    }
}
