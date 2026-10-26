import Foundation

struct BenchmarkUnit: Sendable {
    var id: String, test: String, tokens: Int, context: Int? = nil, curve = false, vision = false
}
struct BenchmarkBrowserStopped: Error {}

/// Each instance owns one provider lane. Providers run concurrently, while its
/// models, retries and context probes remain strictly sequential on the key.
actor BenchmarkWorker {
    let provider: JSONValue, settings: JSONValue, catalog: JSONValue, store: BenchmarkStore, dependencies: BenchmarkDependencies
    let runID: String, tierName: String, tier: BenchmarkTier
    let savedUnits: [String: JSONValue]
    let report: @Sendable (String, String, Int, Int, String?) async throws -> Void
    let rowEvent: @Sendable (JSONValue) async throws -> Void
    let diagnostic: @Sendable (String) async throws -> Void
    private var privateKey = ""
    private var browser: Bool { provider["transport"] == "chatgpt-web" }
    private var providerID: String { provider["id"].string }
    init(provider: JSONValue, settings: JSONValue, catalog: JSONValue, store: BenchmarkStore, dependencies: BenchmarkDependencies,
         runID: String, tierName: String, savedUnits: [String: JSONValue],
         report: @escaping @Sendable (String, String, Int, Int, String?) async throws -> Void,
         rowEvent: @escaping @Sendable (JSONValue) async throws -> Void,
         diagnostic: @escaping @Sendable (String) async throws -> Void = { _ in }) {
        self.provider = provider; self.settings = settings; self.catalog = catalog; self.store = store; self.dependencies = dependencies
        self.runID = runID; self.tierName = tierName; tier = BenchmarkTier.configurations[tierName]!
        self.savedUnits = savedUnits; self.report = report; self.rowEvent = rowEvent; self.diagnostic = diagnostic
    }
    func run(_ models: [String]) async throws {
        let delay = max(0, min(600, BenchmarkMath.number(provider["request_delay_s"]) ?? BenchmarkMath.number(settings["request_delay_s"]) ?? 1.2))
        for requested in models {
            try Task.checkCancellation()
            try await log("Starting " + providerID + " / " + requested)
            let pair = providerID + "|" + requested
            let vision = !browser && (requested.lowercased().contains("vision") || requested.lowercased().contains("-vl") || catalog["meta"][requested]["vision"].bool || catalog["meta"][requested]["input_modalities"].array.contains("image"))
            let total = tier.units(browser: browser, vision: vision)
            var model = requested, done = 0, largest = 0
            func describe(_ current: String?) async throws { try await report(pair, model, total, done, current) }
            do {
                try await describe("First-response latency 1/\(tier.latency)")
                let first = try await unit(.init(id: pair + ":latency:0", test: "latency", tokens: 16), model: model)
                if !browser, !first["ok"].bool, ["model_not_found", "quota", "auth"].contains(first["error_class"].string) {
                    let variants = catalog["ids"].array.map(\.string).filter { $0 != model && BenchmarkMath.family($0) == BenchmarkMath.family(model) }.sorted { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
                    for variant in variants {
                        try await dependencies.sleep(delay)
                        try await describe("Trying discovered variant " + variant)
                        try await log("Trying discovered variant " + variant + " for " + requested)
                        let row = try await unit(.init(id: pair + ":fallback:" + variant, test: "latency", tokens: 16), model: variant)
                        if row["ok"].bool {
                            model = variant
                            var matrix = await store.state("matrix"), item = matrix[BenchmarkMath.family(requested)][providerID]
                            item["active"] = .string(model); var family = matrix[BenchmarkMath.family(requested)]; family[providerID] = item; matrix[BenchmarkMath.family(requested)] = family
                            try await store.save("matrix", matrix); break
                        }
                    }
                }
                done += 1; try await describe(nil); try await dependencies.sleep(delay)
                var units: [BenchmarkUnit] = []
                if tier.latency > 1 { units += (1..<tier.latency).map { .init(id: pair + ":latency:\($0)", test: "latency", tokens: 16) } }
                units += (0..<tier.throughput).map { .init(id: pair + ":throughput:\($0)", test: "throughput", tokens: tier.output, curve: true) }
                units += tier.contexts.map { .init(id: pair + ":context:\($0)", test: "context", tokens: 16, context: $0) }
                if vision { units.append(.init(id: pair + ":vision", test: "vision", tokens: 32, vision: true)) }
                if tier.maxOutput > 0 && !browser { units.append(.init(id: pair + ":maxout", test: "maxout", tokens: tier.maxOutput, curve: true)) }
                for test in units {
                    try Task.checkCancellation(); try await describe(test.test + (test.context.map { ": \($0) estimated input tokens" } ?? ""))
                    var row = try await unit(test, model: model)
                    if test.test == "maxout", !row["ok"].bool, ["bad_request", "ctx_limit"].contains(row["error_class"].string),
                       row["error_excerpt"].string.range(of: "max_?\\w*token", options: [.regularExpression, .caseInsensitive]) != nil,
                       let allowed = Self.allowedCap(row["error_excerpt"].string, below: test.tokens) {
                        var adjusted = test; adjusted.tokens = allowed; adjusted.id += ":allowed:\(allowed)"
                        row = try await unit(adjusted, model: model, extra: ["requested_cap": .number(Double(test.tokens)), "allowed_cap": .number(Double(allowed))])
                    }
                    if test.test == "context", row["ok"].bool { largest = max(largest, test.context ?? 0) }
                    done += 1; try await describe(nil); try await dependencies.sleep(delay)
                }
                if tier.probe { try await describe("Growing and bisecting accepted input"); try await probe(model: model, pair: pair, accepted: largest); done += 1; try await describe(nil) }
            } catch is BenchmarkBrowserStopped { try await describe("Stopped: browser response unavailable; no automatic retry or fallback") }
        }
    }
    static func allowedCap(_ text: String, below cap: Int) -> Int? {
        let expression = try! NSRegularExpression(pattern: "[0-9]{2,7}")
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).flatMap { Int(text[$0]) } }.filter { $0 >= 64 && $0 < cap }.max()
    }
    private func endpoint() throws -> BenchmarkConnection {
        if browser { return try dependencies.bridge(store.paths) }
        let base = provider["base_url"].string
        guard let url = URL(string: base), ["https", "http"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw NativeFailure("Invalid benchmark endpoint") }
        return BenchmarkConnection(baseURL: url, key: provider["api_key"].string)
    }
    private func request(model: String, messages: JSONValue, cap: Int, timeout: Double) async throws -> BenchmarkResponse {
        let connection = try endpoint(); privateKey = connection.key
        let identity = providerID + "|" + model
        for depth in 0..<4 {
            let quirks = try await store.quirk(identity)
            var payload: JSONValue = ["model": .string(model), "messages": messages, "stream": true]
            if browser { payload["metadata"] = ["uniapi_request_id": .string(UUID().uuidString)]; payload["stream_options"] = ["include_usage": true] }
            else {
                if !quirks["no_temperature"].bool { payload["temperature"] = 0 }
                payload[quirks["use_mct"].bool ? "max_completion_tokens" : "max_tokens"] = .number(Double(cap))
                if !quirks["no_stream_options"].bool { payload["stream_options"] = ["include_usage": true] }
            }
            let base = connection.baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let response = try await dependencies.transport.execute(.init(url: URL(string: base + "/chat/completions")!, headers: ["Authorization": "Bearer " + connection.key, "Content-Type": "application/json", "Accept": "text/event-stream", "User-Agent": settings["user_agent"].string.isEmpty ? "Mozilla/5.0 api-bench/native" : settings["user_agent"].string], body: try payload.encoded(), timeout: browser ? max(300, timeout) : timeout))
            guard !browser, depth < 3, [400, 404, 422].contains(response.status) else { return response }
            let text = response.text.lowercased(); var flag: String?
            if text.contains("stream_options") && !quirks["no_stream_options"].bool { flag = "no_stream_options" }
            else if (text.contains("max_completion_tokens") || (text.contains("max_tokens") && text.contains("unsupported"))) && !quirks["use_mct"].bool { flag = "use_mct" }
            else if text.contains("temperature") && text.contains("support") && !quirks["no_temperature"].bool { flag = "no_temperature" }
            guard let flag else { return response }
            _ = try await store.quirk(identity, flag)
        }
        throw NativeFailure("Benchmark quirk adaptation exhausted")
    }
    private func unit(_ unit: BenchmarkUnit, model: String, extra: JSONValue = [:]) async throws -> JSONValue {
        try Task.checkCancellation()
        if let saved = savedUnits[unit.id], saved["model"] == .string(model) { return saved }
        let tpc = await store.calibration(providerID + "|" + model)
        let text: String
        if let context = unit.context { text = BenchmarkPrompts.nonce() + BenchmarkPrompts.filler(context > 64 ? max(16, context - 40) : context, tpc: tpc, seed: runID + unit.id) + "\n\nIgnore the words above. Reply with the single word OK." }
        else if unit.test == "latency" { text = BenchmarkPrompts.nonce() + BenchmarkPrompts.filler(48, tpc: tpc, seed: runID + unit.id) + "\n\nIgnore the words above. Reply with the single word OK." }
        else { text = BenchmarkPrompts.nonce() + BenchmarkPrompts.throughput }
        var messages: JSONValue = [["role": "user", "content": .string(text)]]
        if unit.vision {
            let image = "data:image/png;base64," + BenchmarkPrompts.tinyPNG().base64EncodedString()
            messages = [["role": "user", "content": [["type": "text", "text": .string(BenchmarkPrompts.nonce() + "What color is this image? Answer with one word.")], ["type": "image_url", "image_url": ["url": .string(image)]]]]]
        }
        let timeout: Double
        if let context = unit.context { timeout = min(320.0, 30.0 + 2.0 * Double(context) / 1000.0) }
        else if unit.test == "maxout" { timeout = min(600.0, 90.0 + Double(unit.tokens) / 10.0) }
        else if unit.test == "throughput" { timeout = min(300.0, 60.0 + Double(unit.tokens) / 6.0) }
        else { timeout = 90.0 }
        let retries = browser ? 0 : ["latency", "context"].contains(unit.test) ? 2 : 1
        var attempt = 0
        while true {
            attempt += 1; try Task.checkCancellation(); let began = dependencies.now()
            let response: BenchmarkResponse
            do { response = try await request(model: model, messages: messages, cap: unit.tokens, timeout: timeout) }
            catch is CancellationError { throw CancellationError() }
            catch { response = .init(status: 0, exitCode: 1, error: error.localizedDescription) }
            let analysis = BenchmarkAnalysis.analyze(response)
            var ok = response.status == 200 && analysis.first != nil
            if response.exitCode == 28 && analysis.first != nil && !browser { ok = true }
            var error = ok ? "" : BenchmarkMath.error(status: response.status, body: response.text + " " + response.error, exitCode: response.exitCode, quota429: provider["treat_429_as_quota"].bool)
            if !ok && response.status == 200 && error == "unknown" { error = "empty_response" }
            if browser && response.status == 200 && (response.exitCode != 0 || analysis.streamError || !analysis.done) { ok = false; error = response.exitCode == 28 ? "timeout" : "incomplete_stream" }
            let transient = ["rate_limited", "server_error", "network"].contains(error) || (error == "timeout" && analysis.first == nil && (unit.context ?? 0) < 32768)
            if !ok && transient && attempt <= retries {
                let delay = Double(response.headers["retry-after"] ?? "") ?? [5.0, 15, 45][min(attempt - 1, 2)]
                try await store.event("retry", message: "\(providerID) \(unit.test): \(error)")
                try await log("Retry \(providerID) / \(model) \(unit.test): \(error)")
                try await dependencies.sleep(min(120, max(0, delay))); continue
            }
            let characters = unit.vision ? "data:image/png;base64,".count + BenchmarkPrompts.tinyPNG().base64EncodedString().count : text.unicodeScalars.count
            var result = try await build(unit, model: model, response: response, analysis: analysis, characters: characters, tpc: tpc, began: began, attempts: attempt, ok: ok, error: error, extra: extra)
            result = redact(result, key: privateKey)
            try await store.append(result); try await rowEvent(result)
            try await log(providerID + " / " + model + " " + unit.test + ": " + (ok ? "ok" : error + " HTTP \(response.status) " + result["error_excerpt"].string))
            if browser && !ok && !["ctx_limit", "bad_request"].contains(error) { throw BenchmarkBrowserStopped() }
            return result
        }
    }
    private func build(_ unit: BenchmarkUnit, model: String, response: BenchmarkResponse, analysis: BenchmarkAnalysis, characters: Int, tpc: Double, began: Date, attempts: Int, ok: Bool, error: String, extra: JSONValue) async throws -> JSONValue {
        let usage = analysis.usage
        let input = BenchmarkMath.number(usage["prompt_tokens"]), output = BenchmarkMath.number(usage["completion_tokens"])
        let inputEstimate = browser || input == nil, outputEstimate = browser || output == nil
        let inputCount = input ?? (Double(characters) * tpc).rounded(), outputCount = output ?? (Double(analysis.contentCharacters + analysis.reasoningCharacters) / 4).rounded()
        if !browser, let input { try await store.calibrate(providerID + "|" + model, characters: characters, tokens: input) }
        let generated = analysis.first.flatMap { first in analysis.last.map { $0 - first } }
        let speed: Double? = generated.flatMap { $0 > 50 && outputCount >= 8 ? (outputCount - 1) * 1000 / $0 : nil }
        var curve: [JSONValue] = []
        if unit.curve, let last = analysis.curve.last, last.1 > 0 {
            let factor = outputCount / Double(last.1), count = analysis.curve.count
            let indices = count <= 120 ? Array(0..<count) : Array(Set((0..<120).map { Int(Double($0) * Double(count) / 120) } + [count - 1])).sorted()
            curve = indices.map { .array([.number(analysis.curve[$0].0), .number(Double(analysis.curve[$0].1) * factor)]) }
        }
        var details = extra
        if unit.test == "maxout", details["requested_cap"].isNull { details["requested_cap"] = .number(Double(unit.tokens)) }
        if browser {
            details["output_cap_enforced"] = false; details["speed_measurement"] = "visible_text_estimate"; details["context_measurement"] = "browser_accepted_input"
            details["skipped_tests"] = ["maxout: browser output cannot be capped", "vision: browser image round-trip is unverified"]
            let allowed = ["transport", "requested_model", "observed_model", "observed_browser_mode", "model_identity", "estimated_usage", "queue_ms", "submit_ms", "first_visible_ms", "total_ms"]
            details["browser"] = .object(analysis.metadata.object.filter { allowed.contains($0.key) })
        }
        func phase(_ name: String) -> JSONValue { BenchmarkMath.optional(BenchmarkMath.number(response.timing[name]).map { $0 * 1000 }) }
        let cached = [usage["prompt_tokens_details"]["cached_tokens"], usage["prompt_cache_hit_tokens"], usage["cache_read_input_tokens"]].first { !$0.isNull } ?? .null
        let total = BenchmarkMath.number(response.timing["t_total"]).map { $0 * 1000 } ?? response.chunks.last?.milliseconds ?? 0
        return ["id": .string(UUID().uuidString), "run_id": .string(runID), "unit_id": .string(unit.id), "ts": .string(BenchmarkMath.iso(began)), "ts_end": .string(BenchmarkMath.iso(dependencies.now())), "provider": provider["id"], "provider_name": provider["name"].isNull ? provider["id"] : provider["name"], "model": .string(model), "target": .string(BenchmarkMath.family(model)), "tier": .string(tierName), "test": .string(unit.test), "ok": .bool(ok), "timed_out": .bool(response.exitCode == 28), "http_code": .number(Double(response.status)), "error_class": ok ? .null : .string(error), "error_excerpt": ok ? .null : .string(String((browser && error == "incomplete_stream" ? "Browser response did not complete; no automatic retry was sent." : response.text.isEmpty ? response.error : response.text).prefix(400))), "attempts": .number(Double(attempts)), "req": ["max_tokens": browser ? .null : .number(Double(unit.tokens)), "ctx_tokens": unit.context.map { .number(Double($0)) } ?? .null, "msg_chars": .number(Double(characters)), "stream": true], "timing_ms": ["ttfb": phase("t_starttransfer"), "ttft": BenchmarkMath.optional(analysis.first), "first_content": BenchmarkMath.optional(analysis.firstContent), "total": .number(total), "gen": BenchmarkMath.optional(generated), "dns": phase("t_dns"), "connect": phase("t_connect"), "tls": phase("t_tls")], "tokens": ["in": .number(inputCount), "out": .number(outputCount), "reasoning": browser ? .null : usage["completion_tokens_details"]["reasoning_tokens"], "cached": browser ? .null : cached, "in_est": .bool(inputEstimate), "out_est": .bool(outputEstimate)], "tps": ["decode": BenchmarkMath.optional(speed), "prefill": !browser && ok && (analysis.first ?? 0) > 0 ? .number(inputCount * 1000 / analysis.first!) : .null], "stream_stats": ["events": .number(Double(analysis.events)), "non_stream": .bool(analysis.nonStream), "done_seen": .bool(analysis.done), "gap_p50_ms": BenchmarkMath.optional(BenchmarkMath.percentile(analysis.gaps, 50)), "gap_p95_ms": BenchmarkMath.optional(BenchmarkMath.percentile(analysis.gaps, 95)), "gap_max_ms": BenchmarkMath.optional(analysis.gaps.max())], "finish_reason": analysis.finish.map(JSONValue.string) ?? .null, "content_head": ok ? .string(String(analysis.content.prefix(120))) : .null, "headers": .object(response.headers.mapValues(JSONValue.string)), "curve": curve.isEmpty ? .null : .array(curve), "extra": details, "transport": .string(browser ? "browser" : "api"), "tokens_estimated": .bool(browser), "measurement_note": browser ? .string(BenchmarkMath.browserNote) : .null]
    }
    private func probe(model: String, pair: String, accepted: Int) async throws {
        let summaryID = pair + ":probe-summary"
        if savedUnits[summaryID] != nil { return }
        var lower = accepted, upper: Int?, measured: JSONValue = .null, probes = 0, size = max(accepted * 2, 8192)
        while size <= 1_100_000 {
            let result = try await unit(.init(id: pair + ":probe:\(size)", test: "context_probe", tokens: 16, context: size), model: model); probes += 1
            if result["ok"].bool { lower = size; if !result["tokens"]["in_est"].bool { measured = result["tokens"]["in"] }; size *= 2 }
            else if result["error_class"] == "ctx_limit" { upper = size; break } else { break }
        }
        while let high = upper, high - lower > max(2048, lower / 32) {
            let middle = (lower + high) / 2
            let result = try await unit(.init(id: pair + ":probe:\(middle)", test: "context_probe", tokens: 16, context: middle), model: model); probes += 1
            if result["ok"].bool { lower = middle; if !result["tokens"]["in_est"].bool { measured = result["tokens"]["in"] } }
            else if result["error_class"] == "ctx_limit" { upper = middle } else { break }
        }
        let now = BenchmarkMath.iso(dependencies.now())
        let row: JSONValue = ["id": .string(UUID().uuidString), "run_id": .string(runID), "unit_id": .string(summaryID), "ts": .string(now), "ts_end": .string(now), "provider": provider["id"], "provider_name": provider["name"], "model": .string(model), "target": .string(BenchmarkMath.family(model)), "test": "max_context", "tier": .string(tierName), "ok": true, "req": ["max_tokens": .null], "tokens": ["in_est": .bool(browser), "out_est": .bool(browser)], "timing_ms": [:], "tps": [:], "stream_stats": [:], "transport": .string(browser ? "browser" : "api"), "tokens_estimated": .bool(browser), "measurement_note": browser ? .string(BenchmarkMath.browserNote) : .null, "extra": ["max_ok_requested": lower > 0 ? .number(Double(lower)) : .null, "min_fail_requested": upper.map { .number(Double($0)) } ?? .null, "measured_prompt_tokens": measured, "probes": .number(Double(probes)), "method": "grow+bisect", "inconclusive": .bool(upper == nil && lower * 2 <= 1_100_000), "output_cap_enforced": browser ? false : .null, "context_measurement": browser ? "browser_accepted_input" : "api_accepted_input"]]
        try await store.append(row); try await rowEvent(row)
    }
    private func redact(_ value: JSONValue, key: String) -> JSONValue {
        guard !key.isEmpty else { return value }
        switch value {
        case .string(let text): return .string(text.replacingOccurrences(of: key, with: "<redacted>"))
        case .array(let values): return .array(values.map { redact($0, key: key) })
        case .object(let fields): return .object(fields.mapValues { redact($0, key: key) })
        default: return value
        }
    }
    private func log(_ message: String) async throws {
        let redacted = BenchmarkMath.redact(.string(message), key: provider["api_key"].string).string
        let safe = redacted.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : String($0) }.joined()
        try await diagnostic(String(safe.prefix(300)))
    }
}
