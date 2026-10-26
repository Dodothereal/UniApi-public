import Foundation

public struct NativeProviderInfo: Sendable {
    public let raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }
    public var id: String { raw["id"].string }
    public var name: String { raw["name"].string.isEmpty ? id : raw["name"].string }
    public var browser: Bool { raw["transport"] == "chatgpt-web" }
    public var key: String { guard !browser, case .string(let value) = raw["api_key"] else { return "" }; return value }
    public var format: String { browser ? "" : raw["proxy"]["format"].string }
    public static let customModelLimit = 256
    public var customModels: [String] {
        guard !browser else { return [] }
        var seen = Set<String>()
        return raw["proxy"]["custom_models"].array.compactMap {
            guard case .string(let id) = $0, SwitcherDisk.validLabel($0, limit: 1024), id.utf16.count <= 1024,
                  id == id.trimmingCharacters(in: .whitespacesAndNewlines), seen.insert(id).inserted else { return nil }
            return id
        }
    }
    public var models: [String] {
        var result = (browser ? raw["models"] : raw["proxy"]["models"]).array.compactMap { if case .string(let value) = $0 { return value }; return nil }
        var seen = Set(result)
        for model in customModels where seen.insert(model).inserted { result.append(model) }
        return result
    }
    public var model: String { raw["proxy"]["model"].string }
    public var base: String { raw["base_url"].string }
    public var direct: String { raw["proxy"]["direct_url"].string }
    public var enabled: Bool { !browser && ["anthropic", "openai"].contains(format) && raw["disabled"] != true && raw["enabled"] != false && raw["proxy"]["disabled"] != true && raw["proxy"]["enabled"] != false }
    public var codexEnabled: Bool { enabled && raw["codex"]["disabled"] != true && raw["codex"]["enabled"] != false }
    public static func encoded(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? "" }
    public func claudeURL(port: Int = 8823) -> String { direct.isEmpty ? "http://127.0.0.1:\(port)/" + Self.encoded(id) : direct }
    public func codexURL(port: Int = 8823) -> String { "http://127.0.0.1:\(port)/" + Self.encoded(id) + "/v1" }
    public func catalogIssue(port: Int = 8823) -> String? {
        let codex = raw["codex"]
        if !codexEnabled { return "This provider or its route is disabled." }
        guard SwitcherDisk.validLabel(raw["id"], limit: 1024), case .array = codex["models"], codex["models"].array.allSatisfy({ SwitcherDisk.validLabel($0, limit: 1024) }), Set(codex["models"].array).count == codex["models"].array.count else { return "The registered model list is invalid; check the route again." }
        if codex["base_url"] != .string(codexURL(port: port)) { return "The registered route is not the shared native shim endpoint; check the route again." }
        if !raw["api_key"].isNull { guard case .string = raw["api_key"] else { return "Update the provider credential format." } }
        if key.utf8.count > 16384 || key.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 }) { return "Update the provider credential format." }
        return nil
    }
    public var responsesVerified: Bool { raw["codex"]["responses_verified"].bool }
    public var toolsVerified: Bool { raw["codex"]["tools_verified"].bool }
    public var verified: Bool { responsesVerified && toolsVerified }
    public var codexModels: [String] { raw["codex"]["models"].isNull ? models : raw["codex"]["models"].array.map(\.string) }
    public var efforts: [String] { raw["codex"]["efforts"].array.map(\.string) }
    public func efforts(for model: String) -> [String] { NativeProviderReasoning.efforts(self, model: model) }
    public func publicValue(port: Int = 8823) -> JSONValue {
        let fields = ["base_url", "models", "efforts", "model_efforts", "responses_verified", "tools_verified", "verified_model", "verified_at", "note"]
        var codex: JSONValue = raw["codex"].isNull ? .null : .object(raw["codex"].object.filter { fields.contains($0.key) })
        if !codex.isNull { codex["verified"] = .bool(verified); codex["catalogIssue"] = catalogIssue(port: port).map(JSONValue.string) ?? .null }
        return ["id": .string(id), "name": .string(name), "baseUrl": browser ? .null : .string(base), "hasKey": .bool(!key.isEmpty), "format": format.isEmpty ? .null : .string(format), "model": .string(model), "models": .array(models.map(JSONValue.string)), "customModels": .array(customModels.map(JSONValue.string)), "aliases": raw["proxy"]["aliases"].isNull ? [] : raw["proxy"]["aliases"], "claudeUrl": browser ? .null : .string(claudeURL(port: port)), "transport": browser ? "chatgpt-web" : "api", "contextTokens": raw["proxy"]["context_tokens"], "codex": codex]
    }
    public var codexReason: String {
        let checked = raw["codex"], note = Self.tidyNote(checked["note"].string)
        let model = checked["verified_model"].string, date = String(checked["verified_at"].string.prefix(10))
        let detail = (model.isEmpty ? "" : " using " + model) + (date.isEmpty ? "" : " on " + date)
        if checked["responses_verified"] == false { return "The Codex route check failed" + detail + ". " + note }
        if responsesVerified && !toolsVerified { return "Responses streaming works, but the checked model did not emit a valid tool call" + detail + ". " + note }
        return "Responses streaming and tool compatibility have not been verified."
    }
    public static func tidyNote(_ note: String, limit: Int = 220) -> String {
        var result = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let expression = try? NSRegularExpression(pattern: "^route\\s+\\S+\\s+answered\\s+(\\d{3}):\\s*([\\s\\S]*)$"), let match = expression.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)), let sr = Range(match.range(at: 1), in: result), let br = Range(match.range(at: 2), in: result) {
            let status = String(result[sr]), body = String(result[br]); var message = body
            if let parsed = try? JSONValue.decode(Data(body.utf8)) { message = parsed["error"]["message"].string.isEmpty ? parsed["message"].string.isEmpty ? body : parsed["message"].string : parsed["error"]["message"].string }
            else if let pattern = try? NSRegularExpression(pattern: "\"message\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)"), let capture = pattern.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)), let range = Range(capture.range(at: 1), in: body) { message = String(body[range]).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\n", with: " ").replacingOccurrences(of: "\\\\", with: "\\") }
            result = "HTTP " + status + ": " + message
        }
        return result.count > limit ? String(result.prefix(limit)) + "..." : result
    }
}

public enum NativeProviderDetection {
    public static func classify(status: Int, body: JSONValue) -> (format: String, reason: String) {
        if body["type"] == "error", case .object = body["error"] { return ("anthropic", "Messages returned an Anthropic-shaped error; the route exists") }
        if body["error"].object["param"] != nil || body["error"].object["code"] != nil { return ("openai", "Messages returned an OpenAI-shaped error") }
        return ("openai", [404, 405, 501].contains(status) ? "Messages route is absent" : "Messages error was not Anthropic-shaped")
    }
    public static func chatModel(_ id: String, metadata: JSONValue) -> Bool {
        let veto = "(^|[-_/.])(embed|embedding|rerank|whisper|tts|stt|speech|voice|audio|transcribe|image|vision-only|video|veo|sora|seedream|seedance|kling|hailuo|imagen|dall|flux|sd3|stable-diffusion|upscal|moderation|guard)([-_/.]|$)"
        if id.range(of: veto, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        if case .string = metadata["tags"], !metadata["tags"].string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return metadata["tags"].string.lowercased().contains("text") }
        if !metadata["tags"].array.isEmpty { return metadata["tags"].array.contains { $0.string.lowercased().contains("text") } }
        let outputs = metadata["architecture"]["output_modalities"].array
        return outputs.isEmpty || outputs.contains { $0.string.lowercased() == "text" }
    }
    public static func defaultModel(_ models: [String]) -> String {
        for pattern in ["claude.*sonnet", "claude.*opus", "gpt-5", "gpt-4", "qwen.*max", "deepseek.*(chat|v\\d)", "glm-\\d", "kimi", "llama"] {
            if let model = models.first(where: { $0.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil }) { return model }
        }
        return models.first ?? ""
    }
}
