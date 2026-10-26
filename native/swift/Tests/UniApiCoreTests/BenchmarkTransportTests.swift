import XCTest
@testable import UniApiCore

final class BenchmarkTransportTests: XCTestCase {
    func testSSESplitUTF8ReasoningUsageAndMultilineEvents() throws {
        let one: JSONValue = ["choices": [["delta": ["content": "café"]]]]
        let two: JSONValue = ["choices": [["delta": ["reasoning_content": "reason"]]]]
        let three: JSONValue = ["choices": [["delta": ["content": " end"], "finish_reason": "stop"]], "usage": ["prompt_tokens": 100, "completion_tokens": 20]]
        let bytes = Data(("data: " + String(decoding: try one.encoded(), as: UTF8.self) + "\n\n").utf8)
        let split = try XCTUnwrap(bytes.firstIndex(of: 0xc3)) + 1
        let response = BenchmarkResponse(chunks: [.init(milliseconds: 10, data: Data(bytes.prefix(split))), .init(milliseconds: 100, data: Data(bytes.dropFirst(split))), .init(milliseconds: 200, data: Data(("data: " + String(decoding: try two.encoded(), as: UTF8.self) + "\n").utf8)), .init(milliseconds: 300, data: Data(("data: " + String(decoding: try three.encoded(), as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8))])
        let analysis = BenchmarkAnalysis.analyze(response)
        XCTAssertEqual(analysis.content, "café end"); XCTAssertEqual(analysis.reasoningCharacters, 6); XCTAssertEqual(analysis.first, 100); XCTAssertEqual(analysis.last, 300); XCTAssertEqual(analysis.gaps, [100, 100]); XCTAssertTrue(analysis.done); XCTAssertEqual(analysis.usage["completion_tokens"], 20)
        let multi = BenchmarkResponse(chunks: [.init(milliseconds: 55, data: Data("data: {\"choices\":\ndata: [{\"delta\":{\"content\":\"valid\"}}]}\n\n".utf8))])
        XCTAssertEqual(BenchmarkAnalysis.analyze(multi).content, "valid")
    }
    func testNonstreamAndErrorClassificationAndCaps() {
        let response = BenchmarkResponse(chunks: [.init(milliseconds: 700, data: Data("{\"choices\":[{\"message\":{\"content\":\"reply\"},\"finish_reason\":\"stop\"}],\"usage\":{\"completion_tokens\":2}}".utf8))])
        let analysis = BenchmarkAnalysis.analyze(response); XCTAssertTrue(analysis.nonStream); XCTAssertEqual(analysis.first, 700)
        XCTAssertEqual(BenchmarkMath.error(status: 400, body: "maximum context length exceeded"), "ctx_limit")
        XCTAssertEqual(BenchmarkMath.error(status: 429, body: "limit"), "rate_limited")
        XCTAssertEqual(BenchmarkMath.error(status: 402, body: "Insufficient balance"), "quota")
        XCTAssertEqual(BenchmarkMath.freeOutcome(status: 429, text: "model_requires_purchase locked"), "denied")
        XCTAssertEqual(BenchmarkMath.freeOutcome(status: 429, text: "try later"), "limited")
        XCTAssertEqual(BenchmarkWorker.allowedCap("max_tokens unsupported; maximum 8192", below: 32768), 8192)
        XCTAssertEqual(BenchmarkTier.configurations["quick"]?.units(browser: false, vision: false), 5)
        XCTAssertEqual(BenchmarkTier.configurations["deep"]?.units(browser: true, vision: true), 14)
    }
    func testCurlExecutorKeepsAuthOffArgumentsAndRemovesPrivateFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root))
        let key = "fixture-credential", responseBytes = Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8)
        let transport = BenchmarkCurlTransport(runtime: runtime, executable: root.appendingPathComponent("injected-curl"), executor: { _, arguments, input, directory, output in
            XCTAssertFalse(arguments.joined().contains(key)); XCTAssertFalse(arguments.contains("--location")); XCTAssertEqual(arguments.first, "--disable")
            let config = String(decoding: input, as: UTF8.self)
            XCTAssertTrue(config.contains(key)); XCTAssertTrue(config.contains("noproxy = \"127.0.0.1,localhost,::1\""))
            let body = directory.appendingPathComponent("request.json")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: body.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            try NativeFile.writeAtomic(Data("HTTP/1.1 200 OK\nretry-after: 2\nx-request-id: fixture\nset-cookie: private\n".utf8), to: directory.appendingPathComponent("headers"))
            try output(responseBytes); try output(Data("\n\u{1e}{\"http_code\":200,\"t_dns\":0.01,\"t_total\":1}".utf8))
            return NativeProcessResult(status: 0, stdout: Data(), stderr: Data())
        })
        let result = try await transport.execute(.init(url: URL(string: "https://fixture.invalid/v1/chat/completions")!, headers: ["Authorization": "Bearer " + key], body: Data("{}".utf8)))
        XCTAssertEqual(result.status, 200); XCTAssertEqual(result.timing["t_dns"], 0.01); XCTAssertNil(result.headers["set-cookie"]); XCTAssertTrue(BenchmarkAnalysis.analyze(result).done)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: runtime.paths.tmp, includingPropertiesForKeys: nil).isEmpty)
    }
    func testInjectedCurlCancellationCleansPrivateWorkDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root)), began = expectation(description: "fixture transport began")
        let transport = BenchmarkCurlTransport(runtime: runtime, executable: root.appendingPathComponent("injected-curl"), executor: { _, _, _, _, _ in began.fulfill(); try await Task.sleep(nanoseconds: 30_000_000_000); return NativeProcessResult(status: 0, stdout: Data(), stderr: Data()) })
        let task = Task { try await transport.execute(.init(url: URL(string: "https://fixture.invalid")!)) }
        await fulfillment(of: [began], timeout: 2); task.cancel()
        do { _ = try await task.value; XCTFail("cancelled fixture completed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: runtime.paths.tmp, includingPropertiesForKeys: nil).isEmpty)
    }
    func testLargeResponseCountsRealScalarsWhileRetainingOnlyContentHead() throws {
        let text = String(repeating: "é", count: 4000)
        let event: JSONValue = ["choices": [["delta": ["content": .string(text)]]]]
        let response = BenchmarkResponse(chunks: [.init(milliseconds: 100, data: Data(("data: " + String(decoding: try event.encoded(), as: UTF8.self) + "\n\n").utf8))])
        let analysis = BenchmarkAnalysis.analyze(response)
        XCTAssertEqual(analysis.contentCharacters, 4000); XCTAssertEqual(analysis.content.unicodeScalars.count, 160); XCTAssertEqual(analysis.curve.last?.1, 4000)
    }
    func testOversizedTransportAbortsAndCleansItsOwnedWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root)), drained = expectation(description: "oversized fixture drained")
        let transport = BenchmarkCurlTransport(runtime: runtime, executable: root.appendingPathComponent("injected-curl"), maximumResponseBytes: 256, executor: { _, _, _, _, output in
            defer { drained.fulfill() }
            try output(Data(repeating: 65, count: 200))
            try output(Data(repeating: 65, count: 200))
            XCTFail("Oversized response kept consuming data")
            return .init(status: 0, stdout: Data(), stderr: Data())
        })
        do { _ = try await transport.execute(.init(url: URL(string: "https://fixture.invalid")!)); XCTFail("Oversized transport succeeded") }
        catch { XCTAssertTrue(error.localizedDescription.contains("memory limit")) }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: runtime.paths.tmp.path).isEmpty)
    }
}
