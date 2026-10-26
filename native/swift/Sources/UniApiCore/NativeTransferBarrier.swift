import Foundation

public struct NativeTransferWork: Sendable {
    public var jobs = 0, code = 0, unknownChildren = 0, temporaryFanOwner = false
    public var isIdle: Bool { jobs == 0 && code == 0 && unknownChildren == 0 && !temporaryFanOwner }
    public init(jobs: Int = 0, code: Int = 0, unknownChildren: Int = 0, temporaryFanOwner: Bool = false) {
        self.jobs = jobs; self.code = code; self.unknownChildren = unknownChildren; self.temporaryFanOwner = temporaryFanOwner
    }
}

struct NativeTransferBarrierIO: Sendable {
    var sameProcess: @Sendable (NativeTransferIdentity) throws -> Bool
    var stopped: @Sendable (NativeTransferIdentity) throws -> Bool
    var freeze: @Sendable (NativeTransferIdentity) throws -> Void
    var resume: @Sendable (NativeTransferIdentity) throws -> Void
    var sockets: @Sendable (NativeTransferIdentity) throws -> NativeTransferSockets
    var work: @Sendable () throws -> NativeTransferWork
    /// Removes the managed jobs while their verified processes cannot admit
    /// work. A production adapter must await exact owned process retirement.
    var retire: @Sendable ([NativeTransferIdentity]) async throws -> Void
    var rollbackRetirement: @Sendable () async throws -> Void
    var clock: @Sendable () -> Double
}

/// An idle HTTP check is advisory. The retirement decision is made after all
/// verified service processes have stopped admitting work, then rechecked
/// immediately before retirement. Every refusal resumes the same identities.
enum NativeTransferBarrier {
    static func retire(_ processes: [NativeTransferIdentity], owner: UInt32, io: NativeTransferBarrierIO, deadline: Double = 2) async throws {
        guard !processes.isEmpty, owner > 0, deadline > 0, deadline <= 5,
              Set(processes.map(\.pid)).count == processes.count,
              processes.allSatisfy({ $0.pid > 1 && $0.uid == owner }) else { throw NativeFailure("Invalid verified service set") }
        let started = io.clock()
        guard started.isFinite, deadline.isFinite else { throw NativeFailure("Invalid retirement clock") }
        var frozen: [NativeTransferIdentity] = []
        do {
            guard try io.work().isIdle else { throw NativeFailure("Existing app work is active; retirement refused") }
            for process in processes {
                try time(io: io, started: started, deadline: deadline)
                try Task.checkCancellation()
                guard try io.sameProcess(process), try !io.stopped(process) else { throw NativeFailure("Service identity changed or it was already stopped") }
                // Register rollback ownership before a fallible adapter call:
                // a stop that succeeded just before an error must be resumed.
                frozen.append(process)
                do { try io.freeze(process) }
                catch let failure as NativeTransferFreezeFailure { if !failure.applied { frozen.removeLast() }; throw failure }
                guard try io.sameProcess(process), try io.stopped(process) else { throw NativeFailure("Service admission pause was not confirmed") }
                try time(io: io, started: started, deadline: deadline)
            }
            try check(processes, io: io, started: started, deadline: deadline)
            try check(processes, io: io, started: started, deadline: deadline)
            try await io.retire(processes)
            // The adapter owns a separate bounded retirement/rollback phase.
            // Success still requires exact old instances to be gone.
            for process in processes { guard try !io.sameProcess(process) else { throw NativeFailure("Legacy retirement left a live owned process") } }
        } catch {
            var resumeFailures = 0
            // Caller cancellation must not skip restoration of registrations
            // already removed by the retirement callback.
            do { try await Task.detached { try await io.rollbackRetirement() }.value }
            catch { resumeFailures += 1 }
            for process in frozen.reversed() {
                do { if try io.sameProcess(process) { try io.resume(process) } }
                catch { resumeFailures += 1 }
            }
            if resumeFailures > 0 { throw NativeTransferCleanupFailure(message: error.localizedDescription + "; service recovery or resume is unconfirmed") }
            throw error
        }
    }
    private static func check(_ processes: [NativeTransferIdentity], io: NativeTransferBarrierIO, started: Double, deadline: Double) throws {
        try Task.checkCancellation()
        try time(io: io, started: started, deadline: deadline)
        guard try io.work().isIdle else { throw NativeFailure("Work arrived or service ownership is unknown; retirement refused") }
        for process in processes {
            guard try io.sameProcess(process), try io.stopped(process), try io.sockets(process).isIdle else { throw NativeFailure("A service has traffic or changed identity; retirement refused") }
            try time(io: io, started: started, deadline: deadline)
        }
    }
    private static func time(io: NativeTransferBarrierIO, started: Double, deadline: Double) throws {
        let elapsed = io.clock() - started
        guard elapsed.isFinite, elapsed >= 0, elapsed <= deadline else { throw NativeFailure("Service retirement deadline changed") }
    }
}

public struct NativeTransferFreezeFailure: Error, LocalizedError, Sendable {
    public let applied: Bool
    public let message: String
    public var errorDescription: String? { message }
    public init(applied: Bool, message: String) { self.applied = applied; self.message = message }
}

struct NativeTransferCleanupFailure: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
