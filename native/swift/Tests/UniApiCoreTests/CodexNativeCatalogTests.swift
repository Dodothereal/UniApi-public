import XCTest
@testable import UniApiCore

final class CodexNativeCatalogTests: XCTestCase {
    private func model(_ id: String, priority: Int = 0) -> JSONValue {
        ["slug": .string(id), "display_name": .string(id), "priority": .number(Double(priority)), "visibility": "list", "supported_in_api": true, "multi_agent_version": "v2", "supported_reasoning_levels": [["effort": "high"]], "model_messages": ["retained": true], "native_extra": 42, "comp_hash": "native-hash", "availability_nux": ["native": true], "multi_agent_reasoning_effort": "high"]
    }
    private func provider() -> JSONValue {
        ["id": "fixture", "name": "Fixture", "api_key": "fixture-key", "proxy": ["format": "openai", "models": ["glm:free", "sibling"], "model_context_tokens": ["glm:free": 1048576]], "codex": ["base_url": "http://127.0.0.1:8823/fixture/v1", "models": ["glm:free", "sibling"], "responses_verified": true, "tools_verified": true, "efforts": ["low", "high"]]]
    }
    private var choices: JSONValue { ["providerIds": ["fixture"], "workerModels": ["uniapi/fixture/glm%3Afree"]] }
    func testExactFreeContextNoCredentialLeakAndSiblingFallback() throws {
        let result = try NativeCodexRouteCatalog.augment(["models": [model("native")], "cursor": "retain"], providers: ["providers": [provider()]], choices: choices)
        XCTAssertEqual(result["cursor"], "retain")
        let rows = result["models"].array
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0]["model_messages"], ["retained": true]); XCTAssertEqual(rows[0]["native_extra"], 42)
        XCTAssertEqual(rows[1]["slug"], "uniapi/fixture/glm%3Afree"); XCTAssertEqual(rows[1]["context_window"], 1048576)
        XCTAssertEqual(rows[1]["auto_compact_token_limit"], 943718); XCTAssertEqual(rows[1]["effective_context_window_percent"], 90)
        XCTAssertEqual(rows[1]["display_name"], "Fixture — glm:free")
        XCTAssertEqual(rows[1]["model_messages"], .null); XCTAssertEqual(rows[1]["multi_agent_version"], "v1")
        XCTAssertNil(rows[1].object["comp_hash"]); XCTAssertNil(rows[1].object["availability_nux"]); XCTAssertNil(rows[1].object["multi_agent_reasoning_effort"])
        XCTAssertEqual(rows[1]["supported_reasoning_levels"], [["effort": "low"], ["effort": "high"]])
        XCTAssertEqual(rows[2]["context_window"], 128000)
        XCTAssertFalse(String(decoding: try result.encoded(), as: UTF8.self).contains("fixture-key"))
    }
    func testRefreshReplacesLegacyNoneRowWithModelCapabilitiesThroughCacheDecode() throws {
        let modelID = "deepseek/deepseek-v4.1-flash"
        let alias = NativeCodexCatalogStore.id(provider: "fixture", model: modelID)
        var p = provider()
        p["base_url"] = "https://api.commandcode.ai/provider/v1"
        p["codex"]["models"] = [.string(modelID), "sibling"]
        p["codex"]["efforts"] = []
        var stale = model(alias, priority: 1)
        stale["supported_reasoning_levels"] = [["effort": "none", "description": "No reasoning override"]]
        stale["default_reasoning_level"] = "none"
        let input: JSONValue = ["models": [model("native"), stale]]
        let selected: JSONValue = ["providerIds": ["fixture"], "workerModels": [.string(alias)]]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("models_cache.json")
        // Exercise the catalog producer and picker decoder together: refreshing
        // a cache must replace old provider rows, rather than merge their None.
        let cases: [(JSONValue?, [String])] = [(nil, ["high", "low", "max"]), ([], ["none"]), (["max"], ["max"])]
        for (override, expected) in cases {
            var changed = p
            if let override { changed["codex"]["model_efforts"][modelID] = override }
            let result = try NativeCodexRouteCatalog.augment(input, providers: ["providers": [changed]], choices: selected)
            let providerRows = result["models"].array.filter { $0["slug"] == .string(alias) }
            XCTAssertEqual(providerRows.count, 1)
            let row = try XCTUnwrap(providerRows.first)
            XCTAssertEqual(row["supported_reasoning_levels"].array.map { $0["effort"].string }, expected)
            XCTAssertEqual(row["default_reasoning_level"], .string(expected[0]))
            XCTAssertEqual(row["priority"], 1)
            XCTAssertEqual(result["models"].array.first { $0["slug"] == "uniapi/fixture/sibling" }?["supported_reasoning_levels"], [["effort": "none"]])
            let bytes = try result.encoded()
            XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("fixture-key"))
            try NativeFile.writeAtomic(bytes, to: file)
            let cached = try NativeCodexModelCache.rows(file).filter { $0["slug"] == .string(alias) }
            XCTAssertEqual(cached.count, 1)
            XCTAssertEqual(cached.first?["supported_reasoning_levels"].array.map { $0["effort"].string }, expected)
        }
    }
    func testInvalidContextFallsBackWithoutInventingLimit() throws {
        for bad: JSONValue in [0, -1, 1.5, "1000000", 9007199254740992] {
            var p = provider(); p["proxy"]["model_context_tokens"]["glm:free"] = bad; p["proxy"]["context_tokens"] = 200000
            let routes = try NativeCodexRouteCatalog.routes(providers: ["providers": [p]], choices: choices)
            XCTAssertEqual(routes.first?.context, 200000)
        }
    }
    func testDisabledUnverifiedForeignAndDuplicateRegistrationsCannotRoute() throws {
        var disabled = provider(); disabled["disabled"] = true
        var unverified = provider(); unverified["codex"]["tools_verified"] = false
        var foreign = provider(); foreign["codex"]["base_url"] = "https://foreign.invalid/v1"
        var badKey = provider(); badKey["api_key"] = "line\nbreak"
        var repeated = provider(); repeated["codex"]["models"] = ["glm:free", "glm:free"]
        for rows in [[disabled], [unverified], [foreign], [badKey], [repeated], [provider(), provider()]] {
            XCTAssertTrue(try NativeCodexRouteCatalog.routes(providers: ["providers": .array(rows)], choices: choices).isEmpty)
        }
    }
    func testAnchorAndFourWorkersHaveExactPriorityAndBrowserRowsDisappear() throws {
        var p = provider(); p["codex"]["models"] = ["a", "b", "c", "d", "e"]
        let selected: JSONValue = ["providerIds": ["fixture"], "workerModels": ["uniapi/fixture/d", "native-second", "uniapi/fixture/b", "uniapi/fixture/a"]]
        let result = try NativeCodexRouteCatalog.augment(["models": [model("native"), model("native-second", priority: 2), model("chatgpt-web/medium"), model("uniapi/stale/model")]], providers: ["providers": [p]], choices: selected)
        let ranked = result["models"].array.sorted { $0["priority"].int < $1["priority"].int }
        XCTAssertEqual(Array(ranked.prefix(5)).map { $0["slug"].string }, ["native", "uniapi/fixture/d", "native-second", "uniapi/fixture/b", "uniapi/fixture/a"])
        XCTAssertFalse(ranked.contains { $0["slug"].string.hasPrefix("chatgpt-web/") || $0["slug"] == "uniapi/stale/model" })
    }
    func testInvalidChoicesAndMalformedNativeEnvelopeFailClosed() throws {
        XCTAssertThrowsError(try NativeCodexRouteCatalog.augment(["models": []], providers: ["providers": [provider()]], choices: choices))
        XCTAssertThrowsError(try NativeCodexRouteCatalog.augment(["data": []], providers: ["providers": [provider()]], choices: choices))
        let invalid: JSONValue = ["providerIds": ["fixture"], "workerModels": ["a", "b", "c", "d", "e"]]
        XCTAssertThrowsError(try NativeCodexRouteCatalog.routes(providers: ["providers": [provider()]], choices: invalid))
    }
    func testCombinedCatalogByteBoundRefusesInsteadOfDroppingProvider() throws {
        let native: JSONValue = ["models": [model("native")]]
        let before = try native.encoded().count
        XCTAssertThrowsError(try NativeCodexRouteCatalog.augment(native, providers: ["providers": [provider()]], choices: choices, byteLimit: before + 10))
        let result = try NativeCodexRouteCatalog.augment(native, providers: ["providers": [provider()]], choices: choices, byteLimit: 65536)
        XCTAssertEqual(result["models"].array.count, 3)
    }
    func testProviderRosterWithoutEligibleNativeAnchorRefusesPublication() throws {
        var native = model("native"); native["supported_in_api"] = false
        var p = provider(); p["codex"]["models"] = ["a", "b", "c", "d", "e"]
        let chosen: JSONValue = ["providerIds": ["fixture"], "workerModels": ["uniapi/fixture/a", "uniapi/fixture/b", "uniapi/fixture/c", "uniapi/fixture/d"]]
        XCTAssertThrowsError(try NativeCodexRouteCatalog.augment(["models": [native]], providers: ["providers": [p]], choices: chosen))
        native["supported_in_api"] = true; native["multi_agent_version"] = "disabled"
        XCTAssertThrowsError(try NativeCodexRouteCatalog.augment(["models": [native]], providers: ["providers": [p]], choices: chosen))
    }
}
