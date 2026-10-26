import Foundation
import UniApiCore

package struct NativeStatsExcludedNotice: Equatable, Sendable {
    package let source: String
    package let count: Int
}

/// A scan's file attempts and a page's final read are different stages.
/// Keep the counter out of later stages, including a retained prior scan.
package enum NativeStatsPresentationPolicy {
    package static func progressText(_ value: JSONValue) -> String {
        if value["status"] == "failed" { return "Usage refresh did not finish." }
        switch value["phase"].string {
        case "discovering": return "Finding local usage records…"
        case "assembling": return "Rebuilding usage summary…"
        case "folding": return "Updating usage totals…"
        case "reading", "":
            if let done = count(value["done"]), let total = count(value["total"]),
               total > 0, done <= total {
                return "Reading local usage records · \(done)/\(total) files"
            }
            return "Reading local usage records…"
        default: return "Loading selected statistics…"
        }
    }

    package static func excludedNotices(_ payload: JSONValue, detail: Bool) -> [NativeStatsExcludedNotice] {
        guard !detail else { return [] }
        let selected = payload["source"].string
        return ["codex", "antigravity", "zcode", "opencode", "dsh"].compactMap { source in
            guard selected == "all" || selected == source,
                  let value = count(payload["scan"][source + "Excluded"]), value > 0 else { return nil }
            return NativeStatsExcludedNotice(source: source, count: value)
        }
    }

    private static func count(_ value: JSONValue) -> Int? {
        guard case .number(let number) = value, number.isFinite, number >= 0 else { return nil }
        return Int(exactly: number)
    }
}
