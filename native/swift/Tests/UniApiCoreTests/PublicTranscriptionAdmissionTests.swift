import XCTest
@testable import UniApiCore

final class PublicTranscriptionAdmissionTests: XCTestCase {
    func testMissingLocalRuntimeRejectsAllSubmissionRoutesBeforeJobsOrOwnedCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        let service = NativeTranscriptionService(runtime: runtime)
        let source = root.appendingPathComponent("original.wav")
        try Data("original media fixture".utf8).write(to: source)
        let inputs: [(String, JSONObject)] = [
            ("submit", ["source": "https://example.invalid/never-download"]),
            ("submit", ["source": .string(source.path)]),
            ("upload", ["source": .string(source.path)])
        ]
        for (operation, input) in inputs {
            do { _ = try await service.handle(operation, input: input); XCTFail("Unready local transcription was admitted") }
            catch { XCTAssertTrue(error.localizedDescription.contains("local Whisper")) }
        }
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcripts").isEmpty)
        XCTAssertTrue(try runtime.db.query("SELECT * FROM jobs").isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: runtime.paths.data.appendingPathComponent("uploads").path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("original media fixture".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.data.appendingPathComponent("local-models").path))
    }
}
