import Foundation

public struct ArenaMatchSelection: Equatable, Sendable {
    public enum Scope: Sendable, Hashable { case judge, history }
    public enum JudgeGroup: Int, CaseIterable, Sendable {
        case ready, inProgress, reviewed

        public init(_ match: JSONValue) {
            guard match["voted_at"].isNull else { self = .reviewed; return }
            switch match["status"].string {
            case "done": self = .ready
            case "queued", "running": self = .inProgress
            default: self = .reviewed
            }
        }

        public var title: String {
            switch self {
            case .ready: "Ready to judge"
            case .inProgress: "In progress"
            case .reviewed: "Reviewed"
            }
        }
    }
    private var selection: [Scope: String] = [:]

    public init() {}

    public subscript(scope: Scope) -> String? {
        get { selection[scope] }
        set { selection[scope] = newValue }
    }

    public func visible(_ matches: [JSONValue], in scope: Scope) -> [JSONValue] {
        let selected = self[scope]
        return matches.filter {
            scope == .history || $0["id"].string == selected || JudgeGroup($0) != .reviewed
        }.sorted {
            if scope == .history { return $0["created_at"].double > $1["created_at"].double }
            let left = JudgeGroup($0).rawValue, right = JudgeGroup($1).rawValue
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
    public static func observedSteps(_ events: [JSONValue]) -> Int {
        Set(events.compactMap { event -> String? in
            let payload = event["payload"], id = payload["message_id"].string
            return event["type"].string == "assistant" && payload["parent_tool_use_id"].isNull && !id.isEmpty ? id : nil
        }).count
    }

    public static func verdictOrder(_ record: JSONValue) -> String {
        let contestants = record["contestants"].array
        let groups = Dictionary(grouping: contestants.filter { !$0["rank"].isNull }, by: { $0["rank"].int })
        let order = groups.keys.sorted().map { rank in
            groups[rank, default: []].map { $0["model"].string }.joined(separator: " = ")
        }.joined(separator: " > ")
        let unranked = contestants.filter { $0["rank"].isNull }.map {
            $0["model"].string + ($0["status"].string == "failed" ? " (failed)" : "")
        }.joined(separator: ", ")
        return [order, unranked].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func matchStatus(_ match: JSONValue) -> String {
        if ArenaMatchSelection.JudgeGroup(match) == .ready { return "ready to judge" }
        let status = match["verdict"].isNull ? match["status"] : match["verdict"]
        return status.string.replacingOccurrences(of: "_", with: " ")
    }

    public static func matchesHistorySearch(_ match: JSONValue, term: String) -> Bool {
        [match["prompt"].string, match["category"].string, matchStatus(match)].contains { $0.localizedCaseInsensitiveContains(term) } ||
            match["slots"].array.contains { $0["revealed"].bool && $0["model"].string.localizedCaseInsensitiveContains(term) }
    }

    public static func compactModelNames(_ models: [String], trimSharedSuffix: Bool = false) -> [String: String] {
        let fullNames = Set(models)
        let names = fullNames.sorted()
        let minimumSharedPrefix = 12
        var compact: [String: String] = [:]
        for index in names.indices {
            let name = names[index]
            let before = index > 0 ? name.commonPrefix(with: names[index - 1]).count : 0
            let after = index + 1 < names.count ? name.commonPrefix(with: names[index + 1]).count : 0
            let shared = max(before, after)
            if shared >= minimumSharedPrefix, shared < name.count {
                compact[name] = "…" + name.dropFirst(shared)
            }
        }
        let labelCounts = compact.values.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        let unique = compact.filter { labelCounts[$0.value] == 1 && !fullNames.contains($0.value) }
        guard trimSharedSuffix, unique.count > 1 else { return unique }
        let reversed = unique.values.map { String($0.reversed()) }
        let suffix = reversed.dropFirst().reduce(reversed[0]) { $0.commonPrefix(with: $1) }
        guard let separator = suffix.lastIndex(of: "-") else { return unique }
        let length = suffix.distance(from: suffix.startIndex, to: separator) + 1
        let shortened = unique.mapValues { String($0.dropLast(length)) }
        guard shortened.values.allSatisfy({ $0.count > 1 && !fullNames.contains($0) }),
              Set(shortened.values).count == shortened.count else { return unique }
        return shortened
    }

    public static func trendTicks(_ timestamps: [Double], label: (Double) -> String) -> [Double] {
        let values = timestamps.filter(\.isFinite).sorted()
        guard let first = values.first, let last = values.last else { return [] }
        let firstLabel = label(first), lastLabel = label(last)
        guard firstLabel != lastLabel else { return [first] }
        let spacing = (last - first) / 3
        let midpoint = first + (last - first) / 2
        let middle = values.filter {
            $0 - first >= spacing && last - $0 >= spacing && label($0) != firstLabel && label($0) != lastLabel
        }.min { abs($0 - midpoint) < abs($1 - midpoint) }
        return middle.map { [first, $0, last] } ?? [first, last]
    }

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
