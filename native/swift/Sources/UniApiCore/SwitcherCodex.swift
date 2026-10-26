import Foundation

public actor NativeCodexManager {
    public let runtime: NativeRuntime, settings: NativeCodexSettingsStore, catalog: NativeCodexCatalogStore
    private let io: NativeSwitcherIO, bridge: NativeCodexBridgeClient, port: Int
    private let nativeRoute: NativeCodexRouteStore, nativeControl: NativeCodexControlClient
    private var cachedRows: [JSONValue] = []
    private var retainHandoffRows = false
    private var mutating = false
    public init(runtime: NativeRuntime, io: NativeSwitcherIO, port: Int = 8823) {
        self.runtime = runtime; self.io = io; self.port = port
        settings = .init(configPath: SwitcherDisk.codexHome(runtime.paths).appendingPathComponent("config.toml"), stateDirectory: runtime.paths.data.appendingPathComponent("codex"))
        catalog = .init(bridgeHome: SwitcherDisk.bridgeHome(runtime.paths), providersFile: runtime.paths.providers)
        bridge = .init(paths: runtime.paths, dependencies: io.http)
        nativeRoute = .init(paths: runtime.paths); nativeControl = .init(paths: runtime.paths, dependencies: io.http, port: port)
    }
    private func providers() throws -> [NativeProviderInfo] { try runtime.providers.list().map { NativeProviderInfo(.object($0)) }.filter { !$0.browser } }
    private func shimReady() async -> Bool {
        do {
            let request = ShimHTTPRequest(url: URL(string: "http://127.0.0.1:\(port)/healthz")!, method: "GET", timeout: 1.5)
            let upstream = try await io.http.transport.open(request), value = try JSONValue.decode(await upstream.body(limit: 65536))
            return upstream.status == 200 && value["ok"] == true && value["service"] == "uniapi-shim" && value["runtime"] == "swift"
        } catch { return false }
    }
    private func cachedModels(_ config: JSONObject) -> [JSONValue] {
        let home = SwitcherDisk.codexHome(runtime.paths), selection = config["model_catalog_json"]?.string ?? ""
        let file = selection.isEmpty ? home.appendingPathComponent("models_cache.json") : selection.hasPrefix("/") ? URL(fileURLWithPath: selection) : home.appendingPathComponent(selection)
        let fresh = (try? NativeCodexModelCache.rows(file)) ?? []
        // Web disconnect invalidates Codex's cache. Keep only this manager's
        // already-read metadata until Codex fetches the independent catalog.
        if !fresh.isEmpty {
            cachedRows = fresh
            // A concurrent status read during disconnect must not retire the
            // snapshot just before the bridge removes its on-disk cache.
            if !mutating { retainHandoffRows = false }
        }
        let rows = fresh.isEmpty && retainHandoffRows && !FileManager.default.fileExists(atPath: file.path) ? cachedRows : fresh
        let anchor = rows.filter { !$0["slug"].string.hasPrefix("chatgpt-web/") && !$0["slug"].string.hasPrefix("uniapi/") && $0["visibility"] == "list" && $0["supported_in_api"] == true && $0["multi_agent_version"] != "disabled" }.sorted { $0["priority"].int < $1["priority"].int }.first?["slug"].string
        return rows.compactMap { row in
            let id = row["slug"]
            guard SwitcherDisk.validLabel(id), !id.string.hasPrefix("uniapi/"), row["visibility"] != "hide", row["hidden"] != true else { return nil }
            let web = id.string.hasPrefix("chatgpt-web/")
            let efforts = web ? [] : row["supported_reasoning_levels"].array.compactMap { SwitcherDisk.validLabel($0["effort"]) ? $0["effort"] : nil }
            return ["id": id, "name": SwitcherDisk.validLabel(row["display_name"]) ? row["display_name"] : id, "source": web ? "web" : "subscription", "providerId": .null, "efforts": .array(efforts), "available": true, "workerReserved": .bool(id.string == anchor)]
        }
    }
    public func status(checkWeb: Bool = false) async throws -> JSONValue {
        var config: JSONObject = [:], warnings: [JSONValue] = [], configError: JSONValue = .null, restore = false
        do { config = try settings.read().config; restore = try settings.hasRestore() } catch { configError = .string(error.localizedDescription); warnings.append(configError) }
        let platform = io.platform(runtime), providers = try providers(), nativeShim = await shimReady()
        var native: JSONValue = ["connected": false, "owned": false, "running": false, "error": .null, "healthError": .null]
        do { native = try nativeRoute.status(); native["error"] = .null } catch { native["error"] = .string(error.localizedDescription); warnings.append(native["error"]) }
        do {
            let health = try await nativeControl.status()
            native["nativeVersion"] = health["nativeVersion"]
            native["running"] = .bool(health["nativeVersion"] == 1); native["accepting"] = health["accepting"]; native["activeRequests"] = health["activeRequests"]
            native["healthError"] = .null
        } catch { native["running"] = false; native["healthError"] = .string(error.localizedDescription) }
        let nativeOwned = native["connected"] == true
        let state: JSONValue
        if nativeOwned && !checkWeb { state = await deferredBridgeState(platform) }
        else { state = await bridge.state(config: config, platform: platform, stateDirectory: settings.stateDirectory) }
        native["canConnect"] = .bool(native["error"].isNull && configError.isNull && native["running"] == true && native["accepting"] == true && native["activeRequests"] == 0 && !nativeOwned)
        var membership: JSONValue = ["providerIds": [], "workerModels": []], catalogError: JSONValue = .null
        do { membership = try (nativeOwned ? nativeRoute.catalog : catalog).read() } catch { catalogError = .string(error.localizedDescription); warnings.append(catalogError) }
        var catalogState = membership; catalogState["supported"] = nativeOwned ? .bool(native["running"] == true && native["error"].isNull) : state["catalogSupported"]; catalogState["enabled"] = .bool(catalogError.isNull && !membership["providerIds"].array.isEmpty); catalogState["error"] = catalogError
        catalogState["owner"] = nativeOwned ? "native" : "web"
        catalogState["providers"] = .array(providers.map { provider in let issue = provider.catalogIssue(port: port); return ["id": .string(provider.id), "name": .string(provider.name), "models": .array(provider.codexModels.map(JSONValue.string)), "available": .bool(provider.verified && issue == nil && nativeShim), "reason": !nativeShim ? "Start the native Swift shim; existing legacy listeners were preserved." : issue.map(JSONValue.string) ?? (provider.verified ? .null : .string(provider.codexReason))] })
        let saved = config["model"]?.string ?? "", routed = NativeCodexCatalogStore.parseID(saved), selector = config["model_provider"]?.string ?? ""
        let providerTable = config["model_providers"]?[selector] ?? .null
        let currentProvider = providers.first { routed == nil ? $0.raw["codex"]["base_url"] == providerTable["base_url"] : $0.id == routed!.provider }
        let custom = !selector.isEmpty && selector != "openai", source = custom || routed != nil ? "provider" : saved.hasPrefix("chatgpt-web/") ? "web" : "subscription"
        var models = cachedModels(config)
        if nativeOwned && native["running"] != true {
            for index in models.indices where models[index]["source"] == "subscription" { models[index]["available"] = false; models[index]["reason"] = "The UniApi native routing service is unavailable." }
        }
        var discovery: JSONValue?
        if state["running"] == true { discovery = await bridge.request("/uniapi/v1/models") }
        var discovered: [String: JSONValue] = [:]
        for row in discovery?["data"].array ?? [] where SwitcherDisk.validLabel(row["id"]) && row["id"].string.hasPrefix("chatgpt-web/") {
            discovered[row["id"].string] = row
            if !models.contains(where: { $0["id"] == row["id"] }) { models.append(["id": row["id"], "name": row["name"].string.isEmpty ? row["id"] : row["name"], "source": "web", "providerId": .null, "efforts": [], "available": false]) }
        }
        for index in models.indices where models[index]["source"] == "web" {
            let row = discovered[models[index]["id"].string]
            let available = state["running"] == true && state["integrated"] == true && state["toolsVerified"] == true && row != nil && row?["available"] != false
            models[index]["available"] = .bool(available)
            if let row, !row["name"].string.isEmpty { models[index]["name"] = row["name"] }
            if !available {
                let reason = state["configured"] != true ? "Complete setup in Codex Web GPT." : state["running"] != true ? "Start Codex Web GPT." : discovery == nil ? "Current browser model discovery is unavailable." : row == nil ? "This browser mode is absent from the current account catalog." : row?["available"] == false ? row?["reason"].string ?? "This browser mode is unavailable." : state["toolsVerified"] != true ? "Full coding tools have not been verified for this setup." : "Connect the Web route before selecting this default."
                models[index]["reason"] = .string(reason)
            }
        }
        for provider in providers {
            let issue = !provider.codexEnabled ? "This provider or its route is disabled." : !nativeShim ? "Start the native Swift shim; existing legacy listeners were preserved." : nativeOwned && native["running"] != true ? "The UniApi native routing service is unavailable." : nativeOwned || state["integrated"] == true ? provider.catalogIssue(port: port) : nil
            let custom = Set(provider.customModels)
            for id in provider.codexModels {
                var row: JSONValue = ["id": .string(id), "name": .string(id), "source": "provider", "providerId": .string(provider.id), "catalogId": .string(NativeCodexCatalogStore.id(provider: provider.id, model: id)), "efforts": .array(provider.efforts(for: id).map(JSONValue.string)), "available": .bool(provider.verified && issue == nil), "reason": issue.map(JSONValue.string) ?? (provider.verified ? .null : .string(provider.codexReason))]
                if custom.contains(id) { row["custom"] = true }
                models.append(row)
            }
        }
        if let routed, catalogState["supported"] != true || catalogState["enabled"] != true || !membership["providerIds"].array.contains(.string(routed.provider)) { warnings.append("The saved provider model is absent from the active shared catalog.") }
        if state["integrated"] == true { warnings.append("Native Codex model calls also use the connected bridge. Existing tasks may pick up routing changes when resumed."); if state["running"] != true { warnings.append("The configured bridge is unavailable; restore direct Codex or start Codex Web GPT.") } }
        else if nativeOwned { if native["running"] != true { warnings.append("The saved UniApi native route is unavailable; start its existing background service or restore direct Codex.") } }
        else if !(config["openai_base_url"]?.string ?? "").isEmpty { warnings.append("A separate OpenAI transport override is preserved; subscription model labels do not prove a direct connection.") }
        if source == "web" && state["integrated"] != true { warnings.append("A Web model is selected without its bridge route.") }
        if custom && currentProvider == nil { warnings.append("The current provider is managed outside UniApi; its configuration is preserved.") }
        if !models.contains(where: { $0["source"] == "subscription" }) { warnings.append("No cached native catalog is available; open Codex to refresh it.") }
        let current: JSONValue = ["source": .string(source), "providerId": source == "provider" ? .string(currentProvider?.id ?? routed?.provider ?? selector) : .null, "model": saved.isEmpty ? .null : .string(routed?.model ?? saved), "effort": config["model_reasoning_effort"] ?? .null]
        return ["installed": .bool(platform.codex != nil), "configPath": .string(settings.configPath.path), "configError": configError, "current": current, "bridge": state, "native": native, "nativeShimReady": .bool(nativeShim), "catalog": catalogState, "models": .array(models), "warnings": .array(warnings), "restoreAvailable": .bool(restore || state["integrated"] == true || native["canRestore"] == true)]
    }
    private func deferredBridgeState(_ platform: NativeSwitcherPlatform) async -> JSONValue {
        // Optional browser checks must not impose network timeouts on every
        // native-only read. Explicit doctor/proof actions can still check Web.
        let config = (try? await bridge.config()) ?? [:]
        let configured = config["host"] == "127.0.0.1" && (1024...65535).contains(config["port"].int) && config["port"].double == Double(config["port"].int)
        return ["installed": .bool(platform.bridge != nil), "configured": .bool(configured), "integrated": false,
                "running": .null, "busy": .null, "signInChecked": .null, "toolsVerified": .null, "catalogSupported": false,
                "mode": config["mode"], "version": config["releaseVersion"], "healthDeferred": true,
                "canStart": .bool(platform.openBridge != nil || platform.bridge != nil && configured), "canStop": false]
    }
    private func acquire() throws { try runtime.paths.assertWritable(); guard !mutating else { throw NativeFailure("Another Codex configuration change is active") }; mutating = true }
    public func select(_ value: JSONValue) async throws -> JSONValue {
        try acquire(); defer { mutating = false }
        let native = try await status()["native"]["connected"] == true
        var result: JSONValue
        if native { result = try await nativeControl.drained { try await self.selectChecked(value, native: true) } }
        else { result = try await selectChecked(value, native: false) }
        result["status"] = try await status(); return result
    }
    private func selectChecked(_ value: JSONValue, native: Bool) async throws -> JSONValue {
        let status = try await status(); guard status["configError"].isNull else { throw NativeFailure(status["configError"].string) }
        guard (status["native"]["connected"] == true) == native, status["native"]["error"].isNull else { throw NativeFailure("Codex route ownership changed; refresh before choosing a default") }
        let providerID = value["providerId"].isNull ? JSONValue.null : value["providerId"]
        guard let row = status["models"].array.first(where: { $0["source"] == value["source"] && $0["id"] == value["model"] && $0["providerId"] == providerID }), row["available"] == true else { throw NativeFailure("This source/model is not in the currently verified catalog") }
        if !value["effort"].string.isEmpty && !row["efforts"].array.contains(value["effort"]) { throw NativeFailure("This model does not advertise that effort") }
        let shared = value["source"] == "provider" && (native || status["bridge"]["integrated"] == true) && status["catalog"]["supported"] == true && status["catalog"]["enabled"] == true && status["catalog"]["providerIds"].array.contains(providerID)
        if value["source"] == "provider" && (native || status["bridge"]["integrated"] == true) && !shared { throw NativeFailure("Add this provider to Models in Codex before choosing it on the shared route") }
        let config = try settings.read().config
        if shared && !(config["model_provider"]?.string ?? "").isEmpty && config["model_provider"] != "openai" { throw NativeFailure("Restore the existing provider selector before choosing a shared model") }
        if shared && !(config["model_catalog_json"]?.string ?? "").isEmpty { throw NativeFailure("Reconnect the Web bridge before choosing shared catalog models") }
        if value["source"] != "provider", status["current"]["source"] == "provider", try !settings.hasRestore(), NativeCodexCatalogStore.parseID(config["model"]?.string ?? "") == nil { throw NativeFailure("This provider is managed outside UniApi; restore it there before changing sources") }
        var provider: JSONValue?
        if value["source"] == "provider" {
            guard let fresh = try providers().first(where: { $0.id == providerID.string }), fresh.codexEnabled, fresh.verified, fresh.codexModels.contains(value["model"].string), value["effort"].string.isEmpty || fresh.efforts(for: value["model"].string).contains(value["effort"].string), !shared || fresh.catalogIssue(port: port) == nil else { throw NativeFailure("Provider registration changed; refresh and choose again") }
            if !shared { provider = ["name": .string(fresh.name), "baseUrl": fresh.raw["codex"]["base_url"], "apiKey": .string(fresh.key)] }
        }
        if native { guard try nativeRoute.status()["connected"] == true else { throw NativeFailure("Native route ownership changed") } }
        let model = shared ? NativeCodexCatalogStore.id(provider: providerID.string, model: value["model"].string) : value["model"].string
        try settings.select(["model": .string(model), "model_reasoning_effort": value["source"] == "web" || value["effort"].string.isEmpty ? .null : value["effort"]], provider: provider)
        return ["ok": true, "reloadRequired": true, "message": "Saved the default; reload Codex when tasks are idle."]
    }
    public func configureCatalog(_ choices: JSONValue) async throws -> JSONValue {
        try acquire(); defer { mutating = false }; try NativeCodexCatalogStore.validate(choices)
        let status = try await status()
        try validateCatalog(choices, status: status)
        if status["native"]["connected"] == true { try await nativeControl.drained { try await self.saveCatalog(choices, native: true) } }
        else { try await bridge.drained { try await self.saveCatalog(choices, native: false) } }
        return ["ok": true, "reloadRequired": true, "message": "Saved Models in Codex; reload when tasks are idle to refresh the picker and worker roster.", "status": try await self.status()]
    }
    private func saveCatalog(_ choices: JSONValue, native: Bool) async throws {
        let status = try await status()
        guard (status["native"]["connected"] == true) == native, status["native"]["error"].isNull else { throw NativeFailure("Codex route ownership changed; catalog was preserved") }
        try validateCatalog(choices, status: status)
        try (native ? nativeRoute.catalog : catalog).write(choices)
    }
    private func validateCatalog(_ choices: JSONValue, status: JSONValue) throws {
        guard status["configError"].isNull, status["native"]["error"].isNull, status["catalog"]["error"].isNull, status["catalog"]["supported"] == true else { throw NativeFailure("A healthy connected native route or compatible Web bridge is required") }
        if !choices["providerIds"].array.isEmpty && status["nativeShimReady"] != true { throw NativeFailure("Start the native Swift shim before publishing API providers") }
        let config = try settings.read().config; guard (config["model_catalog_json"]?.string ?? "").isEmpty else { throw NativeFailure("Reconnect the bridge before publishing its shared catalog") }
        let providers = try providers()
        for id in choices["providerIds"].array { guard let provider = providers.first(where: { $0.id == id.string }), provider.verified, provider.catalogIssue(port: port) == nil else { throw NativeFailure("A selected provider is unavailable or unverified") } }
        var eligible = Set(cachedModels(config).filter { $0["source"] == "subscription" && $0["workerReserved"] != true }.map { $0["id"].string })
        eligible.formUnion(status["models"].array.filter { $0["source"] == "web" && $0["available"] == true }.map { $0["id"].string })
        for provider in providers where choices["providerIds"].array.contains(.string(provider.id)) { eligible.formUnion(provider.codexModels.map { NativeCodexCatalogStore.id(provider: provider.id, model: $0) }) }
        guard choices["workerModels"].array.allSatisfy({ eligible.contains($0.string) }) else { throw NativeFailure("A preferred worker is reserved, unavailable, or belongs to an unselected provider") }
        if let routed = NativeCodexCatalogStore.parseID(config["model"]?.string ?? ""), !choices["providerIds"].array.contains(.string(routed.provider)) { throw NativeFailure("Choose a different default before removing its provider from the catalog") }
    }
    private func validateNativeChoices(_ choices: JSONValue, config: JSONObject) throws {
        try NativeCodexCatalogStore.validate(choices)
        let providers = try providers()
        var eligible = Set(cachedModels(config).filter { $0["source"] == "subscription" && $0["workerReserved"] != true }.map { $0["id"].string })
        for id in choices["providerIds"].array {
            guard let provider = providers.first(where: { $0.id == id.string }), provider.verified, provider.catalogIssue(port: port) == nil else { throw NativeFailure("A selected provider is unavailable or unverified") }
            eligible.formUnion(provider.codexModels.map { NativeCodexCatalogStore.id(provider: provider.id, model: $0) })
        }
        guard choices["workerModels"].array.allSatisfy({ eligible.contains($0.string) }) else { throw NativeFailure("Native routing requires available API or subscription workers; Web workers were preserved") }
        let model = config["model"]?.string ?? ""
        guard !model.hasPrefix("chatgpt-web/") else { throw NativeFailure("Choose an API or subscription default before connecting native routing") }
        if let routed = NativeCodexCatalogStore.parseID(model) {
            guard choices["providerIds"].array.contains(.string(routed.provider)), providers.contains(where: { $0.id == routed.provider && $0.codexModels.contains(routed.model) }) else { throw NativeFailure("The current provider default is absent from the selected native catalog") }
        }
    }
    private func connectNative() async throws {
        try await nativeControl.drained { try await self.handoffNative() }
    }
    private func handoffNative() async throws {
        let route = try nativeRoute.status()
        if route["connected"] == true { return }
        let before = try settings.read(), platform = io.platform(runtime)
        let bridgeState = await bridge.state(config: before.config, platform: platform, stateDirectory: settings.stateDirectory)
        let web = bridgeState["integrated"] == true
        let destination = nativeRoute.catalog
        let destinationBefore = try SwitcherDisk.read(destination.file, limit: 65536)
        let choices = try (web || destinationBefore.isEmpty ? catalog : destination).read()
        try validateNativeChoices(choices, config: before.config)
        let selector = before.config["model_provider"]?.string ?? ""
        guard selector.isEmpty || selector == "openai" else { throw NativeFailure("Restore the existing provider selector before connecting native routing") }
        if web {
            guard bridgeState["running"] == true else { throw NativeFailure("The Web route owner must be available for a guarded handoff") }
            try await bridge.drained { try await self.releaseBridgeAndConnect(before: before, choices: choices, destinationBefore: destinationBefore) }
        } else { try finishNativeHandoff(before: before, choices: choices, destinationBefore: destinationBefore, bridgeReleased: false) }
    }
    private func releaseBridgeAndConnect(before: (text: String, config: JSONObject), choices: JSONValue, destinationBefore: Data) async throws {
        guard try settings.read().text == before.text, try catalog.read() == choices else { throw NativeFailure("Codex settings or worker selection changed before handoff") }
        // The journal-aware disconnect restores transport/features, not defaults.
        // Never compensate an uncertain result with an automatic Web reconnect.
        retainHandoffRows = true
        try await command(["route", "disconnect"])
        try finishNativeHandoff(before: before, choices: choices, destinationBefore: destinationBefore, bridgeReleased: true)
    }
    private func finishNativeHandoff(before: (text: String, config: JSONObject), choices: JSONValue, destinationBefore: Data, bridgeReleased: Bool) throws {
        let current = try settings.read()
        for key in ["model", "model_reasoning_effort"] where current.config[key] != before.config[key] {
            throw NativeFailure("Web disconnect changed Codex defaults; native routing was not connected. Inspect the current settings before retrying")
        }
        if !bridgeReleased { guard current.text == before.text else { throw NativeFailure("Codex configuration changed during handoff") } }
        guard (current.config["openai_base_url"]?.string ?? "").isEmpty, current.config["model_catalog_json"] == nil,
              current.config["model_provider"] == nil || current.config["model_provider"] == "openai" else { throw NativeFailure("The released Codex transport still has another owner; native routing was not connected") }
        if bridgeReleased { guard try catalog.read() == choices else { throw NativeFailure("Web worker selection changed during handoff; native catalog was preserved") } }
        try validateNativeChoices(choices, config: current.config)
        guard try nativeRoute.status()["connected"] != true else { throw NativeFailure("Native route ownership changed during handoff") }
        guard try SwitcherDisk.read(nativeRoute.catalog.file, limit: 65536) == destinationBefore else { throw NativeFailure("Native catalog changed during handoff; the newer selection was preserved") }
        let validatedBytes = Data(current.text.utf8)
        guard try SwitcherDisk.read(settings.configPath) == validatedBytes else { throw NativeFailure("Codex configuration changed during handoff; native routing was not connected") }
        let receipt = SwitcherDisk.hash(validatedBytes)
        try nativeRoute.catalog.write(choices)
        _ = try nativeRoute.connect(expectedConfigSHA256: receipt, port: port)
    }
    private func command(_ arguments: [String]) async throws {
        guard var command = io.platform(runtime).bridge else { throw NativeFailure("Codex Web GPT is not installed") }
        command.arguments += arguments; var env = runtime.process.cleanAgentEnvironment(SwitcherDisk.env(runtime.paths)); env["CODEX_HOME"] = SwitcherDisk.codexHome(runtime.paths).path; env["CODEX_CHATGPT_WEB_HOME"] = SwitcherDisk.bridgeHome(runtime.paths).path
        _ = try await io.run(command, env)
    }
    public func action(_ action: String) async throws -> JSONValue {
        if action == "doctor" { return ["ok": true, "message": "Local configuration and service checks completed; no model request was sent.", "reloadRequired": false, "status": try await status(checkWeb: true)] }
        try acquire(); defer { mutating = false }; let status = try await status(), platform = io.platform(runtime)
        var message = "Local configuration and service checks completed; no model request was sent.", reload = false
        if action == "nativeConnect" {
            guard status["configError"].isNull, status["native"]["error"].isNull else { throw NativeFailure("Resolve Codex configuration/route ownership before connecting native routing") }
            try await connectNative(); message = "Connected UniApi native API routing. API and subscription models no longer require Codex Web GPT. Reload Codex when idle."; reload = true
        } else if action == "open" || action == "setup" || (action == "start" && platform.openBridge != nil) {
            guard let command = action == "open" ? platform.openCodex : platform.openBridge else { throw NativeFailure("The desktop launcher is unavailable") }; _ = try await io.run(command, SwitcherDisk.env(runtime.paths)); message = "Opened the requested desktop app without restarting active tasks."
        } else if action == "start" { guard status["bridge"]["configured"] == true else { throw NativeFailure("Complete bridge setup first") }; try await command(["service", "start"]); message = "Requested bridge service start." }
        else if action == "stop" {
            guard status["bridge"]["canStop"] == true, status["bridge"]["integrated"] != true else { throw NativeFailure("The runtime is launcher-owned, busy, unavailable, or still routed; manage it in Codex Web GPT") }
            try await bridge.drained({ try await self.command(["service", "stop"]) }, resumeOnSuccess: false); message = "Requested bridge service stop."
        } else if action == "restore" {
            guard status["native"]["error"].isNull else { throw NativeFailure("Native route ownership is uncertain; resolve it before restoring defaults or Web routing") }
            try settings.assertRestorable()
            if status["native"]["connected"] == true {
                try await nativeControl.drained { try await self.restoreNative() }
            } else {
                if status["bridge"]["integrated"] == true { if status["bridge"]["running"] == true { try await bridge.drained { try await self.command(["route", "disconnect"]) } } else { try await command(["route", "disconnect"]) } }
                _ = try nativeRoute.restore(); try settings.restore(clearWebDefault: true)
            }
            message = "Restored owned routing and defaults; reload Codex when idle."; reload = true
        } else if action == "connect" {
            let native = try nativeRoute.status()
            guard native["connected"] != true, native["phase"].isNull,
                  !(try settings.read().config["openai_base_url"]?.string ?? "").hasPrefix("http://127.0.0.1:\(port)/_uniapi/codex/") else { throw NativeFailure("Restore UniApi native routing before connecting the optional Web bridge") }
            guard status["bridge"]["running"] == true, status["bridge"]["toolsVerified"] == true, status["current"]["source"] != "provider" else { throw NativeFailure("Start the bridge, verify coding tools, and restore the API-provider selection before connecting") }
            try await bridge.drained { try await self.command(["route", "connect"]) }; message = "Connected Web routing; native Codex calls also use this bridge. Reload when idle."; reload = true
        } else if action != "doctor" { throw NativeFailure("Unknown Codex action") }
        return ["ok": true, "message": .string(message), "reloadRequired": .bool(reload), "status": try await self.status()]
    }
    private func restoreNative() throws {
        try settings.assertRestorable()
        guard try nativeRoute.status()["connected"] == true else { throw NativeFailure("Native route ownership changed before restore") }
        _ = try nativeRoute.restore()
        try settings.restore(clearWebDefault: true)
    }
    func verifyTools() async throws -> JSONValue {
        let status = try await status(checkWeb: true)
        guard status["configError"].isNull, status["installed"] == true, status["bridge"]["configured"] == true, status["bridge"]["running"] == true, status["bridge"]["mode"] == "full", status["bridge"]["signInChecked"] == true, status["bridge"]["busy"] == false else { throw NativeFailure("Install Codex and complete an idle full-mode browser sign-in check before verifying tools") }
        return try await NativeCodexToolProof.verify(paths: runtime.paths, platform: io.platform(runtime), io: io)
    }
}
