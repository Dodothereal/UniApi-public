import XCTest
import Darwin
@testable import UniApiCore

final class PromptsTests: XCTestCase {
    private func fixture() throws -> (URL, NativeRuntime, NativePromptsService) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        let providers: JSONValue = ["providers": [["id": "fixture", "name": "Fixture", "models": ["same-model"]]]]
        try NativeFile.writeAtomic(try providers.encoded(), to: runtime.paths.providers)
        return (root, runtime, NativePromptsService(runtime: runtime))
    }
    func testFileClassificationDoesNotDiscardInvalidBytes() {
        XCTAssertEqual(NativePromptFiles.type(name: "unknown", sample: Data([0xff])).kind, "binary")
        XCTAssertEqual(NativePromptFiles.type(name: "active.xhtml", sample: Data()).kind, "html")
        XCTAssertEqual(NativePromptFiles.type(name: "source.swift", sample: Data("print(1)".utf8)).kind, "text")
        XCTAssertEqual(NativePromptFiles.type(name: "unknown", sample: Data([0x61, 0xe2, 0x82])).kind, "text")
        XCTAssertEqual(NativePromptFiles.type(name: "unknown", sample: Data([0x61, 0xe0, 0x80])).kind, "binary")
        XCTAssertEqual(NativePromptFiles.fileExtension("archive.\nhtml"), ".bin")
        XCTAssertEqual(NativePromptFiles.uploadName("../../path/file\n.txt"), "file_.txt")
        XCTAssertLessThanOrEqual(NativePromptFiles.hex(Data(repeating: 0xab, count: 10_000)).split(separator: "\n").count, 256)
    }
    func testFIFOIsRejectedWithoutBlockingTheCallingThread() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("result.txt")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let began = Date()
        XCTAssertThrowsError(try NativePromptFiles.read(fifo))
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.2)
    }
    func testPromptCRUDRanksAndCrossPromptProtection() async throws {
        let (root, runtime, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let created = try await service.handle("create", input: ["title": "Compare", "text": "Produce a useful result"])
        let id = created["prompt"]["id"].string
        let first = try await service.handle("addURL", input: ["id": .string(id), "model": "same-model", "providerId": "fixture", "url": "https://example.test/one"])
        let second = try await service.handle("addURL", input: ["id": .string(id), "model": "freeform", "url": "https://example.test/two"])
        XCTAssertEqual(first["result"]["providerName"], "Fixture")
        let order = [second["result"]["id"], first["result"]["id"]]
        let reordered = try await service.handle("order", input: ["id": .string(id), "resultIds": .array(order)])
        XCTAssertEqual(reordered["results"].array.map { $0["id"] }, order)
        do { _ = try await service.handle("order", input: ["id": .string(id), "resultIds": [order[0], order[0]]]); XCTFail("Duplicate order admitted") } catch {}
        let other = try await service.handle("create", input: ["title": "Other", "text": "Other prompt"])
        do { _ = try await service.handle("deleteResult", input: ["id": other["prompt"]["id"], "resultId": order[0]]); XCTFail("Cross-prompt deletion admitted") } catch {}
        _ = try await service.handle("deleteResult", input: ["id": .string(id), "resultId": order[0]])
        let detail = try await service.handle("detail", input: ["id": .string(id)])
        XCTAssertEqual(detail["prompt"]["resultCount"], 1)
        XCTAssertEqual(detail["results"].array.first?["rank"], 1)
        XCTAssertEqual(try runtime.db.query("SELECT name FROM schema_migrations WHERE name LIKE 'prompts-%'").count, 3)
    }
    func testEmptyUploadSurvivesAndCleanupRemovesOnlyManagedFile() async throws {
        let (root, runtime, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        try Data().write(to: source)
        let created = try await service.handle("create", input: ["title": "Empty", "text": "Check empty files"])
        let id = created["prompt"]["id"]
        let added = try await service.handle("upload", input: ["id": id, "model": "fixture", "filePath": .string(source.path)])
        XCTAssertEqual(added["result"]["fileSize"], 0)
        let preview = try await service.handle("preview", input: ["resultId": added["result"]["id"]])
        XCTAssertEqual(preview["kind"], "text")
        let managed = preview["path"].string
        XCTAssertTrue(managed.hasPrefix(runtime.paths.data.appendingPathComponent("prompts").path + "/"))
        _ = try await service.handle("delete", input: ["id": id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: managed))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testInputRejectionsAndSymlinkPreviewProtection() async throws {
        let (root, runtime, service) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        do { _ = try await service.handle("create", input: ["title": "bad\nlabel", "text": "valid"]); XCTFail("Control character accepted") } catch {}
        let created = try await service.handle("create", input: ["title": "Safe", "text": "Fixture"])
        let id = created["prompt"]["id"]
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://user:pass@example.test"] {
            do { _ = try await service.handle("addURL", input: ["id": id, "model": "fixture", "url": .string(url)]); XCTFail("Unsafe URL accepted") } catch {}
        }
        let source = root.appendingPathComponent("original.bin")
        try Data([0xff]).write(to: source)
        let added = try await service.handle("upload", input: ["id": id, "model": "fixture", "filePath": .string(source.path)])
        let managed = try await service.handle("resolveFile", input: ["resultId": added["result"]["id"]])
        let destination = URL(fileURLWithPath: managed["path"].string)
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        do { _ = try await service.handle("preview", input: ["resultId": added["result"]["id"]]); XCTFail("Symlink preview accepted") } catch {}
        XCTAssertEqual(try runtime.db.query("SELECT COUNT(*) AS n FROM prompts").first?["n"], 1)
    }
}
