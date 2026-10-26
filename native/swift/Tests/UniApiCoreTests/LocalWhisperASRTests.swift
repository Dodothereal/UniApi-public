import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import UniApiCore

private actor LocalWhisperCheckpointLog {
    struct Event: Sendable, Equatable {
        let done: Int
        let total: Int
        let index: Int?
        let text: String?
    }
    private var events: [Event] = []
    func append(_ done: Int, _ total: Int, _ index: Int?, _ text: String?) {
        events.append(Event(done: done, total: total, index: index, text: text))
    }
    func snapshot() -> [Event] { events }
}

final class LocalWhisperASRTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let temporary: URL
        let executable: URL
        let models: NativeLocalWhisperModels
        var asr: NativeLocalWhisperASR {
            NativeLocalWhisperASR(models: models, process: NativeProcess(), temporary: temporary, executable: executable)
        }
        func log(_ suffix: String) -> URL { URL(fileURLWithPath: executable.path + "." + suffix) }
        func lines(_ suffix: String) throws -> [String] {
            guard FileManager.default.fileExists(atPath: log(suffix).path) else { return [] }
            return try String(contentsOf: log(suffix), encoding: .utf8).split(separator: "\n").map(String.init)
        }
    }

    private func fixture(mode: String = "success", install: Bool = true) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("local-whisper-asr-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let temporary = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let model = Data("offline pinned model fixture".utf8)
        let assets = LocalWhisperAssets(url: URL(string: "https://example.invalid/fixture")!, bytes: Int64(model.count),
            sha256: SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined())
        let models = NativeLocalWhisperModels(paths: NativePaths(root: root, home: root), assets: assets,
            downloader: { _, handle, _, _ in try handle.write(contentsOf: model) })
        if install { try await models.install { _, _ in } }
        let executable = root.appendingPathComponent("mock-whisper")
        // This private executable runs through the real NativeProcess, never a mocked runner.
        // No fixture path is interpolated into shell source; $0 anchors the external receipts.
        let script = """
        #!/bin/sh
        set -eu
        umask 077
        printf 'run\\n' >> "$0.runs"
        printf '%s\\n' "$@" >> "$0.args"
        printf '%s\\n' "$PWD" >> "$0.work"
        printf '%s\\n' "$$" > "$0.pid"
        : > "$0.started"
        mode='\(mode)'
        if [ "$mode" = 'error' ]; then printf 'fixture recognition failure\\n' >&2; exit 23; fi
        if [ "$mode" = 'block' ]; then exec /bin/sleep 30; fi
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -m) test -s "$2" || exit 41; shift 2 ;;
                -f) test -s "$2" || exit 42; shift 2 ;;
                -of)
                    base=${2##*/}
                    if [ "$mode" != 'missing' ] || [ "$base" != 'text-1' ]; then
                        printf '  recognized-%s  \\n' "$base" > "$2.txt"
                    fi
                    shift 2 ;;
                *) shift ;;
            esac
        done
        """
        try NativeFile.writeAtomic(Data(script.utf8), to: executable, permissions: 0o700)
        return Fixture(root: root, temporary: temporary, executable: executable, models: models)
    }

    private func audio(seconds: Int = 50) -> NativeAudioPCM {
        NativeAudioPCM(data: Data(repeating: 0, count: seconds * NativeAudioPCM.rate * 2))
    }
    private func assertClean(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path).isEmpty,
                      "Recognition work directory leaked", file: file, line: line)
    }
    private func waitForStart(_ fixture: Fixture) async throws {
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: fixture.log("started").path) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NativeFailure("Mock recognizer did not start within 10 seconds")
    }

    func testMultipleChunksUseOneProcessAndPublishOrderedCheckpoints() async throws {
        let fixture = try await fixture(), pcm = audio(), log = LocalWhisperCheckpointLog()
        XCTAssertEqual(pcm.bounds().count, 2)
        let result = try await fixture.asr.transcribe(pcm, language: "de") {
            await log.append($0, $1, $2, $3)
        }
        XCTAssertEqual(try fixture.lines("runs"), ["run"])
        let arguments = try fixture.lines("args")
        XCTAssertEqual(arguments.filter { $0 == "-m" }.count, 1)
        XCTAssertEqual(arguments.filter { $0 == "-f" }.count, 2)
        XCTAssertEqual(arguments.filter { $0 == "-of" }.count, 2)
        XCTAssertTrue(arguments.contains("de"))
        XCTAssertEqual(result["parts"].array.map(\.string), ["recognized-text-0", "recognized-text-1"])
        XCTAssertEqual(result["text"].string, "recognized-text-0 recognized-text-1")
        XCTAssertEqual(result["totalSec"].double, 50)
        XCTAssertTrue(result["gaps"].array.isEmpty)
        let events = await log.snapshot()
        XCTAssertEqual(events.map(\.done), [0, 1, 2])
        XCTAssertEqual(events.map(\.total), [2, 2, 2])
        XCTAssertEqual(events.compactMap(\.index), [0, 1])
        XCTAssertEqual(events.compactMap(\.text), ["recognized-text-0", "recognized-text-1"])
        try assertClean(fixture)
        try await fixture.models.remove()
    }

    func testFullyCompletedRestartNeedsNoProcessOrInstalledModel() async throws {
        let fixture = try await fixture(install: false), pcm = audio(), log = LocalWhisperCheckpointLog()
        let asr = NativeLocalWhisperASR(models: fixture.models, process: NativeProcess(), temporary: fixture.temporary,
                                      executable: fixture.root.appendingPathComponent("missing-executable"))
        let result = try await asr.transcribe(pcm, language: nil, completed: [0: "saved zero", 1: "saved one"]) {
            await log.append($0, $1, $2, $3)
        }
        XCTAssertEqual(result["text"].string, "saved zero saved one")
        XCTAssertTrue(try fixture.lines("runs").isEmpty)
        let events = await log.snapshot()
        XCTAssertEqual(events, [.init(done: 2, total: 2, index: nil, text: nil)])
        try assertClean(fixture)
        let state = await fixture.models.status(); XCTAssertFalse(state["available"].bool)
    }

    func testInterruptedCheckpointRestartsOnlyMissingChunks() async throws {
        let fixture = try await fixture(), pcm = audio(), log = LocalWhisperCheckpointLog()
        do {
            _ = try await fixture.asr.transcribe(pcm, language: nil) { done, total, index, text in
                await log.append(done, total, index, text)
                if index == 0 { throw CancellationError() }
            }
            XCTFail("Checkpoint cancellation should interrupt transcription")
        } catch is CancellationError { }
        let events = await log.snapshot()
        let checkpoint = try XCTUnwrap(events.first { $0.index == 0 })
        let text = try XCTUnwrap(checkpoint.text)
        try assertClean(fixture)
        try FileManager.default.removeItem(at: fixture.log("args"))
        let resumed = try await fixture.asr.transcribe(pcm, language: "", completed: [0: text]) { _, _, _, _ in }
        XCTAssertEqual(resumed["parts"].array.map(\.string), [text, "recognized-text-1"])
        XCTAssertEqual(try fixture.lines("runs").count, 2)
        let arguments = try fixture.lines("args")
        XCTAssertEqual(arguments.filter { $0 == "-f" }.count, 1)
        XCTAssertTrue(arguments.contains("auto"))
        XCTAssertFalse(arguments.contains { $0.hasSuffix("chunk-0.wav") || $0.hasSuffix("text-0") })
        XCTAssertTrue(arguments.contains { $0.hasSuffix("chunk-1.wav") })
        try assertClean(fixture)
    }

    func testNonzeroExitIncludesDiagnosticAndCleansWorkAndLease() async throws {
        let fixture = try await fixture(mode: "error"), log = LocalWhisperCheckpointLog()
        do {
            _ = try await fixture.asr.transcribe(audio(), language: nil) { await log.append($0, $1, $2, $3) }
            XCTFail("Nonzero recognizer exit must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("fixture recognition failure")) }
        let events = await log.snapshot(); XCTAssertTrue(events.compactMap(\.index).isEmpty)
        XCTAssertEqual(try fixture.lines("runs").count, 1)
        try assertClean(fixture)
        try await fixture.models.remove()
    }

    func testMissingChunkOutputFailsWithoutInventingTranscript() async throws {
        let fixture = try await fixture(mode: "missing"), log = LocalWhisperCheckpointLog()
        do {
            _ = try await fixture.asr.transcribe(audio(), language: nil) { await log.append($0, $1, $2, $3) }
            XCTFail("Missing output must fail")
        } catch { }
        let events = await log.snapshot()
        XCTAssertEqual(events.compactMap(\.index), [0])
        XCTAssertEqual(events.compactMap(\.text), ["recognized-text-0"])
        try assertClean(fixture)
        try await fixture.models.remove()
    }

    func testCancellationStopsOwnedChildCleansWorkAndReleasesModel() async throws {
        let fixture = try await fixture(mode: "block"), pcm = audio()
        let task = Task { try await fixture.asr.transcribe(pcm, language: nil) { _, _, _, _ in } }
        defer { task.cancel() }
        try await waitForStart(fixture)
        do { try await fixture.models.remove(); XCTFail("Running recognizer must hold the model lease") }
        catch { }
        let pidText = try String(contentsOf: fixture.log("pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled recognition succeeded") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        try assertClean(fixture)
        try await fixture.models.remove()
    }

    func testUnavailableModelAndEmptyAudioNeverStartRecognizer() async throws {
        let fixture = try await fixture(install: false)
        do { _ = try await fixture.asr.transcribe(audio(seconds: 1), language: nil) { _, _, _, _ in }; XCTFail("Missing model accepted") }
        catch { }
        do { _ = try await fixture.asr.transcribe(NativeAudioPCM(data: Data()), language: nil) { _, _, _, _ in }; XCTFail("Empty audio accepted") }
        catch { }
        XCTAssertTrue(try fixture.lines("runs").isEmpty)
        try assertClean(fixture)
    }
}
