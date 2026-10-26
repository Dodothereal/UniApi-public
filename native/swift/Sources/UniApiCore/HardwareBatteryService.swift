import Foundation
import Darwin
import CNativeSystem

private actor NativeBatteryClientOwner {
    private var client: NativePowerUIClient?
    func call(_ command: String, _ target: Int?) throws -> JSONValue {
        if client == nil { client = try NativePowerUIClient() }
        switch command { case "state": return try client!.state(); case "set": return try client!.set(target!); case "off": return try client!.off(); case "enable": return try client!.enable(); default: throw NativeFailure("Unknown native charging operation") }
    }
}

public struct NativeBatteryIO: Sendable {
    public var call: @Sendable (String, Int?) async throws -> JSONValue
    public var hold: @Sendable () throws -> (installed: Bool, target: Data, report: JSONValue)
    public var writeTarget: @Sendable (Int) throws -> Void
    public var install: @Sendable () async throws -> Void
    public var now: @Sendable () -> Double
    public var sleep: @Sendable (Double) async throws -> Void
    public var policy: @Sendable () async throws -> JSONValue
    public var monotonic: @Sendable () -> Double
    public init(call: @escaping @Sendable (String, Int?) async throws -> JSONValue, hold: @escaping @Sendable () throws -> (installed: Bool, target: Data, report: JSONValue), writeTarget: @escaping @Sendable (Int) throws -> Void, install: @escaping @Sendable () async throws -> Void, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }, sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }, policy: @escaping @Sendable () async throws -> JSONValue = { .null }, monotonic: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.call = call; self.hold = hold; self.writeTarget = writeTarget; self.install = install; self.now = now; self.sleep = sleep; self.policy = policy; self.monotonic = monotonic
    }
    public static func production(runtime: NativeRuntime) -> NativeBatteryIO {
        let locations = NativeHardwareLocations(paths: runtime.paths), owner = NativeBatteryClientOwner()
        return .init(call: { try await owner.call($0, $1) }, hold: {
            let installed = FileManager.default.fileExists(atPath: locations.batteryTarget.path)
            return (installed, (try? Data(contentsOf: locations.batteryTarget)) ?? Data(), (try? NativeFile.readJSON(locations.batteryState)) ?? .null)
        }, writeTarget: { value in
            let fd = open(locations.batteryTarget.path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw NativeFailure("Install the charging helper before selecting a lower target") }; defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size <= 16 else { throw NativeFailure("The charging target inode has unsafe ownership or shape") }
            errno = 0; let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), code = errno
            if let acl { acl_free(UnsafeMutableRawPointer(acl)) }
            guard acl == nil, code == ENOENT else { throw NativeFailure("The charging target has extended access controls") }
            let bytes = Data((value == 0 ? "off\n" : "\(value)\n").utf8)
            guard ftruncate(fd, 0) == 0 else { throw NativeFailure("The charging target could not be updated") }
            let written = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, $0.count) }
            guard written == bytes.count, fsync(fd) == 0 else { throw NativeFailure("The charging target could not be saved") }
        }, install: {
            guard let osascript = runtime.process.which("osascript"), let shell = runtime.process.which("bash") else { throw NativeFailure("macOS administrator authorization is unavailable") }
            let script = NativeHardwareAuthorization.quote(shell.path) + " " + NativeHardwareAuthorization.quote(locations.batteryInstaller.path) + " install " + String(getuid()) + " " + NativeHardwareAuthorization.quote(locations.batteryBinary.path)
            try await NativeHardwareAuthorization.run(script: script, prompt: "UniApi is installing its charging helper.", process: runtime.process, osascript: osascript)
        }, policy: {
            guard let executable = runtime.process.which("pmset") else { throw NativeFailure("Native policy diagnostics are unavailable") }
            let result = try await runtime.process.run(executable, arguments: ["-g", "battlimit"], timeout: 5)
            return ["error": result.status == 0 ? .null : .string("Native policy command failed"), "output": .string(String(decoding: result.stdout.prefix(65536), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)), "stderr": .string(String(decoding: result.stderr.prefix(2000), as: UTF8.self))]
        })
    }
}

public enum NativeHardwareAuthorization {
    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func run(script: String, prompt: String, process: NativeProcess, osascript: URL) async throws {
        let literal = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let message = prompt.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = try await process.run(osascript, arguments: ["-e", "do shell script \"\(literal)\" with administrator privileges with prompt \"\(message)\""], timeout: 120)
        guard result.status == 0 else { throw NativeFailure("Administrator authorization did not complete; retry the requested installation") }
    }
}

public actor NativeBatteryService {
    private let runtime: NativeRuntime
    private let io: NativeBatteryIO
    private var state: JSONValue = .null
    private var hold: JSONValue = ["installed": false, "active": false, "target": 0, "floor": 0]
    private var sampled: Double = -.infinity, generation = 0
    private var busy = false, error: JSONValue = .null
    private var poller: Task<Void, Never>?
    private let log: NativeBatteryLog?
    private var lastSample: Double = 0, lastPolicy: Double = -.infinity, policyBusy = false
    private var previousPhase: String?
    public init(runtime: NativeRuntime, io: NativeBatteryIO? = nil) { self.runtime = runtime; self.io = io ?? .production(runtime: runtime); log = runtime.paths.readOnly ? nil : NativeBatteryLog(directory: runtime.paths.logs.appendingPathComponent("battery")) }
    deinit { poller?.cancel() }
    public func start() async throws {
        try runtime.db.migrate("battery-2", sql: "DROP TABLE IF EXISTS battery_state")
        guard poller == nil, !runtime.paths.readOnly else { return }
        record("logger.started", ["pollMs": 15000, "maxBytes": 8388608, "files": 8, "systemUptimeSeconds": .number(ProcessInfo.processInfo.systemUptime)])
        poller = Task { [weak self] in
            while !Task.isCancelled {
                guard let service = self else { return }; await service.refresh()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
            }
        }
    }
    private func currentHold() -> JSONValue {
        guard let value = try? io.hold() else { return ["installed": hold["installed"], "active": hold["active"], "target": hold["target"], "healthy": false, "floor": 0] }
        let target = NativeBatteryDaemonPolicy.target(value.target)
        var result = NativeHardwarePolicies.holdReport(value.report, target: target, now: io.now())
        result["installed"] = .bool(value.installed); result["active"] = .bool(value.installed && target > 0); result["target"] = .number(Double(target)); result["floor"] = 0
        return result
    }
    private func status() -> JSONValue {
        hold = currentHold()
        var result: JSONValue = ["supported": .bool(state["supported"].bool), "installed": true, "levels": state["levels"].isNull ? [] : state["levels"], "limit": state["limit"], "engaged": .bool(state["engaged"].bool), "battery": hold["active"].bool ? hold["reportedBattery"] : io.now() - sampled <= 30000 ? state["battery"] : .null, "busy": .bool(busy), "error": error, "hold": hold, "holdMin": 25]
        result["phase"] = .string(NativeHardwarePolicies.batteryPhase(result)); return result
    }
    private func refresh() async {
        guard !busy else { return }
        let before = generation
        do {
            let raw = try await io.call("state", nil); let value = try NativeHardwarePolicies.batteryState(raw)
            guard before == generation else { record("sample.discarded", ["started": .number(Double(before))]); return }
            state = value; sampled = io.now(); error = .null
            if lastSample > 0 && sampled - lastSample > 45000 { record("sampling.gap", ["elapsedMs": .number(sampled - lastSample)]) }; lastSample = sampled
            let current = status()
            record("sample", ["native": raw, "status": current, "controller": (try? io.hold().report) ?? .null])
            if previousPhase != current["phase"].string { record("phase.changed", ["from": previousPhase.map(JSONValue.string) ?? .null, "to": current["phase"]]); previousPhase = current["phase"].string }
            Task { [weak self] in await self?.samplePolicy() }
        }
        catch { guard before == generation else { return }; self.error = .string(error.localizedDescription); record("sample.failed", ["error": self.error, "lastTelemetryAt": .number(sampled), "controller": currentHold()]) }
        await runtime.events.publish("battery.state", status())
    }
    private func record(_ event: String, _ details: JSONValue = [:], generation captured: Int? = nil) { log?.write(event, data: ["generation": .number(Double(captured ?? generation)), "details": details]) }
    private func samplePolicy() async {
        guard log != nil, !policyBusy, io.now() - lastPolicy >= 60000 else { return }
        policyBusy = true; lastPolicy = io.now(); defer { policyBusy = false }
        let captured = generation
        do { record("native.policy", try await io.policy(), generation: captured) } catch { record("native.policy", ["error": .string(error.localizedDescription)], generation: captured) }
    }
    private func stopHold() async throws {
        let current = currentHold()
        if !current["installed"].bool { return }
        try io.writeTarget(0)
        record("target.written", ["target": 0])
        for _ in 0..<40 {
            let value = currentHold()
            if value["healthy"].bool && value["state"].string == "off" { record("restore.acknowledged", value); return }
            try await io.sleep(0.5)
        }
        record("restore.timeout", currentHold()); throw NativeFailure("Charging restoration has not been acknowledged; the helper and its journal remain available")
    }
    private func acknowledgeNative(_ initial: JSONValue, target: Int, deadline: Double) async throws -> JSONValue {
        var value = try NativeHardwarePolicies.batteryState(initial)
        for attempt in 0...20 {
            guard io.monotonic() < deadline else { break }
            if value["supported"].bool && value["limit"].int == target && value["engaged"].bool == (target < 100) { return value }
            guard attempt < 20 else { break }
            try await io.sleep(min(0.25, max(0, deadline - io.monotonic()))); try Task.checkCancellation()
            value = try NativeHardwarePolicies.batteryState(await io.call("state", nil))
        }
        throw NativeFailure("macOS has not acknowledged the requested charging policy within its deadline; refresh to confirm its current limit")
    }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        if operation == "status" { if state.isNull || (input["force"] ?? false).bool { await refresh() }; return status() }
        if operation == "summary" { let s = status(); return ["supported": s["supported"], "percent": s["battery"]["percent"], "charging": s["battery"]["charging"], "limit": s["hold"]["active"].bool ? s["hold"]["target"] : s["phase"].string == "off" ? .null : s["limit"]] }
        try runtime.paths.assertWritable()
        let keys: Set<String> = operation == "limit" ? ["limit"] : operation == "hold" ? ["target"] : []
        guard Set(input.keys).isSubset(of: keys) else { throw NativeFailure("Unknown charging control fields") }
        let value = JSONValue.object(input)
        var target: Int?
        if operation == "limit" { target = try NativeHardwarePolicies.batteryTarget(value["limit"], levels: state["levels"].array, hold: false) }
        if operation == "hold" { target = try NativeHardwarePolicies.batteryTarget(value["target"], levels: state["levels"].array, hold: true) }
        guard ["limit", "off", "hold", "stopHold", "install"].contains(operation) else { throw NativeFailure("Unknown battery operation") }
        guard !busy else { throw NativeFailure("A charge-limit change is already in progress") }
        busy = true; generation += 1
        record("command.started", ["operation": .string(operation), "input": value])
        var enabledBaseline = false
        defer { busy = false }
        do {
            switch operation {
            case "install": try await io.install()
            case "hold":
                let previous = currentHold()
                guard previous["installed"].bool else { throw NativeFailure("Install the charging helper once before selecting a lower target") }
                guard previous["healthy"].bool else { throw NativeFailure("The charging helper is not reporting a fresh state") }
                if !previous["active"].bool {
                    guard previous["state"].string == "off" else { throw NativeFailure("Wait for the previous charging restoration") }
                    let native = try NativeHardwarePolicies.batteryState(await io.call("state", nil))
                    if native["limit"] == 100 || !native["engaged"].bool {
                        enabledBaseline = true
                        let enabled = try NativeHardwarePolicies.batteryState(await io.call("enable", nil))
                        guard enabled["engaged"].bool, !enabled["limit"].isNull, enabled["limit"].double < 100 else { throw NativeFailure("macOS did not enable its native charging baseline") }
                    }
                }
                try io.writeTarget(target!)
                record("target.written", ["previous": previous["target"], "target": .number(Double(target!))])
            case "stopHold": try await stopHold()
            case "limit":
                try await stopHold(); let deadline = io.monotonic() + 5
                state = try await acknowledgeNative(io.call("set", target), target: target!, deadline: deadline); sampled = io.now()
            case "off":
                try await stopHold(); let deadline = io.monotonic() + 5
                state = try await acknowledgeNative(io.call("off", nil), target: 100, deadline: deadline); sampled = io.now()
            default: break
            }
            error = .null; busy = false
            await refresh(); let result = status(); record("command.finished", ["operation": .string(operation), "status": result]); return result
        } catch {
            let message = error.localizedDescription + (enabledBaseline ? " The native baseline may remain enabled; use Off to remove it." : "")
            self.error = .string(message); busy = false
            await refresh(); self.error = .string(message)
            record("command.failed", ["operation": .string(operation), "error": self.error, "status": status()])
            await runtime.events.publish("battery.state", status()); throw NativeFailure(message)
        }
    }
}
