import XCTest
@testable import UniApiCore

final class MediaPromptsAcceptanceTests: XCTestCase {
    private func fixture() throws -> (URL, NativeRuntime, NativePromptsService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-prompts-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let providers: JSONValue = ["providers": [["id": "one", "name": "Provider One", "models": ["shared", "manual"]], ["id": "two", "name": "Provider Two", "models": ["shared"]]]]
        try NativeFile.writeAtomic(try providers.encoded(), to: runtime.paths.providers)
        return (root, runtime, NativePromptsService(runtime: runtime))
    }
    private func prompt(_ service: NativePromptsService) async throws -> JSONValue {
        try await service.handle("create", input: ["title": "Fixture prompt", "text": "Return original output"])["prompt"]["id"]
    }
    func testCatalogKeepsProviderQualifiedModelsNamesAndFreeformLabels() async throws {
        let (_, runtime, service) = try fixture()
        let discovered: JSONValue = ["one": ["ids": ["shared", "discovered"], "meta": ["discovered": ["name": "Friendly model"]]]]
        try NativeFile.writeAtomic(try discovered.encoded(), to: runtime.paths.data.appendingPathComponent("models.json"))
        let models = try await service.handle("models")["providers"].array
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0]["models"].array.map { $0["id"] }, ["shared", "discovered", "manual"])
        XCTAssertEqual(models[0]["models"].array[1]["name"], "Friendly model")
        XCTAssertEqual(models[1]["models"].array.first?["id"], "shared")
        let id = try await prompt(service)
        let result = try await service.handle("addURL", input: ["id": id, "providerId": "two", "model": "freeform not in catalog", "url": "https://example.test/result"])
        XCTAssertEqual(result["result"]["providerId"], "two"); XCTAssertEqual(result["result"]["model"], "freeform not in catalog")
    }
    func testEditingRemovedProviderRetainsAttributionWhenProviderFieldIsOmitted() async throws {
        let (_, runtime, service) = try fixture(), id = try await prompt(service)
        let created = try await service.handle("addURL", input: ["id": id, "providerId": "one", "model": "shared", "url": "https://example.test/before"])["result"]
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: runtime.paths.providers)
        let changed = try await service.handle("updateResult", input: ["id": id, "resultId": created["id"], "model": "corrected label", "url": "https://example.test/after"])["result"]
        XCTAssertEqual(changed["providerId"], "one"); XCTAssertEqual(changed["providerName"], "Provider One")
        let cleared = try await service.handle("updateResult", input: ["id": id, "resultId": created["id"], "providerId": .null])["result"]
        XCTAssertTrue(cleared["providerId"].isNull); XCTAssertTrue(cleared["providerName"].isNull)
    }
    func testLegacyHTMLNameAndOriginalBytesMatchCurrentWebContract() async throws {
        let (_, runtime, service) = try fixture(), id = try await prompt(service)
        try runtime.db.execute("INSERT INTO prompt_results(id,prompt_id,model,kind,rank,created_at,file_extension) VALUES('result-legacy',?,'legacy-model','upload',1,1,'.html')", [id])
        let bytes = Data("<!doctype html><title>fixture</title>original\r\n".utf8)
        try NativeFile.writeAtomic(bytes, to: runtime.paths.data.appendingPathComponent("prompts/result-legacy.html"))
        let detail = try await service.handle("detail", input: ["id": id]), file = try await service.handle("resolveFile", input: ["resultId": "result-legacy"])
        XCTAssertEqual(detail["results"].array.first?["fileName"], "legacy-model.html")
        XCTAssertEqual(file["fileName"], "legacy-model.html"); XCTAssertEqual(file["kind"], "html")
        XCTAssertEqual(try NativePromptFiles.read(URL(fileURLWithPath: file["path"].string)).data, bytes)
    }
    func testCleanupNeverRecursivelyDeletesDirectoryAndRetrySurvivesReopen() async throws {
        let (root, runtime, service) = try fixture(), id = try await prompt(service)
        let source = root.appendingPathComponent("input.txt"); try Data("original".utf8).write(to: source)
        let result = try await service.handle("upload", input: ["id": id, "filePath": .string(source.path), "model": "fixture"])["result"]
        let file = try await service.handle("resolveFile", input: ["resultId": result["id"]]), managed = URL(fileURLWithPath: file["path"].string)
        try FileManager.default.removeItem(at: managed)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: false)
        let sentinel = managed.appendingPathComponent("preserve.txt"); try Data("must survive".utf8).write(to: sentinel)
        let deleted = try await service.handle("deleteResult", input: ["id": id, "resultId": result["id"]])
        XCTAssertEqual(deleted["cleanupPending"], true)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("must survive".utf8))
        XCTAssertEqual(try runtime.db.query("SELECT COUNT(*) AS n FROM prompt_file_cleanup").first?["n"], 1)
        let reopened = NativePromptsService(runtime: runtime)
        _ = try await reopened.handle("list")
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("must survive".utf8))
        // Repair the fixture obstruction; the persisted missing-file receipt
        // must then clear on the next pass, just as server unlink handles ENOENT.
        try FileManager.default.removeItem(at: managed)
        _ = try await reopened.handle("list")
        XCTAssertTrue(try runtime.db.query("SELECT * FROM prompt_file_cleanup").isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }
    func testTextAndHexPreviewsAreBoundedWhileSavedBytesStayExact() async throws {
        let (root, _, service) = try fixture(), id = try await prompt(service)
        for binary in [false, true] {
            let source = root.appendingPathComponent(binary ? "original.bin" : "original.txt")
            let bytes = Data(repeating: binary ? 255 : 97, count: NativePromptFiles.previewBytes + 17)
            try bytes.write(to: source)
            let result = try await service.handle("upload", input: ["id": id, "model": "fixture", "filePath": .string(source.path)])["result"]
            let preview = try await service.handle("preview", input: ["resultId": result["id"]])
            XCTAssertEqual(preview["kind"], binary ? "binary" : "text"); XCTAssertEqual(preview["truncated"], true)
            if binary { XCTAssertEqual(preview["text"].string.split(separator: "\n").count, 256) }
            else { XCTAssertEqual(preview["text"].string.utf8.count, NativePromptFiles.previewBytes) }
            XCTAssertEqual(try NativePromptFiles.read(URL(fileURLWithPath: preview["path"].string)).data, bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }
    func testFiftyMiBBoundaryIncludesEmptyFilesAndRejectsLargerBeforeResultCreation() async throws {
        let (root, runtime, service) = try fixture(), id = try await prompt(service), source = root.appendingPathComponent("boundary.bin")
        FileManager.default.createFile(atPath: source.path, contents: nil)
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(NativePromptFiles.maximumBytes))
        let accepted = try await service.handle("upload", input: ["id": id, "model": "fixture", "filePath": .string(source.path)])
        XCTAssertEqual(accepted["result"]["fileSize"], .number(Double(NativePromptFiles.maximumBytes)))
        try handle.truncate(atOffset: UInt64(NativePromptFiles.maximumBytes + 1))
        do { _ = try await service.handle("upload", input: ["id": id, "model": "fixture", "filePath": .string(source.path)]); XCTFail("Oversize accepted") } catch {}
        XCTAssertEqual(try runtime.db.query("SELECT COUNT(*) AS n FROM prompt_results").first?["n"], 1)
        try handle.truncate(atOffset: 0)
        let empty = try await service.handle("upload", input: ["id": id, "model": "empty", "filePath": .string(source.path)])
        XCTAssertEqual(empty["result"]["fileSize"], 0)
    }
}
