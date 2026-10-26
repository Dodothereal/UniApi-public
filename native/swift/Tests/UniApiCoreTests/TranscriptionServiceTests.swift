import XCTest
@testable import UniApiCore

final class TranscriptionServiceTests: XCTestCase {
    private func fixture() throws -> (URL, NativeRuntime) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home"))))
    }
    private func fakeIO(_ pcm: NativeAudioPCM, decode: (@Sendable (URL, URL) async throws -> NativeAudioPCM)? = nil) -> NativeTranscriptionIO {
        NativeTranscriptionIO(token: { "fixture-token" }, available: { ["wispr": true, "ffmpeg": true, "ytdlp": true] }, probe: { _ in NativeMediaMetadata(title: "Fixture link", duration: pcm.duration, bytes: pcm.data.count) }, download: { _, directory, _ in
            let file = directory.appendingPathComponent("fixture.wav"); try Data("fixture".utf8).write(to: file)
            return NativeMediaMetadata(file: file, title: "Fixture", duration: pcm.duration, bytes: pcm.data.count)
        }, decode: decode ?? { _, _ in pcm })
    }
    private func finish(_ service: NativeTranscriptionService, id: String) async throws -> JSONValue {
        var detail: JSONValue = .null
        for _ in 0..<200 {
            detail = try await service.handle("detail", input: ["id": .string(id)])
            if ["done", "failed"].contains(detail["status"].string) { return detail }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NativeFailure("Fixture transcription did not finish")
    }
    func testReopenedDetailLoadsCheckpointAndResumeSkipsCompletedAudio() async throws {
        let (root, runtime) = try fixture(), source = root.appendingPathComponent("original.wav")
        try Data("original".utf8).write(to: source)
        let asr = NativeWisprASR(transport: { _ in XCTFail("Completed checkpoint was sent to ASR again"); throw NativeFailure("No ASR request expected") }, sleep: { _ in })
        let service = NativeTranscriptionService(runtime: runtime, io: fakeIO(.init(data: Data(repeating: 0, count: 32000))), asr: asr)
        try await service.start()
        try runtime.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at) VALUES('old','transcribe','transcribe','fixture','transcribe','{\"notify\":false}','cancelled',1)")
        try runtime.db.execute("INSERT INTO transcripts(id,title,source,source_kind,media_path,status,created_at,job_id) VALUES('tr-fixture','fixture',?,'file',?,'queued',1,'old')", [.string(source.path), .string(source.path)])
        try runtime.db.execute("INSERT INTO transcript_chunks VALUES('tr-fixture',0,'persisted words')")
        let detail = try await service.handle("detail", input: ["id": "tr-fixture"])
        XCTAssertEqual(detail["checkpointParts"].array.first?["text"], "persisted words")
        XCTAssertEqual(detail["job"]["status"], "cancelled")
        _ = try await service.handle("resume", input: ["id": "tr-fixture", "notify": false])
        let done = try await finish(service, id: "tr-fixture")
        XCTAssertEqual(done["text"], "persisted words"); XCTAssertEqual(done["status"], "done")
        XCTAssertTrue(done["transcribe_ms"].isNull)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcript_chunks").isEmpty)
    }
    func testCompletedFileHasFinalTextTimingAndPreservesOriginal() async throws {
        let (root, runtime) = try fixture(), source = root.appendingPathComponent("original.wav")
        try Data("original fixture".utf8).write(to: source)
        let asr = NativeWisprASR(transport: { _ in NativeASRResponse(status: 200, body: try JSONValue.object(["content": "hello world"]).encoded()) }, sleep: { _ in })
        let service = NativeTranscriptionService(runtime: runtime, io: fakeIO(NativeAudioPCM(data: Data(repeating: 0, count: 32000))), asr: asr)
        let submitted = try await service.handle("submit", input: ["source": .string(source.path)])
        let id = submitted["id"].string, detail = try await finish(service, id: id)
        XCTAssertEqual(detail["status"], "done"); XCTAssertEqual(detail["text"], "hello world")
        XCTAssertEqual(detail["wordCount"], 2); XCTAssertGreaterThan(detail["transcribe_ms"].double, 0)
        XCTAssertEqual(detail["duration_s"], 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let exported = try await service.handle("export", input: ["id": .string(id)])
        XCTAssertEqual(exported["text"], "hello world\n")
        XCTAssertEqual(try runtime.db.query("SELECT * FROM transcribe_runs").count, 1)
        _ = try await service.handle("delete", input: ["id": .string(id)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcripts").isEmpty)
    }
    func testLinkPipelineUsesOwnedDownloadAndLearnsRates() async throws {
        let (_, runtime) = try fixture()
        let asr = NativeWisprASR(transport: { _ in NativeASRResponse(status: 200, body: try JSONValue.object(["content": "link fixture"]).encoded()) }, sleep: { _ in })
        let service = NativeTranscriptionService(runtime: runtime, io: fakeIO(NativeAudioPCM(data: Data(repeating: 0, count: 32000))), asr: asr)
        let submitted = try await service.handle("submit", input: ["source": "https://example.test/audio", "lang": "de"])
        let detail = try await finish(service, id: submitted["id"].string)
        XCTAssertEqual(detail["title"], "Fixture link"); XCTAssertEqual(detail["text"], "link fixture")
        let rows = try runtime.db.query("SELECT * FROM transcribe_runs")
        XCTAssertEqual(rows.first?["host"], "example.test")
        let estimate = try NativeTranscriptionEstimator(db: runtime.db).rate(kind: "url", key: "example.test", phase: .transcribe)
        XCTAssertTrue(estimate["basis"].string.contains("example.test"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.tmp.appendingPathComponent("transcribe-" + submitted["id"].string).path))
    }
    func testFailedCredentialPreflightMarksTranscriptFailed() async throws {
        let (root, runtime) = try fixture(), source = root.appendingPathComponent("input.wav")
        try Data("fixture".utf8).write(to: source)
        var io = fakeIO(NativeAudioPCM(data: Data(repeating: 0, count: 32000)))
        io.token = { throw NativeFailure("Fixture session unavailable") }
        let service = NativeTranscriptionService(runtime: runtime, io: io)
        let submitted = try await service.handle("submit", input: ["source": .string(source.path)])
        let detail = try await finish(service, id: submitted["id"].string)
        XCTAssertEqual(detail["status"], "failed"); XCTAssertTrue(detail["error"].string.contains("Fixture session"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testDeleteWaitsForCancellationBeforeRemovingOwnedData() async throws {
        let (root, runtime) = try fixture(), source = root.appendingPathComponent("input.wav")
        try Data("fixture".utf8).write(to: source)
        let entered = expectation(description: "fixture decode started")
        let io = fakeIO(NativeAudioPCM(data: Data()), decode: { _, _ in entered.fulfill(); try await Task.sleep(nanoseconds: 30_000_000_000); return NativeAudioPCM(data: Data()) })
        let service = NativeTranscriptionService(runtime: runtime, io: io)
        let submitted = try await service.handle("upload", input: ["source": .string(source.path)])
        await fulfillment(of: [entered], timeout: 2)
        let owned = submitted["media_path"].string
        _ = try await service.handle("delete", input: ["id": submitted["id"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcript_chunks").isEmpty)
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcripts").isEmpty)
    }
    func testNotificationUsesOnlyFixtureCredentialsAndVerifiesResponse() async throws {
        let (root, _) = try fixture(), home = root.appendingPathComponent("notify-home")
        try NativeNotifications.save(.init(enabled: true, token: "fixture-bot", chat: "fixture-chat"), home: home)
        try await NativeNotifications.send("fixture complete", home: home, transport: { request in
            let body = try JSONValue.decode(try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body["chat_id"], "fixture-chat"); XCTAssertEqual(body["text"], "fixture complete")
            return (try JSONValue.object(["ok": true]).encoded(), 200)
        })
        do { try await NativeNotifications.send("fixture", home: home, transport: { _ in (Data(), 500) }); XCTFail("Unconfirmed delivery succeeded") } catch {}
        XCTAssertEqual(NativeTranscriptionIO.firstKey(Data("{\"z-first\":\"one\",\"a-second\":\"two\"}".utf8)), "z-first")
    }
}
