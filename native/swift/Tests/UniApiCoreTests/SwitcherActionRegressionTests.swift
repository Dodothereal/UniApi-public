import XCTest
@testable import UniApiCore

final class SwitcherActionRegressionTests: XCTestCase {
    private let api: JSONValue = ["id": "api", "source": "provider", "providerId": "fixture", "efforts": ["high"], "available": true]
    private let native: JSONValue = ["id": "native", "source": "subscription", "providerId": .null, "efforts": ["low"], "available": true]
    private func status(_ restored: Bool) -> JSONValue { ["models": [api, native], "current": restored ? ["source": "subscription", "providerId": .null, "model": "native", "effort": "low"] : ["source": "provider", "providerId": "fixture", "model": "api", "effort": "high"]] }
    func testExactClaudeModelIDWinsOverOtherSubstringMatches() {
        let models = ["gpt-4o", "chatgpt-4o-latest"]
        XCTAssertEqual(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: models, query: "gpt-4o"), "gpt-4o")
        XCTAssertEqual(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: models, query: " gpt-4o "), "gpt-4o")
        XCTAssertEqual(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: models, query: "custom:free"), "custom:free")
    }
    func testSuccessfulRestoreResetsDefaultAndEffortWhilePreservingCatalogDraft() {
        var selected = NativeSwitcherSelectionDraft(); selected.accept(status(false))
        var catalog = NativeSwitcherCatalogDraft(); catalog.accept(["providerIds": [], "workerModels": []]); catalog.toggleProvider(["id": "fixture", "available": true], models: [api])
        let pending = catalog.body
        selected.acceptCompletedAction("codexAction", input: ["action": "restore"], result: ["ok": true, "status": status(true)])
        XCTAssertEqual(selected.key, NativeSwitcherModelKey(native)); XCTAssertEqual(selected.effort, "low"); XCTAssertEqual(catalog.body, pending)
    }
    func testPollsFailuresAndUnrelatedActionsDoNotResetSelectionDraft() {
        var selected = NativeSwitcherSelectionDraft(); selected.accept(status(false)); let old = selected
        selected.accept(status(true)); XCTAssertEqual(selected, old)
        for (operation, input, result) in [("codexAction", ["action": JSONValue.string("restore")], JSONValue.object(["ok": false, "status": status(true)])), ("codexAction", ["action": "doctor"], ["ok": true, "status": status(true)]), ("catalog", [:], ["ok": true, "status": status(true)]), ("codexSelect", [:], ["ok": true, "status": status(true)])] {
            selected.acceptCompletedAction(operation, input: input, result: result); XCTAssertEqual(selected, old)
        }
    }
    func testRestoreWithMissingCatalogDefaultClearsStaleSelectionAndEffort() {
        var selected = NativeSwitcherSelectionDraft(); selected.accept(status(false))
        selected.acceptCompletedAction("codexAction", input: ["action": "restore"], result: ["ok": true, "status": ["models": [], "current": ["source": "subscription", "model": "unknown", "effort": "low"]]])
        XCTAssertNil(selected.key); XCTAssertEqual(selected.effort, "")
    }
    func testEnterChoosesFirstCatalogRowOrExactTrimmedCustomRow() {
        let rows = ["z-model", "a-model", "m-model", "a-model"]
        XCTAssertEqual(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: rows, query: ""), "a-model")
        XCTAssertEqual(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: rows, query: "  "), "a-model")
        XCTAssertEqual(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: rows, query: " m-model "), "m-model")
        XCTAssertEqual(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: rows, query: " custom/id "), "custom/id")
        XCTAssertEqual(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: rows, query: "a"), "a")
        XCTAssertNil(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: [], query: ""))
        XCTAssertEqual(NativeSwitcherDisplayPolicies.claudeSubmitChoice(models: [], query: "custom"), "custom")
    }
}
