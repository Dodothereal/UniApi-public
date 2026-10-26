import XCTest
import Darwin
@testable import UniApiCore

private struct NativeControlLoopback: ShimTransport {
    let gateway: NativeShimGateway
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        var headers = request.headers; headers["host"] = "127.0.0.1"
        let reply = try await gateway.handle(.init(method: request.method, path: request.url.path, headers: headers, body: request.body ?? Data()))
        return .init(status: reply.status, headers: reply.headers, chunks: reply.chunks, cancel: reply.cancel, waitForCompletion: reply.waitForCompletion)
    }
}
private final class NativeControlFlag: @unchecked Sendable {
    private let lock = NSLock(); private var called = false
    func mark() { lock.withLock { called = true } }
    var value: Bool { lock.withLock { called } }
}
private final class NativeControlClock: @unchecked Sendable {
    private let lock = NSLock(); private var time = 100.0
    var now: Double { lock.withLock { time } }
    func set(_ value: Double) { lock.withLock { time = value } }
}
private final class NativeControlGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false, waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if open { return true }; waiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    func signal() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in open = true; let result = waiters; waiters = []; return result }
        pending.forEach { $0.resume() }
    }
}
private actor NativeControlAcquisitionFault: ShimTransport {
    enum Mode: Sendable { case lostResponse, holdForCancellation }
    enum Failure: Error { case drainResponseLost }
    struct Call: Sendable {
        let operation: String, body: JSONValue, wasCancelled: Bool
    }
    let activity: ShimRequestActivity, mode: Mode
    let acquired = NativeControlGate(), deliver = NativeControlGate()
    private var calls: [Call] = []
    init(activity: ShimRequestActivity, mode: Mode) { self.activity = activity; self.mode = mode }
    func captured() -> [Call] { calls }
    func open(_ request: ShimHTTPRequest) async throws -> ShimUpstream {
        let operation = request.url.lastPathComponent
        calls.append(.init(operation: operation, body: try JSONValue.decode(request.body ?? Data("{}".utf8)), wasCancelled: Task.isCancelled))
        // An inherited cancellation must reject cleanup, making detachment observable.
        try Task.checkCancellation()
        var headers = request.headers; headers["host"] = "127.0.0.1"
        let reply = try activity.control(.init(method: request.method, path: request.url.path, headers: headers, body: request.body ?? Data()), operation: operation)
        if operation == "drain", reply.status == 200 {
            // Apply the real admission change before losing its acknowledgement.
            acquired.signal()
            switch mode {
            case .lostResponse: break
            case .holdForCancellation: await deliver.wait(); try Task.checkCancellation()
            }
            throw Failure.drainResponseLost
        }
        return .init(status: reply.status, headers: reply.headers, chunks: reply.chunks, cancel: reply.cancel, waitForCompletion: reply.waitForCompletion)
    }
}
final class CodexNativeControlTests: XCTestCase {
    private func request(_ operation: String, token: String = "fixture", lease: String? = nil, deadline: Double? = nil) throws -> ShimClientRequest {
        let body: JSONValue = operation == "status" ? [:] : ["lease": .string(lease ?? UUID().uuidString), "deadline": .number(deadline ?? ProcessInfo.processInfo.systemUptime + 5)]
        return .init(method: operation == "status" ? "GET" : "POST", path: "/_uniapi/codex/control/" + operation,
                     headers: ["host": "localhost", "authorization": "Bearer " + token], body: try body.encoded())
    }
    private func body(_ response: ShimClientResponse) async throws -> JSONValue { try JSONValue.decode(await response.body()) }
    private func faultFixture(_ mode: NativeControlAcquisitionFault.Mode) throws -> (root: URL, activity: ShimRequestActivity, transport: NativeControlAcquisitionFault, client: NativeCodexControlClient) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-control-fault-" + UUID().uuidString)
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        let activity = ShimRequestActivity(); activity.configure(token: try NativeCodexControlSecret.load(paths, create: true))
        let transport = NativeControlAcquisitionFault(activity: activity, mode: mode)
        return (root, activity, transport, NativeCodexControlClient(paths: paths, dependencies: .init(transport: transport)))
    }
    private func assertMatchingCleanup(_ calls: [NativeControlAcquisitionFault.Call], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(calls.map(\.operation), ["drain", "resume"], file: file, line: line)
        guard calls.count == 2 else { return }
        XCTAssertEqual(Set(calls[0].body.object.keys), ["lease", "deadline"], file: file, line: line)
        XCTAssertNotNil(UUID(uuidString: calls[0].body["lease"].string), file: file, line: line)
        XCTAssertEqual(calls[1].body, calls[0].body, file: file, line: line)
        XCTAssertFalse(calls[1].wasCancelled, file: file, line: line)
    }
    func testDrainClosesAdmissionUntilMatchingLeaseAndDoesNotHideHeldOwners() async throws {
        let activity = ShimRequestActivity(); activity.configure(token: "fixture")
        let lease = UUID().uuidString, deadline = ProcessInfo.processInfo.systemUptime + 5
        let first = try XCTUnwrap(activity.begin()), producer = first.fork()
        let drained = try await body(activity.control(request("drain", lease: lease, deadline: deadline), operation: "drain"))
        XCTAssertEqual(drained["accepting"], false); XCTAssertEqual(drained["activeRequests"], 1)
        XCTAssertEqual(drained["lease"], .string(lease))
        XCTAssertNil(activity.begin())
        first.finish(); XCTAssertEqual(activity.active, 1)
        let busy = try activity.control(request("drain"), operation: "drain"); XCTAssertEqual(busy.status, 409)
        let wrong = try activity.control(request("resume", lease: UUID().uuidString), operation: "resume"); XCTAssertEqual(wrong.status, 409)
        XCTAssertNil(activity.begin()); producer.finish(); XCTAssertEqual(activity.active, 0)
        let resumed = try await body(activity.control(request("resume", lease: drained["lease"].string, deadline: deadline), operation: "resume"))
        XCTAssertEqual(resumed["accepting"], true); XCTAssertNotNil(activity.begin())
    }
    func testResumeBeforeDelayedAcquireKeepsAdmissionOpen() async throws {
        let activity = ShimRequestActivity(); activity.configure(token: "fixture")
        let lease = UUID().uuidString, deadline = ProcessInfo.processInfo.systemUptime + 5
        let delayed = try request("drain", lease: lease, deadline: deadline)
        let early = try activity.control(request("resume", lease: lease, deadline: deadline), operation: "resume")
        XCTAssertEqual(early.status, 200)
        let released = try await body(early); XCTAssertEqual(released["accepting"], true)
        let admitted = try XCTUnwrap(activity.begin()); defer { admitted.finish() }
        let refused = try activity.control(delayed, operation: "drain"); XCTAssertEqual(refused.status, 409)
        let after = try await body(activity.control(request("status"), operation: "status"))
        XCTAssertEqual(after["accepting"], true); XCTAssertEqual(after["activeRequests"], 1)
        let next = try XCTUnwrap(activity.begin()); next.finish()
        let fresh = UUID().uuidString
        let acquired = try activity.control(request("drain", lease: fresh, deadline: deadline), operation: "drain")
        XCTAssertEqual(acquired.status, 200); XCTAssertNil(activity.begin())
        let resumed = try activity.control(request("resume", lease: fresh, deadline: deadline), operation: "resume")
        XCTAssertEqual(resumed.status, 200)
    }
    func testRetiringAnotherLeaseDuringContentionStillRejectsItsDelayedAcquisition() async throws {
        let activity = ShimRequestActivity(); activity.configure(token: "fixture")
        let a = UUID().uuidString, b = UUID().uuidString, deadline = ProcessInfo.processInfo.systemUptime + 5
        XCTAssertEqual(try activity.control(request("drain", lease: b, deadline: deadline), operation: "drain").status, 200)
        XCTAssertEqual(try activity.control(request("resume", lease: a, deadline: deadline), operation: "resume").status, 409)
        XCTAssertNil(activity.begin())
        XCTAssertEqual(try activity.control(request("resume", lease: b, deadline: deadline), operation: "resume").status, 200)
        XCTAssertEqual(try activity.control(request("drain", lease: a, deadline: deadline), operation: "drain").status, 409)
        let state = try await body(activity.control(request("status"), operation: "status"))
        XCTAssertEqual(state["accepting"], true); XCTAssertEqual(state["activeRequests"], 0)
        let next = try XCTUnwrap(activity.begin()); next.finish()
    }
    func testFullRetirementLedgerCannotReenableAnUnrecordedDelayedAcquisitionAfterPruning() throws {
        let clock = NativeControlClock(), activity = ShimRequestActivity(clock: { clock.now })
        activity.configure(token: "fixture")
        for _ in 0..<4096 {
            XCTAssertEqual(try activity.control(request("resume", lease: UUID().uuidString, deadline: 101), operation: "resume").status, 200)
        }
        let pending = UUID().uuidString
        XCTAssertEqual(try activity.control(request("resume", lease: pending, deadline: 105), operation: "resume").status, 200)
        clock.set(102) // Earlier entries prune before the unrecorded acquire expires.
        XCTAssertEqual(try activity.control(request("drain", lease: pending, deadline: 105), operation: "drain").status, 409)
        XCTAssertNotNil(activity.begin()) // Only configuration acquisition is delayed.
        clock.set(106)
        XCTAssertEqual(try activity.control(request("drain", lease: UUID().uuidString, deadline: 110), operation: "drain").status, 200)
    }
    func testOtherLeaseAndWrongDeadlineCannotReleaseAdmission() async throws {
        let activity = ShimRequestActivity(); activity.configure(token: "fixture")
        let lease = UUID().uuidString, deadline = ProcessInfo.processInfo.systemUptime + 5
        let acquired = try activity.control(request("drain", lease: lease, deadline: deadline), operation: "drain")
        XCTAssertEqual(acquired.status, 200)
        for (otherLease, otherDeadline) in [(UUID().uuidString, deadline), (lease, deadline - 1)] {
            let wrong = try activity.control(request("resume", lease: otherLease, deadline: otherDeadline), operation: "resume")
            XCTAssertEqual(wrong.status, 409); XCTAssertNil(activity.begin())
            let held = try await body(activity.control(request("status"), operation: "status"))
            XCTAssertEqual(held["accepting"], false); XCTAssertEqual(held["activeRequests"], 0)
        }
        let resumed = try await body(activity.control(request("resume", lease: lease, deadline: deadline), operation: "resume"))
        XCTAssertEqual(resumed["accepting"], true)
        let admitted = try XCTUnwrap(activity.begin()); admitted.finish()
    }
    func testExpiredAcquireRefusesWithoutClosingAdmission() async throws {
        let activity = ShimRequestActivity(); activity.configure(token: "fixture")
        let expired = try activity.control(request("drain", lease: UUID().uuidString, deadline: ProcessInfo.processInfo.systemUptime - 1), operation: "drain")
        XCTAssertEqual(expired.status, 409)
        let after = try await body(activity.control(request("status"), operation: "status"))
        XCTAssertEqual(after["accepting"], true); XCTAssertEqual(after["activeRequests"], 0)
        let admitted = try XCTUnwrap(activity.begin()); admitted.finish(); XCTAssertEqual(activity.active, 0)
    }
    func testRepeatedAcquireAndReleaseOfSameLeaseAreIdempotent() async throws {
        let activity = ShimRequestActivity(); activity.configure(token: "fixture")
        let lease = UUID().uuidString, deadline = ProcessInfo.processInfo.systemUptime + 5
        let admitted = try XCTUnwrap(activity.begin()); defer { admitted.finish() }
        for _ in 0..<2 {
            let response = try activity.control(request("drain", lease: lease, deadline: deadline), operation: "drain")
            XCTAssertEqual(response.status, 200)
            let drained = try await body(response)
            XCTAssertEqual(drained["lease"], .string(lease)); XCTAssertEqual(drained["accepting"], false)
            XCTAssertEqual(drained["activeRequests"], 1); XCTAssertNil(activity.begin())
        }
        for _ in 0..<2 {
            let response = try activity.control(request("resume", lease: lease, deadline: deadline), operation: "resume")
            XCTAssertEqual(response.status, 200)
            let resumed = try await body(response)
            XCTAssertEqual(resumed["accepting"], true); XCTAssertEqual(resumed["activeRequests"], 1)
        }
        admitted.finish(); XCTAssertEqual(activity.active, 0)
        let retired = try activity.control(request("drain", lease: lease, deadline: deadline), operation: "drain")
        XCTAssertEqual(retired.status, 409)
        let next = try XCTUnwrap(activity.begin()); next.finish()
    }
    func testControlTokenCannotBeOmittedOrUsedForWrongLease() throws {
        let activity = ShimRequestActivity(); activity.configure(token: "fixture")
        for token in ["", "fixture-foreign", "fixtur"] { XCTAssertEqual(try activity.control(request("drain", token: token), operation: "drain").status, 401) }
        XCTAssertNotNil(activity.begin())
    }
    func testSecretReadIsNonCreatingAndPrivateCapabilityRejectsLinksPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-control-" + UUID().uuidString)
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try NativeCodexControlSecret.load(paths)); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let token = try NativeCodexControlSecret.load(paths, create: true)
        XCTAssertEqual(token.count, 64); XCTAssertEqual(try NativeCodexControlSecret.load(paths), token)
        let file = NativeCodexControlSecret.file(paths)
        XCTAssertEqual(chmod(file.path, 0o644), 0); XCTAssertThrowsError(try NativeCodexControlSecret.load(paths))
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let hard = file.appendingPathExtension("hard")
        XCTAssertEqual(link(file.path, hard.path), 0); XCTAssertThrowsError(try NativeCodexControlSecret.load(paths))
        XCTAssertEqual(unlink(hard.path), 0)
        let moved = file.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: file, to: moved); try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        XCTAssertThrowsError(try NativeCodexControlSecret.load(paths))
    }
    func testRoutingAndControlCapabilitiesAreIndependentPrivateValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-routing-capability-" + UUID().uuidString)
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        defer { try? FileManager.default.removeItem(at: root) }
        let control = try NativeCodexControlSecret.load(paths, create: true)
        XCTAssertThrowsError(try NativeCodexRoutingSecret.load(paths))
        let routing = try NativeCodexRoutingSecret.load(paths, create: true)
        XCTAssertNotEqual(routing, control); XCTAssertTrue(NativeCodexRoutingSecret.valid(routing))
        XCTAssertEqual(try NativeCodexControlSecret.load(paths), control)
        XCTAssertEqual(try NativeCodexRoutingSecret.load(paths), routing)
    }
    func testClientRunsMutationOnlyDuringExclusiveDrainAndResumesOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-control-client-" + UUID().uuidString)
        let paths = NativePaths(root: root, home: root.appendingPathComponent("home"))
        defer { try? FileManager.default.removeItem(at: root) }
        try NativeFile.writeAtomic(try JSONValue.object(["providers": []]).encoded(), to: paths.providers)
        let token = try NativeCodexControlSecret.load(paths, create: true)
        let gateway = NativeShimGateway(providers: NativeProviderStore(paths: paths), paths: paths)
        gateway.configureNativeControl(token: token)
        let client = NativeCodexControlClient(paths: paths, dependencies: .init(transport: NativeControlLoopback(gateway: gateway)))
        let flag = NativeControlFlag()
        do {
            let _: Int = try await client.drained {
                let during = try await client.status(); XCTAssertEqual(during["accepting"], false); XCTAssertEqual(during["activeRequests"], 0)
                let refused = try await gateway.handle(.init(method: "POST", path: "/unknown/v1/responses", headers: ["host": "localhost"]))
                XCTAssertEqual(refused.status, 503); flag.mark(); throw NativeFailure("fixture mutation failure")
            }
            XCTFail("Mutation failure was lost")
        } catch { XCTAssertTrue(error.localizedDescription.contains("fixture mutation failure")) }
        XCTAssertTrue(flag.value)
        let resumed = try await client.status(); XCTAssertEqual(resumed["accepting"], true)
        let held = gateway.beginRequest(.init(method: "POST", path: "/held"))
        let forbidden = NativeControlFlag()
        do { try await client.drained { forbidden.mark() }; XCTFail("Busy mutation admitted") } catch {}
        XCTAssertFalse(forbidden.value); held?.finish()
        let again = try await client.status(); XCTAssertEqual(again["accepting"], true); XCTAssertEqual(again["activeRequests"], 0)
    }
    func testClientLostDrainResponseSkipsMutationAndResumesAdmission() async throws {
        let fixture = try faultFixture(.lostResponse), mutation = NativeControlFlag()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        do {
            try await fixture.client.drained { mutation.mark() }
            XCTFail("Lost acquisition response was accepted")
        } catch { XCTAssertTrue(error is NativeControlAcquisitionFault.Failure) }
        XCTAssertFalse(mutation.value)
        let calls = await fixture.transport.captured(); assertMatchingCleanup(calls)
        let after = try await fixture.client.status()
        XCTAssertEqual(after["accepting"], true); XCTAssertEqual(after["activeRequests"], 0)
        let admitted = try XCTUnwrap(fixture.activity.begin()); admitted.finish()
    }
    func testClientCancellationDuringAcquisitionUsesDetachedCleanup() async throws {
        let fixture = try faultFixture(.holdForCancellation), mutation = NativeControlFlag()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pending = Task {
            defer { fixture.transport.acquired.signal() }
            try await fixture.client.drained { mutation.mark() }
        }
        defer { pending.cancel(); fixture.transport.deliver.signal() }
        await fixture.transport.acquired.wait()
        XCTAssertNil(fixture.activity.begin()); XCTAssertFalse(mutation.value)
        pending.cancel(); fixture.transport.deliver.signal()
        do { try await pending.value; XCTFail("Acquisition cancellation was lost") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(mutation.value)
        let calls = await fixture.transport.captured(); assertMatchingCleanup(calls)
        let after = try await fixture.client.status()
        XCTAssertEqual(after["accepting"], true); XCTAssertEqual(after["activeRequests"], 0)
        let admitted = try XCTUnwrap(fixture.activity.begin()); admitted.finish()
    }
}
