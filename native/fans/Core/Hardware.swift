import Foundation

protocol FanHardware: AnyObject {
    func snapshot() throws -> Snapshot
    func setSpeeds(_ speeds: [Double]) throws
    /// `force` reclaims fans this process never touched. Only an explicit Automatic from the user
    /// may pass true - see Controller.handle for why, and why nothing internal ever does.
    func restore(force: Bool) throws
}
// Each instance is confined to a single serial queue (or the helper loop).
final class Hardware: FanHardware, @unchecked Sendable {
    let smc: SMCConnection
    private let hid = HIDTemperatures()
    private var sensorKeys: [String] = []
    private var modeKeys: [String] = []
    private let hasUnlock: Bool
    private var touched = false
    init() throws {
        guard let connection = SMCConnection() else { throw FanError("AppleSMC is unavailable on this Mac.") }
        smc = connection
        hasUnlock = smc.getKeyInfo("Ftst") != nil
        let count = Int(value("FNum") ?? 0)
        guard count >= 0, count <= 8 else { throw FanError("The fan count could not be read.") }
        modeKeys = (0..<count).map { smc.getKeyInfo("F\($0)md") != nil ? "F\($0)md" : "F\($0)Md" }
        let keyCount = min(smc.getKeyCount(), 10000)
        for i in 0..<keyCount {
            // Discovery must not filter on the CURRENT reading. It used to require 10-130°C here,
            // which permanently excluded any sensor that happened to be parked at that instant -
            // and since the helper became a LaunchDaemon it starts at boot, on a cold machine,
            // where every `Tg*` GPU key reads the idle sentinel below 10°C. The result was a
            // daemon with no GPU sensor for its entire lifetime, so `Snapshot.temperature("GPU")`
            // was nil, `Policy.shouldRelease` said "blind", and every single acquisition was
            // refused with "Valid fan and processor readings are required" - observed 1h50m after
            // a reboot with the machine at 107°C and the fans idling at 2422 RPM. The per-read
            // filter in `snapshot()` already drops a sentinel, which is the right place for it:
            // there it is a transient fact about one sample, not a permanent verdict about a key.
            if let key = smc.getKeyAtIndex(i), (Self.knownKeys.contains(key) || key.hasPrefix("Tg")), value(key) != nil,
               let type = smc.getKeyInfo(key)?.type, ["flt ", "sp78", "ioft"].contains(type) { sensorKeys.append(key) }
        }
    }
    static let knownKeys: Set<String> = ["TCMb", "TCMz", "TC0P", "TB0T", "TB1T", "TB2T", "TH0x", "TH0A", "TH0B", "Tm0p", "Tm1p", "Tm2p", "Tm02", "Tm06", "Tm08", "Tm09", "TAOL", "TA0P", "TS0P", "TaLP", "TaRF", "TW0P"]
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset*8) }
            let value = Double(Float(bitPattern: bits)); return value.isFinite ? value : nil
        case "fpe2":
            guard bytes.count == 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))/4
        case "sp78":
            guard bytes.count == 2 else { return nil }; return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1])))/256
        case "ui8 ": guard bytes.count == 1 else { return nil }; return Double(bytes[0])
        case "ui16": guard bytes.count == 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ioft":
            guard bytes.count == 8 else { return nil }
            let bits = bytes.prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset*8) }
            return Double(bits)/65536
        default: return nil
        }
    }
    func value(_ key: String) -> Double? {
        guard let info = smc.getKeyInfo(key) else { return nil }
        let read = smc.readKey(key)
        return read.success ? Self.decode(read.bytes, type: info.type) : nil
    }
    private func writeNumber(_ key: String, _ number: Double) -> Bool {
        guard number.isFinite, let info = smc.getKeyInfo(key) else { return false }
        if info.type == "flt " { var v = Float(number); return smc.writeKey(key, bytes: withUnsafeBytes(of:&v) { Array($0) }) }
        if info.type == "fpe2", number >= 0, number <= 16383 { let v = UInt16(number * 4); return smc.writeKey(key, bytes:[UInt8(v >> 8), UInt8(v & 255)]) }
        return false
    }
    func snapshot() throws -> Snapshot {
        guard let count = value("FNum"), Int(count) == modeKeys.count else { throw FanError("Fan telemetry was interrupted.") }
        var fans: [Fan] = []
        for i in modeKeys.indices {
            guard let actual = value("F\(i)Ac"), let target = value("F\(i)Tg"), let lo = value("F\(i)Mn"), let hi = value("F\(i)Mx"), let mode = value(modeKeys[i]), actual >= 0, actual < 20000 else { throw FanError("Fan \(i+1) is not reporting valid readings.") }
            fans.append(Fan(id:i, actual:actual, target:target, minimum:lo, maximum:hi, mode:Int(mode)))
        }
        var sensors = sensorKeys.compactMap { key -> Sensor? in
            guard let v = value(key), v >= 10, v < 130 else { return nil }; return Sensor(id:key,value:v)
        }
        sensors += hid.read()
        return Snapshot(fans:fans, sensors:sensors, thermal:ProcessInfo.processInfo.thermalState.rawValue)
    }
    func setSpeeds(_ speeds: [Double]) throws {
        let current = try snapshot()
        guard speeds.count == current.fans.count, !speeds.isEmpty else { throw FanError("Fan configuration changed.") }
        for (fan,rpm) in zip(current.fans,speeds) {
            guard fan.validLimits, rpm.isFinite, rpm >= max(1200,fan.minimum), rpm <= fan.maximum else { throw FanError("The requested speed is outside this fan’s limits.") }
        }
        // No thermal gate here at all any more. It threw at exactly the moment the fans were most
        // worth writing - a 107°C machine with macOS idling them at 2348 RPM - and the throw
        // surfaced as "Control interrupted", releasing the override. Thermal policy is the
        // Controller's, it holds the smoothing, and its answer to heat is now the 100% floor.
        if current.fans.contains(where: { $0.mode != 1 }) {
            touched = true
            if hasUnlock && !smc.writeKey("Ftst", bytes:[1]) { throw FanError("macOS denied fan control. Enable controls with administrator authentication.") }
            let deadline = Date().addingTimeInterval(8)
            for key in modeKeys {
                while Date() < deadline {
                    if smc.writeKey(key,bytes:[1]), value(key) == 1 { break }
                    Thread.sleep(forTimeInterval:0.1)
                }
                guard value(key) == 1 else { throw FanError("macOS did not release the fans. Another fan utility may be controlling them.") }
            }
        }
        for (i,rpm) in speeds.enumerated() {
            guard writeNumber("F\(i)Tg",rpm) else { throw FanError("Fan \(i+1) rejected its target speed.") }
        }
        // Apple Silicon target readback trails a successful write by about a second.
        // Verify both fans after writing both; an immediate read falsely rolls back valid commands.
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if speeds.enumerated().allSatisfy({ i,rpm in value("F\(i)Tg").map { abs($0-rpm) < 100 } ?? false }) { return }
            Thread.sleep(forTimeInterval:0.1)
        } while Date() < deadline
        throw FanError("The fans did not confirm their requested speeds.")
    }
    func restore(force: Bool = false) throws {
        guard touched || force else { return }
        for key in modeKeys { _ = smc.writeKey(key,bytes:[0]) }
        if hasUnlock { _ = smc.writeKey("Ftst",bytes:[0]) }
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if modeKeys.allSatisfy({ let mode = value($0); return mode == 0 || mode == 3 }) && (!hasUnlock || value("Ftst") == 0) { touched = false; return }
            Thread.sleep(forTimeInterval:0.1)
            for key in modeKeys { _ = smc.writeKey(key,bytes:[0]) }
            if hasUnlock { _ = smc.writeKey("Ftst",bytes:[0]) }
        } while Date() < deadline
        throw FanError("Automatic control could not be verified. Quit other fan utilities and retry Restore automatic.")
    }
}
