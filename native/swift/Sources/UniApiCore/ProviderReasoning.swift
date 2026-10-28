import Foundation

/// Catalog choices and request translation must use the same model-level
/// contract. An absent override leaves the upstream default untouched.
enum NativeProviderReasoning {
    private static let allowed: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    static func levels(_ value: JSONValue) -> [String] {
        var seen = Set<String>()
        return value.array.compactMap {
            guard case .string(let level) = $0, allowed.contains(level), seen.insert(level).inserted else { return nil }
            return level
        }
    }

    static func efforts(_ provider: NativeProviderInfo, model: String) -> [String] {
        capabilities(provider, model: model).efforts
    }

    // Display order need not put the default first. Explicit declarations
    // retain their order and first valid effort as the default.
    static func capabilities(_ provider: NativeProviderInfo, model: String) -> (efforts: [String], defaultEffort: String?) {
        let codex = provider.raw["codex"]
        // A present empty or malformed model override must not inherit another
        // model's capabilities, including the documented fallback below.
        if let own = codex["model_efforts"].object[model] {
            let declared = levels(own)
            return (declared, declared.first)
        }
        let declared = levels(codex["efforts"])
        if !declared.isEmpty { return (declared, declared.first) }
        // CommandCode documents an OpenAI-compatible endpoint; DeepSeek's
        // documented discrete API efforts are low/high/max, not its numeric
        // open-weight control. Keep this fallback bound to the exact route.
        let endpoint = provider.direct.isEmpty ? provider.base : provider.direct
        // Compare original spelling, not decoded/normalized URL paths: the
        // endpoint builder must receive the very same version suffix.
        let documentedBases = ["https://api.commandcode.ai/provider/v1", "https://api.commandcode.ai/provider/v1/",
                               "https://api.commandcode.ai:443/provider/v1", "https://api.commandcode.ai:443/provider/v1/"]
        if provider.format == "openai", model == "deepseek/deepseek-v4.1-flash", documentedBases.contains(endpoint) {
            return (["low", "high", "max"], "high")
        }
        return ([], nil)
    }

    static func apply(request: JSONValue, responses: Bool, provider: NativeProviderInfo,
                      model: String, payload: inout JSONValue) throws {
        let control = request[responses ? "reasoning" : "output_config"]
        guard !control.isNull else { return }
        // Native Messages already carries the original output_config through.
        // Do not reject a vendor's direct contract or newly invent support for
        // an unregistered OpenAI-format route from a Claude client hint.
        if !responses && (provider.format == "anthropic" || efforts(provider, model: model).isEmpty) { return }
        guard case .object = control else { throw NativeFailure("Reasoning settings must be an object") }
        let value = control["effort"]
        guard !value.isNull else { return }
        guard case .string(let effort) = value, allowed.contains(effort) else { throw NativeFailure("Invalid reasoning effort") }
        let supported = efforts(provider, model: model)
        // Older catalogs represented an unknown/default provider policy with
        // the sole value `none`. Do not turn their existing turns into an
        // explicit thinking-disable request when capabilities are refreshed.
        if effort == "none", !supported.contains("none") { return }
        guard supported.contains(effort) else { throw NativeFailure("This provider model does not advertise that reasoning effort") }
        if provider.format == "anthropic" {
            if effort == "none" { payload["thinking"] = ["type": "disabled"] }
            else { payload["output_config"]["effort"] = .string(effort) }
        } else {
            payload["reasoning_effort"] = .string(effort)
        }
    }
}
