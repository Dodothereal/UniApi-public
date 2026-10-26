import Foundation

public enum NativeActivityFold {
    private static func bounded(_ n: Double) -> Double { max(0, min(100, n)) }
    private static func sum(_ values: [JSONValue]) -> JSONValue {
        let numbers = values.compactMap(NativeHardwarePolicies.number)
        return numbers.isEmpty ? .null : .number(numbers.reduce(0, +))
    }
    public static func identity(_ process: JSONValue) -> String { process["pid"].string + "@" + process["started"].string }
    public static func snapshot(_ raw: JSONValue, previous: JSONValue = .null) throws -> JSONValue {
        guard case .array = raw["processes"], case .array = raw["apps"], let monotonic = NativeHardwarePolicies.number(raw["monotonic"]), let total = NativeHardwarePolicies.number(raw["totalMemory"]), total > 0, let cores = NativeHardwarePolicies.number(raw["logicalCpus"]), cores >= 1 else { throw NativeFailure("The Activity sample is incomplete") }
        let elapsed = monotonic - previous["monotonic"].double
        let comparable = !previous.isNull && elapsed >= 0.1 && elapsed <= 15 && previous["logicalCpus"].double == cores
        let old = Dictionary(previous["processes"].array.map { (identity($0), $0) }, uniquingKeysWith: { first, _ in first })
        func rate(_ value: JSONValue, _ before: JSONValue) -> JSONValue {
            guard comparable, let n = NativeHardwarePolicies.number(value), let p = NativeHardwarePolicies.number(before), n >= p else { return .null }
            return .number((n - p) / elapsed)
        }
        let rows: [JSONValue] = raw["processes"].array.map { process in
            var row = process, prior = comparable ? old[identity(process)] ?? .null : .null
            row["id"] = .string(identity(process))
            var cpu: JSONValue = .null
            if comparable, let current = UInt64(process["cpuNs"].string), let before = UInt64(prior["cpuNs"].string), current >= before { cpu = .number(bounded(Double(current - before) / 1e9 / elapsed / cores * 100)) }
            row["cpuPercent"] = cpu
            row["memoryPercent"] = NativeHardwarePolicies.number(process["memoryBytes"]).map { .number(bounded($0 / total * 100)) } ?? .null
            row["readPerSecond"] = rate(process["readBytes"], prior["readBytes"])
            row["writePerSecond"] = rate(process["writeBytes"], prior["writeBytes"])
            row.object.keys.filter { ["cpuNs", "readBytes", "writeBytes"].contains($0) }.forEach { key in var d = row.object; d.removeValue(forKey: key); row = .object(d) }
            return row
        }
        let byPID = Dictionary(rows.map { ($0["pid"].int, $0) }, uniquingKeysWith: { first, _ in first })
        let apps = raw["apps"].array.filter { byPID[$0["pid"].int] != nil }
        let appByPID = Dictionary(apps.map { ($0["pid"].int, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [String: (app: JSONValue, root: JSONValue, members: [JSONValue])] = [:]
        for row in rows {
            var app = appByPID[row["pid"].int] ?? .null, parent = row, visited = Set<Int>()
            while app.isNull, parent["ppid"].int > 1, visited.insert(parent["ppid"].int).inserted {
                guard let next = byPID[parent["ppid"].int], next["uid"] == row["uid"] else { break }
                app = appByPID[next["pid"].int] ?? .null; parent = next
            }
            if app.isNull {
                let candidates = apps.filter { byPID[$0["pid"].int]?["uid"] == row["uid"] && row["path"].string.hasPrefix($0["bundlePath"].string + "/") }.sorted { $0["bundlePath"].string.count > $1["bundlePath"].string.count }
                if let first = candidates.first, candidates.filter({ $0["bundlePath"] == first["bundlePath"] }).count == 1 { app = first }
            }
            let root = app.isNull ? row : byPID[app["pid"].int]!
            let key = (app.isNull ? "process:" : "app:") + root["id"].string
            var bucket = grouped[key] ?? (app, root, []); bucket.members.append(row); grouped[key] = bucket
        }
        let groups: [JSONValue] = grouped.keys.sorted().map { key in
            let bucket = grouped[key]!
            let members = bucket.members.sorted { $0["id"] == bucket.root["id"] ? true : $1["id"] == bucket.root["id"] ? false : $0["pid"].int < $1["pid"].int }
            let cpu = sum(members.map { $0["cpuPercent"] }), memory = sum(members.map { $0["memoryBytes"] })
            return ["id": .string(key), "kind": .string(bucket.app.isNull ? "background" : "app"), "name": bucket.app.isNull ? bucket.root["name"] : bucket.app["name"], "bundleId": bucket.app.isNull ? .null : bucket.app["bundleId"], "rootId": bucket.root["id"], "processes": .array(members), "cpuPercent": cpu.isNull ? .null : .number(bounded(cpu.double)), "memoryBytes": memory, "memoryPercent": memory.isNull ? .null : .number(bounded(memory.double / total * 100)), "readPerSecond": sum(members.map { $0["readPerSecond"] }), "writePerSecond": sum(members.map { $0["writePerSecond"] }), "partial": .bool(members.contains { $0["cpuPercent"].isNull || $0["memoryBytes"].isNull || $0["memoryKind"].string == "resident" }), "protectedReason": members.first(where: { !$0["protectedReason"].isNull })?["protectedReason"] ?? .null]
        }
        var cpu: JSONValue = .null
        if comparable, raw["cpuTicks"].array.count == 4, previous["cpuTicks"].array.count == 4 {
            let ticks = zip(raw["cpuTicks"].array, previous["cpuTicks"].array).map { ($0.double - $1.double + 4294967296).truncatingRemainder(dividingBy: 4294967296) }
            let total = ticks.reduce(0, +)
            if total > 0 { cpu = .number(bounded((total - ticks[2]) / total * 100)) }
        }
        return ["timestamp": raw["timestamp"], "logicalCpus": raw["logicalCpus"], "totalMemory": raw["totalMemory"], "cpuPercent": cpu, "memoryUsed": raw["memoryUsed"], "memoryPercent": raw["memoryUsed"].isNull ? .null : .number(bounded(raw["memoryUsed"].double / total * 100)), "compressedBytes": raw["compressedBytes"], "swapUsed": raw["swapUsed"], "pressure": raw["pressure"], "groups": .array(groups), "processCount": .number(Double(rows.count)), "omitted": raw["omitted"], "sampledCount": .number(Double(rows.filter { !$0["cpuPercent"].isNull }.count))]
    }
    public static func action(_ input: JSONValue) throws -> JSONValue {
        guard ["quit", "force"].contains(input["mode"].string), case .bool(let individual) = input["process"] else { throw NativeFailure("Invalid termination request") }
        let pattern = individual ? "^[1-9][0-9]{0,9}@[0-9]{1,20}:[0-9]{1,6}$" : "^(app|process):[1-9][0-9]{0,9}@[0-9]{1,20}:[0-9]{1,6}$"
        guard input["id"].string.range(of: pattern, options: .regularExpression) != nil else { throw NativeFailure("Invalid process identity") }
        return ["id": input["id"], "mode": input["mode"], "process": .bool(individual)]
    }
    public static func ticksToNanoseconds(user: UInt64, system: UInt64, numerator: UInt32, denominator: UInt32) -> UInt64? {
        guard denominator > 0 else { return nil }
        let a = user.multipliedFullWidth(by: UInt64(numerator)), b = system.multipliedFullWidth(by: UInt64(numerator))
        let sum = a.low.addingReportingOverflow(b.low)
        let high = a.high &+ b.high &+ (sum.overflow ? 1 : 0)
        guard high < UInt64(denominator) else { return nil }
        return UInt64(denominator).dividingFullWidth((high: high, low: sum.partialValue)).quotient
    }
}
