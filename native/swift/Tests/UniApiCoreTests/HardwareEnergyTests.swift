import XCTest
@testable import UniApiCore

final class HardwareEnergyTests: XCTestCase {
    private func sampleRawTelemetry(date: Double = 1_700_000_000_000, systemInMw: Double = 14_500, systemLoadMw: Double = 12_000, batteryMw: Double = 2_500) -> NativeEnergySystem.RawTelemetry {
        let batteryRegistry: JSONValue = [
            "BatteryInstalled": true,
            "CurrentCapacity": 82,
            "IsCharging": batteryMw > 0,
            "ExternalConnected": systemInMw > 0,
            "FullyCharged": false,
            "Voltage": 12_200,
            "InstantAmperage": .number(batteryMw / 12.2),
            "Temperature": 2_980,
            "AppleRawCurrentCapacity": 3_400,
            "AppleRawMaxCapacity": 4_150,
            "DesignCapacity": 4_500,
            "CycleCount": 78,
            "TimeRemaining": 145,
            "AdapterDetails": [
                "Watts": 67,
                "Description": "usb host",
                "AdapterVoltage": 20_000,
                "Current": 3_350
            ],
            "PowerTelemetryData": [
                "SystemPowerIn": .number(systemInMw),
                "SystemLoad": .number(systemLoadMw),
                "BatteryPower": .number(batteryMw),
                "SystemVoltageIn": 19_950,
                "SystemCurrentIn": 727,
                "WallEnergyEstimate": .number((systemInMw + 1_800) / 3.6),
                "AdapterEfficiencyLoss": .number(1_800 / 3.6),
                "AccumulatedSystemEnergyConsumed": 45_500_000,
                "AccumulatedWallEnergyEstimate": 52_000_000,
                "AccumulatedAdapterEfficiencyLoss": 6_500_000,
                "AccumulatedSystemLoad": 120_000_000,
                "SystemLoadAccumulatorCount": 10_000,
                "AccumulatedSystemPowerIn": 145_000_000,
                "SystemPowerInAccumulatorCount": 10_000,
                "AccumulatedBatteryPower": 25_000_000,
                "BatteryPowerAccumulatorCount": 10_000
            ]
        ]
        let smc: [String: Double] = [
            "PSTR": systemLoadMw / 1000.0,
            "PDTR": systemInMw / 1000.0,
            "PMVR": 4.2,
            "PPMR": 2.6,
            "PPSR": 1.1,
            "PO3R": 0.4,
            "PO5R": 0.5,
            "PUTC": 0.8,
            "PP0b": 1.5,
            "PHPB": 67.0,
            "VD0R": 19.95,
            "ID0R": 0.727
        ]
        return .init(date: date, batteryRegistry: batteryRegistry, smcSensors: smc)
    }

    func testBuildSnapshotAndPolicies() throws {
        let raw = sampleRawTelemetry()
        let snapshot = NativeEnergySystem.buildSnapshot(raw)
        XCTAssertTrue(NativeHardwarePolicies.energySnapshot(snapshot))
        XCTAssertEqual(snapshot["systemPowerInW"].double, 14.5, accuracy: 0.01)
        XCTAssertEqual(snapshot["systemLoadW"].double, 12.0, accuracy: 0.01)
        XCTAssertEqual(snapshot["batteryPowerW"].double, 2.5, accuracy: 0.01)
        XCTAssertEqual(snapshot["adapterLossW"].double, 1.8, accuracy: 0.01)
        XCTAssertEqual(snapshot["wallPowerW"].double, 16.3, accuracy: 0.01)
        XCTAssertEqual(snapshot["efficiencyPercent"].double, 88.96, accuracy: 0.05)
        XCTAssertEqual(snapshot["boot"]["systemEnergyWh"].double, 45.5, accuracy: 0.01)
        XCTAssertEqual(snapshot["boot"]["avgSystemLoadW"].double, 12.0, accuracy: 0.01)
        XCTAssertFalse(snapshot["subsystems"].array.isEmpty)
        XCTAssertFalse(snapshot["sensors"].array.isEmpty)

        let rows = NativeHardwareDisplayPolicies.energySensorRows(snapshot["sensors"].array, favorites: ["PMVR"], group: "All", query: "")
        XCTAssertEqual(rows.first?["id"].string, "PMVR")
    }

    func testEnergyServiceHistoryAndSession() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uniapi-energy-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try NativeRuntime(paths: NativePaths.discover(root: root, data: root.appendingPathComponent("data")))
        var now = 1_700_000_000_000.0
        var loadMw = 12_000.0
        let io = NativeEnergyIO(
            supported: { true },
            sample: { [unowned self] timestamp in
                NativeEnergySystem.buildSnapshot(self.sampleRawTelemetry(date: timestamp, systemInMw: loadMw + 2_000, systemLoadMw: loadMw, batteryMw: 2_000))
            },
            now: { now },
            sleep: { _ in try await Task.sleep(nanoseconds: 1_000_000_000) }
        )

        let service = NativeEnergyService(runtime: runtime, io: io)
        let firstStatus = try await service.handle("status")
        XCTAssertTrue(firstStatus["supported"].bool)
        XCTAssertEqual(firstStatus["snapshot"]["systemLoadW"].double, 12.0, accuracy: 0.01)

        // Advance 20 seconds with 24W load
        now += 20_000
        loadMw = 24_000
        let secondStatus = try await service.handle("status", input: ["force": true])
        XCTAssertEqual(secondStatus["snapshot"]["systemLoadW"].double, 24.0, accuracy: 0.01)
        XCTAssertEqual(secondStatus["session"]["sampleCount"].int, 2)
        XCTAssertEqual(secondStatus["session"]["avgSystemLoadW"].double, 18.0, accuracy: 0.01)
        XCTAssertEqual(secondStatus["session"]["peakSystemLoadW"].double, 24.0, accuracy: 0.01)
        XCTAssertGreaterThan(secondStatus["session"]["systemEnergyWh"].double, 0.1)

        let history = try await service.handle("history", input: ["range": "30m"])
        XCTAssertFalse(history["points"].array.isEmpty)
        XCTAssertGreaterThan(history["summary"]["systemEnergyWh"].double, 0)

        let csv = NativeHardwareDisplayPolicies.energyHistoryCSV(history["points"].array)
        XCTAssertTrue(csv.contains("system_load_w"))
        XCTAssertTrue(csv.contains("wall_power_w"))

        let updatedPrefs = try await service.handle("preferences", input: ["ratePerKwh": 0.42, "currency": "EUR ", "badgeMetric": "wallPower"])
        XCTAssertEqual(updatedPrefs["preferences"]["ratePerKwh"].double, 0.42, accuracy: 0.001)
        XCTAssertEqual(updatedPrefs["preferences"]["currency"].string, "EUR")
        XCTAssertEqual(NativeHardwareDisplayPolicies.energyBadgeText(updatedPrefs), "27.8W")

        let reset = try await service.handle("resetSession")
        XCTAssertEqual(reset["session"]["sampleCount"].int, 1)
        XCTAssertEqual(reset["session"]["systemEnergyWh"].double, 0, accuracy: 0.0001)
    }
}
