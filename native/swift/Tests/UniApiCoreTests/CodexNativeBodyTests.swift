import XCTest
@testable import UniApiCore

final class CodexNativeBodyTests: XCTestCase {
    private func bytes(_ base64: String) -> Data { Data(base64Encoded: base64)! }
    func testIdentityAndStrictEncodingDoNotChangeRequestBytes() throws {
        let body = Data(" {\n\"input\":\"hello\"} ".utf8)
        XCTAssertEqual(try NativeCodexRequestBody.decode(body, encoding: nil), body)
        XCTAssertEqual(try NativeCodexRequestBody.decode(body, encoding: "identity"), body)
        XCTAssertThrowsError(try NativeCodexRequestBody.decode(body, encoding: "gzip"))
        XCTAssertThrowsError(try NativeCodexRequestBody.decode(body, encoding: nil, limit: body.count - 1))
    }
    func testCompleteConcatenatedAndSkippableFramesDecodeWithoutFiles() throws {
        let first = bytes("KLUv/SAFKQAAeyJhIjo="), second = bytes("KLUv/SACEQAAMX0=")
        let skip = Data([0x50,0x2a,0x4d,0x18,3,0,0,0,1,2,3])
        XCTAssertEqual(try NativeCodexRequestBody.decode(first + skip + second, encoding: "zstd"), Data("{\"a\":1}".utf8))
        XCTAssertEqual(try NativeCodexRequestBody.decode(bytes("KLUv/SACEQAAe30="), encoding: "zstd"), Data("{}".utf8))
    }
    func testTruncationGarbageAndExpansionLimitFailClosed() {
        let compressed = bytes("KLUv/SAiEQEAeyJtb2RlbCI6Im5hdGl2ZSIsImlucHV0IjoiaGVsbG8ifQ==")
        XCTAssertThrowsError(try NativeCodexRequestBody.decode(Data(compressed.dropLast()), encoding: "zstd"))
        XCTAssertThrowsError(try NativeCodexRequestBody.decode(compressed + Data([1]), encoding: "zstd"))
        XCTAssertThrowsError(try NativeCodexRequestBody.decode(Data(), encoding: "zstd"))
        // Its encoded bytes fit, but the combined plain bodies do not.
        let frame = bytes("KLUv/WDoAk0AABBhYQEA4yuABQ==")
        XCTAssertLessThan(frame.count, 64)
        XCTAssertThrowsError(try NativeCodexRequestBody.decode(frame, encoding: "zstd", limit: 64))
    }
    func testTerminatorChunkBoundaryIsNotLineCompletion() {
        var marker = NativeCodexTerminator()
        marker.feed(Data("data: [DONE]".utf8)); XCTAssertFalse(marker.completed)
        marker.feed(Data(" not-a-terminator\n".utf8)); marker.finish(); XCTAssertFalse(marker.completed)
        marker.feed(Data("data: [DO".utf8)); marker.feed(Data("NE]\r\n".utf8)); XCTAssertTrue(marker.completed)
        var final = NativeCodexTerminator(); final.feed(Data("data: [DONE]".utf8)); final.finish(); XCTAssertTrue(final.completed)
        var embedded = NativeCodexTerminator(); embedded.feed(Data("data: {\"text\":\"data: [DONE]\"}\n".utf8)); embedded.finish(); XCTAssertFalse(embedded.completed)
    }
}
