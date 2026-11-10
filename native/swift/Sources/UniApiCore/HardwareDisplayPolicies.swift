import Foundation

/// Presentation rules only: these helpers never load stores, sample hardware or send commands.
public enum NativeHardwareDisplayPolicies {
    /// AppStorage fallback only: a saved or migrated value, including Never (0), wins.
    public static let defaultFanDuration = 600
    public static let fanDurations = [0, 60, 300, 600, 900, 1800, 3600]
    public static let boostDurations = fanDurations.filter { $0 > 0 }
    public static let defaultFanCurve: [JSONValue] = [
        ["temperature": 45, "percent": 0], ["temperature": 65, "percent": 25],
        ["temperature": 80, "percent": 65], ["temperature": 90, "percent": 100]
    ]
    public static func number(_ value: JSONValue) -> Double? {
        if case .number(let value) = value, value.isFinite { return value }
        return nil
    }

    /// The current policy may have been set by another client between OS level-set changes.
    /// Keep it visible even when the optional lower-target helper is absent.
    public static func batteryTarget(_ status: JSONValue) -> Int {
        let raw = status["hold"]["active"].bool ? status["hold"]["target"] : status["limit"]
        guard let target = number(raw), target.rounded() == target, (1...100).contains(target) else { return 100 }
        return Int(target)
    }
    public static func batteryLevels(_ status: JSONValue) -> [Int] {
        let native = status["levels"].array.compactMap { value -> Int? in
            guard let n = number(value), n.rounded() == n, (1...100).contains(n) else { return nil }
            return Int(n)
        }
        let minimum = native.min() ?? 80
        let floor = number(status["holdMin"]).map { Int(max(25, min(100, $0.rounded()))) } ?? 25
        let lower = status["hold"]["installed"].bool && floor < minimum ? Array(floor..<minimum) : []
        return Array(Set(lower + native + [batteryTarget(status), 100])).sorted()
    }
    public static func fanModeName(_ mode: String) -> String {
        ["automatic": "Automatic", "cooler": "Cooler", "curve": "Custom curve", "boost": "Boost", "manual": "Manual", "unknown": "Recovery pending", "external": "External control"][mode] ?? mode.capitalized
    }
    public static func fanThermalLabel(_ snapshot: JSONValue) -> String {
        guard let pressure = number(snapshot["thermal"]), pressure.rounded() == pressure, (0...3).contains(pressure) else { return "Telemetry unavailable" }
        return ["Thermals normal", "Thermals elevated", "Thermals serious", "Thermals critical"][Int(pressure)]
    }
    public static func fanMenuReadings(_ state: JSONValue) -> (title: String, temperature: String, rpm: String, spinning: Bool) {
        let cpu = state["snapshot"]["sensors"].array.first { $0["id"].string == "TCMb" }.flatMap { number($0["value"]) }
        let fahrenheit = state["preferences"]["unit"].string == "f"
        let temperature = cpu.map { String(format: "%.0f°", fahrenheit ? $0 * 1.8 + 32 : $0) } ?? "—"
        let rpm = state["snapshot"]["fans"].array.compactMap { number($0["actual"]) }.max()
        let rpmText = rpm.map { String(format: "%.0f", $0) } ?? "—"
        let title: String
        switch state["preferences"]["menuMetric"].string {
        case "rpm": title = " " + rpmText
        case "both": title = " " + temperature + "  " + rpmText
        case "icon": title = ""
        default: title = " " + temperature
        }
        return (title, temperature, rpmText, (rpm ?? 0) > 0)
    }
    public static func manualFanCommand(snapshot: JSONValue, id: Int, rpm: Double, duration: Int) -> JSONObject? {
        guard rpm.isFinite, !snapshot["fans"].array.isEmpty else { return nil }
        var found = false, speeds: [JSONValue] = []
        for fan in snapshot["fans"].array {
            guard let minimum = number(fan["minimum"]), let maximum = number(fan["maximum"]), minimum <= maximum else { return nil }
            let value: Double
            if fan["id"].int == id { found = true; value = rpm }
            else { guard let current = number(fan["target"]).flatMap({ $0 > 0 ? $0 : nil }) ?? number(fan["actual"]) else { return nil }; value = current }
            speeds.append(.number(max(minimum, min(maximum, value))))
        }
        let command: JSONObject = ["command": "manual", "duration": .number(Double(duration)), "speeds": .array(speeds)]
        return found && (try? NativeHardwarePolicies.fanCommand(.object(command))) != nil ? command : nil
    }
    public static func typedFanRPM(_ text: String, minimum: Double, maximum: Double) -> Double? {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum,
              let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")),
              value.isFinite, (minimum...maximum).contains(value) else { return nil }
        return value.rounded()
    }

    /// Match the web trace's 12-second gap rule, including memory after pause/resume.
    public static func activityHistorySegments(_ points: [(time: Double, value: Double?)]) -> [Int] {
        var segment = 0, previous: Double?
        return points.map { point in
            if point.value == nil || previous.map({ point.time - $0 > 12000 || point.time <= $0 }) == true { segment += 1 }
            previous = point.time
            return segment
        }
    }

    public static func fanHistoryCSV(_ points: [JSONValue]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        func timestamp(_ value: JSONValue) -> String {
            guard let ms = number(value) else { return "" }
            return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        func cell(_ value: JSONValue) -> String { number(value).map { JSONValue.number($0).string } ?? "" }
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["timestamp,end,metric,mean,min,max,samples,resolution_ms"]
        for point in points {
            func add(_ metric: String, _ values: [JSONValue]) {
                let cells = [timestamp(point["mean"]["date"]), timestamp(point["end"]), quoted(metric)]
                    + values.map(cell) + [cell(point["count"]), cell(point["resolutionMs"])]
                lines.append(cells.joined(separator: ","))
            }
            let kinds = ["mean", "min", "max"]
            let sensorIDs = Set(kinds.flatMap { point[$0]["sensors"].array.map { $0["id"].string } }).sorted()
            for id in sensorIDs {
                add("temperature_c:" + id, kinds.map { kind in
                    point[kind]["sensors"].array.first { $0["id"].string == id }?["value"] ?? .null
                })
            }
            let fanIDs = Set(kinds.flatMap { point[$0]["fans"].array.compactMap { number($0["id"]) } }).sorted()
            for id in fanIDs where id >= 0 && id.rounded() == id {
                add("fan_\(JSONValue.number(id + 1).string)_rpm", kinds.map { kind in
                    point[kind]["fans"].array.first { number($0["id"]) == id }?["actual"] ?? .null
                })
            }
            add("thermal_pressure", kinds.map { point[$0]["thermal"] })
        }
        return lines.joined(separator: "\n")
    }

    /// Calendar arithmetic includes the entire final local day, including 23/25-hour DST days.
    public static func fanHistoryDays(from: Date, through: Date, calendar: Calendar = .current) throws -> JSONObject {
        guard from.timeIntervalSince1970.isFinite, through.timeIntervalSince1970.isFinite else {
            throw NativeFailure("Choose valid history dates")
        }
        let start = calendar.startOfDay(for: from), last = calendar.startOfDay(for: through)
        guard start <= last, start.timeIntervalSince1970 >= 0,
              let next = calendar.date(byAdding: .day, value: 1, to: last) else {
            throw NativeFailure("The history end date must follow its start date")
        }
        return ["since": .number((start.timeIntervalSince1970 * 1000).rounded()),
                "until": .number((next.timeIntervalSince1970 * 1000).rounded() - 1)]
    }

    /// Changing a timer reissues the active profile; Automatic/External and untimed Boost have no timer to set.
    public static func currentFanCommand(state: JSONValue, duration: Int, curve: [JSONValue]) -> JSONObject? {
        guard duration == 0 || (10...3600).contains(duration), !state["snapshot"].isNull else { return nil }
        let mode = state["control"]["mode"].string
        var command: JSONObject = ["command": .string(mode)]
        switch mode {
        case "manual":
            let fans = state["snapshot"]["fans"].array
            guard !fans.isEmpty else { return nil }
            var speeds: [JSONValue] = []
            for fan in fans {
                guard let minimum = number(fan["minimum"]), let maximum = number(fan["maximum"]),
                      minimum <= maximum,
                      let target = number(fan["target"]).flatMap({ $0 > 0 ? $0 : nil }) ?? number(fan["actual"]) else { return nil }
                speeds.append(.number(max(minimum, min(maximum, target))))
            }
            command["speeds"] = .array(speeds)
            command["duration"] = .number(Double(duration))
        case "boost":
            guard duration > 0 else { return nil }
            command["duration"] = .number(Double(duration))
        case "cooler":
            if duration > 0 { command["duration"] = .number(Double(duration)) }
        case "curve":
            guard validFanCurve(curve) else { return nil }
            command["curve"] = .array(curve)
            if duration > 0 { command["duration"] = .number(Double(duration)) }
        default: return nil
        }
        return command
    }

    public static func validFanCurve(_ points: [JSONValue]) -> Bool {
        guard points.count == 4 else { return false }
        var previousTemperature = 25.0, previousPercent = 0.0
        for point in points {
            guard case .object = point, let t = number(point["temperature"]), let p = number(point["percent"]),
                  (30...90).contains(t), (0...100).contains(p),
                  t - previousTemperature >= 5, p >= previousPercent else { return false }
            previousTemperature = t; previousPercent = p
        }
        return previousPercent == 100
    }
    public static func fanCurvePercent(_ points: [JSONValue], temperature: Double) -> Double {
        guard temperature.isFinite, validFanCurve(points) else { return 100 }
        if temperature <= points[0]["temperature"].double { return points[0]["percent"].double }
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            if temperature <= b["temperature"].double {
                return a["percent"].double + (b["percent"].double - a["percent"].double) * (temperature - a["temperature"].double) / (b["temperature"].double - a["temperature"].double)
            }
        }
        return 100
    }
    public static func curveBounds(_ points: [JSONValue], index: Int) -> (temperature: ClosedRange<Double>, percent: ClosedRange<Double>)? {
        guard validFanCurve(points), points.indices.contains(index) else { return nil }
        let lowT = index == 0 ? 30 : points[index - 1]["temperature"].double + 5
        let highT = index == 3 ? 90 : points[index + 1]["temperature"].double - 5
        let lowP = index == 3 ? 100 : index == 0 ? 0 : points[index - 1]["percent"].double
        let highP = index == 3 ? 100 : points[index + 1]["percent"].double
        return (lowT...highT, lowP...highP)
    }
    public static func moveFanCurve(_ points: [JSONValue], index: Int, temperature: Double, percent: Double) -> [JSONValue] {
        guard temperature.isFinite, percent.isFinite, let bounds = curveBounds(points, index: index) else { return points }
        var changed = points
        // Clamp again after rounding so a valid fractional saved neighbour cannot be crossed.
        func roundedClamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
            max(range.lowerBound, min(range.upperBound, max(range.lowerBound, min(range.upperBound, value)).rounded()))
        }
        changed[index]["temperature"] = .number(roundedClamp(temperature, bounds.temperature))
        changed[index]["percent"] = .number(roundedClamp(percent, bounds.percent))
        return changed
    }
    public static func curveTextValue(_ text: String, bounds: ClosedRange<Double>) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite else { return nil }
        return max(bounds.lowerBound, min(bounds.upperBound, value))
    }

    public static func sensorGroup(_ id: String) -> String {
        if id.hasPrefix("HID:") { return id.contains("ACC") ? "CPU" : id.contains("GPU") ? "GPU" : "System" }
        if ["TC", "Tp", "Te"].contains(where: id.hasPrefix) { return "CPU" }
        if ["TG", "Tg"].contains(where: id.hasPrefix) { return "GPU" }
        if id.hasPrefix("TB") { return "Battery" }
        if ["Tm", "TM", "TR"].contains(where: id.hasPrefix) { return "Memory" }
        return id.hasPrefix("TH") ? "Storage" : "System"
    }
    public static func sensorName(_ id: String) -> String {
        let names = ["TCMb": "CPU die average", "TCMz": "CPU die maximum", "TB0T": "Battery", "TB1T": "Battery cell 1", "TB2T": "Battery cell 2", "TH0x": "SSD", "TAOL": "Ambient", "TS0P": "Palm rest", "TaLP": "Left airflow", "TaRF": "Right airflow", "TW0P": "Wireless"]
        if let name = names[id] { return name }
        if id.hasPrefix("HID:") {
            return String(id.dropFirst(4)).replacingOccurrences(of: "pACC MTR Temp Sensor", with: "Performance core ")
                .replacingOccurrences(of: "eACC MTR Temp Sensor", with: "Efficiency core ").replacingOccurrences(of: "GPU MTR Temp Sensor", with: "GPU core ")
        }
        return sensorGroup(id) + " sensor " + id
    }
    public static func sensorRows(_ sensors: [JSONValue], favorites: Set<String>, group: String, query: String) -> [JSONValue] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sensors.filter {
            let id = $0["id"].string
            let inGroup = group == "All" || (group == "Favorites" ? favorites.contains(id) : sensorGroup(id) == group)
            return inGroup && (query.isEmpty || (sensorName(id) + " " + id).localizedCaseInsensitiveContains(query))
        }.sorted {
            let a = $0["id"].string, b = $1["id"].string
            if favorites.contains(a) != favorites.contains(b) { return favorites.contains(a) }
            let order = sensorName(a).localizedStandardCompare(sensorName(b))
            return order == .orderedSame ? a < b : order == .orderedAscending
        }
    }
    public static func temperature(_ snapshot: JSONValue, group: String) -> Double? {
        let sensors = snapshot["sensors"].array
        if group == "CPU", let average = sensors.first(where: { $0["id"].string == "TCMb" }), let value = number(average["value"]) { return value }
        return sensors.filter { sensorGroup($0["id"].string) == group }.compactMap { number($0["value"]) }.max()
    }

    public static func diskRate(_ row: JSONValue) -> Double? {
        let read = number(row["readPerSecond"]), write = number(row["writePerSecond"])
        return read == nil && write == nil ? nil : (read ?? 0) + (write ?? 0)
    }
    public static func sortActivity(_ groups: [JSONValue], by sort: String, descending: Bool) -> [JSONValue] {
        func value(_ row: JSONValue) -> Double? {
            if sort == "disk" { return diskRate(row) }
            let key = ["cpu": "cpuPercent", "memory": "memoryBytes", "read": "readPerSecond", "write": "writePerSecond"][sort] ?? sort
            return number(row[key])
        }
        return groups.sorted { a, b in
            if sort != "name" {
                let av = value(a), bv = value(b)
                if (av == nil) != (bv == nil) { return av != nil }
                if let av, let bv, av != bv { return descending ? av > bv : av < bv }
            }
            let names = a["name"].string.localizedStandardCompare(b["name"].string)
            if names != .orderedSame { return sort == "name" && descending ? names == .orderedDescending : names == .orderedAscending }
            return a["id"].string < b["id"].string
        }
    }
    /// Hold each existing child's slot as well as its group; defer newly spawned children until release.
    public static func holdActivityRows(current: [JSONValue], held: [JSONValue]) -> [JSONValue] {
        func indexed(_ rows: [JSONValue]) -> [String: JSONValue] {
            Dictionary(rows.map { ($0["id"].string, $0) }, uniquingKeysWith: { first, _ in first })
        }
        func exited(_ row: JSONValue) -> JSONValue {
            var row = row; row["exited"] = true
            for key in ["cpuPercent", "memoryBytes", "memoryPercent", "readPerSecond", "writePerSecond"] { row[key] = .null }
            return row
        }
        let latest = indexed(current), heldIDs = Set(held.map { $0["id"].string })
        let kept: [JSONValue] = held.map { prior in
            let fresh = latest[prior["id"].string]
            var group = fresh ?? exited(prior)
            let children = indexed(fresh?["processes"].array ?? [])
            group["processes"] = .array(prior["processes"].array.map { children[$0["id"].string] ?? exited($0) })
            return group
        }
        return kept + current.filter { !heldIDs.contains($0["id"].string) }
    }

    // MARK: - Energy Display Policies

    public static func energySensorGroup(_ id: String, unit: String) -> String {
        if id.hasPrefix("TELE:") { return "Telemetry" }
        if unit == "V" { return "Voltage (V)" }
        if unit == "A" { return "Current (A)" }
        if ["PSTR", "PDTR", "PHPB", "PHPS", "PZC0", "PZC1", "PZCU"].contains(id) { return "System Power" }
        if ["PMVR", "PPMR", "PPSR", "PCPC", "PCPG", "PC0C", "PC0G", "PG0R"].contains(id) || id.hasPrefix("PP") || id.hasPrefix("PR") { return "Processor & SoC" }
        if ["PUTC", "PU5C", "PUAC", "PO3R", "PO5R", "PBLC", "PB0R"].contains(id) { return "Rails & Ports" }
        return "Power (W)"
    }

    public static func energySensorName(_ id: String) -> String {
        let names: [String: String] = [
            "TELE:WALL": "Wall power estimate",
            "TELE:SYSI": "System DC-in power",
            "TELE:SYSL": "System load power",
            "TELE:BATT": "Battery net power flow",
            "TELE:LOSS": "Adapter efficiency loss",
            "TELE:VIN": "DC-in voltage",
            "TELE:IIN": "DC-in current",
            "TELE:VBAT": "Battery pack voltage",
            "TELE:IBAT": "Battery pack current",
            "PSTR": "System total power",
            "PDTR": "DC-in total power",
            "PMVR": "SoC main voltage regulator",
            "PPMR": "PMIC & memory rail power",
            "PPSR": "System & PCIe rail power",
            "PHPS": "Thermal subsystem power",
            "PHPB": "Adapter power budget",
            "PUTC": "USB-C total power",
            "PU5C": "USB-C 5V rail power",
            "PUAC": "USB-C accessory power",
            "PO3R": "3.3V system rail power",
            "PO5R": "5V system rail power",
            "PZC0": "Power zone C0",
            "PZC1": "Power zone C1",
            "PZCU": "Power zone CPU/SoC",
            "PCPC": "CPU package power",
            "PCPG": "GPU package power",
            "PBLC": "Backlight power",
            "VD0R": "DC-in rail voltage",
            "ID0R": "DC-in rail current",
            "IMVR": "SoC regulator current",
            "IPMR": "PMIC rail current",
            "IPSR": "System rail current",
            "IO3R": "3.3V rail current",
            "IO5R": "5V rail current",
            "IU5C": "USB-C 5V rail current",
            "IUAC": "USB-C accessory current"
        ]
        if let known = names[id] { return known }
        if id.hasPrefix("PP") { return "Core rail " + id }
        if id.hasPrefix("PR") { return "Cluster rail " + id }
        if id.hasPrefix("VP") { return "Core rail voltage " + id }
        if id.hasPrefix("VR") { return "Cluster rail voltage " + id }
        if id.hasPrefix("IP") { return "Core rail current " + id }
        if id.hasPrefix("I0") { return "Input rail current " + id }
        return "Electrical sensor " + id
    }

    public static func energySensorRows(_ sensors: [JSONValue], favorites: Set<String>, group: String, query: String) -> [JSONValue] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sensors.filter { sensor in
            let id = sensor["id"].string
            let unit = sensor["unit"].string
            let category = energySensorGroup(id, unit: unit)
            let matchesGroup: Bool
            switch group {
            case "All": matchesGroup = true
            case "Favorites": matchesGroup = favorites.contains(id)
            case "Power (W)": matchesGroup = unit == "W"
            case "Voltage (V)": matchesGroup = unit == "V"
            case "Current (A)": matchesGroup = unit == "A"
            default: matchesGroup = category == group
            }
            return matchesGroup && (trimmed.isEmpty || (energySensorName(id) + " " + id + " " + category).localizedCaseInsensitiveContains(trimmed))
        }.sorted { a, b in
            let aid = a["id"].string, bid = b["id"].string
            if favorites.contains(aid) != favorites.contains(bid) { return favorites.contains(aid) }
            if aid.hasPrefix("TELE:") != bid.hasPrefix("TELE:") { return aid.hasPrefix("TELE:") }
            let order = energySensorName(aid).localizedStandardCompare(energySensorName(bid))
            return order == .orderedSame ? aid < bid : order == .orderedAscending
        }
    }

    public static func energyBadgeText(_ state: JSONValue) -> String {
        let snapshot = state["snapshot"]
        guard !snapshot.isNull else { return "" }
        let metric = state["preferences"]["badgeMetric"].string
        switch metric {
        case "none":
            return ""
        case "wallPower":
            guard let w = number(snapshot["wallPowerW"]) else { return "" }
            return String(format: "%.1fW", w)
        case "batteryNet":
            guard let b = number(snapshot["batteryPowerW"]) else { return "" }
            return String(format: "%+.1fW", b)
        default:
            guard let l = number(snapshot["systemLoadW"]) else { return "" }
            return String(format: "%.1fW", l)
        }
    }

    public static func formatEnergyWh(_ wh: Double?) -> String {
        guard let wh, wh.isFinite else { return "—" }
        let absWh = abs(wh)
        if absWh >= 1000 {
            return String(format: "%.2f kWh", wh / 1000.0)
        } else if absWh >= 10 {
            return String(format: "%.1f Wh", wh)
        } else {
            return String(format: "%.2f Wh", wh)
        }
    }

    public static func formatWatts(_ watts: Double?, signed: Bool = false) -> String {
        guard let watts, watts.isFinite else { return "—" }
        return String(format: signed ? "%+.1f W" : "%.1f W", watts)
    }

    public static func formatCost(wh: Double?, ratePerKwh: Double, currency: String) -> String {
        guard let wh, wh.isFinite, ratePerKwh >= 0 else { return "—" }
        let cost = (max(0, wh) / 1000.0) * ratePerKwh
        if cost < 0.01 && cost > 0 {
            return String(format: "%@%.4f", currency, cost)
        }
        return String(format: "%@%.2f", currency, cost)
    }

    public static func energyHistoryCSV(_ points: [JSONValue]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        func timestamp(_ value: JSONValue) -> String {
            guard let ms = number(value) else { return "" }
            return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        func cell(_ value: JSONValue) -> String { number(value).map { JSONValue.number($0).string } ?? "" }
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["timestamp,end,metric,mean,min,max,energy_wh,samples,resolution_ms"]
        let metrics: [(key: String, label: String, whKey: String?)] = [
            ("systemLoadW", "system_load_w", "systemEnergyWh"),
            ("wallPowerW", "wall_power_w", "wallEnergyWh"),
            ("systemPowerInW", "system_power_in_w", "systemInEnergyWh"),
            ("batteryPowerW", "battery_power_w", "batteryNetWh"),
            ("adapterLossW", "adapter_loss_w", "adapterLossWh"),
            ("voltageInV", "voltage_in_v", nil),
            ("currentInA", "current_in_a", nil)
        ]
        for point in points {
            let kinds = ["mean", "min", "max"]
            for m in metrics {
                let wh = m.whKey.map { cell(point[$0]) } ?? ""
                let row = [
                    timestamp(point["mean"]["date"]),
                    timestamp(point["end"]),
                    quoted(m.label),
                    cell(point["mean"][m.key]),
                    cell(point["min"][m.key]),
                    cell(point["max"][m.key]),
                    wh,
                    cell(point["count"]),
                    cell(point["resolutionMs"])
                ]
                lines.append(row.joined(separator: ","))
            }
            let sensorIDs = Set(kinds.flatMap { point[$0]["sensors"].array.map { $0["id"].string } }).sorted()
            for id in sensorIDs {
                let unit = point["mean"]["sensors"].array.first(where: { $0["id"].string == id })?["unit"].string ?? "W"
                let values = kinds.map { kind in
                    point[kind]["sensors"].array.first { $0["id"].string == id }?["value"] ?? .null
                }
                let row = [
                    timestamp(point["mean"]["date"]),
                    timestamp(point["end"]),
                    quoted("sensor_\(unit.lowercased()):\(id)"),
                    cell(values[0]),
                    cell(values[1]),
                    cell(values[2]),
                    "",
                    cell(point["count"]),
                    cell(point["resolutionMs"])
                ]
                lines.append(row.joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n")
    }
}

