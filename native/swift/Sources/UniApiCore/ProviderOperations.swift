import Foundation

/// The existing Swift store is the only provider writer. Long probes commit
/// against the complete original document, so a concurrent editor always wins.
public actor NativeProviderOperations {
    public let store: NativeProviderStore, port: Int
    private let dependencies: ShimDependencies
    public init(store: NativeProviderStore, port: Int = 8823, dependencies: ShimDependencies = .init()) { self.store = store; self.port = port; self.dependencies = dependencies }
    private func provider(_ id: String, document: JSONObject) throws -> JSONValue {
        guard let row = document["providers"]!.array.first(where: { $0["id"] == .string(id) }) else { throw NativeFailure("Unknown provider") }
        guard row["transport"] != "chatgpt-web" else { throw NativeFailure("Browser credentials are managed as references by the Codex tab") }; return row
    }
    private func commit(_ expected: JSONObject, providers: [JSONValue]) throws {
        try store.mutate { current in guard current == expected else { throw NativeFailure("Provider configuration changed during the check; reload and explicitly retry") }; current["providers"] = .array(providers) }
    }
    public static func endpoint(_ base: String, _ suffix: String) throws -> URL {
        var base = base.trimmingCharacters(in: CharacterSet(charactersIn: "/")); if base.hasSuffix("/v1") { base = String(base.dropLast(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        guard let url = URL(string: base + suffix), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw NativeFailure("Use a valid HTTP provider base URL") }; return url
    }
    public func discover(base: String, key: String) async throws -> JSONValue {
        let request = ShimHTTPRequest(url: try Self.endpoint(base, "/v1/models"), method: "GET", headers: ["Authorization": "Bearer " + key, "x-api-key": key, "User-Agent": "Mozilla/5.0 uniapi-native"] , timeout: 25)
        let upstream = try await dependencies.transport.open(request), data = try await upstream.body(limit: 8 * 1024 * 1024)
        guard upstream.status == 200 else { throw NativeFailure("Model catalog returned HTTP \(upstream.status)") }
        let parsed = try JSONValue.decode(data), rows = parsed.array.isEmpty ? parsed["data"].array : parsed.array
        var models: [String] = [], dropped = 0
        for row in rows {
            let id = row.string.isEmpty ? row["id"].string : row.string
            guard SwitcherDisk.validLabel(.string(id), limit: 1024) else { continue }
            if NativeProviderDetection.chatModel(id, metadata: row) { models.append(id) } else { dropped += 1 }
        }
        return ["ids": .array(Set(models).sorted().map(JSONValue.string)), "rows": .array(rows), "dropped": .number(Double(dropped))]
    }
    public func detect(base: String, key: String, catalog: JSONValue? = nil) async throws -> JSONValue {
        let models: JSONValue
        if let catalog { models = catalog } else { models = (try? await discover(base: base, key: key)) ?? [:] }
        for row in models["rows"].array where !row["supported_endpoint_types"].array.isEmpty {
            let formats = row["supported_endpoint_types"].array.map { $0.string.lowercased() }
            if formats.contains(where: { $0.contains("anthropic") }) { return ["format": "anthropic", "reason": "Model metadata advertises an Anthropic endpoint"] }
            if formats.contains(where: { $0.contains("openai") }) { return ["format": "openai", "reason": "Model metadata advertises an OpenAI endpoint"] }
        }
        let model = models["rows"].array.compactMap { $0["id"].string.isEmpty ? nil : $0["id"].string }.first ?? "probe-nonexistent-model"
        let payload: JSONValue = ["model": .string(model), "max_tokens": 1, "messages": [["role": "user", "content": "hi"]]]
        let request = ShimHTTPRequest(url: try Self.endpoint(base, "/v1/messages"), headers: ["Content-Type": "application/json", "Authorization": "Bearer " + key, "x-api-key": key, "anthropic-version": "2023-06-01", "User-Agent": "Mozilla/5.0 uniapi-native"], body: try payload.encoded(), timeout: 25)
        do {
            let upstream = try await dependencies.transport.open(request), body = try await upstream.body(limit: 8 * 1024 * 1024)
            if upstream.status == 200 { return ["format": "anthropic", "reason": "Messages accepted a request"] }
            let classification = NativeProviderDetection.classify(status: upstream.status, body: (try? JSONValue.decode(body)) ?? [:])
            return ["format": .string(classification.format), "reason": .string(classification.reason)]
        } catch is CancellationError { throw CancellationError() }
        catch { return ["format": "openai", "reason": "Format probe was unavailable; OpenAI is the provisional default", "provisional": true] }
    }
    private func fill(_ input: JSONValue) async throws -> (JSONValue, JSONValue) {
        var row = input
        let catalog = (try? await discover(base: row["base_url"].string, key: row["api_key"].string)) ?? ["ids": [], "rows": [], "dropped": 0]
        let detection = try await detect(base: row["base_url"].string, key: row["api_key"].string, catalog: catalog)
        var proxy = row["proxy"]; proxy["format"] = detection["format"]; proxy["models"] = catalog["ids"]
        row["proxy"] = proxy
        let models = NativeProviderInfo(row).models
        if proxy["model"].string.isEmpty || !models.contains(proxy["model"].string) { proxy["model"] = .string(NativeProviderDetection.defaultModel(models)) }
        row["proxy"] = proxy
        return (row, ["id": row["id"], "format": detection["format"], "reason": detection["reason"], "models": .number(Double(models.count)), "dropped_non_chat": catalog["dropped"], "model": proxy["model"]])
    }
    public func handle(_ operation: String, input: JSONObject = [:]) async throws -> JSONValue {
        let value = JSONValue.object(input), original = try store.document(); var rows = original["providers"]!.array
        switch operation {
        case "add":
            guard SwitcherDisk.validLabel(value["name"]), case .string(let key) = value["key"], key.utf8.count <= 16384,
                  !key.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw NativeFailure("Use a provider name, endpoint and valid API key (which may be empty)") }
            _ = try Self.endpoint(value["url"].string, "")
            let slug = value["name"].string.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let stem = slug.isEmpty ? "provider" : String(slug.prefix(90)); var id = stem, suffix = 2
            while let existing = rows.first(where: { $0["id"] == .string(id) }), existing["base_url"].string.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != value["url"].string.trimmingCharacters(in: CharacterSet(charactersIn: "/")) { id = stem + "-\(suffix)"; suffix += 1 }
            var row = rows.first { $0["id"] == .string(id) } ?? ["id": .string(id)]
            guard row["transport"] != "chatgpt-web" else { throw NativeFailure("Browser provider identity is reserved") }
            row["name"] = value["name"]; row["base_url"] = .string(value["url"].string.trimmingCharacters(in: CharacterSet(charactersIn: "/"))); row["api_key"] = value["key"]
            let (filled, result) = try await fill(row); rows.removeAll { $0["id"] == .string(id) }; rows.append(filled); try commit(original, providers: rows); return result
        case "adopt":
            let row = try provider(value["id"].string, document: original), (filled, result) = try await fill(row)
            rows = rows.map { $0["id"] == row["id"] ? filled : $0 }; try commit(original, providers: rows); return result
        case "refresh":
            var row = try provider(value["id"].string, document: original)
            if row["proxy"]["format"].isNull { return try await handle("adopt", input: input) }
            let info = NativeProviderInfo(row), catalog = try await discover(base: info.direct.isEmpty ? info.base : info.direct, key: info.key)
            var proxy = row["proxy"]; proxy["models"] = catalog["ids"]; row["proxy"] = proxy
            let models = NativeProviderInfo(row).models
            if !models.contains(proxy["model"].string) { proxy["model"] = .string(NativeProviderDetection.defaultModel(models)) }; row["proxy"] = proxy
            rows = rows.map { $0["id"] == row["id"] ? row : $0 }; try commit(original, providers: rows); return ["id": row["id"], "models": .number(Double(models.count)), "model": proxy["model"], "dropped_non_chat": catalog["dropped"]]
        case "addModel":
            guard Set(input.keys) == ["id", "model"], SwitcherDisk.validLabel(value["model"], limit: 1024), value["model"].string.utf16.count <= 1024,
                  value["model"].string == value["model"].string.trimmingCharacters(in: .whitespacesAndNewlines) else { throw NativeFailure("Enter the exact model ID without surrounding whitespace") }
            var row = try provider(value["id"].string, document: original)
            let info = NativeProviderInfo(row), model = value["model"].string
            guard info.enabled else { throw NativeFailure("Enable this API provider before adding a custom model") }
            guard NativeCodexCatalogStore.id(provider: info.id, model: model).utf16.count <= 1024 else { throw NativeFailure("The encoded model ID is too long for the shared Codex catalog") }
            var custom = info.customModels
            if !custom.contains(model) {
                guard custom.count < NativeProviderInfo.customModelLimit else { throw NativeFailure("This provider already has 256 user-added models") }
                custom.append(model)
            }
            var proxy = row["proxy"]; proxy["custom_models"] = .array(custom.map(JSONValue.string)); row["proxy"] = proxy
            if !row["codex"].isNull {
                var codex = row["codex"]
                guard case .object = codex, case .array = codex["models"],
                      codex["models"].array.allSatisfy({ SwitcherDisk.validLabel($0, limit: 1024) }),
                      Set(codex["models"].array).count == codex["models"].array.count else { throw NativeFailure("The registered Codex model list is invalid; check the provider route first") }
                var registered = codex["models"].array
                if !registered.contains(.string(model)) { registered.append(.string(model)) }
                codex["models"] = .array(registered); row["codex"] = codex
            }
            rows = rows.map { $0["id"] == row["id"] ? row : $0 }; try commit(original, providers: rows)
            return ["id": row["id"], "model": .string(model), "ok": true, "message": "Added the custom model locally. Save preferred workers if needed, then reload Codex when idle. Model availability is not verified by adding it."]
        case "remove", "model", "unregisterResponses":
            var row = try provider(value["id"].string, document: original)
            if operation == "remove" { rows.removeAll { $0["id"] == row["id"] } }
            else {
                if operation == "model" { guard SwitcherDisk.validLabel(value["model"], limit: 1024) else { throw NativeFailure("A model ID is required") }; var proxy = row["proxy"]; proxy["model"] = value["model"]; row["proxy"] = proxy }
                else { row = .object(row.object.filter { $0.key != "codex" }) }
                rows = rows.map { $0["id"] == row["id"] ? row : $0 }
            }
            try commit(original, providers: rows); return ["id": row["id"], "ok": true]
        case "registerWeb":
            if let existing = rows.first(where: { $0["id"] == "chatgpt-web" }), existing["transport"] != "chatgpt-web" { throw NativeFailure("The browser provider identity already belongs to an API provider") }
            var row = rows.first { $0["id"] == "chatgpt-web" } ?? ["id": "chatgpt-web", "name": "ChatGPT Web", "models": []]
            row = .object(row.object.filter { !["api_key", "proxy", "codex"].contains($0.key) }); row["transport"] = "chatgpt-web"; row["credential_ref"] = "chatgpt-web"; row["base_url"] = "http://127.0.0.1:17841/uniapi/v1"
            rows.removeAll { $0["id"] == "chatgpt-web" }; rows.append(row); try commit(original, providers: rows); return ["id": "chatgpt-web", "credential_ref": "chatgpt-web"]
        case "registerResponses":
            var row = try provider(value["id"].string, document: original); let info = NativeProviderInfo(row)
            guard info.enabled else { throw NativeFailure("Enable this provider for Claude before checking Responses") }
            let chosen = value["model"].string.isEmpty ? info.model.isEmpty ? NativeProviderDetection.defaultModel(info.models) : info.model : value["model"].string
            guard !chosen.isEmpty && info.models.contains(chosen) else { throw NativeFailure("Choose a current provider model to check") }
            let proof = try await responsesProof(info, model: chosen)
            row["codex"] = ["base_url": .string(info.codexURL(port: port)), "models": .array(info.models.map(JSONValue.string)), "efforts": [], "responses_verified": proof["responses_verified"], "tools_verified": proof["tools_verified"], "verified_model": .string(chosen), "verified_at": .string(ISO8601DateFormatter().string(from: dependencies.now())), "note": proof["note"]]
            for key in ["efforts", "model_efforts"] where !info.raw["codex"][key].isNull { row["codex"][key] = info.raw["codex"][key] }
            rows = rows.map { $0["id"] == row["id"] ? row : $0 }; try commit(original, providers: rows); return proof
        default: throw NativeFailure("Unknown provider operation")
        }
    }
    private func responsesProof(_ provider: NativeProviderInfo, model: String) async throws -> JSONValue {
        let payload: JSONValue = ["model": .string(model), "stream": true, "max_output_tokens": 256, "instructions": "Call the tool when asked.", "input": [["type": "message", "role": "user", "content": "Call get_weather for Paris, then say DONE."]], "tools": [["type": "function", "name": "get_weather", "parameters": ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]]]]]
        let request = ShimHTTPRequest(url: URL(string: provider.codexURL(port: port) + "/responses")!, headers: ["Content-Type": "application/json", "Accept": "text/event-stream", "x-api-key": provider.key], body: try payload.encoded(), timeout: 180)
        do {
            let health = try await dependencies.transport.open(.init(url: URL(string: "http://127.0.0.1:\(port)/healthz")!, method: "GET", timeout: 1.5))
            let identity = try JSONValue.decode(await health.body(limit: 65536))
            guard health.status == 200, identity["service"] == "uniapi-shim", identity["runtime"] == "swift", identity["ok"] == true else { return ["responses_verified": false, "tools_verified": false, "note": "The route is not served by the native Swift shim"] }
            let upstream = try await dependencies.transport.open(request), body = try await upstream.body()
            guard upstream.status == 200 else { return ["responses_verified": false, "tools_verified": false, "note": .string("route \(request.url.absoluteString) answered \(upstream.status): " + String(String(decoding: body, as: UTF8.self).replacingOccurrences(of: provider.key, with: provider.key.isEmpty ? "" : "<redacted>").prefix(200)))] }
            var parser = ShimSSEParser(); let frames = try parser.feed(body, final: true)
            guard frames.first?.event == "response.created", frames.last?.event == "done", frames.dropLast().last?.event == "response.completed", !String(decoding: body, as: UTF8.self).contains("[uniapi-shim:") else { return ["responses_verified": false, "tools_verified": false, "note": "Responses route did not complete a valid stream"] }
            let calls = frames.filter { $0.event == "response.output_item.done" }.map { $0.data["item"] }.filter { ["function_call", "custom_tool_call"].contains($0["type"].string) }
            guard !calls.isEmpty || frames.contains(where: { $0.event == "response.output_text.delta" && !$0.data["delta"].string.isEmpty }) else { return ["responses_verified": false, "tools_verified": false, "note": "The Responses stream carried no content"] }
            guard let call = calls.first else { return ["responses_verified": true, "tools_verified": false, "note": "Responses streaming completed but the model did not call a tool"] }
            let valid = call["type"] == "custom_tool_call" || (try? JSONValue.decode(Data(call["arguments"].string.utf8))) != nil
            return ["responses_verified": true, "tools_verified": .bool(valid), "note": .string(valid ? "Responses route streamed a valid tool call" : "Tool call arguments were invalid JSON")]
        } catch is CancellationError { throw CancellationError() }
        catch { return ["responses_verified": false, "tools_verified": false, "note": "Native shim route was unavailable; no tool readiness was recorded"] }
    }
}
