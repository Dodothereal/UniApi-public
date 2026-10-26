import XCTest
import Darwin
@testable import UniApiCore

final class HardwareTransportTests: XCTestCase {
    func testSocketReadsOneValidReplyFromAnIsolatedFixture() async throws {
        let server = try UnixReplyFixture(.reply(Data("{\"ok\":true,\"mode\":\"automatic\",\"message\":\"fixture\"}\n".utf8)))
        defer { server.stop() }
        let value = try await NativeUnixJSON.request(["command": "status"], path: server.path, timeout: 1)
        XCTAssertEqual(value["mode"], "automatic")
        await server.finished()
    }
    func testFinalLineCannotBypassTheResponseByteLimit() async throws {
        let response: JSONValue = ["ok": true, "mode": "automatic", "message": .string(String(repeating: "x", count: 9000))]
        let server = try UnixReplyFixture(.reply(try response.encoded() + Data([10])))
        defer { server.stop() }
        do { _ = try await NativeUnixJSON.request(["command": "status"], path: server.path, timeout: 1); XCTFail("Oversized complete reply admitted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("size limit")) }
        await server.finished()
    }
    func testTrickledReplyCannotExtendTheOverallDeadline() async throws {
        let server = try UnixReplyFixture(.trickle)
        defer { server.stop() }
        let start = ProcessInfo.processInfo.systemUptime
        do { _ = try await NativeUnixJSON.request(["command": "status"], path: server.path, timeout: 0.06); XCTFail("Slow reply escaped the deadline") }
        catch { XCTAssertTrue(error.localizedDescription.contains("deadline")) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        await server.finished()
    }
    func testCancellationClosesOnlyTheOwnedFixtureConnection() async throws {
        let server = try UnixReplyFixture(.stall)
        defer { server.stop() }
        let request = Task { try await NativeUnixJSON.request(["command": "status"], path: server.path, timeout: 20) }
        for _ in 0..<100 { if server.accepted { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(server.accepted)
        let start = ProcessInfo.processInfo.systemUptime
        request.cancel()
        do { _ = try await request.value; XCTFail("Cancelled request completed") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.5)
        await server.finished()
    }
}

private final class UnixReplyFixture: @unchecked Sendable {
    enum Behavior: Sendable { case reply(Data), trickle, stall }
    let path = "/tmp/uniapi-unix-" + UUID().uuidString + ".sock"
    private let descriptor: Int32
    private let lock = NSLock()
    private var isAccepted = false, isStopped = false
    private var task: Task<Void, Never>?
    var accepted: Bool { lock.lock(); defer { lock.unlock() }; return isAccepted }
    init(_ behavior: Behavior) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw NativeFailure("Fixture socket unavailable") }
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(descriptor); throw NativeFailure("Fixture socket bind failed") }
        guard listen(descriptor, 1) == 0 else { close(descriptor); unlink(path); throw NativeFailure("Fixture listener unavailable") }
        task = Task.detached { [self] in
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }; defer { close(client) }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            markAccepted()
            var request = [UInt8](repeating: 0, count: 4096)
            guard read(client, &request, request.count) > 0 else { return }
            switch behavior {
            case .reply(let data):
                data.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let count = Darwin.write(client, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        guard count > 0 else { return }; offset += count
                    }
                }
            case .trickle:
                var byte: UInt8 = 123
                for _ in 0..<100 { guard Darwin.write(client, &byte, 1) == 1 else { return }; Thread.sleep(forTimeInterval: 0.02) }
            case .stall:
                var byte: UInt8 = 0; _ = Darwin.read(client, &byte, 1)
            }
        }
    }
    private func markAccepted() { lock.lock(); isAccepted = true; lock.unlock() }
    func finished() async { await task?.value }
    func stop() { lock.lock(); defer { lock.unlock() }; guard !isStopped else { return }; isStopped = true; shutdown(descriptor, SHUT_RDWR); close(descriptor); unlink(path) }
    deinit { stop() }
}
