import Foundation
import XCTest
@testable import UniApiCore

final class HardwareDisplayPolicyTests: XCTestCase {
    private typealias Policy = NativeHardwareDisplayPolicies
    private let curve = NativeHardwareDisplayPolicies.defaultFanCurve

    func testCSVExportsEveryStatisticAndThermalIndependentOfSelectedChart() {
        let point: JSONValue = [
            "mean": ["date": 1000, "thermal": 0.5, "sensors": [["id": "TC\"Mb,die", "value": 60]], "fans": [["id": 0, "actual": 2100]]],
            "min": ["thermal": 0, "sensors": [["id": "TC\"Mb,die", "value": 40]], "fans": [["id": 0, "actual": 1800]]],
            "max": ["thermal": 2, "sensors": [["id": "TC\"Mb,die", "value": 80]], "fans": [["id": 0, "actual": 2500]]],
            "end": 3000, "count": 3, "resolutionMs": 60000
        ]
        XCTAssertEqual(Policy.fanHistoryCSV([point]), """
        timestamp,end,metric,mean,min,max,samples,resolution_ms
        1970-01-01T00:00:01.000Z,1970-01-01T00:00:03.000Z,"temperature_c:TC""Mb,die",60,40,80,3,60000
        1970-01-01T00:00:01.000Z,1970-01-01T00:00:03.000Z,"fan_1_rpm",2100,1800,2500,3,60000
        1970-01-01T00:00:01.000Z,1970-01-01T00:00:03.000Z,"thermal_pressure",0.5,0,2,3,60000
        """)
    }
    func testCSVPreservesPartialMetricsAsBlanksInsteadOfInventingZero() {
        let point: JSONValue = ["mean": ["date": 1000, "sensors": [["id": "CPU", "value": 60]]],
                                "min": ["sensors": [["id": "GPU", "value": 45]]], "max": [:], "end": 1000, "count": 1, "resolutionMs": 10000]
        let rows = Policy.fanHistoryCSV([point]).components(separatedBy: "\n")
        XCTAssertTrue(rows.contains("1970-01-01T00:00:01.000Z,1970-01-01T00:00:01.000Z,\"temperature_c:CPU\",60,,,1,10000"))
        XCTAssertTrue(rows.contains("1970-01-01T00:00:01.000Z,1970-01-01T00:00:01.000Z,\"temperature_c:GPU\",,45,,1,10000"))
        XCTAssertTrue(rows.contains("1970-01-01T00:00:01.000Z,1970-01-01T00:00:01.000Z,\"thermal_pressure\",,,,1,10000"))
    }
    func testCustomDatesIncludeFullDSTDaysAndHaveIntegerMilliseconds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let iso = ISO8601DateFormatter()
        for (month, day, hours, expectedStart, expectedNext) in [
            (3, 29, 23, "2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z"),
            (10, 25, 25, "2026-10-24T22:00:00Z", "2026-10-25T23:00:00Z")
        ] {
            let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
            let range = try Policy.fanHistoryDays(from: noon, through: noon, calendar: calendar)
            let start = try XCTUnwrap(iso.date(from: expectedStart)), next = try XCTUnwrap(iso.date(from: expectedNext))
            XCTAssertEqual(range["since"], .number(start.timeIntervalSince1970 * 1000))
            XCTAssertEqual(range["until"], .number(next.timeIntervalSince1970 * 1000 - 1))
            XCTAssertEqual(range["until"]!.double - range["since"]!.double + 1, Double(hours) * 3600000)
        }
    }
    func testCustomDatesRejectReversedDaysButAcceptDifferentTimesOnSameDay() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = Date(timeIntervalSince1970: 172800 + 3600), evening = Date(timeIntervalSince1970: 172800 + 72000)
        XCTAssertNoThrow(try Policy.fanHistoryDays(from: evening, through: morning, calendar: calendar))
        XCTAssertThrowsError(try Policy.fanHistoryDays(from: evening.addingTimeInterval(86400), through: morning, calendar: calendar))
    }
    private func fanState(_ mode: String, fans: [JSONValue] = [["id": 0, "minimum": 1200, "maximum": 6000, "target": 2100, "actual": 2200]]) -> JSONValue {
        ["control": ["mode": .string(mode)], "snapshot": ["fans": .array(fans)]]
    }
    func testCurrentDurationPreservesCoolerCurveAndBoostCommands() throws {
        XCTAssertEqual(Policy.currentFanCommand(state: fanState("cooler"), duration: 600, curve: curve), ["command": "cooler", "duration": 600])
        XCTAssertEqual(Policy.currentFanCommand(state: fanState("cooler"), duration: 0, curve: curve), ["command": "cooler"])
        XCTAssertEqual(Policy.currentFanCommand(state: fanState("curve"), duration: 1800, curve: curve), ["command": "curve", "curve": .array(curve), "duration": 1800])
        XCTAssertEqual(Policy.currentFanCommand(state: fanState("curve"), duration: 0, curve: curve), ["command": "curve", "curve": .array(curve)])
        XCTAssertEqual(Policy.currentFanCommand(state: fanState("boost"), duration: 600, curve: curve), ["command": "boost", "duration": 600])
        XCTAssertNil(Policy.currentFanCommand(state: fanState("boost"), duration: 0, curve: curve))
        for mode in ["automatic", "external", "unknown"] { XCTAssertNil(Policy.currentFanCommand(state: fanState(mode), duration: 600, curve: curve)) }
        XCTAssertTrue(Policy.fanDurations.contains(600)); XCTAssertTrue(Policy.fanDurations.contains(1800))
        XCTAssertTrue(Policy.boostDurations.contains(600)); XCTAssertTrue(Policy.boostDurations.contains(1800))
        XCTAssertFalse(Policy.boostDurations.contains(0))
    }
    func testManualDurationClampsEachFanAndRejectsUnavailableSnapshot() {
        let state = fanState("manual", fans: [
            ["id": 0, "minimum": 1200, "maximum": 6000, "target": 10000, "actual": 2200],
            ["id": 1, "minimum": 1500, "maximum": 6200, "target": 0, "actual": 900]
        ])
        XCTAssertEqual(Policy.currentFanCommand(state: state, duration: 0, curve: curve), ["command": "manual", "duration": 0, "speeds": [6000, 1500]])
        XCTAssertNil(Policy.currentFanCommand(state: .null, duration: 600, curve: curve))
        XCTAssertNil(Policy.currentFanCommand(state: fanState("manual", fans: [["minimum": 1200, "maximum": 6000]]), duration: 600, curve: curve))
        for duration in [-1, 1, 3601] { XCTAssertNil(Policy.currentFanCommand(state: state, duration: duration, curve: curve)) }
    }
    func testSavedCurveValidationRejectsMalformedOrUnsafePoints() {
        XCTAssertTrue(Policy.validFanCurve(curve))
        XCTAssertFalse(Policy.validFanCurve(Array(curve.prefix(3))))
        for (index, key, value) in [(0, "temperature", JSONValue.string("45")), (1, "temperature", .number(48)),
                                    (2, "percent", .number(20)), (3, "percent", .number(99)),
                                    (0, "temperature", .number(29)), (2, "temperature", .number(.infinity))] {
            var invalid = curve; invalid[index][key] = value
            XCTAssertFalse(Policy.validFanCurve(invalid))
            XCTAssertNil(Policy.currentFanCommand(state: fanState("curve"), duration: 600, curve: invalid))
        }
    }
    func testCurveDragAndKeyboardMovementStayMonotoneAndFullyCooled() {
        let start = Policy.moveFanCurve(curve, index: 0, temperature: 1000, percent: 1000)
        XCTAssertEqual(start[0], ["temperature": 60, "percent": 25]); XCTAssertTrue(Policy.validFanCurve(start))
        let last = Policy.moveFanCurve(curve, index: 3, temperature: -100, percent: -100)
        XCTAssertEqual(last[3], ["temperature": 85, "percent": 100]); XCTAssertTrue(Policy.validFanCurve(last))
        var moved = curve
        for _ in 0..<100 { moved = Policy.moveFanCurve(moved, index: 1, temperature: moved[1]["temperature"].double + 1, percent: moved[1]["percent"].double + 1) }
        XCTAssertEqual(moved[1], ["temperature": 75, "percent": 65]); XCTAssertTrue(Policy.validFanCurve(moved))
        XCTAssertEqual(Policy.moveFanCurve(curve, index: 0, temperature: .nan, percent: 0), curve)
        XCTAssertEqual(Policy.moveFanCurve(curve, index: 9, temperature: 50, percent: 50), curve)
    }
    func testCurveTextSubmitClampsFiniteInputAndRejectsEmptyOrNonNumbers() {
        XCTAssertEqual(Policy.curveTextValue(" 500 ", bounds: 50...75), 75)
        XCTAssertEqual(Policy.curveTextValue("-20", bounds: 50...75), 50)
        XCTAssertEqual(Policy.curveTextValue("60.5", bounds: 50...75), 60.5)
        for value in ["", " ", "NaN", "inf", "not a number"] { XCTAssertNil(Policy.curveTextValue(value, bounds: 50...75)) }
        let fractional: [JSONValue] = [["temperature": 45.2, "percent": 0], ["temperature": 60.8, "percent": 25], ["temperature": 80, "percent": 65], ["temperature": 90, "percent": 100]]
        let moved = Policy.moveFanCurve(fractional, index: 0, temperature: 999, percent: 999)
        XCTAssertTrue(Policy.validFanCurve(moved)); XCTAssertEqual(moved[0]["temperature"], 55.8)
    }
    func testSensorsSortFavoritesFirstThenNamesAndFilterByFriendlyNameOrID() {
        let sensors: [JSONValue] = ["TW0P", "TCMz", "TB0T", "TAOL", "TCMb"].map { ["id": .string($0), "value": 60] }
        func ids(_ rows: [JSONValue]) -> [String] { rows.map { $0["id"].string } }
        XCTAssertEqual(ids(Policy.sensorRows(sensors, favorites: ["TW0P", "TCMb"], group: "All", query: "")), ["TCMb", "TW0P", "TAOL", "TB0T", "TCMz"])
        XCTAssertEqual(ids(Policy.sensorRows(sensors, favorites: ["TW0P"], group: "Favorites", query: "")), ["TW0P"])
        XCTAssertEqual(ids(Policy.sensorRows(sensors, favorites: [], group: "CPU", query: " DIE ")), ["TCMb", "TCMz"])
        XCTAssertEqual(ids(Policy.sensorRows(sensors, favorites: [], group: "All", query: "tb0t")), ["TB0T"])
    }
    func testTemperatureUsesCPUAverageAndKeepsMissingReadingsUnavailable() {
        let sample: JSONValue = ["sensors": [["id": "TCMb", "value": 55], ["id": "TCMz", "value": 90], ["id": "TG0D", "value": 70], ["id": "TG1D", "value": .null]]]
        XCTAssertEqual(Policy.temperature(sample, group: "CPU"), 55)
        XCTAssertEqual(Policy.temperature(sample, group: "GPU"), 70)
        XCTAssertNil(Policy.temperature(sample, group: "Battery"))
        XCTAssertNil(Policy.number(.null)); XCTAssertNil(Policy.number(.string("0")))
    }
    private func row(_ id: String, name: String, cpu: JSONValue = .null, read: JSONValue = .null, write: JSONValue = .null, children: [JSONValue] = []) -> JSONValue {
        ["id": .string(id), "name": .string(name), "cpuPercent": cpu, "readPerSecond": read, "writePerSecond": write, "processes": .array(children)]
    }
    func testActivityNameAndDirectionSortingWithStableIDTies() {
        let rows = [row("b", name: "Alpha"), row("a", name: "Alpha"), row("c", name: "Zulu")]
        XCTAssertEqual(Policy.sortActivity(rows, by: "name", descending: false).map { $0["id"].string }, ["a", "b", "c"])
        XCTAssertEqual(Policy.sortActivity(rows, by: "name", descending: true).map { $0["id"].string }, ["c", "a", "b"])
    }
    func testActivityCombinedDiskSortKeepsUnknownLastInBothDirections() {
        let rows = [row("missing", name: "A"), row("zero", name: "B", read: 0), row("read", name: "C", read: 30), row("both", name: "D", read: 20, write: 20)]
        XCTAssertNil(Policy.diskRate(rows[0])); XCTAssertEqual(Policy.diskRate(rows[1]), 0)
        XCTAssertEqual(Policy.sortActivity(rows, by: "disk", descending: true).map { $0["id"].string }, ["both", "read", "zero", "missing"])
        XCTAssertEqual(Policy.sortActivity(rows, by: "disk", descending: false).map { $0["id"].string }, ["zero", "read", "both", "missing"])
        XCTAssertEqual(Policy.sortActivity([row("missing", name: "A"), row("zero", name: "Z", cpu: 0)], by: "cpu", descending: false).map { $0["id"].string }, ["zero", "missing"])
    }
    func testHeldActivityRetainsChildPositionsAndExitedSlotsButUpdatesLiveValues() {
        let p1 = row("p1", name: "First", cpu: 10), p2 = row("p2", name: "Second", cpu: 20)
        let old = row("app", name: "App", cpu: 30, children: [p1, p2])
        let updated = row("app", name: "App", cpu: 90, children: [row("new", name: "New", cpu: 50), row("p2", name: "Second", cpu: 40)])
        let shown = Policy.holdActivityRows(current: [updated], held: [old])
        XCTAssertEqual(shown[0]["cpuPercent"], 90)
        let children = shown[0]["processes"].array
        XCTAssertEqual(children.map { $0["id"].string }, ["p1", "p2"])
        XCTAssertTrue(children[0]["exited"].bool); XCTAssertTrue(children[0]["cpuPercent"].isNull)
        XCTAssertFalse(children[1]["exited"].bool); XCTAssertEqual(children[1]["cpuPercent"], 40)
        XCTAssertEqual(old["processes"].array, [p1, p2])
    }
    func testHeldExitedGroupsKeepChildrenAndNewGroupsAppendAfterExistingSlots() {
        let old = [row("gone", name: "Gone", cpu: 20, children: [row("p1", name: "First", cpu: 20)]), row("live", name: "Live", cpu: 30)]
        let current = [row("new", name: "New", cpu: 100), row("live", name: "Live", cpu: 10)]
        let shown = Policy.holdActivityRows(current: current, held: old)
        XCTAssertEqual(shown.map { $0["id"].string }, ["gone", "live", "new"])
        XCTAssertTrue(shown[0]["exited"].bool); XCTAssertTrue(shown[0]["cpuPercent"].isNull)
        XCTAssertTrue(shown[0]["processes"].array[0]["exited"].bool)
        XCTAssertEqual(shown[1]["cpuPercent"], 10)
    }
    func testHeldChildIdentityDoesNotTransferToAReusedPID() {
        let old = row("app", name: "App", children: [row("7:start1", name: "Old process", cpu: 5)])
        let next = row("app", name: "App", children: [row("7:start2", name: "Replacement", cpu: 80)])
        let children = Policy.holdActivityRows(current: [next], held: [old])[0]["processes"].array
        XCTAssertEqual(children.count, 1); XCTAssertEqual(children[0]["id"].string, "7:start1")
        XCTAssertTrue(children[0]["exited"].bool)
        XCTAssertEqual(Policy.holdActivityRows(current: [next], held: [next])[0]["processes"].array[0]["id"].string, "7:start2")
    }
}
