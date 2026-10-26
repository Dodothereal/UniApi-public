import XCTest
@testable import UniApiCore

final class NativeTOMLTests: XCTestCase {
    func testDottedAssignmentsCannotReopenExplicitTableOrArrayTableHeaders() throws {
        let invalid = [
            "[a.b]\nx=1\n[a]\nb.y=2\n",
            "[a.b.c]\nx=1\n[a]\nb.c.y=2\n",
            "[[a.b]]\nx=1\n[a]\nb.y=2\n",
            "[[a]]\n[a.b]\nx=1\n[a]\nb.y=2\n"
        ]
        for document in invalid {
            XCTAssertThrowsError(try NativeTOML.parse(document), document)
            XCTAssertThrowsError(try NativeTOML.patchDefaults(document, values: ["model": "new"]), document)
        }
        let sibling = "[a.b]\nx=1\n[a]\nc.y=2\n"
        XCTAssertEqual(try NativeTOML.parse(sibling)["a"]?["c"]["y"], 2)
        XCTAssertEqual(try NativeTOML.parse("[a]\nb.x=1\nb.y=2\n")["a"]?["b"]["y"], 2)
        let separateElements = "[[a]]\n[a.b]\nx=1\n[[a]]\nb.y=2\n"
        XCTAssertEqual(try NativeTOML.parse(separateElements)["a"]?.array.last?["b"]["y"], 2)
        XCTAssertEqual(try NativeTOML.parse(NativeTOML.patchDefaults(sibling, values: ["model": "new"]))["a"]?["b"]["x"], 1)
    }

    func testNestedInlineTablesAndStaticArraysRemainImmutable() throws {
        let invalid = [
            "x={a={b=1},a.c=2}\n",
            "x={a=[{b=1}],a.c=2}\n",
            "x={a=[],a.c=2}\n",
            "x={a.b={c=1},a.b.d=2}\n",
            "x={a.b=[{c=1}],a.b.d=2}\n",
            "x={a={b={c=1},b.d=2}}\n",
            "x={a=[{b={c=1},b.d=2}]}\n"
        ]
        for document in invalid {
            XCTAssertThrowsError(try NativeTOML.parse(document), document)
            XCTAssertThrowsError(try NativeTOML.patchDefaults(document, values: ["model": "new"]), document)
        }
        XCTAssertEqual(try NativeTOML.parse("x={a.b=1,a.c=2}\n")["x"]?["a"]["c"], 2)
        XCTAssertEqual(try NativeTOML.parse("x={a={b=1},c=2}\n")["x"]?["c"], 2)
        let sibling = "x={a.b={c=1},a.d=2}\n"
        XCTAssertEqual(try NativeTOML.parse(sibling)["x"]?["a"]["d"], 2)
        XCTAssertEqual(try NativeTOML.parse(NativeTOML.patchDefaults(sibling, values: ["model": "new"]))["x"]?["a"]["b"]["c"], 1)
    }

    func testInvalidNamespacesPreserveConfigAndNeverCreateOwnershipJournal() throws {
        for document in ["[a.b]\nx=1\n[a]\nb.y=2\n", "x={a={b=1},a.c=2}\n"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("toml-namespace-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("config.toml"), original = Data(document.utf8)
            try NativeFile.writeAtomic(original, to: file)
            let store = NativeCodexSettingsStore(configPath: file, stateDirectory: root.appendingPathComponent("state"))
            XCTAssertThrowsError(try store.select(["model": "new"]))
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.journalPath.path))
        }
    }
}
