import Foundation
import Darwin
import CryptoKit

/// The production adapter holds an exclusive per-user transfer lock across
/// registration removal and recovery. Releasing it never changes services.
public final class NativeLegacyRetirementLease: @unchecked Sendable {
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?
    public init(release: @escaping @Sendable () -> Void) { self.release = release }
    public func close() {
        lock.lock(); let callback = release; release = nil; lock.unlock()
        callback?()
    }
    deinit { close() }
}

/// Loaded registration evidence must agree with the private launch definition.
/// Raw argv/environment/definition contents never appear in CLI result output.
public struct NativeLegacyRegistration: Equatable, Sendable {
    public let label: String, pid: Int32
    public let definitionPath: URL, definition: Data
    public let arguments: [String], directory: URL, sourceRoot: URL, home: URL, data: URL, providers: URL
    public let port: UInt16
    public var restorable = true
    // Public construction remains strict. Only the production adapter can
    // attach privately constructed OS-selector evidence after kernel checks.
    internal var pythonResolution: NativeLegacyPythonResolution? = nil
    public init(label: String, pid: Int32, definitionPath: URL, definition: Data, arguments: [String], directory: URL, sourceRoot: URL, home: URL,
                data: URL, providers: URL, port: UInt16, restorable: Bool = true) {
        self.label = label; self.pid = pid; self.definitionPath = definitionPath; self.definition = definition; self.arguments = arguments
        self.directory = directory; self.sourceRoot = sourceRoot; self.home = home; self.data = data; self.providers = providers
        self.port = port; self.restorable = restorable
    }
}

/// Only a failure known to precede command issuance may leave the old job as-is.
/// A returned command, cancellation or uncertain command failure can still remove
/// launchd's registration later, even while the original PID is visible.
public enum NativeLegacyBootoutDisposition: Equatable, Sendable { case notIssued, mayHaveApplied }
public struct NativeLegacyBootoutFailure: Error, LocalizedError, Sendable {
    public let disposition: NativeLegacyBootoutDisposition
    public let message: String
    public var errorDescription: String? { message }
    public init(disposition: NativeLegacyBootoutDisposition, message: String) {
        self.disposition = disposition; self.message = message
    }
}

/// A post-request observation, never evidence that the old process is alive.
/// Only explicit label absence permits survivor cleanup or a fresh bootstrap.
public enum NativeLegacyUnregisterObservation: Equatable, Sendable {
    case absent, capturedRegistrationStillVisible
}

/// All controls are explicit. Callbacks must honor remaining seconds and await
/// command closure; no detached bootout/bootstrap may outlive this operation.
public struct NativeLegacyRetirementIO: Sendable {
    var role: NativeRetirementRole = .legacy
    var admission: @Sendable () throws -> Void = {}
    public var owner: UInt32
    /// A protected stable per-user lock must cover both known launch labels,
    /// even when two CLI invocations select different source/storage roots.
    public var exclusive: @Sendable () throws -> NativeLegacyRetirementLease
    public var inspect: @Sendable (Double) async throws -> NativeTransferCheck
    public var registration: @Sendable (String, Double) async throws -> NativeLegacyRegistration?
    public var identity: @Sendable (Int32) throws -> NativeTransferIdentity
    public var sameInstance: @Sendable (NativeTransferIdentity) throws -> Bool
    public var stopped: @Sendable (NativeTransferIdentity) throws -> Bool
    public var freeze: @Sendable (NativeTransferIdentity) throws -> Void
    public var resume: @Sendable (NativeTransferIdentity) throws -> Void
    public var terminate: @Sendable (NativeTransferIdentity) throws -> Void
    public var children: @Sendable (Int32) throws -> [Int32]
    public var sockets: @Sendable (NativeTransferIdentity) throws -> NativeTransferSockets
    public var temporaryFanOwner: @Sendable (Int32) throws -> Bool
    public var work: @Sendable () throws -> NativeTransferWork
    /// Return means accepted/pending, not confirmed absent. Untyped errors are
    /// conservatively mayHaveApplied; only explicit notIssued proves no command.
    public var bootout: @Sendable (NativeLegacyRegistration, Double) async throws -> Void
    /// Restore refuses conflicting loaded jobs, verifies the original hash and
    /// routing, then awaits a new kernel birth with readiness owned by that PID.
    public var restore: @Sendable (NativeLegacyRegistration, Double) async throws -> Void
    public var ready: @Sendable (NativeLegacyRegistration, [NativeTransferIdentity], Double) async throws -> Bool
    public var portsAbsent: @Sendable () throws -> Void
    public var pause: @Sendable (Double) async throws -> Void
    public var clock: @Sendable () -> Double
    public var settlement: (@Sendable (NativeLegacyRegistration, Double) async throws -> NativeLegacyUnregisterObservation)?
    public init(
        owner: UInt32,
        exclusive: @escaping @Sendable () throws -> NativeLegacyRetirementLease,
        inspect: @escaping @Sendable (Double) async throws -> NativeTransferCheck,
        registration: @escaping @Sendable (String, Double) async throws -> NativeLegacyRegistration?,
        identity: @escaping @Sendable (Int32) throws -> NativeTransferIdentity,
        sameInstance: @escaping @Sendable (NativeTransferIdentity) throws -> Bool,
        stopped: @escaping @Sendable (NativeTransferIdentity) throws -> Bool,
        freeze: @escaping @Sendable (NativeTransferIdentity) throws -> Void,
        resume: @escaping @Sendable (NativeTransferIdentity) throws -> Void,
        terminate: @escaping @Sendable (NativeTransferIdentity) throws -> Void,
        children: @escaping @Sendable (Int32) throws -> [Int32],
        sockets: @escaping @Sendable (NativeTransferIdentity) throws -> NativeTransferSockets,
        temporaryFanOwner: @escaping @Sendable (Int32) throws -> Bool,
        work: @escaping @Sendable () throws -> NativeTransferWork,
        bootout: @escaping @Sendable (NativeLegacyRegistration, Double) async throws -> Void,
        restore: @escaping @Sendable (NativeLegacyRegistration, Double) async throws -> Void,
        ready: @escaping @Sendable (NativeLegacyRegistration, [NativeTransferIdentity], Double) async throws -> Bool,
        portsAbsent: @escaping @Sendable () throws -> Void,
        pause: @escaping @Sendable (Double) async throws -> Void,
        settlement: (@Sendable (NativeLegacyRegistration, Double) async throws -> NativeLegacyUnregisterObservation)? = nil,
        clock: @escaping @Sendable () -> Double
    ) {
        self.owner = owner; self.exclusive = exclusive; self.inspect = inspect; self.registration = registration
        self.identity = identity; self.sameInstance = sameInstance; self.stopped = stopped; self.freeze = freeze
        self.resume = resume; self.terminate = terminate; self.children = children; self.sockets = sockets
        self.temporaryFanOwner = temporaryFanOwner; self.work = work; self.bootout = bootout; self.restore = restore
        self.ready = ready; self.portsAbsent = portsAbsent; self.pause = pause; self.clock = clock
        self.settlement = settlement
    }
}

public enum NativeLegacyRetirement {
    static let labels = ["app.devved.uniapi-server", "app.devved.uniapi-shim"]
    private struct Service: Sendable { let registration: NativeLegacyRegistration, nodes: [NativeTransferIdentity] }
    private struct Plan: Sendable { let services: [Service]; var nodes: [NativeTransferIdentity] { services.flatMap(\.nodes) } }
    private struct Attempt: Sendable {
        let service: Service
        var disposition: NativeLegacyBootoutDisposition = .notIssued
    }
    private final class Transaction: @unchecked Sendable {
        private let lock = NSLock()
        private var attempts: [Attempt] = [], removed = Set<String>(), failure = false, recovered = false
        func attempt(_ service: Service) { lock.lock(); attempts.append(Attempt(service: service)); lock.unlock() }
        func disposition(_ label: String, _ value: NativeLegacyBootoutDisposition) {
            lock.lock(); defer { lock.unlock() }
            if let index = attempts.firstIndex(where: { $0.service.registration.label == label }) { attempts[index].disposition = value }
        }
        func failed() { lock.lock(); failure = true; lock.unlock() }
        func restored() { lock.lock(); recovered = true; lock.unlock() }
        func unregistered(_ label: String) { lock.lock(); removed.insert(label); lock.unlock() }
        func isRemoved(_ label: String) -> Bool { lock.lock(); defer { lock.unlock() }; return removed.contains(label) }
        func isIssued(_ label: String) -> Bool { lock.lock(); defer { lock.unlock() }; return attempts.contains { $0.service.registration.label == label && $0.disposition == .mayHaveApplied } }
        func state() -> ([Attempt], Bool, Bool) { lock.lock(); defer { lock.unlock() }; return (attempts, failure, recovered) }
    }
    private struct Budget: Sendable {
        let start: Double, seconds: Double, clock: @Sendable () -> Double
        init(_ seconds: Double, clock: @escaping @Sendable () -> Double) throws {
            let start = clock()
            guard start.isFinite, seconds.isFinite, seconds > 0, seconds <= 30 else { throw NativeFailure("Invalid retirement deadline") }
            self.start = start; self.seconds = seconds; self.clock = clock
        }
        func remaining() throws -> Double {
            let elapsed = clock() - start
            guard elapsed.isFinite, elapsed >= 0, elapsed < seconds else { throw NativeFailure("Legacy retirement deadline expired or clock changed") }
            return seconds - elapsed
        }
    }

    // Production controls require the explicit IO.production factory; page
    // startup and advisory reads never implicitly construct or invoke controls.
    public static func prepare(paths: NativePaths, io: NativeLegacyRetirementIO) async -> JSONValue {
        do {
            let plan = try await capture(paths: paths, io: io)
            let hashes = Dictionary(uniqueKeysWithValues: plan.services.map { ($0.registration.label, JSONValue.string(hash($0.registration.definition))) })
            return ["status": "prepared", "canPrepare": true, "safeToInstall": false,
                    "services": .array(plan.services.map { .string($0.registration.label) }), "definitionHashes": .object(hashes)]
        } catch { return result("refused", message: error.localizedDescription) }
    }

    public static func retire(paths: NativePaths, io: NativeLegacyRetirementIO, freezeDeadline: Double = 2,
                       retirementDeadline: Double = 15, rollbackDeadline: Double = 8, portDeadline: Double = 30) async -> JSONValue {
        let transaction = Transaction()
        do {
            try paths.assertWritable()
            let lease = try io.exclusive()
            defer { lease.close() }
            _ = try Budget(retirementDeadline, clock: io.clock); _ = try Budget(rollbackDeadline, clock: io.clock)
            _ = try Budget(portDeadline, clock: io.clock)
            let plan = try await capture(paths: paths, io: io)
            if plan.services.isEmpty { try io.portsAbsent(); return result("retired") }
            let work: @Sendable () throws -> NativeTransferWork = {
                try io.admission()
                let backendIssued = io.role.isNative && transaction.isIssued(labels[0])
                var value = plan.services.contains { $0.registration.label == labels[0] } && !backendIssued ? try io.work() : NativeTransferWork()
                let known = Set(plan.nodes.map(\.pid))
                for service in plan.services {
                    // A native batch must issue the second target while the
                    // first may already be dying. Its frozen admission proof is
                    // retained until strict label settlement, never reinterpreted
                    // as a fresh kernel/work-census or absence observation.
                    if io.role.isNative && transaction.isIssued(service.registration.label) { continue }
                    for node in service.nodes {
                        if try !io.sameInstance(node) {
                            guard transaction.isRemoved(service.registration.label) else { throw NativeFailure("Service instance disappeared before unregister") }
                            continue
                        }
                        let now = try io.identity(node.pid)
                        guard (now == node || transaction.isRemoved(service.registration.label) && sameExecution(now, node)), belongs(now, service: service.registration, role: io.role) else { throw NativeFailure("Service execution or parent identity changed") }
                        for child in try io.children(node.pid) {
                            if let captured = plan.nodes.first(where: { $0.pid == child }), known.contains(child) {
                                if try !io.sameInstance(captured) { value.unknownChildren += 1 }
                            } else { value.unknownChildren += 1 }
                        }
                        if try io.temporaryFanOwner(node.pid) { value.temporaryFanOwner = true }
                    }
                }
                return value
            }
            let rollback: @Sendable () async throws -> Void = {
                let attempts = transaction.state().0
                guard !attempts.isEmpty else { return }
                let budget = try Budget(rollbackDeadline, clock: io.clock)
                var pending: [Service] = [], firstFailure: Error?
                // Restore known removals before even querying an uncertain later
                // command. A stuck pending job must not consume their recovery budget.
                let ordered = attempts.filter { transaction.isRemoved($0.service.registration.label) }
                    + attempts.filter { !transaction.isRemoved($0.service.registration.label) }
                for attempt in ordered {
                    let service = attempt.service
                    do {
                        if transaction.isRemoved(service.registration.label) {
                            try await recover(service, paths: paths, io: io, budget: budget)
                            transaction.restored(); continue
                        }
                        // An issued request may be exiting between any two
                        // kernel reads. Observe its label before asking for a
                        // fresh process identity; no further control is allowed
                        // until that observation proves explicit absence.
                        if attempt.disposition == .mayHaveApplied {
                            pending.append(service); continue
                        }
                        let current = try await io.registration(service.registration.label, budget.remaining())
                        _ = try budget.remaining()
                        if let current {
                            try confirmOld(current, service: service, io: io)
                        } else {
                            try await recover(service, paths: paths, io: io, budget: budget)
                            transaction.restored()
                        }
                    } catch { if firstFailure == nil { firstFailure = error } }
                }
                for service in pending {
                    do {
                        try await awaitAbsence(service, io: io, budget: budget)
                        try await recover(service, paths: paths, io: io, budget: budget)
                        transaction.restored()
                    } catch { if firstFailure == nil { firstFailure = error } }
                }
                if let firstFailure { transaction.failed(); throw firstFailure }
            }
            let barrier = NativeTransferBarrierIO(sameProcess: io.sameInstance, stopped: io.stopped, freeze: io.freeze, resume: { node in
                    let now = try io.identity(node.pid)
                    guard sameExecution(now, node), let service = plan.services.first(where: { $0.nodes.contains(node) }),
                          belongs(now, service: service.registration, role: io.role) else { throw NativeFailure("Paused service execution changed; resume refused") }
                    try io.resume(node)
                },
                sockets: { node in
                    let sockets = try io.sockets(node)
                    guard let service = plan.services.first(where: { $0.nodes.contains(node) }),
                          sockets.listeningPorts.isSubset(of: allowedPorts(node, service: service.registration, role: io.role)) else { throw NativeFailure("A service owns an unexpected listener") }
                    return sockets
                }, work: work, retire: { nodes in
                    let budget = try Budget(retirementDeadline, clock: io.clock)
                    // Resolve any launcher exception again after every process
                    // is paused, before removing even the first registration.
                    for service in plan.services where service.registration.pythonResolution != nil {
                        guard try await io.registration(service.registration.label, budget.remaining()) == service.registration else { throw NativeFailure("Python launcher selection changed before retirement") }
                    }
                    for service in plan.services {
                        try Task.checkCancellation()
                        guard try await io.registration(service.registration.label, budget.remaining()) == service.registration,
                              try io.sameInstance(service.nodes[0]), try io.stopped(service.nodes[0]), try work().isIdle else { throw NativeFailure("Loaded service changed before retirement") }
                        for node in nodes {
                            if io.role.isNative, let owner = plan.services.first(where: { $0.nodes.contains(node) }), transaction.isIssued(owner.registration.label) { continue }
                            // Earlier bootouts can remove one forest; every
                            // still-live original must remain stopped and idle.
                            if try io.sameInstance(node) { guard try io.stopped(node), try io.sockets(node).isIdle else { throw NativeFailure("Traffic arrived before retirement") } }
                        }
                        let remaining = try budget.remaining()
                        transaction.attempt(service)
                        do {
                            try await io.bootout(service.registration, remaining)
                            // This must precede every post-command await, budget
                            // or cancellation check: launchd may finish later.
                            transaction.disposition(service.registration.label, .mayHaveApplied)
                        } catch {
                            transaction.disposition(service.registration.label,
                                (error as? NativeLegacyBootoutFailure)?.disposition ?? .mayHaveApplied)
                            throw error
                        }
                        if !io.role.isNative {
                            try await awaitAbsence(service, io: io, budget: budget)
                            transaction.unregistered(service.registration.label)
                        }
                    }
                    if io.role.isNative {
                        for service in plan.services {
                            try await awaitAbsence(service, io: io, budget: budget)
                            transaction.unregistered(service.registration.label)
                        }
                    }
                    for service in plan.services { try await removeSurvivors(service.nodes, service: service.registration, io: io, budget: budget) }
                    _ = try budget.remaining()
                    // All service controls are finished. Closed TCP connections
                    // can retain an exclusive port beyond the service budget;
                    // neither address reuse nor a busy-port exception proves
                    // ownership. Both ports must pass the original claim within
                    // one separately bounded, control-free settlement phase.
                    try await awaitPortsAbsent(io: io, budget: Budget(portDeadline, clock: io.clock))
                }, rollbackRetirement: rollback, clock: io.clock)
            try await NativeTransferBarrier.retire(plan.nodes, owner: io.owner, io: barrier, deadline: freezeDeadline)
            return result("retired", services: plan.services.map { $0.registration.label })
        } catch {
            if error is NativeTransferCleanupFailure { transaction.failed() }
            let state = transaction.state()
            return result(state.1 ? "recovery-incomplete" : state.2 ? "rolled-back" : "refused", message: error.localizedDescription,
                          services: state.0.map { $0.service.registration.label })
        }
    }

    private static func result(_ status: String, message: String = "", services: [String] = []) -> JSONValue {
        ["status": .string(status), "canPrepare": false, "safeToInstall": .bool(status == "retired"),
         "services": .array(services.map(JSONValue.string)), "message": .string(message)]
    }
    private static func capture(paths: NativePaths, io: NativeLegacyRetirementIO) async throws -> Plan {
        let budget = try Budget(10, clock: io.clock), advisory = try await io.inspect(budget.remaining())
        guard io.owner > 0, advisory.canPrepare, !advisory.legacyWindowRunning else { throw NativeFailure("Existing work or the legacy window is active; retirement refused") }
        var services: [Service] = [], seen = Set<Int32>()
        for label in labels {
            guard let registration = try await io.registration(label, budget.remaining()) else { continue }
            try validate(registration, paths: paths, role: io.role)
            let root = try io.identity(registration.pid)
            guard root.uid == io.owner, root.parent == 1, root.bornSeconds > 0, root.bornMicroseconds < 1_000_000,
                  label != labels[0] || rootRole(root, service: registration, role: io.role),
                  sameArguments(root, registration: registration), belongs(root, service: registration, role: io.role) else { throw NativeFailure("Loaded service does not match its launch definition") }
            var nodes = [root], offset = 0, ports = Set<UInt16>()
            while offset < nodes.count {
                let node = nodes[offset]; offset += 1
                guard seen.insert(node.pid).inserted, node.pid != getpid(), node.uid == root.uid, nodes.count <= 8,
                      node.bornSeconds > 0, node.bornMicroseconds < 1_000_000,
                      try io.sameInstance(node), try !io.stopped(node), belongs(node, service: registration, role: io.role) else { throw NativeFailure("Service forest contains unknown or already stopped work") }
                let sockets = try io.sockets(node)
                guard sockets.listeningPorts.isSubset(of: allowedPorts(node, service: registration, role: io.role)) else { throw NativeFailure("A service owns an unexpected listener") }
                ports.formUnion(sockets.listeningPorts)
                let children = try io.children(node.pid)
                guard children.isEmpty || !auxiliary(node, service: registration, role: io.role) else { throw NativeFailure("An auxiliary service owns unexpected work") }
                for pid in children {
                    let child = try io.identity(pid)
                    guard child.parent == node.pid, child.uid == root.uid, belongs(child, service: registration, role: io.role),
                          !auxiliary(child, service: registration, role: io.role) || rootRole(node, service: registration, role: io.role) else { throw NativeFailure("A service owns an unknown child") }
                    nodes.append(child)
                }
            }
            if label == labels[0] && advisory.legacyPresent || label == labels[1] && advisory.shimPresent {
                guard ports.contains(registration.port) else { throw NativeFailure("The listener is not owned by its registered service") }
            }
            services.append(.init(registration: registration, nodes: nodes))
        }
        guard !advisory.legacyPresent || services.contains(where: { $0.registration.label == labels[0] }),
              !advisory.shimPresent || services.contains(where: { $0.registration.label == labels[1] }) else { throw NativeFailure("Existing listeners have no verified managed owner") }
        if services.isEmpty { try io.portsAbsent() }
        _ = try budget.remaining()
        return Plan(services: services)
    }
    private static func validate(_ service: NativeLegacyRegistration, paths: NativePaths, role: NativeRetirementRole = .legacy) throws {
        guard labels.contains(service.label), service.pid > 1, !service.definition.isEmpty, service.definition.count <= 1 << 20,
              service.restorable, canonical(service.sourceRoot) == canonical(paths.root),
              canonical(service.home) == canonical(paths.home),
              canonical(service.data) == canonical(paths.data), canonical(service.providers) == canonical(paths.providers),
              service.port == (service.label == labels[0] ? 8780 : 8823) else { throw NativeFailure("Legacy registration, control state or storage does not match this transfer") }
        let plist: [String: Any]?
        do { plist = try PropertyListSerialization.propertyList(from: service.definition, format: nil) as? [String: Any] }
        catch { throw NativeFailure("Legacy launch definition is invalid") }
        guard let plist, plist["Label"] as? String == service.label, plist["Disabled"] as? Bool != true,
              plist["ProgramArguments"] as? [String] == service.arguments,
              plist["WorkingDirectory"] == nil || (plist["WorkingDirectory"] as? String).map({ canonical(URL(fileURLWithPath: $0)) }) == canonical(service.directory) else { throw NativeFailure("Loaded registration and launch definition disagree") }
        guard canonical(service.definitionPath) == canonical(service.home.appendingPathComponent("Library/LaunchAgents/" + service.label + ".plist")) else { throw NativeFailure("Legacy launch definition path is unverified") }
        guard plist["EnvironmentVariables"] == nil || plist["EnvironmentVariables"] is [String: String],
              plist["Disabled"] == nil || plist["Disabled"] is Bool else { throw NativeFailure("Legacy launch definition has unsupported control metadata") }
        if let resolution = service.pythonResolution {
            guard resolution.applies(to: service) else { throw NativeFailure("Python launcher evidence does not match its launch definition") }
        }
        let environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
        func directory(_ value: String) -> URL { URL(fileURLWithPath: value, relativeTo: service.directory).standardizedFileURL }
        let declaredHome = environment["HOME"].map(directory) ?? service.home
        guard canonical(declaredHome) == canonical(service.home) else { throw NativeFailure("Loaded service home differs from its launch definition") }
        if service.label == labels[0] {
            let declaredRoot = environment["UNIAPI_ROOT"].map(directory) ?? service.sourceRoot
            let declaredData = environment["UNIAPI_DATA"].map(directory) ?? declaredRoot.appendingPathComponent("data")
            let declaredProviders = environment["UNIAPI_PROVIDERS"].map(directory) ?? declaredRoot.appendingPathComponent("providers.json")
            guard canonical(declaredRoot) == canonical(service.sourceRoot), canonical(declaredData) == canonical(service.data), canonical(declaredProviders) == canonical(service.providers),
                  environment["UNIAPI_PORT"].map({ $0 == "8780" }) ?? true else { throw NativeFailure("Loaded service routing differs from its launch definition") }
        }
        if case .native(_, let instance) = role {
            guard service.pythonResolution == nil, environment["UNIAPI_NATIVE_INSTALL_NONCE"].flatMap(UUID.init(uuidString:))?.uuidString == instance,
                  environment["UNIAPI_NATIVE_READ_ONLY"] != "1" else { throw NativeFailure("Native registration nonce or writable role differs") }
        } else if service.label == labels[1] {
            let legacy = service.home.appendingPathComponent("UniApi")
            guard canonical(service.data) == canonical(legacy.appendingPathComponent("data")),
                  canonical(service.providers) == canonical(legacy.appendingPathComponent("providers.json")) else { throw NativeFailure("Legacy Python shim ignores data/provider overrides; storage is incompatible") }
        }
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func canonical(_ path: URL) -> String { path.standardizedFileURL.resolvingSymlinksInPath().path }
    private static func argumentPath(_ value: String, service: NativeLegacyRegistration) -> String? {
        if value.hasPrefix("file://") {
            guard let url = URL(string: value), url.isFileURL, url.host == nil || url.host == "", url.query == nil, url.fragment == nil else { return nil }
            return canonical(url)
        }
        guard !value.hasPrefix("-"), !value.isEmpty else { return nil }
        return canonical(URL(fileURLWithPath: value, relativeTo: service.directory))
    }
    private static func sameArguments(_ node: NativeTransferIdentity, registration: NativeLegacyRegistration) -> Bool {
        if let resolution = registration.pythonResolution { return resolution.matches(node, registration: registration) }
        guard node.arguments.count == registration.arguments.count, let first = node.arguments.first, let other = registration.arguments.first else { return false }
        return canonical(URL(fileURLWithPath: first)) == canonical(URL(fileURLWithPath: other)) && node.arguments.dropFirst() == registration.arguments.dropFirst()
    }
    private static func sameExecution(_ a: NativeTransferIdentity, _ b: NativeTransferIdentity) -> Bool {
        a.pid == b.pid && a.uid == b.uid && a.bornSeconds == b.bornSeconds && a.bornMicroseconds == b.bornMicroseconds && a.executable == b.executable && a.arguments == b.arguments
    }
    private static func sameDefinition(_ a: NativeLegacyRegistration, _ b: NativeLegacyRegistration) -> Bool {
        var previous = b
        previous = .init(label: b.label, pid: a.pid, definitionPath: b.definitionPath, definition: b.definition, arguments: b.arguments, directory: b.directory,
                         sourceRoot: b.sourceRoot, home: b.home, data: b.data, providers: b.providers, port: b.port, restorable: b.restorable)
        previous.pythonResolution = b.pythonResolution
        return a == previous
    }
    // Read-only census stays internal so fixtures can exercise restored-root
    // roles directly, independently of rollback's earlier definition checks.
    static func forest(_ registration: NativeLegacyRegistration, owner: UInt32, io: NativeLegacyRetirementIO) throws -> [NativeTransferIdentity] {
        let root = try io.identity(registration.pid)
        guard root.uid == owner, root.parent == 1,
              registration.label != labels[0] || rootRole(root, service: registration, role: io.role),
              sameArguments(root, registration: registration) else { throw NativeFailure("Restored process does not match its registration") }
        var nodes = [root], seen = Set<Int32>(), cursor = 0
        while cursor < nodes.count {
            let node = nodes[cursor]; cursor += 1
            guard nodes.count <= 8, seen.insert(node.pid).inserted, node.uid == owner,
                  node.bornSeconds > 0, node.bornMicroseconds < 1_000_000, belongs(node, service: registration, role: io.role),
                  try io.sameInstance(node), try !io.stopped(node) else { throw NativeFailure("Restored service tree is unverified") }
            let sockets = try io.sockets(node)
            guard sockets.listeningPorts.isSubset(of: allowedPorts(node, service: registration, role: io.role)) else { throw NativeFailure("Restored service owns an unexpected listener") }
            let children = try io.children(node.pid)
            guard children.isEmpty || !auxiliary(node, service: registration, role: io.role) else { throw NativeFailure("Restored auxiliary service owns unexpected work") }
            for pid in children {
                let child = try io.identity(pid)
                guard child.parent == node.pid,
                      !auxiliary(child, service: registration, role: io.role) || rootRole(node, service: registration, role: io.role) else { throw NativeFailure("Restored child parent changed") }
                nodes.append(child)
            }
        }
        return nodes
    }
    static func belongs(_ node: NativeTransferIdentity, service: NativeLegacyRegistration, role: NativeRetirementRole = .legacy) -> Bool {
        if role.isNative { return node.uid > 0 && node.pid > 1 && node.bornSeconds > 0 && node.bornMicroseconds < 1_000_000 && role.belongs(node, service: service) }
        let executable = URL(fileURLWithPath: node.executable).lastPathComponent.lowercased()
        guard node.pid > 1, node.arguments.count >= 2,
              canonical(URL(fileURLWithPath: node.arguments[0], relativeTo: service.directory)) == canonical(URL(fileURLWithPath: node.executable)) else { return false }
        if fanMonitor(node, service: service) || NativeLegacyEsbuild.matches(node, service: service) { return true }
        if service.label == labels[1] {
            guard ["python", "python3", "python3.9", "python3.10", "python3.11", "python3.12", "python3.13", "python3.14"].contains(executable) else { return false }
            let script: String
            if node.arguments.count == 2 { script = node.arguments[1] }
            else if node.arguments.count == 3, node.arguments[1] == "-u" { script = node.arguments[2] }
            else { return false }
            return argumentPath(script, service: service) == canonical(service.sourceRoot.appendingPathComponent("proxy/uniapi_shim.py"))
        }
        return nodeRuntime(node, service: service)
    }
    private static func nodeRuntime(_ node: NativeTransferIdentity, service: NativeLegacyRegistration) -> Bool {
        guard URL(fileURLWithPath: node.executable).lastPathComponent.lowercased() == "node", service.label == labels[0] else { return false }
        let main = canonical(service.sourceRoot.appendingPathComponent("server/src/main.ts")), tsx = service.sourceRoot.appendingPathComponent("server/node_modules/tsx/dist")
        if node.arguments.count == 3 {
            return argumentPath(node.arguments[1], service: service) == canonical(tsx.appendingPathComponent("cli.mjs")) && argumentPath(node.arguments[2], service: service) == main
        }
        guard node.arguments.count == 6, node.arguments[1] == "--require", node.arguments[3] == "--import" else { return false }
        return argumentPath(node.arguments[2], service: service) == canonical(tsx.appendingPathComponent("preflight.cjs")) &&
            argumentPath(node.arguments[4], service: service) == canonical(tsx.appendingPathComponent("loader.mjs")) && argumentPath(node.arguments[5], service: service) == main
    }
    // Once belongs() has admitted a server node, every non-Node role is a
    // read-only leaf. Classifying it does not re-resolve mutable package links.
    private static func rootRole(_ node: NativeTransferIdentity, service: NativeLegacyRegistration, role: NativeRetirementRole) -> Bool {
        role.isNative ? role.root(node, service: service) : nodeRuntime(node, service: service)
    }
    private static func allowedPorts(_ node: NativeTransferIdentity, service: NativeLegacyRegistration, role: NativeRetirementRole) -> Set<UInt16> {
        if role.isNative { return node.pid == service.pid && service.port == 8823 ? [8823] : [] }
        return auxiliary(node, service: service) ? [] : [service.port]
    }
    private static func auxiliary(_ node: NativeTransferIdentity, service: NativeLegacyRegistration, role: NativeRetirementRole = .legacy) -> Bool {
        if role.isNative { return node.pid != service.pid }
        return service.label == labels[0] && !nodeRuntime(node, service: service)
    }
    // The legacy hub always spawns this read-only monitor. Control sessions
    // (--serve), probes and root daemons are outside the transferable forest.
    private static func fanMonitor(_ node: NativeTransferIdentity, service: NativeLegacyRegistration) -> Bool {
        service.label == labels[0] && node.parent > 1 && node.arguments.count == 2 && node.arguments[1] == "--monitor" &&
            canonical(URL(fileURLWithPath: node.executable)) == canonical(service.data.appendingPathComponent("bin/uniapi-fans")) &&
            argumentPath(node.arguments[0], service: service) == canonical(service.data.appendingPathComponent("bin/uniapi-fans"))
    }
    private static func confirmOld(_ current: NativeLegacyRegistration, service: Service, io: NativeLegacyRetirementIO) throws {
        guard current == service.registration, try io.sameInstance(service.nodes[0]),
              try io.identity(service.nodes[0].pid) == service.nodes[0] else {
            throw NativeFailure("A different, starting or unverified service registration appeared; recovery refused")
        }
    }
    private static func awaitPortsAbsent(io: NativeLegacyRetirementIO, budget: Budget) async throws {
        while true {
            try Task.checkCancellation()
            _ = try budget.remaining()
            do { try io.portsAbsent() }
            catch let failure as NativeOwnershipBindFailure where failure.code == EADDRINUSE {
                _ = try budget.remaining()
                try Task.checkCancellation()
                try await io.pause(min(0.02, budget.remaining()))
                continue
            }
            _ = try budget.remaining()
            try Task.checkCancellation()
            return
        }
    }

    private static func awaitAbsence(_ service: Service, io: NativeLegacyRetirementIO, budget: Budget) async throws {
        while true {
            try Task.checkCancellation()
            if let settlement = io.settlement {
                let observation = try await settlement(service.registration, budget.remaining())
                _ = try budget.remaining()
                try Task.checkCancellation()
                if observation == .absent { return }
            } else {
                let current = try await io.registration(service.registration.label, budget.remaining())
                _ = try budget.remaining()
                try Task.checkCancellation()
                guard let current else { return }
                // Legacy injected callers retain their strict liveness checks.
                try confirmOld(current, service: service, io: io)
            }
            try await io.pause(min(0.02, budget.remaining()))
        }
    }
    private static func recover(_ service: Service, paths: NativePaths, io: NativeLegacyRetirementIO, budget: Budget) async throws {
        guard try await io.registration(service.registration.label, budget.remaining()) == nil else {
            throw NativeFailure("Legacy recovery requires confirmed registration absence")
        }
        try await removeSurvivors(service.nodes, service: service.registration, io: io, budget: budget)
        try await io.restore(service.registration, budget.remaining())
        guard let current = try await io.registration(service.registration.label, budget.remaining()), sameDefinition(current, service.registration) else {
            throw NativeFailure("Restored registration definition is unconfirmed")
        }
        try validate(current, paths: paths, role: io.role)
        let restored = try forest(current, owner: io.owner, io: io)
        guard let root = restored.first, root.bornSeconds != service.nodes[0].bornSeconds || root.bornMicroseconds != service.nodes[0].bornMicroseconds,
              try await io.ready(current, restored, budget.remaining()) else {
            throw NativeFailure("Restored service PID readiness is unconfirmed")
        }
        _ = try budget.remaining()
    }
    private static func removeSurvivors(_ nodes: [NativeTransferIdentity], service: NativeLegacyRegistration, io: NativeLegacyRetirementIO, budget: Budget) async throws {
        for node in nodes.reversed() where try io.sameInstance(node) {
            _ = try budget.remaining()
            let now = try io.identity(node.pid)
            guard now.bornSeconds == node.bornSeconds, now.bornMicroseconds == node.bornMicroseconds, now.uid == node.uid,
                  now.executable == node.executable, now.arguments == node.arguments, belongs(now, service: service, role: io.role),
                  try io.stopped(node) else { throw NativeFailure("Survivor is not the exact paused legacy instance") }
            try io.terminate(node)
        }
        while try nodes.contains(where: { try io.sameInstance($0) }) { try await io.pause(min(0.01, budget.remaining())) }
        _ = try budget.remaining()
    }
}
