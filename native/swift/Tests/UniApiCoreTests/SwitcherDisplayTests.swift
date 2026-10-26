import XCTest
@testable import UniApiCore

final class SwitcherDisplayTests: XCTestCase {
    private func model(_ id: String, provider: String? = nil, available: Bool = true, reserved: Bool = false) -> JSONValue {
        ["id": .string(id), "name": .string(id), "source": provider == nil ? "subscription" : "provider", "providerId": provider.map(JSONValue.string) ?? .null,
         "available": .bool(available), "workerReserved": .bool(reserved), "efforts": ["low", "high"],
         "catalogId": provider.map { .string(NativeCodexCatalogStore.id(provider: $0, model: id)) } ?? .null]
    }
    func testTupleModelKeysCannotCollideAndCurrentDefaultInitializesEffortOnce() {
        let a = model("c", provider: "a|b"), b = model("b|c", provider: "a")
        XCTAssertNotEqual(NativeSwitcherModelKey(a), NativeSwitcherModelKey(b))
        let status: JSONValue = ["models": [a, b], "current": ["source": "provider", "providerId": "a", "model": "b|c", "effort": "high"]]
        var draft = NativeSwitcherSelectionDraft(); draft.accept(status)
        XCTAssertEqual(draft.key, NativeSwitcherModelKey(b)); XCTAssertEqual(draft.effort, "high")
        draft.choose(a); draft.effort = "low"; draft.accept(status)
        XCTAssertEqual(draft.key, NativeSwitcherModelKey(a)); XCTAssertEqual(draft.effort, "low")
        var unsupported = status; unsupported["current"]["effort"] = "unsupported"
        var initial = NativeSwitcherSelectionDraft(); initial.accept(unsupported); XCTAssertEqual(initial.effort, "")
        var noEfforts = b; noEfforts["efforts"] = []
        draft.choose(noEfforts); XCTAssertEqual(draft.effort, "")
    }
    func testCatalogDraftSurvivesPollsUnrelatedActionsAndExternalSavedChanges() {
        var draft = NativeSwitcherCatalogDraft(); draft.accept(["providerIds": [], "workerModels": []])
        let row: JSONValue = ["id": "one", "available": true]
        draft.toggleProvider(row, models: []); draft.toggleWorker(model("model", provider: "one"))
        let pending = draft.body
        for _ in 0..<3 { draft.accept(["providerIds": [], "workerModels": []]) }
        XCTAssertEqual(draft.body, pending); XCTAssertTrue(draft.dirty)
        draft.accept(["providerIds": ["two"], "workerModels": ["native"]])
        XCTAssertEqual(draft.body, pending); XCTAssertEqual(draft.savedProviderIDs, ["two"])
        // A successful save acknowledges the submitted draft. Failed actions
        // never dispatch a replacement value, just the same status baseline.
        draft.accept(.object(pending)); XCTAssertFalse(draft.dirty)
        draft.accept(["providerIds": ["external"], "workerModels": []]); XCTAssertEqual(draft.providerIDs, ["external"])
    }
    func testProviderRemovalPrunesVisibleAndVanishedEncodedWorkersWithoutReorderingOthers() {
        let provider = "a/b%", own = model("shown", provider: provider), vanished = NativeCodexCatalogStore.id(provider: provider, model: "gone"), other = model("shown", provider: "other")
        var draft = NativeSwitcherCatalogDraft(); draft.accept(["providerIds": [.string(provider), "other"], "workerModels": ["native", own["catalogId"], .string(vanished), other["catalogId"]]])
        draft.toggleProvider(["id": .string(provider), "available": false], models: [own, other])
        XCTAssertEqual(draft.providerIDs, ["other"]); XCTAssertEqual(draft.workers, ["native", other["catalogId"].string])
        draft.toggleProvider(["id": "unavailable", "available": false], models: []); XCTAssertEqual(draft.providerIDs, ["other"])
    }
    func testVanishedAndUnavailableCheckedSelectionsStayVisibleAndRemovableAtCapacity() {
        var draft = NativeSwitcherCatalogDraft(); draft.accept(["providerIds": ["removed"], "workerModels": ["gone", "a", "b", "c"]])
        let providers = draft.visibleProviders([]); XCTAssertEqual(providers[0]["id"], "removed"); XCTAssertEqual(providers[0]["available"], false)
        let rows = draft.visibleWorkers([model("a", available: false), model("b", reserved: true), model("c"), model("extra")])
        let gone = rows.first { NativeSwitcherCatalogDraft.workerID($0) == "gone" }!
        XCTAssertEqual(gone["available"], false)
        draft.toggleWorker(model("extra")); XCTAssertEqual(draft.workers.count, 4)
        draft.toggleWorker(gone); draft.toggleWorker(model("a", available: false)); draft.toggleWorker(model("b", reserved: true))
        XCTAssertEqual(draft.workers, ["c"])
        draft.toggleWorker(model("extra")); XCTAssertEqual(draft.workers, ["c", "extra"])
        draft.toggleProvider(providers[0], models: []); XCTAssertTrue(draft.providerIDs.isEmpty)
        draft.toggleWorker(model("unselected", provider: "other")); XCTAssertEqual(draft.workers, ["c", "extra"])
    }
    func testProviderOrderHasNoMeaningButPreferredWorkerOrderDefinesSlots() {
        var draft = NativeSwitcherCatalogDraft(); draft.accept(["providerIds": ["one", "two"], "workerModels": ["first", "second"]])
        draft.accept(["providerIds": ["two", "one"], "workerModels": ["first", "second"]]); XCTAssertFalse(draft.dirty)
        draft.toggleWorker(model("first")); draft.toggleWorker(model("first")); XCTAssertEqual(draft.workers, ["second", "first"]); XCTAssertTrue(draft.dirty)
        draft.accept(["providerIds": ["one", "two"], "workerModels": ["second", "first"]]); XCTAssertFalse(draft.dirty)
    }
    func testSavedEngineFallbackSearchAndVerificationControlsFollowCurrentContracts() {
        XCTAssertEqual(NativeSwitcherDisplayPolicies.engine("codex"), "codex")
        XCTAssertEqual(NativeSwitcherDisplayPolicies.engine("invalid"), "claude")
        XCTAssertEqual(NativeSwitcherDisplayPolicies.matchingModels(["Claude Sonnet", "Claude Opus", "gpt-model"], query: " CLAUDE son "), ["Claude Sonnet"])
        for kind in ["switcher.codex.verify", "switcher.codex.provider"] {
            for status in ["queued", "running"] { XCTAssertTrue(NativeSwitcherDisplayPolicies.checksRunning([["kind": .string(kind), "status": .string(status)]])) }
            for status in ["done", "failed", "cancelled"] { XCTAssertFalse(NativeSwitcherDisplayPolicies.checksRunning([["kind": .string(kind), "status": .string(status)]])) }
        }
        XCTAssertFalse(NativeSwitcherDisplayPolicies.checksRunning([["kind": "other", "status": "running"]]))
    }
    func testSelectionAndCatalogReadinessUseSavedMembershipAndPreserveExternalOwnership() {
        let row = model("shared", provider: "one")
        var status: JSONValue = ["installed": true, "bridge": ["integrated": true, "busy": false], "catalog": ["supported": true, "enabled": true, "providerIds": []], "current": ["source": "subscription"]]
        XCTAssertTrue(NativeSwitcherDisplayPolicies.selectionIssue(status, model: row)?.contains("save the catalog") == true)
        status["catalog"]["providerIds"] = ["one"]
        XCTAssertNil(NativeSwitcherDisplayPolicies.selectionIssue(status, model: row)); XCTAssertNil(NativeSwitcherDisplayPolicies.catalogIssue(status))
        status["current"]["source"] = "provider"
        XCTAssertTrue(NativeSwitcherDisplayPolicies.selectionIssue(status, model: model("native"))?.contains("managed outside") == true)
        status["restoreAvailable"] = true; XCTAssertNil(NativeSwitcherDisplayPolicies.selectionIssue(status, model: model("native")))
        status["bridge"]["busy"] = true; XCTAssertNotNil(NativeSwitcherDisplayPolicies.catalogIssue(status))
        status["installed"] = false; XCTAssertNotNil(NativeSwitcherDisplayPolicies.selectionIssue(status, model: row))
    }
}
