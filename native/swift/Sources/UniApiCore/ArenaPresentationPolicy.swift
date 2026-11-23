import Foundation

public struct ArenaMatchSelection: Equatable, Sendable {
    public enum Scope: Sendable, Hashable { case judge, history }
    private var selection: [Scope: String] = [:]

    public init() {}

    public subscript(scope: Scope) -> String? {
        get { selection[scope] }
        set { selection[scope] = newValue }
    }

    public func visible(_ matches: [JSONValue], in scope: Scope) -> [JSONValue] {
        let selected = self[scope]
        return matches.filter {
            scope == .history || $0["id"].string == selected ||
                ($0["voted_at"].isNull && ["done", "running", "queued"].contains($0["status"].string))
        }.sorted {
            if scope == .history { return $0["created_at"].double > $1["created_at"].double }
            let left = $0["status"].string == "done" ? 0 : 1, right = $1["status"].string == "done" ? 0 : 1
            return left == right ? $0["created_at"].double < $1["created_at"].double : left < right
        }
    }

    public func current(_ visible: [JSONValue], in scope: Scope) -> JSONValue? {
        visible.first { $0["id"].string == self[scope] } ?? visible.first
    }
}

public struct ArenaPairResult: Equatable, Sendable {
    public var wins: Int, losses: Int, draws: Int
    public var sample: Int { wins + losses + draws }
    public var winRate: Double? { sample == 0 ? nil : Double(wins) / Double(sample) }
}

public struct ArenaPairMatrix: Sendable {
    private var pairs: [String: [String: ArenaPairResult]] = [:]

    public init(_ comparisons: [JSONValue]) {
        for entry in comparisons {
            let first = entry["first"].string, second = entry["second"].string
            let result = ArenaPairResult(wins: entry["wins"].int, losses: entry["losses"].int, draws: entry["draws"].int)
            pairs[first, default: [:]][second] = result
            pairs[second, default: [:]][first] = ArenaPairResult(wins: result.losses, losses: result.wins, draws: result.draws)
        }
    }

    public subscript(row: String, column: String) -> ArenaPairResult? { pairs[row]?[column] }
}

public struct ArenaPresetGroup: Identifiable, Equatable, Sendable {
    public let category: String
    public var presets: [JSONValue]
    public var id: Data { Data(category.utf8) }
    public var title: String { category.isEmpty ? "Uncategorized" : category }
}

/// Presentation only; category and task order follow the saved preset catalog.
public enum ArenaPresentationPolicy {
    /// Advance in the displayed order, wrapping after the last eligible match.
    /// History includes prior verdicts; Judge moves only to unjudged matches.
    public static func nextMatchID(in visible: [JSONValue], after currentID: String, history: Bool) -> String? {
        let current = visible.firstIndex { $0["id"].string == currentID } ?? -1
        var first: String?
        for (index, match) in visible.enumerated() {
            let id = match["id"].string
            guard id != currentID, history || match["voted_at"].isNull else { continue }
            if first == nil { first = id }
            if index > current { return id }
        }
        return first
    }

    public static func presetGroups(_ presets: [JSONValue]) -> [ArenaPresetGroup] {
        var groups: [ArenaPresetGroup] = [], indices: [Data: Int] = [:]
        for preset in presets {
            let category = preset["category"].string, key = Data(category.utf8)
            if let index = indices[key] { groups[index].presets.append(preset) }
            else {
                indices[key] = groups.count
                groups.append(ArenaPresetGroup(category: category, presets: [preset]))
            }
        }
        return groups
    }

    /// Same millisecond thresholds and rounding as the web's fmtAgo, with an
    /// injected clock and an explicit unknown label for absent/invalid dates.
    public static func verdictAge(_ timestamp: JSONValue, now: Date) -> String {
        guard case .number(let timestamp) = timestamp, timestamp.isFinite else { return "Time unavailable" }
        let elapsed = now.timeIntervalSince1970 * 1000 - timestamp
        guard elapsed.isFinite else { return "Time unavailable" }
        if elapsed < 45_000 { return "just now" }
        if elapsed < 3_600_000 { return String(format: "%.0f min ago", (elapsed / 60_000).rounded()) }
        if elapsed < 86_400_000 { return String(format: "%.0f h ago", (elapsed / 3_600_000).rounded()) }
        return String(format: "%.0f d ago", (elapsed / 86_400_000).rounded())
    }

    public static func recentVerdictMetadata(_ record: JSONValue, now: Date) -> String {
        var parts = [verdictAge(record["ts"], now: now), record["mode"].string]
        if !record["category"].string.isEmpty { parts.append(record["category"].string) }
        parts += [record["verdict"].string, record["voter"].string]
        return parts.joined(separator: " · ")
    }
}
