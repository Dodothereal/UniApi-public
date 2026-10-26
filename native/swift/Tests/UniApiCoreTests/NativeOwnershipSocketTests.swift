import XCTest
import Foundation
import Darwin
@testable import UniApiCore

final class NativeOwnershipSocketTests: XCTestCase {
    func testNonReuseClaimRejectsIPv4ExactAndWildcardBoundOrListeningWithEitherReusePolicy() throws {
        for wildcard in [false, true] {
            for reuse in OwnershipSocketReuse.allCases {
                for listening in [false, true] {
                    let owner = try OwnershipRawSocket(ipv6: false, reuse: reuse)
                    let port = try owner.bindIPv4(wildcard: wildcard)
                    if listening { try owner.listen() }
                    assertBusy(port, context: "IPv4 wildcard \(wildcard), reuse \(reuse), listening \(listening)")
                    XCTAssertEqual(try owner.portIPv4(), port)
                    withExtendedLifetime(owner) {}
                }
            }
        }
    }
    func testNonReuseClaimRejectsDualStackExactAndWildcardBoundOrListeningWithEitherReusePolicy() throws {
        for wildcard in [false, true] {
            for reuse in OwnershipSocketReuse.allCases {
                for listening in [false, true] {
                    let owner = try OwnershipRawSocket(ipv6: true, reuse: reuse)
                    let port = try owner.bindIPv6(wildcard: wildcard)
                    if listening { try owner.listen() }
                    assertBusy(port, context: "dual-stack wildcard \(wildcard), reuse \(reuse), listening \(listening)")
                    XCTAssertEqual(try owner.portIPv6(), port)
                    withExtendedLifetime(owner) {}
                }
            }
        }
    }
    func testClosedOwnTCPFINRetainsTypedUnavailablePortAndErrno() throws {
        for reuse in OwnershipSocketReuse.allCases {
            let listener = try OwnershipRawSocket(ipv6: false, reuse: reuse)
            let port = try listener.bindIPv4(wildcard: false); try listener.listen()
            let client = try OwnershipRawSocket(ipv6: false, reuse: .none)
            let context = "owner reuse \(reuse.rawValue)"
            let setupDeadline = ProcessInfo.processInfo.systemUptime + 2
            try client.connectIPv4(port: port, deadline: setupDeadline, context: context)
            let peer = try listener.acceptReady(deadline: setupDeadline, context: context)
            // Server actively closes first. Both EOFs complete the FIN exchange;
            // all owned descriptors close before testing the retained TCP state.
            XCTAssertEqual(Darwin.shutdown(peer.fd, Int32(SHUT_WR)), 0)
            var byte: UInt8 = 0
            XCTAssertEqual(Darwin.recv(client.fd, &byte, 1, 0), 0)
            XCTAssertEqual(Darwin.shutdown(client.fd, Int32(SHUT_WR)), 0)
            XCTAssertEqual(Darwin.recv(peer.fd, &byte, 1, 0), 0)
            client.close(); peer.close(); listener.close()
            XCTAssertEqual(client.fd, -1); XCTAssertEqual(peer.fd, -1); XCTAssertEqual(listener.fd, -1)
            assertBusy(port, context: "own complete FIN exchange, owner reuse \(reuse), no retained process descriptor")
        }
    }
    func testRetainedLeaseIsExclusiveAndReleaseAllowsSamePortReclaim() throws {
        var lease: NativeOwnershipLease? = try NativeOwnership.claim(port: 0)
        let port = try XCTUnwrap(lease).port
        XCTAssertGreaterThan(port, 0)
        weak var released = lease
        assertBusy(port, context: "retained production lease")
        XCTAssertNotNil(lease); withExtendedLifetime(lease) {}
        lease = nil
        XCTAssertNil(released)
        let replacement = try NativeOwnership.claim(port: port)
        XCTAssertEqual(replacement.port, port)
        assertBusy(port, context: "replacement production lease")
        withExtendedLifetime(replacement) {}
    }
    private func assertBusy(_ port: UInt16, context: String, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let claim = try NativeOwnership.claim(port: port)
            withExtendedLifetime(claim) { XCTFail("Unsafe successful ownership claim: \(context)", file: file, line: line) }
        } catch let failure as NativeOwnershipBindFailure {
            XCTAssertEqual(failure.port, port, context, file: file, line: line)
            XCTAssertEqual(failure.code, EADDRINUSE, context, file: file, line: line)
            XCTAssertFalse(failure.localizedDescription.contains("existing hub service"), file: file, line: line)
        } catch { XCTFail("Missing typed bind failure for \(context): \(error)", file: file, line: line) }
    }
}

private enum OwnershipSocketReuse: String, CaseIterable { case none, addressOnly, addressAndPort }

/// Disposable loopback TCP endpoints only: no configured service port,
/// launchd, application, process signals or provider operation is involved.
private final class OwnershipRawSocket {
    private(set) var fd: Int32
    init(ipv6: Bool, reuse: OwnershipSocketReuse) throws {
        fd = Darwin.socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NativeFailure("Fixture socket failed: \(errno)") }
        do {
            if reuse != .none { try option(SOL_SOCKET, SO_REUSEADDR, 1) }
            if reuse == .addressAndPort { try option(SOL_SOCKET, SO_REUSEPORT, 1) }
            if ipv6 { try option(Int32(IPPROTO_IPV6), IPV6_V6ONLY, 0) }
            try receiveDeadline()
        } catch { close(); throw error }
    }
    init(accepted: Int32) throws {
        fd = accepted
        do {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else { throw NativeFailure("Fixture accepted socket mode failed: \(errno)") }
            try receiveDeadline()
        } catch { close(); throw error }
    }
    deinit { close() }
    func close() { if fd >= 0 { Darwin.close(fd); fd = -1 } }
    private func option(_ level: Int32, _ name: Int32, _ value: Int32) throws {
        var value = value
        guard setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else { throw NativeFailure("Fixture socket option failed: \(errno)") }
    }
    private func receiveDeadline() throws {
        var deadline = timeval(tv_sec: 2, tv_usec: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size)) == 0 else { throw NativeFailure("Fixture receive deadline failed: \(errno)") }
    }
    func bindIPv4(wildcard: Bool) throws -> UInt16 {
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr(wildcard ? "0.0.0.0" : "127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { throw NativeFailure("Fixture IPv4 bind failed: \(errno)") }
        return try portIPv4()
    }
    func bindIPv6(wildcard: Bool) throws -> UInt16 {
        var address = sockaddr_in6(); address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        guard inet_pton(AF_INET6, wildcard ? "::" : "::ffff:127.0.0.1", &address.sin6_addr) == 1 else { throw NativeFailure("Fixture IPv6 address failed") }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        guard result == 0 else { throw NativeFailure("Fixture IPv6 bind failed: \(errno)") }
        return try portIPv6()
    }
    func portIPv4() throws -> UInt16 {
        var address = sockaddr_in(), size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard result == 0 else { throw NativeFailure("Fixture IPv4 name failed: \(errno)") }
        return UInt16(bigEndian: address.sin_port)
    }
    func portIPv6() throws -> UInt16 {
        var address = sockaddr_in6(), size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard result == 0 else { throw NativeFailure("Fixture IPv6 name failed: \(errno)") }
        return UInt16(bigEndian: address.sin6_port)
    }
    func listen() throws {
        guard Darwin.listen(fd, 1) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw NativeFailure("Fixture listen failed: \(errno)") }
    }
    func connectIPv4(port: UInt16, deadline: Double, context: String) throws {
        _ = try remaining(until: deadline, context: context, stage: "connect setup")
        try nonblocking(true, context: context, stage: "connect mode")
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result != 0 {
            let code = errno
            guard code == EINPROGRESS || code == EALREADY || code == EINTR else {
                throw NativeFailure("Fixture connect failed (\(context)): errno \(code)")
            }
            try waitReady(events: Int16(POLLOUT), deadline: deadline, context: context, stage: "connect readiness")
            var socketError: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else {
                throw NativeFailure("Fixture connect SO_ERROR query failed (\(context)): errno \(errno)")
            }
            guard socketError == 0 else { throw NativeFailure("Fixture connect completion failed (\(context)): errno \(socketError)") }
        }
        _ = try remaining(until: deadline, context: context, stage: "connect completion")
        try nonblocking(false, context: context, stage: "connected socket mode")
    }
    func acceptReady(deadline: Double, context: String) throws -> OwnershipRawSocket {
        try nonblocking(true, context: context, stage: "accept mode")
        while true {
            _ = try remaining(until: deadline, context: context, stage: "accept")
            let accepted = Darwin.accept(fd, nil, nil)
            if accepted >= 0 {
                // Take ownership before any setup/deadline check can throw.
                let peer: OwnershipRawSocket
                do { peer = try OwnershipRawSocket(accepted: accepted) }
                catch { throw NativeFailure("Fixture accepted socket setup failed (\(context)): \(error)") }
                _ = try remaining(until: deadline, context: context, stage: "accept completion")
                return peer
            }
            let code = errno
            if code == EINTR { continue }
            guard code == EAGAIN || code == EWOULDBLOCK else {
                throw NativeFailure("Fixture accept failed (\(context)): errno \(code)")
            }
            try waitReady(events: Int16(POLLIN), deadline: deadline, context: context, stage: "accept readiness")
        }
    }
    private func nonblocking(_ enabled: Bool, context: String, stage: String) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, enabled ? flags | O_NONBLOCK : flags & ~O_NONBLOCK) == 0 else {
            throw NativeFailure("Fixture \(stage) failed (\(context)): errno \(errno)")
        }
    }
    private func remaining(until deadline: Double, context: String, stage: String) throws -> Double {
        let value = deadline - ProcessInfo.processInfo.systemUptime
        guard value > 0 else { throw NativeFailure("Fixture \(stage) deadline expired (\(context))") }
        return value
    }
    private func waitReady(events: Int16, deadline: Double, context: String, stage: String) throws {
        while true {
            let time = try remaining(until: deadline, context: context, stage: stage)
            let milliseconds = Int32(min(20, (time * 1_000).rounded(.up)))
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, milliseconds)
            let code = errno
            _ = try remaining(until: deadline, context: context, stage: stage)
            if result < 0 {
                if code == EINTR { continue }
                throw NativeFailure("Fixture \(stage) poll failed (\(context)): errno \(code)")
            }
            guard descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
                throw NativeFailure("Fixture \(stage) poll terminal events (\(context)): revents \(descriptor.revents)")
            }
            if result > 0, descriptor.revents & events != 0 { return }
        }
    }
}
