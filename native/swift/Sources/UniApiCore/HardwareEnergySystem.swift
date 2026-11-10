import Foundation
import Darwin
import IOKit

/// Unprivileged macOS power & electrical telemetry reader using AppleSmartBattery (`PowerTelemetryData`)
/// and AppleSMC (`P*` Watts, `V*` Volts, `I*` Amps).
public enum NativeEnergySystem {
    public struct RawTelemetry: Sendable {
        public let date: Double
        public let batteryRegistry: JSONValue
        public let smcSensors: [String: Double]
        public init(date: Double, batteryRegistry: JSONValue, smcSensors: [String: Double]) {
            self.date = date
            self.batteryRegistry = batteryRegistry
            self.smcSensors = smcSensors
        }
    }

    /// Reads a live hardware snapshot on macOS without requiring root privileges.
    public static func sample(now: Double = Date().timeIntervalSince1970 * 1000) -> JSONValue {
        let registry = readBatteryRegistry()
        let smc = readSMCSensors()
        return buildSnapshot(RawTelemetry(date: now.rounded(), batteryRegistry: registry, smcSensors: smc))
    }

    public static func isSupported() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            IOObjectRelease(service)
            return true
        }
        let smc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        if smc != 0 {
            IOObjectRelease(smc)
            return true
        }
        return false
    }

    /// Deterministic snapshot builder from raw battery registry and SMC dictionary.
    /// Exposed for unit testing and cross-stack parity.
    public static func buildSnapshot(_ raw: RawTelemetry) -> JSONValue {
        let reg = raw.batteryRegistry
        let telemetry = reg["PowerTelemetryData"]
        let adapter = reg["AdapterDetails"]
        let smc = raw.smcSensors

        func finite(_ value: JSONValue) -> Double? {
            if case .number(let n) = value, n.isFinite { return n }
            return nil
        }
        func smcPositive(_ key: String, max: Double = 500) -> Double? {
            guard let v = smc[key], v.isFinite, v >= 0, v <= max else { return nil }
            return v
        }
        func smcSigned(_ key: String, maxAbs: Double = 500) -> Double? {
            guard let v = smc[key], v.isFinite, abs(v) <= maxAbs else { return nil }
            return v
        }
        func round3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }

        // 1. Primary power flows (Watts)
        let teleSystemInW = finite(telemetry["SystemPowerIn"]).map { max(0, $0 / 1000.0) }
        let teleSystemLoadW = finite(telemetry["SystemLoad"]).map { max(0, $0 / 1000.0) }
        let teleBatteryW = finite(telemetry["BatteryPower"]).map { $0 / 1000.0 }
        // PowerTelemetryData per-sample energy fields are in uWh per second: * 0.0036 = Watts
        let teleWallW = finite(telemetry["WallEnergyEstimate"]).map { max(0, $0 * 0.0036) }
        let teleAdapterLossW = finite(telemetry["AdapterEfficiencyLoss"]).map { max(0, $0 * 0.0036) }

        let smcSystemTotalW = smcPositive("PSTR")
        let smcDcInW = smcPositive("PDTR")

        // Fallback battery power from InstantAmperage (mA) * Voltage (mV) / 1e6
        let fallbackBatteryW: Double? = {
            guard let amp = finite(reg["InstantAmperage"]), let volt = finite(reg["Voltage"]), volt > 0 else { return nil }
            return (amp * volt) / 1_000_000.0
        }()

        let batteryPowerW = round3(teleBatteryW ?? fallbackBatteryW ?? 0)
        let systemPowerInW = round3(teleSystemInW ?? smcDcInW ?? 0)
        let systemLoadW: Double = {
            if let load = teleSystemLoadW, load > 0 || smcSystemTotalW == nil { return round3(load) }
            if let pstr = smcSystemTotalW { return round3(pstr) }
            return round3(max(0, systemPowerInW - max(0, batteryPowerW)))
        }()
        let adapterLossW = round3(teleAdapterLossW ?? 0)
        let wallPowerW: Double = {
            if let wall = teleWallW, wall > 0 { return round3(max(wall, systemPowerInW + adapterLossW)) }
            return round3(systemPowerInW + adapterLossW)
        }()

        let externalConnected = reg["ExternalConnected"].bool || systemPowerInW > 0.25
        let efficiencyPercent: JSONValue = {
            guard externalConnected, wallPowerW > 0.25, systemPowerInW > 0 else { return .null }
            return .number(round2(min(100, max(0, (systemPowerInW / wallPowerW) * 100.0))))
        }()

        // 2. Electrical input (Volts, Amps, Power Budget)
        let voltageInV: Double = {
            if let mv = finite(telemetry["SystemVoltageIn"]), mv > 0 { return round3(mv / 1000.0) }
            if let vd0r = smcPositive("VD0R", max: 60), vd0r > 0 { return round3(vd0r) }
            if let mv = finite(adapter["AdapterVoltage"]), mv > 0 { return round3(mv / 1000.0) }
            return 0
        }()
        let currentInA: Double = {
            if let ma = finite(telemetry["SystemCurrentIn"]), ma > 0 { return round3(ma / 1000.0) }
            if let id0r = smcPositive("ID0R", max: 30), id0r > 0 { return round3(id0r) }
            if let ma = finite(adapter["Current"]), ma > 0 { return round3(ma / 1000.0) }
            return 0
        }()
        let adapterWatts = finite(adapter["Watts"]).flatMap { $0 > 0 ? round2($0) : nil }
        let powerBudgetW = smcPositive("PHPB", max: 500).map(round2) ?? adapterWatts

        // 3. Hardware boot accumulators (since boot)
        let bootSystemWh = finite(telemetry["AccumulatedSystemEnergyConsumed"]).map { max(0, $0 / 1_000_000.0) } ?? 0
        let bootWallWh = finite(telemetry["AccumulatedWallEnergyEstimate"]).map { max(0, $0 / 1_000_000.0) } ?? 0
        let bootAdapterLossWh = finite(telemetry["AccumulatedAdapterEfficiencyLoss"]).map { max(0, $0 / 1_000_000.0) } ?? 0

        let loadAcc = finite(telemetry["AccumulatedSystemLoad"]) ?? 0
        let loadCount = finite(telemetry["SystemLoadAccumulatorCount"]) ?? 0
        let bootAvgSystemLoadW: JSONValue = loadCount > 0 ? .number(round3((loadAcc / loadCount) / 1000.0)) : .null

        let powerInAcc = finite(telemetry["AccumulatedSystemPowerIn"]) ?? 0
        let powerInCount = finite(telemetry["SystemPowerInAccumulatorCount"]) ?? 0
        let bootAvgSystemInW: JSONValue = powerInCount > 0 ? .number(round3((powerInAcc / powerInCount) / 1000.0)) : .null

        let battAcc = finite(telemetry["AccumulatedBatteryPower"]) ?? 0
        let battCount = finite(telemetry["BatteryPowerAccumulatorCount"]) ?? 0
        let bootAvgBatteryNetW: JSONValue = battCount > 0 ? .number(round3((battAcc / battCount) / 1000.0)) : .null
        let bootBatteryNetWh = round3((battAcc / 1000.0) / 3600.0)

        let bootEfficiencyPercent: JSONValue = {
            guard bootWallWh > 0.01, bootSystemWh > 0 else { return .null }
            return .number(round2(min(100, max(0, (bootSystemWh / bootWallWh) * 100.0))))
        }()

        let bootObject: JSONValue = [
            "systemEnergyWh": .number(round3(bootSystemWh)),
            "wallEnergyWh": .number(round3(bootWallWh)),
            "adapterLossWh": .number(round3(bootAdapterLossWh)),
            "batteryNetWh": .number(bootBatteryNetWh),
            "avgSystemLoadW": bootAvgSystemLoadW,
            "avgSystemPowerInW": bootAvgSystemInW,
            "avgBatteryPowerW": bootAvgBatteryNetW,
            "efficiencyPercent": bootEfficiencyPercent,
            "sampleCount": .number(max(0, loadCount.rounded()))
        ]

        // 4. Battery energy capacity & state
        let batteryPresent = reg["BatteryInstalled"].bool || finite(reg["CurrentCapacity"]) != nil
        let batteryPercent = finite(reg["CurrentCapacity"]).map { max(0, min(100, $0.rounded())) } ?? 0
        let batteryVoltageV = finite(reg["Voltage"]).map { round3(max(0, $0 / 1000.0)) } ?? 0
        let batteryCurrentA = finite(reg["InstantAmperage"]).map { round3($0 / 1000.0) } ?? 0
        let batteryTempC = finite(reg["Temperature"]).map { round2($0 / 100.0) }
        let rawCurrentMah = finite(reg["AppleRawCurrentCapacity"]) ?? 0
        let rawMaxMah = finite(reg["AppleRawMaxCapacity"]) ?? finite(reg["NominalChargeCapacity"]) ?? 0
        let designMah = finite(reg["DesignCapacity"]) ?? 0
        // Nominal pack voltage for 3-cell MacBook Pro/Air packs is ~11.4V (or live voltage when reasonable)
        let nominalV = (batteryVoltageV >= 9.0 && batteryVoltageV <= 14.0) ? batteryVoltageV : 11.4
        let remainingWh = round2((rawCurrentMah * nominalV) / 1000.0)
        let maxCapacityWh = round2((rawMaxMah * nominalV) / 1000.0)
        let designCapacityWh = round2((designMah * nominalV) / 1000.0)
        let timeRemainingMin = finite(reg["TimeRemaining"]).flatMap { $0 >= 0 && $0 < 6000 ? Int($0.rounded()) : nil }

        let batteryObject: JSONValue = [
            "present": .bool(batteryPresent),
            "percent": .number(batteryPercent),
            "charging": .bool(reg["IsCharging"].bool),
            "externalConnected": .bool(externalConnected),
            "fullyCharged": .bool(reg["FullyCharged"].bool),
            "powerW": .number(batteryPowerW),
            "voltageV": .number(batteryVoltageV),
            "currentA": .number(batteryCurrentA),
            "temperatureC": batteryTempC.map(JSONValue.number) ?? .null,
            "remainingWh": .number(remainingWh),
            "maxCapacityWh": .number(maxCapacityWh),
            "designCapacityWh": .number(designCapacityWh),
            "cycleCount": finite(reg["CycleCount"]).map { .number($0.rounded()) } ?? .null,
            "timeRemainingMinutes": timeRemainingMin.map { .number(Double($0)) } ?? .null,
            "adapterWatts": adapterWatts.map(JSONValue.number) ?? .null,
            "adapterDescription": .string(adapter["Description"].string)
        ]

        // 5. Subsystem power breakdown (Watts)
        let socRegulatorW = round3(smcPositive("PMVR") ?? 0)
        let memoryPmicW = round3(smcPositive("PPMR") ?? 0)
        let pcieSystemW = round3(smcPositive("PPSR") ?? 0)
        let coreRailsKeys = ["PP0b", "PP1b", "PP2b", "PP4b", "PP7b", "PP7l", "PP9b", "PPbb", "PPeb", "PR4l", "PR5b", "PRcl"]
        let coreRailsW = round3(coreRailsKeys.compactMap { smcPositive($0, max: 200) }.reduce(0, +))
        let usbcTotalW = round3(smcPositive("PUTC") ?? ((smcPositive("PU5C") ?? 0) + (smcPositive("PUAC") ?? 0)))
        let lowVoltageRailsW = round3((smcPositive("PO3R") ?? 0) + (smcPositive("PO5R") ?? 0))
        let accountedW = socRegulatorW + memoryPmicW + pcieSystemW + usbcTotalW + lowVoltageRailsW
        let residualSystemW = round3(max(0, systemLoadW - accountedW))

        let subsystems: [JSONValue] = [
            ["id": "soc", "label": "SoC main regulator (PMVR)", "group": "Processor & SoC", "watts": .number(socRegulatorW)],
            ["id": "pmic", "label": "Memory & PMIC rails (PPMR)", "group": "Memory", "watts": .number(memoryPmicW)],
            ["id": "cores", "label": "Core & cluster rails (PP*/PR*)", "group": "Processor & SoC", "watts": .number(coreRailsW)],
            ["id": "pcie", "label": "System & PCIe rail (PPSR)", "group": "System", "watts": .number(pcieSystemW)],
            ["id": "rails", "label": "3.3V & 5V system rails (PO3R/PO5R)", "group": "Rails", "watts": .number(lowVoltageRailsW)],
            ["id": "usbc", "label": "USB-C & ports (PUTC/PU5C)", "group": "Ports", "watts": .number(usbcTotalW)],
            ["id": "other", "label": "Display, storage & rest of system", "group": "System", "watts": .number(residualSystemW)]
        ]

        // 6. Electrical sensors list (Power W, Voltage V, Current A)
        var sensors: [JSONValue] = []
        var seen = Set<String>()
        func appendSensor(id: String, value: Double, unit: String) {
            guard value.isFinite, !seen.contains(id) else { return }
            seen.insert(id)
            sensors.append([
                "id": .string(id),
                "value": .number(round3(value)),
                "unit": .string(unit)
            ])
        }

        // Synthesize telemetry virtual sensors so they appear even if SMC keys are absent
        appendSensor(id: "TELE:WALL", value: wallPowerW, unit: "W")
        appendSensor(id: "TELE:SYSI", value: systemPowerInW, unit: "W")
        appendSensor(id: "TELE:SYSL", value: systemLoadW, unit: "W")
        appendSensor(id: "TELE:BATT", value: batteryPowerW, unit: "W")
        appendSensor(id: "TELE:LOSS", value: adapterLossW, unit: "W")
        if voltageInV > 0 { appendSensor(id: "TELE:VIN", value: voltageInV, unit: "V") }
        if currentInA > 0 { appendSensor(id: "TELE:IIN", value: currentInA, unit: "A") }
        if batteryVoltageV > 0 { appendSensor(id: "TELE:VBAT", value: batteryVoltageV, unit: "V") }
        if batteryCurrentA != 0 { appendSensor(id: "TELE:IBAT", value: batteryCurrentA, unit: "A") }

        for key in smc.keys.sorted() {
            guard let first = key.first else { continue }
            if first == "P", let v = smcSigned(key, maxAbs: 500), abs(v) < 500 {
                appendSensor(id: key, value: v, unit: "W")
            } else if first == "V", let v = smcSigned(key, maxAbs: 100), v >= 0, v < 100 {
                appendSensor(id: key, value: v, unit: "V")
            } else if first == "I", let v = smcSigned(key, maxAbs: 100), abs(v) < 100 {
                appendSensor(id: key, value: v, unit: "A")
            }
        }

        return [
            "date": .number(raw.date),
            "wallPowerW": .number(wallPowerW),
            "systemPowerInW": .number(systemPowerInW),
            "systemLoadW": .number(systemLoadW),
            "batteryPowerW": .number(batteryPowerW),
            "adapterLossW": .number(adapterLossW),
            "efficiencyPercent": efficiencyPercent,
            "voltageInV": .number(voltageInV),
            "currentInA": .number(currentInA),
            "powerBudgetW": powerBudgetW.map(JSONValue.number) ?? .null,
            "externalConnected": .bool(externalConnected),
            "charging": .bool(reg["IsCharging"].bool),
            "boot": bootObject,
            "battery": batteryObject,
            "subsystems": .array(subsystems),
            "sensors": .array(sensors)
        ]
    }

    // MARK: - AppleSmartBattery Registry Reader

    private static func readBatteryRegistry() -> JSONValue {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return [:] }
        return convertCF(dict)
    }

    private static func convertCF(_ value: Any) -> JSONValue {
        if let b = value as? Bool { return .bool(b) }
        if let n = value as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let d = n.doubleValue
            return d.isFinite ? .number(d) : .null
        }
        if let s = value as? String { return .string(s) }
        if let dict = value as? [String: Any] {
            var out: JSONObject = [:]
            for (k, v) in dict {
                let converted = convertCF(v)
                if !converted.isNull { out[k] = converted }
            }
            return .object(out)
        }
        if let arr = value as? [Any] {
            return .array(arr.map(convertCF))
        }
        return .null
    }

    // MARK: - Unprivileged AppleSMC Electrical Sensor Reader

    private struct SMCKeyDataVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCKeyDataVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
        ) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private static let candidateSMCKeys: [String] = [
        // Primary system & DC-In power
        "PSTR", "PDTR", "PMVR", "PPMR", "PPSR", "PHPS", "PHPB",
        // USB-C & low-voltage rails
        "PUTC", "PU5C", "PUAC", "PO3R", "PO5R",
        // Power zones
        "PZC0", "PZC1", "PZCU",
        // Core & cluster power rails
        "PP0b", "PP1b", "PP2b", "PP4b", "PP7b", "PP7l", "PP9b", "PPbb", "PPeb",
        "PR4l", "PR5b", "PRcl",
        // Intel / legacy Mac SMC power keys (gracefully skipped if absent)
        "PCPC", "PCPG", "PC0C", "PC0G", "PG0R", "PBLC", "PB0R",
        // Voltages
        "VD0R", "VP0R", "VMVR", "VPMR", "VPSR", "VO3R", "VO5R",
        "VP0b", "VP1b", "VP2b", "VP4b", "VP7b", "VP7l", "VP9b", "VPbb", "VPeb",
        "VR4l", "VR5b", "VRcl", "VReb",
        // Currents
        "ID0R", "IB0R", "IMVR", "IPMR", "IPSR", "IO3R", "IO5R", "IU5C", "IUAC",
        "I000", "I001", "I002", "I003",
        "IP0b", "IP1b", "IP2b", "IP4b", "IP7b", "IP7l", "IP9b", "IPbb", "IPeb"
    ]

    private static func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
        return r
    }

    private static func readSMCSensors() -> [String: Double] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }
        var conn: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return [:] }
        defer { IOServiceClose(conn) }

        let fltType = fourCC("flt ")
        let sp78Type = fourCC("sp78")
        let fpe2Type = fourCC("fpe2")
        var out: [String: Double] = [:]

        for name in candidateSMCKeys {
            let k = fourCC(name)
            var input = SMCKeyData()
            var output = SMCKeyData()
            input.key = k
            input.data8 = 9 // kSMCReadKeyInfo
            var outSize = MemoryLayout<SMCKeyData>.stride
            guard IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize) == KERN_SUCCESS,
                  output.result == 0,
                  output.keyInfo.dataSize >= 2 else { continue }

            let dataType = output.keyInfo.dataType
            let dataSize = output.keyInfo.dataSize
            input.keyInfo.dataSize = dataSize
            input.data8 = 5 // kSMCReadBytes
            outSize = MemoryLayout<SMCKeyData>.stride
            guard IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.stride, &output, &outSize) == KERN_SUCCESS,
                  output.result == 0 else { continue }

            let value: Double? = withUnsafeBytes(of: output.bytes) { raw in
                if dataType == fltType, dataSize == 4 {
                    var f: Float = 0
                    _ = withUnsafeMutableBytes(of: &f) { dst in
                        raw.prefix(4).copyBytes(to: dst)
                    }
                    return Double(f)
                } else if dataType == sp78Type, dataSize == 2 {
                    let s = Int16(bitPattern: (UInt16(raw[0]) << 8) | UInt16(raw[1]))
                    return Double(s) / 256.0
                } else if dataType == fpe2Type, dataSize == 2 {
                    let u = (UInt16(raw[0]) << 8) | UInt16(raw[1])
                    return Double(u) / 4.0
                }
                return nil
            }
            if let v = value, v.isFinite {
                out[name] = v
            }
        }
        return out
    }
}
