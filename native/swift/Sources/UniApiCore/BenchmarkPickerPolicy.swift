import Foundation

/// Shared by pointer and Return actions; browser modes must come from discovery.
public enum BenchmarkPickerPolicy {
    public static func customModel(provider: JSONValue, query: String) -> String? {
        guard case .object = provider, provider["transport"] != "chatgpt-web", provider["capabilities"]["arbitraryModels"] != false else { return nil }
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !provider["catalog"].array.contains(where: { $0["id"].string == value }) else { return nil }
        return value
    }
    public static func toggling(_ model: String, in chosen: [String]) -> [String] {
        chosen.contains(model) ? Array(Set(chosen.filter { $0 != model })).sorted() : Array(Set(chosen + [model])).sorted()
    }
    public static func selectingMatches(_ entries: [JSONValue], in chosen: [String]) -> [String] {
        Array(Set(chosen + entries.filter { $0["available"] != false }.map { $0["id"].string })).sorted()
    }
}
