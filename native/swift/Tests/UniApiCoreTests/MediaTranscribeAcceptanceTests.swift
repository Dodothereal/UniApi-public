import XCTest
@testable import UniApiCore

final class MediaTranscribeAcceptanceTests: XCTestCase {
    private func fixture() throws -> (URL, NativeRuntime) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-transcribe-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, runtime)
    }
    private func media(_ root: URL) throws -> URL {
        let url = root.appendingPathComponent("original.wav"); try Data("original bytes".utf8).write(to: url); return url
    }
    private func io(_ pcm: NativeAudioPCM) -> NativeTranscriptionIO {
        NativeTranscriptionIO(token: { "fixture-token" }, available: { ["wispr": true, "ffmpeg": true, "ytdlp": true] }, probe: { _ in NativeMediaMetadata(title: "Fixture link", duration: pcm.duration, bytes: 20) }, download: { _, work, _ in
            let file = work.appendingPathComponent("fixture.wav"); try Data("download fixture".utf8).write(to: file)
            return NativeMediaMetadata(file: file, title: "Fixture link", duration: pcm.duration, bytes: 20)
        }, decode: { _, _ in pcm })
    }
    private func wait(_ service: NativeTranscriptionService, id: String, condition: (JSONValue) -> Bool) async throws -> JSONValue {
        for _ in 0..<1500 {
            let detail = try await service.handle("detail", input: ["id": .string(id)])
            if condition(detail) { return detail }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw NativeFailure("Fixture transcript did not reach expected state")
    }
    private func unusedASR() -> NativeWisprASR {
        NativeWisprASR(transport: { _ in XCTFail("Unexpected ASR fixture request"); throw NativeFailure("Unexpected ASR fixture request") }, sleep: { _ in })
    }
    func testPresentationCopyUsesOrderedLiveChunksAndFinalTextWins() {
        let live: JSONValue = ["status": "running", "text": "", "job": ["status": "running"]]
        XCTAssertEqual(NativeTranscriptPresentation.text(live, parts: [2: "third", 0: "first", 1: "second"]), "first second third")
        XCTAssertFalse(NativeTranscriptPresentation.canResume(live))
        XCTAssertEqual(NativeTranscriptPresentation.text(["text": "final"], parts: [0: "stale"]), "final")
        for status in ["cancelled", "failed", "queued"] {
            XCTAssertTrue(NativeTranscriptPresentation.canResume(["status": .string(status), "job": ["status": "cancelled"]]))
        }
        XCTAssertFalse(NativeTranscriptPresentation.canResume(["status": "done", "job": ["status": "done"]]))
    }
    func testDownloadProgressHandlesSplitStreamsOversizeLinesAndTrailingEOF() async {
        let progress = NativeTranscriptionDownloadProgress()
        var iterator = progress.stream.makeAsyncIterator()
        progress.receive(Data("[down".utf8))
        progress.receive(Data("unrelated stdout\n".utf8), isError: false)
        progress.receive(Data("load] 12.5% of fixture\r".utf8))
        let first = await iterator.next(); XCTAssertEqual(first, 12.5)
        progress.receive(Data(repeating: 65, count: 1_000_000))
        progress.receive(Data("[download] 90%\n[download] 150%\n[download] 100%".utf8))
        progress.finish()
        let last = await iterator.next(), ended = await iterator.next()
        XCTAssertEqual(last, 100); XCTAssertNil(ended)
    }
    func testLocalExecutableStderrProgressPreservesStdoutAndDrainsBeforeReturn() async throws {
        let (root, _) = try fixture(), script = root.appendingPathComponent("fixture-downloader")
        let source = "#!/bin/sh\nprintf '[download] 25%% of fixture\\n' >&2\nprintf '{\"title\":\"fixture\"}\\n'\nprintf '[download] 100%% of fixture\\n' >&2\n"
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let progress = NativeTranscriptionDownloadProgress()
        let reader = Task { () -> [Double] in var values: [Double] = []; for await value in progress.stream { values.append(value) }; return values }
        let result = try await NativeProcess().runStreaming(script, onErrorOutput: { progress.receive($0) }, onOutput: { progress.receive($0, isError: false) })
        progress.finish()
        let values = await reader.value
        XCTAssertEqual(result.status, 0); XCTAssertTrue(result.output.contains("\"title\":\"fixture\""))
        XCTAssertTrue(result.errorOutput.contains("100%")); XCTAssertEqual(values.last, 100)
    }
    func testQueuedCancellationBecomesTerminalInDetailListAndSummaryWithoutTouchingOriginals() async throws {
        let (root, runtime) = try fixture(), source = try media(root), pcm = NativeAudioPCM(data: Data(repeating: 0, count: 32000))
        var fixtureIO = io(pcm)
        let entered = expectation(description: "two decoding slots"); entered.expectedFulfillmentCount = 2
        fixtureIO.decode = { _, _ in entered.fulfill(); try await Task.sleep(nanoseconds: 30_000_000_000); return pcm }
        let notices = MediaTranscriptMessages()
        let service = NativeTranscriptionService(runtime: runtime, io: fixtureIO, asr: unusedASR(), notify: { await notices.append($0) })
        let first = try await service.handle("submit", input: ["source": .string(source.path), "notify": false])
        let second = try await service.handle("submit", input: ["source": .string(source.path), "notify": false])
        let queued = try await service.handle("submit", input: ["source": .string(source.path), "notify": false])
        await fulfillment(of: [entered], timeout: 2)
        _ = try await runtime.jobs.cancelAndWait(queued["job_id"].string)
        let detail = try await service.handle("detail", input: ["id": queued["id"]])
        let list = try await service.handle("list"), summary = try await service.handle("summary")
        XCTAssertEqual(detail["status"], "cancelled")
        XCTAssertEqual(list.array.first { $0["id"] == queued["id"] }?["status"], "cancelled")
        XCTAssertEqual(summary["running"], 2); XCTAssertTrue(NativeTranscriptPresentation.canResume(detail))
        _ = try await runtime.jobs.cancelAndWait(first["job_id"].string); _ = try await runtime.jobs.cancelAndWait(second["job_id"].string)
        let cancelled = try await service.handle("detail", input: ["id": first["id"]])
        XCTAssertEqual(cancelled["status"], "cancelled"); XCTAssertFalse(cancelled["finished_at"].isNull)
        XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
        let delivered = await notices.messages; XCTAssertTrue(delivered.isEmpty)
    }
    func testLiveASRCancellationRetainsCheckpointAndResumeSkipsAlreadyPaidChunk() async throws {
        let (root, runtime) = try fixture(), source = try media(root), pcm = NativeAudioPCM(data: Data(repeating: 0, count: 46 * 32000))
        let script = MediaTranscriptASRScript()
        let asr = NativeWisprASR(transport: { try await script.respond($0) }, sleep: { _ in })
        let service = NativeTranscriptionService(runtime: runtime, io: io(pcm), asr: asr, notify: { _ in XCTFail("Notification disabled") })
        let submitted = try await service.handle("submit", input: ["source": .string(source.path), "notify": false])
        let id = submitted["id"].string
        _ = try await wait(service, id: id) { $0["checkpointParts"].array.count == 1 }
        _ = try await runtime.jobs.cancelAndWait(submitted["job_id"].string)
        let cancelled = try await service.handle("detail", input: ["id": .string(id)])
        XCTAssertEqual(cancelled["status"], "cancelled"); XCTAssertEqual(cancelled["checkpointParts"].array.count, 1)
        _ = try await service.handle("resume", input: ["id": .string(id), "notify": false])
        let done = try await wait(service, id: id) { $0["status"] == "done" }
        XCTAssertEqual(done["text"], "first second"); XCTAssertTrue(done["transcribe_ms"].isNull)
        let calls = await script.calls; XCTAssertEqual(calls, 3)
        XCTAssertTrue(done["checkpointParts"].array.isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
    }
    func testShutdownRecoveryReusesDownloadAndCheckpointWithoutAnotherDownload() async throws {
        let (_, runtime) = try fixture(), pcm = NativeAudioPCM(data: Data(repeating: 0, count: 46 * 32000)), script = MediaTranscriptASRScript()
        let service = NativeTranscriptionService(runtime: runtime, io: io(pcm), asr: NativeWisprASR(transport: { try await script.respond($0) }, sleep: { _ in }), notify: { _ in XCTFail("Notification disabled") })
        let submitted = try await service.handle("submit", input: ["source": "https://media.example.test/audio", "notify": false]), id = submitted["id"].string
        _ = try await wait(service, id: id) { $0["checkpointParts"].array.count == 1 }
        await runtime.jobs.suspendForShutdown()
        let suspended = try await service.handle("detail", input: ["id": .string(id)])
        XCTAssertEqual(suspended["status"], "queued"); XCTAssertEqual(suspended["job"]["status"], "running")
        let reopened = try NativeRuntime(paths: runtime.paths)
        var resumedIO = io(pcm)
        resumedIO.probe = { _ in XCTFail("Resumed link was probed"); return NativeMediaMetadata() }
        resumedIO.download = { _, _, _ in XCTFail("Resumed media was downloaded again"); throw NativeFailure("Unexpected download") }
        let secondASR = NativeWisprASR(transport: { _ in NativeASRResponse(status: 200, body: try JSONValue.object(["content": "second"]).encoded()) }, sleep: { _ in })
        let resumedService = NativeTranscriptionService(runtime: reopened, io: resumedIO, asr: secondASR, notify: { _ in XCTFail("Notification disabled") })
        try await resumedService.start(); try await reopened.jobs.recover()
        // Transcript completion is published before work-directory cleanup;
        // the job becomes done only after the handler has attempted cleanup.
        let done = try await wait(resumedService, id: id) { $0["status"] == "done" && $0["job"]["status"] == "done" }
        XCTAssertEqual(done["text"], "first second"); XCTAssertTrue(done["transcribe_ms"].isNull)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.paths.tmp.appendingPathComponent("transcribe-" + id).path))
    }
    func testRenameWhileDecodeIsSuspendedSurvivesCompletion() async throws {
        let (root, runtime) = try fixture(), source = try media(root), pcm = NativeAudioPCM(data: Data(repeating: 0, count: 32000)), latch = MediaTranscriptLatch()
        var fixtureIO = io(pcm)
        let entered = expectation(description: "decode suspended")
        fixtureIO.decode = { _, _ in entered.fulfill(); await latch.wait(); return pcm }
        let asr = NativeWisprASR(transport: { _ in NativeASRResponse(status: 200, body: try JSONValue.object(["content": "words"]).encoded()) }, sleep: { _ in })
        let service = NativeTranscriptionService(runtime: runtime, io: fixtureIO, asr: asr, notify: { _ in })
        let submitted = try await service.handle("submit", input: ["source": .string(source.path), "title": "Before"])
        await fulfillment(of: [entered], timeout: 2)
        _ = try await service.handle("rename", input: ["id": submitted["id"], "title": "Renamed while decoding"])
        await latch.release()
        let done = try await wait(service, id: submitted["id"].string) { $0["status"] == "done" }
        XCTAssertEqual(done["title"], "Renamed while decoding"); XCTAssertEqual(done["job"]["title"], "Transcribe Renamed while decoding")
    }
    func testRejectedUploadAdmissionRemovesOnlyOwnedCopy() async throws {
        let (root, runtime) = try fixture(), source = try media(root)
        let service = NativeTranscriptionService(runtime: runtime, io: io(.init(data: Data())), asr: unusedASR(), notify: { _ in })
        try await service.start(); await runtime.jobs.suspendForShutdown()
        do { _ = try await service.handle("upload", input: ["source": .string(source.path)]); XCTFail("Shutdown admitted upload") } catch {}
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcripts").isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: runtime.paths.data.appendingPathComponent("uploads"), includingPropertiesForKeys: nil).isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
    }
    func testLanguagePayloadNotificationAndASROnlyMetricsUseInjectedTransports() async throws {
        let (root, runtime) = try fixture(), source = try media(root), notices = MediaTranscriptMessages()
        let asr = NativeWisprASR(transport: { request in
            let body = try JSONValue.decode(try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body["language"], "de"); XCTAssertEqual(request.value(forHTTPHeaderField: "authorization"), "fixture-token")
            return NativeASRResponse(status: 200, body: try JSONValue.object(["content": "eins zwei drei"]).encoded())
        }, sleep: { _ in })
        let service = NativeTranscriptionService(runtime: runtime, io: io(.init(data: Data(repeating: 0, count: 32000))), asr: asr, notify: { await notices.append($0) })
        let submitted = try await service.handle("submit", input: ["source": .string(source.path), "lang": "de", "notify": true])
        let done = try await wait(service, id: submitted["id"].string) { $0["job"]["status"] == "done" }
        XCTAssertEqual(done["wordCount"], 3); XCTAssertGreaterThan(done["transcribe_ms"].double, 0)
        XCTAssertEqual(done["wordsPerMinute"].double, 180000 / done["transcribe_ms"].double, accuracy: 0.001)
        XCTAssertEqual(done["duration_s"], 1)
        let messages = await notices.messages; XCTAssertEqual(messages.count, 1); XCTAssertTrue(messages.first?.hasPrefix("Done: Transcribe") == true)
        let exported = try await service.handle("export", input: ["id": submitted["id"]]); XCTAssertEqual(exported["text"], "eins zwei drei\n")
    }
    private func seedAdmissionTranscript(_ runtime: NativeRuntime, source: URL, id: String = "admission", job: String? = nil) throws {
        try runtime.db.execute("INSERT INTO transcripts(id,title,source,source_kind,media_path,status,created_at,job_id) VALUES (?,'Admission fixture',?,'file',?,'failed',1,?)", [.string(id), .string(source.path), .string(source.path), job.map(JSONValue.string) ?? .null])
    }
    private func entered(_ barrier: MediaTranscriptAdmissionBarrier) async throws {
        for _ in 0..<500 {
            if await barrier.entered { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw NativeFailure("Admission fixture did not reach its held boundary")
    }
    func testHeldResumeSubmissionRefusesDeleteThenDeleteDrainsItsNewBackend() async throws {
        let (root, runtime) = try fixture(), source = try media(root)
        let admission = MediaTranscriptAdmissionBarrier(), backend = MediaTranscriptAdmissionBarrier(), deleted = MediaTranscriptAdmissionBarrier(), cancelled = MediaTranscriptAdmissionBarrier()
        var fixtureIO = io(.init(data: Data()))
        fixtureIO.decode = { _, work in
            try await withTaskCancellationHandler {
                await backend.hold()
                try Data("backend finished before delete".utf8).write(to: work.appendingPathComponent("late-backend"))
                await backend.recordWrite()
                return NativeAudioPCM(data: Data())
            } onCancel: { Task { await cancelled.markEntered() } }
        }
        let service = NativeTranscriptionService(runtime: runtime, io: fixtureIO, asr: unusedASR(), notify: { _ in XCTFail("No notification") }, submitJob: { title, params in
            await admission.hold(); try Task.checkCancellation()
            return try await runtime.jobs.submit(kind: "transcribe", app: "transcribe", title: title, params: params)
        })
        try await service.start(); try seedAdmissionTranscript(runtime, source: source)
        addTeardownBlock { await admission.release(); await backend.release(); await runtime.jobs.suspendForShutdown() }
        let resuming = Task { try await service.handle("resume", input: ["id": "admission", "notify": false]) }
        try await entered(admission)
        do { _ = try await service.handle("delete", input: ["id": "admission"]); XCTFail("Delete passed resume admission") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy resuming or deleting")) }
        XCTAssertEqual(try runtime.db.query("SELECT COUNT(*) AS n FROM transcripts").first?["n"], 1)
        await admission.release(); let resumed = try await resuming.value
        XCTAssertFalse(resumed["job_id"].string.isEmpty)
        try await entered(backend)
        let deletion = Task { let result = try await service.handle("delete", input: ["id": "admission"]); await deleted.markEntered(); return result }
        // A second control operation must see the delete owner while its actual
        // backend remains held, rather than waiting on an actor-wide lock.
        try await entered(cancelled)
        let returnedEarly = await deleted.entered; XCTAssertFalse(returnedEarly)
        do { _ = try await service.handle("resume", input: ["id": "admission"]); XCTFail("Resume passed delete admission") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy resuming or deleting")) }
        await backend.release(); _ = try await deletion.value
        let writes = await backend.writes; XCTAssertEqual(writes, 1)
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcripts WHERE id='admission'").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.paths.tmp.appendingPathComponent("transcribe-admission").path))
        XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
    }
    func testHeldDeleteAfterQueueDrainRefusesResumeOfItsTerminalJob() async throws {
        let (root, runtime) = try fixture(), source = try media(root), drain = MediaTranscriptAdmissionBarrier()
        let service = NativeTranscriptionService(runtime: runtime, io: io(.init(data: Data())), asr: unusedASR(), notify: { _ in XCTFail("No notification") }, cancelJob: { id in
            let cancelled = try await runtime.jobs.cancelAndWait(id)
            await drain.hold(); return cancelled
        })
        try await service.start()
        try runtime.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at) VALUES ('old','transcribe','transcribe','old','transcribe','{}','cancelled',1)")
        try seedAdmissionTranscript(runtime, source: source, job: "old")
        addTeardownBlock { await drain.release(); await runtime.jobs.suspendForShutdown() }
        let deletion = Task { try await service.handle("delete", input: ["id": "admission"]) }
        try await entered(drain)
        do { _ = try await service.handle("resume", input: ["id": "admission"]); XCTFail("Delete drain admitted a replacement worker") }
        catch { XCTAssertTrue(error.localizedDescription.contains("busy resuming or deleting")) }
        let jobs = try await runtime.jobs.list(); XCTAssertEqual(jobs.count, 1)
        await drain.release(); _ = try await deletion.value
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcripts").isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
    }
    func testCancelledHeldResumeRestoresRowAndReleasesAdmissionForDelete() async throws {
        let (root, runtime) = try fixture(), source = try media(root), admission = MediaTranscriptAdmissionBarrier()
        let service = NativeTranscriptionService(runtime: runtime, io: io(.init(data: Data())), asr: unusedASR(), notify: { _ in XCTFail("No notification") }, submitJob: { _, _ in
            await admission.hold(); try Task.checkCancellation()
            throw NativeFailure("Cancelled fixture unexpectedly continued")
        })
        try await service.start(); try seedAdmissionTranscript(runtime, source: source)
        addTeardownBlock { await admission.release() }
        let resuming = Task { try await service.handle("resume", input: ["id": "admission"]) }
        try await entered(admission); resuming.cancel(); await admission.release()
        do { _ = try await resuming.value; XCTFail("Cancelled resume succeeded") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation: \(error)") }
        XCTAssertEqual(try runtime.db.query("SELECT status FROM transcripts WHERE id='admission'").first?["status"], "failed")
        _ = try await service.handle("delete", input: ["id": "admission"])
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcripts").isEmpty)
    }
    func testCancelledDeleteDrainReleasesAdmissionForRetryWithoutRemovingOriginal() async throws {
        let (root, runtime) = try fixture(), source = try media(root), drain = MediaTranscriptAdmissionBarrier()
        let service = NativeTranscriptionService(runtime: runtime, io: io(.init(data: Data())), asr: unusedASR(), notify: { _ in XCTFail("No notification") }, cancelJob: { id in
            let result = try await runtime.jobs.cancelAndWait(id)
            await drain.hold(); try Task.checkCancellation(); return result
        })
        try await service.start()
        try runtime.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at) VALUES ('old','transcribe','transcribe','old','transcribe','{}','cancelled',1)")
        try seedAdmissionTranscript(runtime, source: source, job: "old")
        addTeardownBlock { await drain.release() }
        let deletion = Task { try await service.handle("delete", input: ["id": "admission"]) }
        try await entered(drain); deletion.cancel(); await drain.release()
        do { _ = try await deletion.value; XCTFail("Cancelled delete succeeded") } catch is CancellationError {} catch { XCTFail("Unexpected cancellation: \(error)") }
        XCTAssertFalse(try runtime.db.query("SELECT * FROM transcripts WHERE id='admission'").isEmpty)
        _ = try await service.handle("delete", input: ["id": "admission"])
        XCTAssertTrue(try runtime.db.query("SELECT * FROM transcripts").isEmpty)
        XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
    }
    func testCredentialFailureHasHonestMetricsAndOneInjectedFailureNotification() async throws {
        let (root, runtime) = try fixture(), source = try media(root), notices = MediaTranscriptMessages()
        var fixtureIO = io(.init(data: Data()))
        fixtureIO.token = { throw NativeFailure("Fixture session expired") }
        let service = NativeTranscriptionService(runtime: runtime, io: fixtureIO, asr: unusedASR(), notify: { await notices.append($0) })
        let submitted = try await service.handle("submit", input: ["source": .string(source.path), "notify": true])
        let failed = try await wait(service, id: submitted["id"].string) { $0["job"]["status"] == "failed" }
        XCTAssertEqual(failed["status"], "failed"); XCTAssertTrue(failed["transcribe_ms"].isNull); XCTAssertTrue(failed["wordsPerMinute"].isNull)
        let messages = await notices.messages; XCTAssertEqual(messages.count, 1); XCTAssertTrue(messages.first?.hasPrefix("Failed: Transcribe") == true)
        XCTAssertEqual(try Data(contentsOf: source), Data("original bytes".utf8))
    }
}

private actor MediaTranscriptMessages {
    var messages: [String] = []
    func append(_ text: String) { messages.append(text) }
}
private actor MediaTranscriptAdmissionBarrier {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var writes = 0
    func hold() async { entered = true; if released { return }; await withCheckedContinuation { continuation = $0 } }
    func release() { released = true; continuation?.resume(); continuation = nil }
    func markEntered() { entered = true }
    func recordWrite() { writes += 1 }
}
private actor MediaTranscriptLatch {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { if released { return }; await withCheckedContinuation { continuation = $0 } }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor MediaTranscriptASRScript {
    var calls = 0
    func respond(_ request: URLRequest) async throws -> NativeASRResponse {
        calls += 1
        let number = calls
        let body = try JSONValue.decode(try XCTUnwrap(request.httpBody)), wav = try XCTUnwrap(Data(base64Encoded: body["audio"].string))
        let first = wav.count > 10 * 32000
        if !first && number <= 2 { try await Task.sleep(nanoseconds: 30_000_000_000) }
        return NativeASRResponse(status: 200, body: try JSONValue.object(["content": first ? "first" : "second"]).encoded())
    }
}
