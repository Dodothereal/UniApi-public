import XCTest
@testable import UniApiCore

final class TransferBarrierTests: XCTestCase {
    func testWorkArrivingAfterAdvisoryCheckResumesEveryServiceWithoutRetirement() async throws {
        let fixture = TransferBarrierFixture()
        fixture.onFreeze = { fixture.pending = .init(jobs: 1) }
        do { try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: fixture.io); XCTFail("Late work was stopped") } catch {}
        XCTAssertEqual(fixture.retireCalls, 0)
        XCTAssertEqual(fixture.resumed, [222, 111])
    }
    func testIndependentShimTrafficAndPendingAcceptsPreventRetirement() async throws {
        for traffic in [NativeTransferSockets(activeTCP: 1), NativeTransferSockets(pendingAccepts: 1)] {
            let fixture = TransferBarrierFixture()
            fixture.shim = traffic
            do { try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: fixture.io); XCTFail("Shim traffic was interrupted") } catch {}
            XCTAssertEqual(fixture.retireCalls, 0)
            XCTAssertEqual(fixture.resumed.count, 2)
        }
    }
    func testUnknownChildrenAndTemporaryHardwareOwnerNeverProceed() async throws {
        for work in [NativeTransferWork(unknownChildren: 1), NativeTransferWork(temporaryFanOwner: true)] {
            let fixture = TransferBarrierFixture(); fixture.pending = work
            do { try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: fixture.io); XCTFail("Unknown work was stopped") } catch {}
            XCTAssertTrue(fixture.frozen.isEmpty); XCTAssertEqual(fixture.retireCalls, 0)
        }
    }
    func testChangedPIDIdentityIsNeverSignaledOnRollback() async throws {
        let fixture = TransferBarrierFixture()
        fixture.onFreeze = { fixture.replaced.insert(111) }
        do { try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: fixture.io); XCTFail("Reused PID accepted") } catch {}
        XCTAssertFalse(fixture.resumed.contains(111)); XCTAssertEqual(fixture.retireCalls, 0)
    }
    func testDeadlineAndPartialFreezeFailureCleanUpOwnedServices() async throws {
        for timeout in [true, false] {
            let fixture = TransferBarrierFixture()
            fixture.onFreeze = { if timeout { fixture.time = 3 } }
            fixture.failFreeze = !timeout
            do { try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: fixture.io); XCTFail("Uncertain freeze accepted") } catch {}
            XCTAssertTrue(fixture.resumed.contains(111)); XCTAssertEqual(fixture.retireCalls, 0)
        }
    }
    func testIdleVerifiedSetRetiresExactlyOnce() async throws {
        let fixture = TransferBarrierFixture()
        try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: fixture.io)
        XCTAssertEqual(fixture.retireCalls, 1)
        XCTAssertEqual(fixture.frozen, [111, 222]); XCTAssertTrue(fixture.resumed.isEmpty)
    }
    func testAlreadyStoppedControlTargetIsNeverResumed() async throws {
        let fixture = TransferBarrierFixture(); fixture.preStopped = [111]
        do { try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: fixture.io); XCTFail("Existing stop was claimed") } catch {}
        XCTAssertTrue(fixture.frozen.isEmpty); XCTAssertTrue(fixture.resumed.isEmpty)
    }
    func testSlowSocketReadCannotBypassDeadline() async throws {
        let fixture = TransferBarrierFixture(); var io = fixture.io
        io.sockets = { _ in fixture.time = 3; return .init() }
        do { try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: io); XCTFail("Slow census accepted") } catch {}
        XCTAssertEqual(fixture.retireCalls, 0); XCTAssertEqual(fixture.resumed, [222, 111])
    }
    func testUnappliedFreezeErrorDoesNotResumeAnUnownedStop() async throws {
        let fixture = TransferBarrierFixture(); var io = fixture.io
        io.freeze = { _ in throw NativeTransferFreezeFailure(applied: false, message: "Already stopped before signal") }
        do { try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: io); XCTFail("Freeze error accepted") } catch {}
        XCTAssertTrue(fixture.resumed.isEmpty)
    }
    func testCancelledRetirementStillRunsRegistrationRecovery() async throws {
        let fixture = TransferBarrierFixture(); var io = fixture.io
        io.retire = { _ in throw CancellationError() }
        io.rollbackRetirement = { XCTAssertFalse(Task.isCancelled) }
        do { try await NativeTransferBarrier.retire(fixture.processes, owner: 503, io: io); XCTFail("Cancelled retirement accepted") } catch {}
        XCTAssertEqual(fixture.resumed, [222, 111])
    }
}

private final class TransferBarrierFixture: @unchecked Sendable {
    let processes = [111, 222].map { NativeTransferIdentity(pid: Int32($0), parent: 1, uid: 503, bornSeconds: 100, bornMicroseconds: 10, executable: "fixture", arguments: []) }
    var pending = NativeTransferWork(), shim = NativeTransferSockets(), time = 0.0
    var frozen: [Int32] = [], resumed: [Int32] = [], retireCalls = 0, replaced = Set<Int32>(), gone = Set<Int32>(), preStopped = Set<Int32>()
    var onFreeze: (() -> Void)?, failFreeze = false
    var io: NativeTransferBarrierIO {
        .init(sameProcess: { !self.replaced.contains($0.pid) && !self.gone.contains($0.pid) }, stopped: { self.frozen.contains($0.pid) || self.preStopped.contains($0.pid) }, freeze: { process in
            self.frozen.append(process.pid); self.onFreeze?()
            if self.failFreeze { throw NativeFailure("fixture partial stop failure") }
        }, resume: { self.resumed.append($0.pid) }, sockets: { $0.pid == 222 ? self.shim : .init() }, work: { self.pending }, retire: { nodes in self.retireCalls += 1; self.gone.formUnion(nodes.map(\.pid)) }, rollbackRetirement: {}, clock: { self.time })
    }
}
