import Foundation

public enum ArenaContestantPolicy {
    /// Ordinary saved keys remain compatible. Separately encoded components are
    /// used when either component contains the legacy separator, so two real
    /// identities can never alias in selection, exclusions or Elo.
    public static func key(_ contestant: JSONValue) -> String {
        let route = contestant["route"].string, model = contestant["model"].string
        if route.contains("::") || model.contains("::") || route.utf8.contains(where: { $0 >= 128 }) || model.utf8.contains(where: { $0 >= 128 }) {
            return "pair:" + Data(route.utf8).base64EncodedString() + "." + Data(model.utf8).base64EncodedString()
        }
        return route + "::" + model
    }
    public static func unique(_ contestants: [JSONValue]) -> [JSONValue] {
        var seen = Set<String>()
        return contestants.compactMap { contestant in
            guard case .string(let route) = contestant["route"], !route.isEmpty,
                  case .string(let model) = contestant["model"], !model.isEmpty else { return nil }
            let key = key(contestant)
            guard seen.insert(key).inserted else { return nil }
            var value = contestant; value["key"] = .string(key); return value
        }
    }
    /// Legacy exclusions are conservative: an ambiguous old key continues to
    /// exclude every matching identity instead of silently enabling a route.
    public static func selection(_ saved: Set<String>, contestants: [JSONValue]) -> Set<String> {
        let savedBytes = Set(saved.map { Data($0.utf8) })
        return Set(contestants.compactMap { contestant in
            let canonical = key(contestant)
            let legacy = contestant["route"].string + "::" + contestant["model"].string
            return savedBytes.contains(Data(canonical.utf8)) || savedBytes.contains(Data(legacy.utf8)) ? canonical : nil
        })
    }
}

public struct ArenaStandingDetail: Equatable, Sendable {
    public let firsts: Int, failures: Int, matches: Int
    public init(_ row: JSONValue) {
        firsts = max(0, row["firsts"].int); matches = max(0, row["matches"].int)
        failures = max(0, min(matches, row["failures"].int))
    }
    public var firstPlaceLabel: String { "\(firsts) first place\(firsts == 1 ? "" : "s")" }
    public var accessibilitySummary: String { firstPlaceLabel + "; \(failures) failures in \(matches) matches" }
}
