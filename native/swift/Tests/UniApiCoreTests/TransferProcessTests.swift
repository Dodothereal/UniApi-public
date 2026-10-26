import XCTest
import Darwin
@testable import UniApiCore

final class TransferProcessTests: XCTestCase {
    private func argumentBytes(image: String = "/fixture/node", argv: [String], environment: [String] = ["RETIREMENT_SECRET=fixture-private"], count: Int32? = nil) -> Data {
        var count = count ?? Int32(argv.count)
        var result = withUnsafeBytes(of: &count) { Data($0) }
        result.append(Data(image.utf8)); result.append(contentsOf: [0, 0, 0])
        for value in argv + environment { result.append(Data(value.utf8)); result.append(0) }
        return result
    }
    func testArgumentDecoderReturnsExactlyArgcAndNeverEnvironmentTail() throws {
        let args = ["/fixture/node", "", "--import=file:///fixture/loader.mjs", "/fixture/main.ts"]
        let decoded = try NativeTransferProcessSystem.decodeArguments(argumentBytes(argv: args))
        XCTAssertEqual(decoded, args)
        XCTAssertFalse(decoded.joined().contains("RETIREMENT_SECRET"))
        XCTAssertEqual(try NativeTransferProcessSystem.decodeArguments(argumentBytes(argv: ["node"])), ["node"])
    }
    func testEmptyArgvZeroOrInflatedCountCannotShiftIntoEnvironment() throws {
        for args in [[""], ["", "/fixture/main.ts"], ["", "/fixture/node"]] {
            XCTAssertThrowsError(try NativeTransferProcessSystem.decodeArguments(argumentBytes(argv: args)))
        }
        for tail in ["SECRET=fixture-private", "name.with.dot=fixture-private", "1NAME=fixture-private"] {
            XCTAssertThrowsError(try NativeTransferProcessSystem.decodeArguments(argumentBytes(argv: ["/fixture/node"], environment: [tail], count: 2)))
        }
        XCTAssertThrowsError(try NativeTransferProcessSystem.decodeArguments(Data([0, 1, 2])))
        var truncated = argumentBytes(argv: ["/fixture/node", "last"], environment: [])
        truncated.removeLast()
        XCTAssertThrowsError(try NativeTransferProcessSystem.decodeArguments(truncated))
    }
    func testOwnFixtureIdentityAndChildCensusNeverReadOrSignalAnApp() async throws {
        let current = try NativeTransferProcessSystem.identity(getpid())
        XCTAssertEqual(current.uid, getuid())
        XCTAssertTrue(NativeTransferProcessSystem.sameProcess(current))
        XCTAssertFalse(current.arguments.isEmpty)
        XCTAssertEqual(try NativeTransferProcessSystem.directory(current).resolvingSymlinksInPath().path,
                       URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path)
        let process = NativeProcess()
        let child = try process.open(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "read value"])
        defer { child.cancel() }
        let identity = try NativeTransferProcessSystem.identity(child.pid)
        XCTAssertEqual(identity.parent, getpid())
        XCTAssertTrue(try NativeTransferProcessSystem.children(getpid()).contains(child.pid))
        var changed = current
        changed = .init(pid: current.pid, parent: current.parent, uid: current.uid, bornSeconds: current.bornSeconds + 1, bornMicroseconds: current.bornMicroseconds, executable: current.executable, arguments: current.arguments)
        XCTAssertFalse(NativeTransferProcessSystem.sameProcess(changed))
        child.cancel()
        do { _ = try await child.wait() } catch is CancellationError {}
    }
    func testPrivateSocketCensusIncludesPendingAndClosingConnections() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
        XCTAssertEqual(listen(listener, 2), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        XCTAssertEqual(withUnsafeMutablePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) } }, 0)
        let port = UInt16(bigEndian: address.sin_port)
        XCTAssertTrue(try NativeTransferProcessSystem.sockets(getpid()).listeningPorts.contains(port))
        let client = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { close(client) }
        XCTAssertEqual(withUnsafePointer(to: &address) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }, 0)
        let pending = try NativeTransferProcessSystem.sockets(getpid())
        XCTAssertGreaterThanOrEqual(pending.pendingAccepts, 1)
        XCTAssertGreaterThanOrEqual(pending.activeTCP, 1)
        let peer = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(peer, 0)
        defer { close(peer) }
        XCTAssertEqual(shutdown(client, SHUT_WR), 0)
        let closing = try NativeTransferProcessSystem.sockets(getpid())
        XCTAssertGreaterThanOrEqual(closing.activeTCP, 2)
    }
}
