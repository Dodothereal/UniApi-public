import Foundation

struct NativeCodexProviderRoute: Sendable {
    let alias: String, provider: NativeProviderInfo, model: String, context: Int, efforts: [String]
}

/// API keys belong to request routing and never enter Codex model metadata.
enum NativeCodexRouteCatalog {
    static let prefix = "uniapi/"
    static func routes(providers: JSONValue, choices: JSONValue, port: Int = 8823) throws -> [NativeCodexProviderRoute] {
        try NativeCodexCatalogStore.validate(choices)
        guard case .array(let rows) = providers["providers"] else { throw NativeFailure("Missing provider document") }
        var result: [NativeCodexProviderRoute] = []
        let allowed: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
        for id in choices["providerIds"].array.map(\.string) {
            let matches = rows.filter { $0["id"] == .string(id) }
            guard matches.count == 1, let row = matches.first else { continue }
            let provider = NativeProviderInfo(row)
            guard provider.codexEnabled, provider.verified, provider.catalogIssue(port: port) == nil else { continue }
            for model in provider.codexModels {
                var seen = Set<String>()
                let efforts = provider.efforts(for: model).filter { allowed.contains($0) && seen.insert($0).inserted }
                let context = positiveInteger(row["proxy"]["model_context_tokens"][model]) ?? positiveInteger(row["proxy"]["context_tokens"]) ?? 128000
                result.append(.init(alias: NativeCodexCatalogStore.id(provider: id, model: model), provider: provider, model: model, context: context, efforts: efforts.isEmpty ? ["none"] : efforts))
            }
        }
        return result
    }
    static func augment(_ native: JSONValue, providers: JSONValue, choices: JSONValue, port: Int = 8823, byteLimit: Int = 64 * 1024 * 1024) throws -> JSONValue {
        guard case .object = native, case .array(let raw) = native["models"] else { throw NativeFailure("Native catalog is missing a models array") }
        let nativeBytes = try native.encoded().count
        guard byteLimit > 0, nativeBytes <= byteLimit else { throw NativeFailure("Native catalog exceeded its byte bound") }
        var remainingBytes = byteLimit - nativeBytes
        let rows = raw.filter { !$0["slug"].string.hasPrefix(prefix) && !$0["slug"].string.hasPrefix("chatgpt-web/") }
        let sorted = rows.enumerated().sorted { a, b in
            let x = a.element["priority"].double, y = b.element["priority"].double
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
        guard let template = sorted.first(where: eligible) else { throw NativeFailure("Native catalog has no eligible native worker anchor") }
        var output = rows
        let lastPriority = rows.reduce(0.0) { max($0, min(9_007_199_254_740_990, $1["priority"].double)) }
        for route in try routes(providers: providers, choices: choices, port: port) {
            var row = template
            row = .object(row.object.filter { !["comp_hash", "availability_nux", "multi_agent_reasoning_effort"].contains($0.key) })
            row["slug"] = .string(route.alias); row["display_name"] = .string(route.provider.name + " — " + route.model)
            row["description"] = .string("UniApi Responses route through " + route.provider.name + ".")
            row["model_messages"] = .null; row["visibility"] = "list"; row["supported_in_api"] = true
            row["multi_agent_version"] = "v1"; row["upgrade"] = .null; row["tool_mode"] = .null
            row["priority"] = .number(lastPriority + 1)
            row["context_window"] = .number(Double(route.context)); row["max_context_window"] = row["context_window"]
            row["effective_context_window_percent"] = 90; row["auto_compact_token_limit"] = .number((Double(route.context) * 0.9).rounded(.down))
            // Codex requires a description on each preset; omitting it rejects
            // the entire catalog, even when the effort itself is supported.
            row["supported_reasoning_levels"] = .array(route.efforts.map { ["effort": .string($0), "description": .string($0 == "none" ? "No reasoning override" : $0)] }); row["default_reasoning_level"] = .string(route.efforts[0])
            row["input_modalities"] = route.provider.raw["codex"]["vision_models"].array.contains(.string(route.model)) ? ["text", "image"] : ["text"]
            row["additional_speed_tiers"] = []; row["service_tiers"] = []; row["default_service_tier"] = .null
            row["supports_search_tool"] = false; row["experimental_supported_tools"] = []; row["supports_image_detail_original"] = false
            row["supports_experimental_context"] = false; row["use_responses_lite"] = false; row["support_verbosity"] = false; row["default_verbosity"] = .null
            let bytes = try row.encoded().count + 1
            guard bytes <= remainingBytes else { throw NativeFailure("Combined Codex catalog exceeded its byte bound; no providers were dropped") }
            remainingBytes -= bytes
            output.append(row)
        }
        for i in output.indices where output[i]["multi_agent_version"] != "disabled" { output[i]["multi_agent_version"] = "v1" }
        let anchor = sorted.first(where: eligible)?["slug"].string
        var priorities: [String: Int] = [:]
        if let anchor { priorities[anchor] = 0 }
        var next = 1
        for id in choices["workerModels"].array.map(\.string) where priorities[id] == nil && output.contains(where: { $0["slug"] == .string(id) && eligible($0) }) {
            priorities[id] = next; next += 1
        }
        let remaining = output.indices.filter { priorities[output[$0]["slug"].string] == nil }.sorted { a, b in
            let x = output[a]["priority"].double, y = output[b]["priority"].double
            return x == y ? a < b : x < y
        }
        for (rank, index) in remaining.enumerated() { output[index]["priority"] = .number(Double(5 + rank)) }
        for i in output.indices where priorities[output[i]["slug"].string] != nil {
            output[i]["priority"] = .number(Double(priorities[output[i]["slug"].string]!))
        }
        var result = native; result["models"] = .array(output)
        guard try result.encoded().count <= byteLimit else { throw NativeFailure("Combined Codex catalog exceeded its byte bound") }
        return result
    }
    private static func eligible(_ row: JSONValue) -> Bool { !row["slug"].string.isEmpty && row["visibility"] == "list" && row["supported_in_api"] == true && row["multi_agent_version"] != "disabled" }
    private static func positiveInteger(_ value: JSONValue) -> Int? {
        guard case .number(let n) = value, n.isFinite, n > 0, n <= 9_007_199_254_740_991, n.rounded() == n else { return nil }; return Int(n)
    }
}
