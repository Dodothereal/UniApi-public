import Foundation

public enum NativeTranscriptPresentation {
    public static func text(_ detail: JSONValue, parts: [Int: String]) -> String {
        let final = detail["text"].string
        return final.isEmpty ? parts.keys.sorted().compactMap { parts[$0] }.joined(separator: " ") : final
    }
    public static func canResume(_ detail: JSONValue) -> Bool {
        ["queued", "failed", "cancelled"].contains(detail["status"].string) && !["queued", "running"].contains(detail["job"]["status"].string)
    }
}
