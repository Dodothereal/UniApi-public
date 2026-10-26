import Foundation
import AppKit
import Darwin
import CNativeSystem

/// OS adapter only. Tests inject samples and signal functions instead of
/// invoking this adapter, so no real processes or hardware are inspected.
public enum NativeActivitySystem {
    private static func bsd(_ pid: pid_t) -> proc_bsdinfo? {
        var value = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size else { return nil }
        return value
    }
    private static func birth(_ info: proc_bsdinfo) -> String { "\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)" }
    private static func executable(_ pid: pid_t) -> String {
        var bytes = [UInt8](repeating: 0, count: Int(NativeProcPathBufferSize))
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return "" }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    private static func name(_ info: proc_bsdinfo) -> String {
        var copy = info
        let named = withUnsafeBytes(of: &copy.pbi_name) { Array($0.prefix(while: { $0 != 0 })) }
        let fallback = withUnsafeBytes(of: &copy.pbi_comm) { Array($0.prefix(while: { $0 != 0 })) }
        return String(decoding: named.isEmpty ? fallback : named, as: UTF8.self)
    }
    private static func ancestors() -> Set<pid_t> {
        var result: Set<pid_t> = [getpid()], next = getppid()
        for _ in 0..<128 {
            guard next > 1, result.insert(next).inserted, let info = bsd(next) else { break }
            next = pid_t(info.pbi_ppid)
        }
        return result
    }
    static func protection(pid: pid_t, uid: UInt32, path: String, name: String, system: Bool, owner: UInt32, ancestors: Set<pid_t>) -> String? {
        if pid <= 1 || uid != owner || owner == 0 { return "Owned by macOS or another user" }
        if ancestors.contains(pid) { return "Runs this monitor or its app" }
        if path.contains("/UniApi.app/") || ["uniapi-activity", "UniApiNative"].contains(URL(fileURLWithPath: path).lastPathComponent) { return "Runs this monitor" }
        if system || ["loginwindow", "WindowServer", "launchd", "kernel_task", "Dock", "Finder", "SystemUIServer", "ControlCenter"].contains(name) { return "Essential macOS process" }
        return nil
    }
    private static func blocked(_ pid: pid_t, _ info: proc_bsdinfo, _ parents: Set<pid_t>) -> String? {
        protection(pid: pid, uid: info.pbi_uid, path: executable(pid), name: name(info), system: info.pbi_flags & UInt32(PROC_FLAG_SYSTEM) != 0, owner: getuid(), ancestors: parents)
    }
    public static func sample() async throws -> JSONValue {
        var result = try await Task.detached(priority: .utility) { try rawSample() }.value
        result["apps"] = await MainActor.run {
            .array(NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy != .prohibited, !app.isTerminated, let url = app.bundleURL else { return nil }
                if app.activationPolicy == .accessory && (url.path.hasPrefix("/System/") || url.path.contains(".app/Contents/") || url.pathExtension.lowercased() != "app") { return nil }
                return ["pid": .number(Double(app.processIdentifier)), "name": .string(app.localizedName ?? "Application"), "bundlePath": .string(url.path), "bundleId": .string(app.bundleIdentifier ?? "")]
            })
        }
        return result
    }
    private static func rawSample() throws -> JSONValue {
        let capacity = proc_listallpids(nil, 0) + 1024
        guard capacity > 1024 else { throw NativeFailure("macOS did not return its process list") }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var timebase = mach_timebase_info_data_t()
        let hasTimebase = mach_timebase_info(&timebase) == KERN_SUCCESS && timebase.denom != 0
        let parents = ancestors()
        var rows: [JSONValue] = [], omitted = 0
        for pid in pids.prefix(max(0, min(Int(count), pids.count))) where pid > 0 && pid != getpid() {
            guard let before = bsd(pid) else { omitted += 1; continue }
            let path = executable(pid)
            var task = proc_taskinfo(), usage = rusage_info_v2()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
            let hasUsage = withUnsafeMutablePointer(to: &usage) { $0.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0 } }
            guard let after = bsd(pid), birth(before) == birth(after), before.pbi_uid == after.pbi_uid else { omitted += 1; continue }
            let cpu = hasTask && hasTimebase ? NativeActivityFold.ticksToNanoseconds(user: task.pti_total_user, system: task.pti_total_system, numerator: timebase.numer, denominator: timebase.denom) : nil
            let memory = hasUsage ? JSONValue.number(Double(usage.ri_phys_footprint)) : hasTask ? .number(Double(task.pti_resident_size)) : .null
            rows.append(["pid": .number(Double(pid)), "ppid": .number(Double(before.pbi_ppid)), "uid": .number(Double(before.pbi_uid)), "started": .string(birth(before)), "name": .string(name(before)), "path": .string(path), "cpuNs": cpu.map { .string(String($0)) } ?? .null, "memoryBytes": memory, "memoryKind": .string(hasUsage ? "footprint" : hasTask ? "resident" : "unavailable"), "threads": hasTask ? .number(Double(task.pti_threadnum)) : .null, "readBytes": hasUsage ? .number(Double(usage.ri_diskio_bytesread)) : .null, "writeBytes": hasUsage ? .number(Double(usage.ri_diskio_byteswritten)) : .null, "protectedReason": blocked(pid, before, parents).map(JSONValue.string) ?? .null])
        }
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var cpu = host_cpu_load_info_data_t(), vm = vm_statistics64_data_t(), page: vm_size_t = 0
        var cpuCount = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let hasCPU = withUnsafeMutablePointer(to: &cpu) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(cpuCount)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &cpuCount) == KERN_SUCCESS } }
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let hasVM = withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(host, HOST_VM_INFO64, $0, &vmCount) == KERN_SUCCESS } }
        host_page_size(host, &page)
        let total = ProcessInfo.processInfo.physicalMemory
        let usedPages = Int64(vm.active_count) + Int64(vm.inactive_count) + Int64(vm.wire_count) + Int64(vm.compressor_page_count) - Int64(vm.purgeable_count) - Int64(vm.external_page_count)
        let used = min(total, UInt64(max(0, usedPages)) * UInt64(page))
        var swap = xsw_usage(), swapSize = MemoryLayout<xsw_usage>.size
        let hasSwap = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0
        var pressure: UInt64 = 0, pressureSize = MemoryLayout<UInt64>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &pressureSize, nil, 0)
        let ticks = withUnsafeBytes(of: &cpu.cpu_ticks) { Array($0.bindMemory(to: UInt32.self)).map { JSONValue.number(Double($0)) } }
        return ["timestamp": .number(Date().timeIntervalSince1970 * 1000), "monotonic": .number(ProcessInfo.processInfo.systemUptime), "logicalCpus": .number(Double(max(1, ProcessInfo.processInfo.activeProcessorCount))), "totalMemory": .number(Double(total)), "cpuTicks": hasCPU ? .array(ticks) : .null, "memoryUsed": hasVM ? .number(Double(used)) : .null, "compressedBytes": hasVM ? .number(Double(UInt64(vm.compressor_page_count) * UInt64(page))) : .null, "swapUsed": hasSwap ? .number(Double(swap.xsu_used)) : .null, "pressure": .string(pressure == 1 ? "normal" : pressure == 2 ? "warning" : pressure == 4 ? "critical" : "unknown"), "processes": .array(rows), "apps": [], "omitted": .number(Double(omitted))]
    }
    public static func terminate(_ request: JSONValue) async throws -> JSONValue {
        guard ["quit", "force"].contains(request["mode"].string), (1...2048).contains(request["targets"].array.count) else { throw NativeFailure("Invalid termination request") }
        let parents = ancestors()
        var validated: [(pid_t, String)] = [], gone = 0
        for target in request["targets"].array {
            guard let rawPID = NativeHardwarePolicies.number(target["pid"]), rawPID >= 2, rawPID <= Double(Int32.max), rawPID.rounded() == rawPID, case .string(let started) = target["started"] else { throw NativeFailure("Invalid process identity") }
            let pid = pid_t(rawPID)
            guard let info = bsd(pid) else { gone += 1; continue }
            guard birth(info) == started else { throw NativeFailure("A process restarted; refresh before trying again") }
            if let reason = blocked(pid, info, parents) { throw NativeFailure(reason) }
            validated.append((pid, started))
        }
        var failed: [JSONValue] = [], requested = 0
        for (pid, started) in validated {
            guard let info = bsd(pid) else { gone += 1; continue }
            guard birth(info) == started, blocked(pid, info, parents) == nil else { failed.append(["pid": .number(Double(pid)), "reason": "Process identity or permissions changed"]); continue }
            let accepted: Bool
            if request["application"].bool && request["mode"].string == "quit" { accepted = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.terminate() == true } }
            else { accepted = kill(pid, request["mode"].string == "force" ? SIGKILL : SIGTERM) == 0 }
            if accepted { requested += 1 } else { failed.append(["pid": .number(Double(pid)), "reason": "macOS refused the request or the process exited"]) }
        }
        return ["ok": .bool(failed.isEmpty), "requested": .number(Double(requested)), "gone": .number(Double(gone)), "failed": .array(failed)]
    }
}
