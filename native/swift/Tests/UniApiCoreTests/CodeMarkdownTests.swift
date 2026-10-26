import XCTest
@testable import UniApiCore

final class CodeMarkdownTests: XCTestCase {
    private func all(_ node: CodeMarkdownNode) -> [CodeMarkdownNode] { [node] + node.children.flatMap(all) }
    func testGFMTableAlignmentEscapedPipesAndInlineFormatting() throws {
        let tree = try CodeMarkdown.parse("| Left | Center | Right |\n| :--- | :---: | ---: |\n| **bold** | `a\\|b` | ~~gone~~ |\n| | sparse | |")
        let table = try XCTUnwrap(all(tree).first { if case .table = $0.kind { return true }; return false })
        XCTAssertEqual(table.kind, .table(alignments: [.left, .center, .right])); XCTAssertEqual(table.children.count, 3)
        XCTAssertEqual(table.children[0].kind, .row(header: true)); XCTAssertEqual(table.children[2].children.count, 3)
        XCTAssertTrue(table.children[1].children[0].spans.contains { $0.strong }); XCTAssertTrue(table.children[1].children[1].spans.contains { $0.code && $0.text == "a|b" }); XCTAssertTrue(table.children[1].children[2].spans.contains { $0.strike })
    }
    func testNestedListsStartingOrdinalTasksQuotesAndMultipleParagraphs() throws {
        let tree = try CodeMarkdown.parse("7. first\n8. second\n   - [x] done\n   - [ ] pending\n     > nested quote\n\n> outer\n>\n> another paragraph")
        let nodes = all(tree)
        XCTAssertTrue(nodes.contains { $0.kind == .item(ordinal: 7, checked: nil) })
        XCTAssertTrue(nodes.contains { $0.kind == .item(ordinal: 1, checked: true) }); XCTAssertTrue(nodes.contains { $0.kind == .item(ordinal: 2, checked: false) })
        XCTAssertEqual(nodes.filter { $0.kind == .quote }.count, 2); XCTAssertTrue(tree.plainText.contains("nested quote")); XCTAssertFalse(tree.plainText.contains("[x]"))
        let literals = all(try CodeMarkdown.parse("- \\[x] literal\n- `[x]` code\n\n[x] outside a list"))
        XCTAssertFalse(literals.contains { if case .item(_, let checked) = $0.kind { return checked != nil }; return false })
    }
    func testFencedIndentedUnclosedCodeAndCopyTextRemainLiteral() throws {
        let text = "~~~swift\nlet x = \"**literal**\"\n\n~~~\n\n    indented\n\n```js\nunfinished"
        let code = all(try CodeMarkdown.parse(text)).filter { if case .code = $0.kind { return true }; return false }
        XCTAssertEqual(code.count, 3); XCTAssertEqual(code[0].kind, .code(language: "swift")); XCTAssertEqual(code[0].plainText, "let x = \"**literal**\"\n\n"); XCTAssertFalse(code[0].spans.contains { $0.strong }); XCTAssertEqual(code[1].plainText, "indented\n"); XCTAssertEqual(code[2].plainText, "unfinished\n")
    }
    func testLinksAutolinksReferencesImagesAndUnsafeSchemes() throws {
        let tree = try CodeMarkdown.parse("[named][ref] www.example.invalid me@example.invalid\n\n![alt](https://example.invalid/a.png \"title\") ![](relative.png)\n\n[ref]: https://example.invalid/path\n\n[unsafe](javascript:alert) ![unsafe](file:///private/fixture)")
        let spans = all(tree).flatMap(\.spans)
        XCTAssertTrue(spans.contains { $0.link == "https://example.invalid/path" }); XCTAssertTrue(spans.contains { $0.link == "http://www.example.invalid" }); XCTAssertTrue(spans.contains { $0.link == "mailto:me@example.invalid" })
        XCTAssertTrue(spans.contains { $0.image == "https://example.invalid/a.png" && $0.text == "alt" && $0.title == "title" }); XCTAssertTrue(spans.contains { $0.image == "relative.png" })
        XCTAssertFalse(spans.contains { $0.link?.hasPrefix("javascript:") == true || $0.image?.hasPrefix("file:") == true })
        XCTAssertNil(CodeMarkdown.safeURL("data:text/html,fixture")); XCTAssertNil(CodeMarkdown.safeURL("java\nscript:fixture")); XCTAssertEqual(CodeMarkdown.relativeAsset("../image.png", document: "docs/readme.md"), "image.png")
    }
    func testHeadingsRulesUnicodeSoftAndHardBreaksAndRawHTMLNeverBecomeAnAppSurface() throws {
        let nodes = all(try CodeMarkdown.parse("Title\n=====\n\n# Unicode café 漢字\n\n---\n\nsoft\nline  \nhard\n\n<script>fixture</script>"))
        XCTAssertEqual(nodes.filter { if case .heading = $0.kind { return true }; return false }.count, 2)
        XCTAssertTrue(nodes.contains { $0.kind == .rule }); XCTAssertTrue(nodes.flatMap(\.spans).map(\.text).joined().contains("café 漢字"))
        XCTAssertEqual(try CodeMarkdown.parse("before\n\n<script>fixture</script>\n\nafter").children.map(\.plainText), ["before", "<script>fixture</script>\n", "after"])
    }
    func testLiveBlockFoldPartialToolArgumentsPrefixDedupAndNestedIsolation() throws {
        var live = CodeLiveState(); live.apply(["type": "message_start", "message": ["id": "m"]])
        live.apply(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": "reason"]]); live.apply(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "ing"]]); live.apply(["type": "content_block_stop", "index": 0])
        live.apply(["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "tool", "name": "Write"]]); live.apply(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "{\"file_path\":" ]]); XCTAssertEqual(live.blocks[1]?.input["partial"].string, "{\"file_path\":")
        live.apply(["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": "\"fixture\"}"]]); XCTAssertEqual(live.blocks[1]?.input["file_path"].string, "fixture")
        let before = live; live.apply(["type": "message_start", "message": ["id": "nested"]], parent: "parent"); XCTAssertEqual(live, before)
        let persisted: [JSONValue] = [["type": "assistant", "payload": ["message_id": "m", "content": [["type": "thinking", "thinking": "reasoning"]]]]]
        XCTAssertEqual(live.remaining(events: persisted).map(\.index), [1]); XCTAssertEqual(CodeLiveState(json: live.json), live)
        live.apply(["type": "message_stop"]); XCTAssertTrue(live.remaining(events: []).isEmpty)
    }
    func testScrollPolicyPreservesManualPositionAndResumesOnlyOnUserIntent() {
        var policy = CodeScrollPolicy(); XCTAssertEqual(policy.target(oldHeight: 500, newHeight: 800, viewport: 300, oldOffset: 200), 500)
        policy.userScrolled(distanceToBottom: 200); XCTAssertFalse(policy.follows); XCTAssertEqual(policy.target(oldHeight: 800, newHeight: 1200, viewport: 300, oldOffset: 300), 300)
        policy.userScrolled(distanceToBottom: 20); XCTAssertTrue(policy.follows); policy.userScrolled(distanceToBottom: 500); policy.userSent(); XCTAssertTrue(policy.follows)
        policy.userScrolled(distanceToBottom: .nan); XCTAssertFalse(policy.follows); policy.jumpToBottom(); XCTAssertTrue(policy.follows)
    }
}
