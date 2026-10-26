import Foundation

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
