import Foundation

public enum NativeHardwarePolicies {
    public static func number(_ value: JSONValue) -> Double? { if case .number(let n) = value, n.isFinite { return n }; return nil }
    public static func fanCommand(_ value: JSONValue) throws -> JSONValue {
        guard case .object(let body) = value, Set(body.keys).isSubset(of: ["command", "duration", "speeds", "curve"]),
              ["automatic", "cooler", "curve", "boost", "manual"].contains(value["command"].string) else { throw NativeFailure("Invalid fan command") }
        let mode = value["command"].string
        if let supplied = body["duration"] {
            guard let duration = number(supplied), (duration >= 10 || mode == "manual" && duration == 0), duration <= 3600 else { throw NativeFailure("Fan duration must be 10–3600 seconds, or Never for Manual") }
        }
        if ["boost", "manual"].contains(mode), body["duration"] == nil { throw NativeFailure("Choose a duration") }
        if mode == "manual" {
            guard case .array(let speeds) = value["speeds"], (1...8).contains(speeds.count), speeds.allSatisfy({ number($0).map { (1200...20000).contains($0) } ?? false }) else { throw NativeFailure("Manual targets must be valid RPM values for every fan") }
        }
        if mode == "curve" {
            guard case .array(let curve) = value["curve"], curve.count == 4 else { throw NativeFailure("A curve requires four points") }
            var temperature: Double = 25, percent: Double = 0
            for point in curve {
                guard let t = number(point["temperature"]), let p = number(point["percent"]), (30...90).contains(t), t - temperature >= 5, p >= percent, p <= 100 else { throw NativeFailure("Curve temperatures need 5-degree spacing and monotone output") }
                temperature = t; percent = p
            }
            guard percent == 100 else { throw NativeFailure("The final curve point must reach full output") }
        }
        return value
    }
    public static func keptFanCommand(_ value: JSONValue) -> JSONValue {
        guard (try? fanCommand(value)) != nil else { return .null }
        let mode = value["command"].string
        if mode == "manual" { return value["duration"].double == 0 ? value : .null }
        return ["cooler", "curve"].contains(mode) && value.object["duration"] == nil ? value : .null
    }
    public static func fanPoll(mode: String, ok: Bool, kept: Bool, releaseRequested: Bool, snapshotAge: Double, clientAge: Double, reassertIn: Double) -> String {
        let held = kept && !releaseRequested
        if releaseRequested || snapshotAge > 6000 || !held && clientAge > 10000 { return mode == "automatic" && ok ? "status" : "automatic" }
        if held && mode == "automatic" && reassertIn <= 0 { return "reassert" }
        return "status"
    }
    public static func fanBackoff(heldMs: Double, previous: Double) -> Double { heldMs >= 120000 ? 15000 : min(300000, max(15000, previous * 2)) }
    public static func fanSnapshot(_ value: JSONValue) -> Bool {
        guard number(value["date"]) != nil, let thermal = number(value["thermal"]), thermal.rounded() == thermal, (0...3).contains(thermal),
              case .array(let fans) = value["fans"], fans.count <= 8,
              case .array(let sensors) = value["sensors"], sensors.count <= 512 else { return false }
        return fans.allSatisfy { fan in
            guard let id = number(fan["id"]), id.rounded() == id else { return false }
            return ["actual", "target", "minimum", "maximum", "mode"].allSatisfy { number(fan[$0]) != nil }
        } && sensors.allSatisfy {
            guard case .string(let id) = $0["id"], id.count <= 120, let reading = number($0["value"]) else { return false }
            return reading >= 10 && reading < 130
        }
    }
    public static func batterySnapshot(_ value: JSONValue) -> JSONValue {
        guard case .object = value, value["present"].bool, let percent = number(value["percent"]), (0...100).contains(percent) else { return .null }
        var result: JSONValue = ["present": true, "percent": .number(percent), "charging": .bool(value["charging"].bool), "externalConnected": .bool(value["externalConnected"].bool), "fullyCharged": .bool(value["fullyCharged"].bool)]
        for key in ["health", "cycleCount", "notChargingReason"] { if let n = number(value[key]) { result[key] = .number(n) } }
        return result
    }
    public static func batteryState(_ value: JSONValue) throws -> JSONValue {
        guard case .object = value, value["ok"].bool else { throw NativeFailure("The battery helper returned an unreadable state") }
        let levels = value["levels"].array.compactMap(number).filter { $0.rounded() == $0 && $0 > 0 && $0 <= 100 }.sorted()
        let limit = number(value["limit"]).flatMap { $0.rounded() == $0 && $0 > 0 && $0 <= 100 ? $0 : nil }
        return ["ok": true, "supported": .bool(value["supported"].bool), "levels": .array(levels.map(JSONValue.number)), "limit": limit.map(JSONValue.number) ?? .null, "engaged": .bool(value["engaged"].bool), "battery": batterySnapshot(value["battery"])]
    }
    public static func batteryTarget(_ value: JSONValue, levels: [JSONValue], hold: Bool) throws -> Int {
        guard let target = number(value), target.rounded() == target else { throw NativeFailure("Choose a whole percentage") }
        let available = levels.compactMap(number)
        if hold {
            guard target >= 25 else { throw NativeFailure("A held level must be at least 25%") }
            guard target < (available.min() ?? 80) else { throw NativeFailure("Use the native charge limit for this level") }
        } else {
            guard !available.isEmpty else { throw NativeFailure("This Mac has not reported its accepted charge limits") }
            guard available.contains(target) else { throw NativeFailure("Choose a charge limit accepted by macOS") }
        }
        return Int(target)
    }
    public static func holdReport(_ value: JSONValue, target: Int, now: Double) -> JSONValue {
        guard value["version"] == 2, number(value["target"]) == Double(target), let updated = number(value["updatedAt"]), updated <= now + 1000, now - updated <= 15000,
              ["pending", "inhibiting", "charging", "write-refused", "off", "on-battery", "telemetry-unavailable"].contains(value["state"].string) else { return ["healthy": false] }
        var output: JSONValue = ["healthy": true, "state": value["state"]]
        let battery = value["battery"]
        if case .bool = battery["external"], case .bool = battery["charging"] {
            var raw = battery; raw["present"] = true; raw["externalConnected"] = battery["external"]
            let parsed = batterySnapshot(raw)
            if !parsed.isNull { output["reportedBattery"] = parsed }
        }
        return output
    }
    public static func batteryPhase(_ status: JSONValue) -> String {
        guard status["supported"].bool else { return "unsupported" }
        let hold = status["hold"]
        if hold["installed"].bool {
            if !hold["healthy"].bool { return "control-pending" }
            if ["write-refused", "telemetry-unavailable"].contains(hold["state"].string) { return "control-error" }
            if hold["active"].bool {
                if hold["state"].string == "pending" { return "control-pending" }
                let measured = hold["reportedBattery"]
                if measured.isNull { return "control-pending" }
                if !measured["externalConnected"].bool { return "on-battery" }
                if hold["state"].string == "inhibiting" {
                    if measured["charging"].bool { return "control-pending" }
                    return measured["percent"].double > hold["target"].double ? "above-limit" : "holding-low"
                }
                return measured["percent"].double < hold["target"].double ? (measured["charging"].bool ? "charging-to-limit" : "below-limit-idle") : "control-pending"
            }
            if hold["state"].string != "off" { return "control-pending" }
        }
        let limit = status["limit"], battery = status["battery"]
        if limit.isNull || limit.double >= 100 { return "off" }
        if battery.isNull { return "control-pending" }
        if !battery["externalConnected"].bool { return "on-battery" }
        if battery["percent"].double >= limit.double && battery["charging"].bool { return "control-pending" }
        if battery["percent"].double > limit.double { return "above-limit" }
        if battery["percent"].double == limit.double { return "holding" }
        return battery["charging"].bool ? "charging-to-limit" : "below-limit-idle"
    }
}
