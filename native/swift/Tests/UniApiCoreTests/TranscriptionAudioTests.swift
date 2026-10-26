import XCTest
@testable import UniApiCore

final class TranscriptionAudioTests: XCTestCase {
    func testQuietBoundariesWAVAndOddByteTail() throws {
        let pcm = NativeAudioPCM(data: Data(repeating: 0, count: 50 * 16000 * 2 + 1))
        XCTAssertEqual(pcm.samples, 50 * 16000)
        let bounds = pcm.bounds()
        XCTAssertEqual(bounds.count, 2)
        XCTAssertEqual(bounds.first?.lowerBound, 0)
        XCTAssertEqual(bounds.last?.upperBound, pcm.samples)
        XCTAssertEqual(bounds[0].upperBound, bounds[1].lowerBound)
        XCTAssertGreaterThanOrEqual(bounds[0].upperBound, Int(43.5 * 16000))
        XCTAssertLessThanOrEqual(bounds[0].upperBound, Int(46.5 * 16000))
        let wav = try pcm.wav(bounds[1])
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav.count, bounds[1].count * 2 + 44)
        XCTAssertThrowsError(try pcm.wav((-1)..<2))
        XCTAssertTrue(NativeAudioPCM(data: Data()).bounds().isEmpty)
    }
    func testActualWordCountsAndUnavailableTiming() {
        let text = "Hello, world!\nLet's build tests. …"
        let metrics = NativeTranscriptMetrics.augment(["text": .string(text), "status": "done", "transcribe_ms": 30000])
        XCTAssertEqual(metrics["wordCount"], 5)
        XCTAssertEqual(metrics["wordsPerMinute"], 10)
        XCTAssertGreaterThan(NativeTranscriptMetrics.words("こんにちは世界"), 1)
        XCTAssertEqual(NativeTranscriptMetrics.words("… — !!!"), 0)
        for elapsed: JSONValue in [.null, 0, -1, .number(.infinity), .number(.nan), "30000", .number(Double.leastNonzeroMagnitude)] {
            let result = NativeTranscriptMetrics.augment(["text": "a word", "status": "done", "transcribe_ms": elapsed])
            XCTAssertTrue(result["wordsPerMinute"]!.isNull)
        }
        let running = NativeTranscriptMetrics.augment(["text": "a word", "status": "running", "transcribe_ms": 30000])
        XCTAssertTrue(running["transcribe_ms"]!.isNull)
    }
    func testResumeSkipsCompletedChunkAndKeepsOrdering() async throws {
        let recorder = TranscriptionFixtureRecorder()
        let asr = NativeWisprASR(transport: { request in
            await recorder.record(request)
            return NativeASRResponse(status: 200, body: try JSONValue.object(["content": "second part"]).encoded())
        }, sleep: { _ in })
        let pcm = NativeAudioPCM(data: Data(repeating: 0, count: 50 * 16000 * 2))
        let result = try await asr.transcribe(pcm, language: "de", token: "fixture-token", completed: [0: "first part"], progress: { _, _, _, _ in })
        XCTAssertEqual(result["text"], "first part second part")
        XCTAssertEqual(result["parts"].array, ["first part", "second part"])
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "authorization"), "fixture-token")
        let body = try JSONValue.decode(try XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual(body["language"], "de")
        XCTAssertEqual(String(decoding: try XCTUnwrap(Data(base64Encoded: body["audio"].string)).prefix(4), as: UTF8.self), "RIFF")
    }
    func testRetryAfterIsBoundedAnd401Terminates() async throws {
        let recorder = TranscriptionFixtureRecorder()
        let asr = NativeWisprASR(transport: { request in
            let count = await recorder.record(request)
            return count == 1 ? NativeASRResponse(status: 429, body: Data(), retryAfter: 60) : NativeASRResponse(status: 200, body: try JSONValue.object(["content": "ok"]).encoded())
        }, sleep: { await recorder.delay($0) })
        let pcm = NativeAudioPCM(data: Data(repeating: 0, count: 16000 * 2))
        let result = try await asr.transcribe(pcm, language: nil, token: "fixture-token", progress: { _, _, _, _ in })
        XCTAssertEqual(result["text"], "ok")
        let delays = await recorder.delays
        XCTAssertEqual(delays, [15])
        let expired = NativeWisprASR(transport: { _ in NativeASRResponse(status: 401, body: Data()) }, sleep: { _ in })
        do { _ = try await expired.transcribe(pcm, language: nil, token: "fixture", progress: { _, _, _, _ in }); XCTFail("Expired session succeeded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 401")) }
    }
    func testPermanentFailuresPreserveGapWithoutInventingText() async throws {
        let asr = NativeWisprASR(transport: { _ in NativeASRResponse(status: 400, body: Data()) }, sleep: { _ in })
        let result = try await asr.transcribe(NativeAudioPCM(data: Data(repeating: 0, count: 16000 * 2)), language: nil, token: "fixture", progress: { _, _, _, _ in })
        XCTAssertEqual(result["text"], "")
        XCTAssertEqual(result["gaps"].array, [0])
        XCTAssertEqual(result["totalSec"], 1)
    }
}

private actor TranscriptionFixtureRecorder {
    var requests: [URLRequest] = []
    var delays: [Double] = []
    @discardableResult func record(_ request: URLRequest) -> Int { requests.append(request); return requests.count }
    func delay(_ seconds: Double) { delays.append(seconds) }
}
