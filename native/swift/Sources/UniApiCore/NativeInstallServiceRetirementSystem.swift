import Foundation
import Darwin
import CNativeSystem
import CoreFoundation

/// Native proof adapter for the common retirement transaction. Metadata-only
/// settlement is deliberately separate from full pre-control kernel admission.
final class NativeInstallRetirementSystem: @unchecked Sendable {
    let paths: NativePaths, application: URL, instance: String, d: NativeLegacySystemDependencies
    private let gui: NativeUpdateGUIAdmission.Reader
    private let nativeStatus: @Sendable (Int32, String) throws -> JSONValue
    private let expectedHashes: [String: String]?
    private let lock = NSLock()
    private var leaseFD: Int32 = -1, backendPID: Int32?
    private var issued: [String: NativeLegacyRegistration] = [:], backups: [String: URL] = [:]
    private var absent = Set<String>(), frozen: [Int32: NativeTransferIdentity] = [:]
    private let base = "Library/Application Support/UniApi Native Transfer"
    var domain: String { "gui/\(d.owner)" }
    var role: NativeRetirementRole { .native(application: application, instance: instance) }
    init(paths: NativePaths, application: URL, instance: String, dependencies: NativeLegacySystemDependencies,
         expectedHashes: [String: String]? = nil,
         gui: @escaping NativeUpdateGUIAdmission.Reader = { try NativeUpdateGUIAdmission.read() },
         nativeStatus: (@Sendable (Int32, String) throws -> JSONValue)? = nil) throws {
        guard let nonce = UUID(uuidString: instance), application.isFileURL, application.path.hasPrefix("/"), dependencies.owner > 0,
              Self.path(paths.home) == Self.path(dependencies.home) else { throw NativeFailure("Invalid native update identity") }
        self.paths = paths; self.application = application.standardizedFileURL; self.instance = nonce.uuidString; d = dependencies
        self.expectedHashes = expectedHashes; self.gui = gui
        self.nativeStatus = nativeStatus ?? { _, _ in
            try JSONValue.decode(NativeLegacyProtected.read(anchor: paths.data, relative: "native-status.json", owner: dependencies.owner, maximum: 65536))
        }
    }
    private static func path(_ url: URL) -> String { NativeLegacyRetirementSystem.canonical(url) }
    private func executable(_ label: String) -> URL {
        application.appendingPathComponent(label == NativeLegacyRetirement.labels[0] ? "Contents/MacOS/UniApiNative" : "Contents/Resources/Helpers/uniapi-shim")
    }
    private func arguments(_ label: String) -> [String] { [executable(label).path, label == NativeLegacyRetirement.labels[0] ? "--background" : "--serve"] }
    func makeIO() -> NativeLegacyRetirementIO {
        var io = NativeLegacyRetirementIO(owner: d.owner, exclusive: { try self.exclusive() }, inspect: { try await self.inspect($0) },
            registration: { try await self.registration($0, seconds: $1) }, identity: { try self.identity($0) }, sameInstance: d.same,
            stopped: d.stopped, freeze: { try self.freeze($0) }, resume: { try self.resume($0) }, terminate: { try self.terminate($0) },
            children: d.children, sockets: { try self.sockets($0) }, temporaryFanOwner: d.fanOwner, work: d.work,
            bootout: { try await self.bootout($0, seconds: $1) }, restore: { try await self.restore($0, seconds: $1) },
            ready: { try await self.ready($0, nodes: $1, seconds: $2) }, portsAbsent: {
                if self.lock.withLock({ self.leaseFD >= 0 }) { try self.checkLease() }
                try self.checkDefinitions(); try self.d.absent()
            }, pause: d.pause,
            settlement: { try await self.settlement($0, seconds: $1) }, clock: d.clock)
        io.role = role; io.admission = { try self.guiAdmission() }
        return io
    }
    func exclusive() throws -> NativeLegacyRetirementLease {
        try paths.assertWritable()
        return try lock.withLock {
            guard leaseFD < 0 else { throw NativeFailure("Native update already owns a lease") }
            let parent = try NativeLegacyProtected.directory(anchor: paths.home, relative: base, owner: d.owner, create: true, privateLast: true)
            defer { close(parent) }
            let fd = openat(parent, "transfer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NativeFailure("Native update lock is unavailable") }
            do {
                try NativeLegacyProtected.validateFile(fd, owner: d.owner, maximum: 16, privateFile: true, empty: true)
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NativeFailure("Another transfer owns the service labels") }
            } catch { close(fd); throw error }
            leaseFD = fd
            return NativeLegacyRetirementLease { [self] in
                let held = lock.withLock { let value = leaseFD; leaseFD = -1; return value }
                if held >= 0 { _ = flock(held, LOCK_UN); close(held) }
            }
        }
    }
    func checkLease() throws {
        try lock.withLock {
            guard leaseFD >= 0 else { throw NativeFailure("Native update controls require an exclusive lease") }
            let parent = try NativeLegacyProtected.directory(anchor: paths.home, relative: base, owner: d.owner, privateLast: true)
            defer { close(parent) }
            var held = stat(), current = stat()
            guard fstat(leaseFD, &held) == 0, fstatat(parent, "transfer.lock", &current, AT_SYMLINK_NOFOLLOW) == 0,
                  held.st_dev == current.st_dev, held.st_ino == current.st_ino else { throw NativeFailure("Native update transfer lock changed") }
            try NativeLegacyProtected.validateFile(leaseFD, owner: d.owner, maximum: 16, privateFile: true, empty: true)
        }
    }
    private func checkDefinitions() throws {
        if let expectedHashes {
            guard let selected = try NativeServiceUpdate.selection(paths: paths), selected.instance == instance,
                  selected.hashes == expectedHashes else { throw NativeFailure("Prepared native definitions changed") }
        }
    }
    private func original(_ label: String) throws -> Data {
        try NativeLegacyProtected.read(anchor: paths.home, relative: "Library/LaunchAgents/" + label + ".plist", owner: d.owner, maximum: 1 << 20)
    }
    private struct Loaded { let job: NativeLegacyLoadedJob; let record: NativeLegacyRegistration }
    private static func exitGrace(_ plist: [String: Any]) throws -> Double? {
        guard let raw = plist["ExitTimeOut"] else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"].contains(String(cString: number.objCType)),
              number.doubleValue.isFinite, number.doubleValue > 0, number.doubleValue < 30 else {
            throw NativeFailure("Explicit native ExitTimeOut cannot settle within the shared 30-second retirement budget")
        }
        return number.doubleValue
    }
    private func loaded(_ label: String, seconds: Double) async throws -> Loaded? {
        guard NativeLegacyRetirement.labels.contains(label), seconds.isFinite, seconds > 0 else { throw NativeFailure("Invalid native registration query") }
        let deadline = d.clock() + seconds
        guard deadline.isFinite else { throw NativeFailure("Invalid native registration deadline") }
        let value = try await d.command(["print", domain + "/" + label], seconds)
        guard d.clock() < deadline, value.stdout.count <= 1 << 20, value.stderr.count <= 65536 else { throw NativeFailure("Native registration query exceeded its bound") }
        if value.status != 0 {
            guard NativeLegacyLoadedJob.isAbsent(value, label: label, owner: d.owner) else { throw NativeFailure("Native registration inspection failed") }
            return nil
        }
        let job = try NativeLegacyLoadedJob.parse(value.output, target: domain + "/" + label)
        try checkDefinitions()
        let definition = paths.home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist"), bytes = try original(label)
        if Self.path(job.path) != Self.path(definition) {
            let prefix = Self.path(paths.home.appendingPathComponent(base)) + "/", source = Self.path(job.path)
            guard source.hasPrefix(prefix) else { throw NativeFailure("Native recovery source is unowned") }
            let relative = String(source.dropFirst(prefix.count)), parts = relative.split(separator: "/").map(String.init)
            guard parts.count == 2, UUID(uuidString: parts[0]) != nil, parts[1] == label + ".plist",
                  try NativeLegacyProtected.read(anchor: paths.home, relative: base + "/" + relative, owner: d.owner, maximum: 1 << 20, privateFile: true) == bytes else { throw NativeFailure("Native recovery source bytes differ") }
        }
        guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              plist["Label"] as? String == label, plist["ProgramArguments"] as? [String] == arguments(label),
              plist["KeepAlive"] as? Bool == true, plist["Disabled"] == nil || plist["Disabled"] is Bool,
              plist["Disabled"] as? Bool != true,
              let directory = plist["WorkingDirectory"] as? String, Self.path(URL(fileURLWithPath: directory)) == Self.path(paths.root),
              let env = plist["EnvironmentVariables"] as? [String: String],
              env["UNIAPI_ROOT"].map({ Self.path(URL(fileURLWithPath: $0)) }) == Self.path(paths.root),
              env["UNIAPI_NATIVE_INSTALL_NONCE"].flatMap(UUID.init(uuidString:))?.uuidString == instance,
              job.arguments == arguments(label), Self.path(job.program) == Self.path(executable(label)),
              env.allSatisfy({ job.environment[$0.key] == $0.value }) else { throw NativeFailure("Loaded service is not this native installation") }
        _ = try Self.exitGrace(plist)
        func selected(_ key: String, fallback: URL) throws -> URL {
            guard let actual = job.environment[key] else { return fallback }
            guard !actual.isEmpty, !actual.contains("\0") else { throw NativeFailure("Native installation routing is invalid") }
            return URL(fileURLWithPath: actual, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardizedFileURL
        }
        let home = try selected("UNIAPI_NATIVE_HOME", fallback: d.home)
        let root = try selected("UNIAPI_ROOT", fallback: home.appendingPathComponent("UniApi"))
        guard Self.path(home) == Self.path(paths.home), Self.path(root) == Self.path(paths.root),
              Self.path(try selected("UNIAPI_DATA", fallback: root.appendingPathComponent("data"))) == Self.path(paths.data),
              Self.path(try selected("UNIAPI_PROVIDERS", fallback: root.appendingPathComponent("providers.json"))) == Self.path(paths.providers),
              Self.path(try selected("HOME", fallback: d.home)) == Self.path(paths.home),
              job.environment["UNIAPI_NATIVE_READ_ONLY"] != "1" else { throw NativeFailure("Native installation routing differs") }
        let disabled = try await d.command(["print-disabled", domain], deadline - d.clock())
        guard disabled.status == 0, disabled.stdout.count <= 1 << 20, disabled.stderr.count <= 65536,
              try !NativeLegacyLoadedJob.disabled(disabled.output, label: label), d.clock() < deadline else { throw NativeFailure("Native launch control is disabled or unconfirmed") }
        return Loaded(job: job, record: .init(label: label, pid: job.pid, definitionPath: definition, definition: bytes, arguments: arguments(label), directory: paths.root,
            sourceRoot: paths.root, home: paths.home, data: paths.data, providers: paths.providers, port: label == NativeLegacyRetirement.labels[0] ? 8780 : 8823))
    }
    func registration(_ label: String, seconds: Double) async throws -> NativeLegacyRegistration? {
        let deadline = d.clock() + seconds
        guard let loaded = try await loaded(label, seconds: seconds) else { return nil }
        let record = loaded.record, node = try d.identity(record.pid)
        guard node.uid == d.owner, node.parent == 1, node.bornSeconds > 0, node.bornMicroseconds < 1_000_000,
              node.arguments == arguments(label), Self.path(URL(fileURLWithPath: node.executable)) == Self.path(executable(label)),
              Self.path(try d.directory(node)) == Self.path(paths.root), try d.same(node), d.clock() < deadline else { throw NativeFailure("Native update kernel identity differs") }
        try admitExecutable(executable(label))
        if record.port == 8780 { lock.withLock { backendPID = node.pid } }
        return record
    }
    func settlement(_ record: NativeLegacyRegistration, seconds: Double) async throws -> NativeLegacyUnregisterObservation {
        try checkLease()
        guard lock.withLock({ issued[record.label] }) == record else { throw NativeFailure("Native settlement requires an issued owned request") }
        guard let value = try await loaded(record.label, seconds: seconds) else {
            lock.withLock { _ = absent.insert(record.label) }; return .absent
        }
        guard value.record == record else { throw NativeFailure("Native registration changed while unregister was pending") }
        return .capturedRegistrationStillVisible
    }
    private func admitExecutable(_ file: URL) throws {
        let relative = String(file.deletingLastPathComponent().path.dropFirst(application.path.count + 1))
        let parent = try NativeLegacyProtected.directory(anchor: application.deletingLastPathComponent(), relative: application.lastPathComponent + "/" + relative, owner: d.owner)
        defer { close(parent) }
        let fd = openat(parent, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Native update executable is unavailable") }; defer { close(fd) }
        try NativeLegacyProtected.validateFile(fd, owner: d.owner, maximum: 512 << 20)
    }
    func identity(_ pid: Int32) throws -> NativeTransferIdentity {
        let node = try d.identity(pid)
        if node.arguments == [application.appendingPathComponent("Contents/Resources/Helpers/uniapi-fans").path, "--monitor"] {
            try admitExecutable(application.appendingPathComponent("Contents/Resources/Helpers/uniapi-fans"))
        }
        return node
    }
    func sockets(_ node: NativeTransferIdentity) throws -> NativeTransferSockets {
        guard try d.same(node) else { throw NativeFailure("Native socket owner changed") }
        let value = try d.sockets(node)
        let allowed: Set<UInt16> = node.arguments == arguments(NativeLegacyRetirement.labels[1]) ? [8823] : []
        guard value.listeningPorts.isSubset(of: allowed), try d.same(node) else { throw NativeFailure("Native installation has an unexpected listener") }
        return value
    }
    func guiAdmission() throws {
        let state = lock.withLock { (backendPID, issued[NativeLegacyRetirement.labels[0]] != nil) }
        try NativeUpdateGUIAdmission.check(gui(), application: application, managedPID: state.0, requireManagedMembership: !state.1)
    }
    private func status(_ record: NativeLegacyRegistration) throws -> Bool {
        let value = try nativeStatus(record.pid, instance)
        let node = try d.identity(record.pid)
        guard value["schema"] == 2, value["runtime"] == "swift", value["instance"] == .string(instance),
              value["pid"] == .number(Double(record.pid)), value["error"].isNull, case .bool(let ready) = value["ready"],
              case .number(let updated) = value["updatedAt"], updated.isFinite,
              updated >= Double(node.bornSeconds) * 1000 + Double(node.bornMicroseconds) / 1000,
              role.root(node, service: record), try d.same(node) else { throw NativeFailure("Native background identity or health differs") }
        return ready
    }
    private func shim(_ record: NativeLegacyRegistration, seconds: Double) async throws {
        let value = try await d.health(8823, seconds)
        guard value["ok"] == true, value["service"] == "uniapi-shim", value["runtime"] == "swift", value["instance"] == .string(instance),
              value["pid"] == .number(Double(record.pid)), value["activeRequests"] == 0,
              try d.same(d.identity(record.pid)), try sockets(d.identity(record.pid)).listeningPorts == [8823] else { throw NativeFailure("Native shim idle readiness is unconfirmed") }
    }
    private func inspect(_ seconds: Double) async throws -> NativeTransferCheck {
        let deadline = d.clock() + seconds
        let backend = try await registration(NativeLegacyRetirement.labels[0], seconds: seconds)
        let shimRecord = try await registration(NativeLegacyRetirement.labels[1], seconds: deadline - d.clock())
        try guiAdmission()
        let work = backend == nil ? NativeTransferWork() : try d.work()
        guard work.isIdle else { throw NativeFailure("Native installation owns active or unknown work") }
        if let backend { guard try status(backend) else { throw NativeFailure("Native background is not ready") } }
        if let shimRecord { try await shim(shimRecord, seconds: deadline - d.clock()) }
        let settle = min(deadline, d.clock() + 0.5)
        while let shimRecord, try !sockets(d.identity(shimRecord.pid)).isIdle {
            try Task.checkCancellation()
            guard d.clock() < settle else { throw NativeFailure("Native shim probe transport did not close") }
            try await d.pause(min(0.01, settle - d.clock()))
        }
        guard d.clock() < deadline else { throw NativeFailure("Native update inspection expired") }
        // The backend's 8780 socket is a bound lease, not an HTTP listener.
        // Only the shim listener participates in the common listener proof.
        return .init(legacyPresent: false, activeJobs: work.jobs, activeCode: work.code, legacyWindowRunning: false,
                     shimPresent: shimRecord != nil, activeShim: shimRecord == nil ? nil : 0)
    }
    func freeze(_ node: NativeTransferIdentity) throws {
        do {
            try checkLease(); try guiAdmission(); try checkDefinitions()
            guard try d.same(node), try !d.stopped(node), try identity(node.pid) == node else { throw NativeFailure("Native update changed before pause") }
        } catch { throw NativeTransferFreezeFailure(applied: false, message: error.localizedDescription) }
        lock.withLock { frozen[node.pid] = node }
        try d.signal(node, SIGSTOP)
        let until = d.clock() + 0.4
        do {
            while try !d.stopped(node) { try Task.checkCancellation(); guard d.clock() < until, try d.same(node) else { throw NativeFailure("Native update pause expired") }; usleep(1000) }
        } catch { throw NativeTransferFreezeFailure(applied: true, message: "Native update pause is unconfirmed") }
    }
    private func resume(_ node: NativeTransferIdentity) throws {
        guard lock.withLock({ leaseFD >= 0 && frozen[node.pid] == node }) else { throw NativeFailure("Native resume has no captured pause ownership") }
        let now = try d.identity(node.pid)
        guard NativeLegacyRetirementSystem.sameExecution(now, node) else { throw NativeFailure("Native resume identity changed") }; try d.signal(now, SIGCONT)
    }
    private func terminate(_ node: NativeTransferIdentity) throws {
        try checkLease()
        guard lock.withLock({ frozen[node.pid] == node && issued.values.contains { absent.contains($0.label) && role.belongs(node, service: $0) } }),
              try d.same(node), try d.stopped(node), try NativeLegacyRetirementSystem.sameExecution(d.identity(node.pid), node) else { throw NativeFailure("Native survivor is not an absent registration's exact paused instance") }
        try d.signal(node, SIGKILL)
    }
    private func bootout(_ record: NativeLegacyRegistration, seconds: Double) async throws {
        var didIssue = false
        do {
            try checkLease(); try Task.checkCancellation(); try checkDefinitions(); try guiAdmission()
            let deadline = d.clock() + seconds
            guard seconds.isFinite, seconds > 0, deadline.isFinite,
                  try await registration(record.label, seconds: seconds) == record else { throw NativeFailure("Native registration changed before bootout") }
            let relative = base + "/" + UUID().uuidString
            let fd = try NativeLegacyProtected.directory(anchor: paths.home, relative: relative, owner: d.owner, create: true, privateLast: true)
            defer { close(fd) }
            try NativeLegacyProtected.publish(record.definition, parent: fd, name: record.label + ".plist", owner: d.owner)
            let copy = paths.home.appendingPathComponent(relative + "/" + record.label + ".plist")
            lock.withLock { backups[record.label] = copy }
            let remaining = deadline - d.clock()
            guard remaining.isFinite, remaining > 0 else { throw NativeFailure("Native unregister deadline expired") }
            guard let plist = try PropertyListSerialization.propertyList(from: record.definition, format: nil) as? [String: Any] else { throw NativeFailure("Native unregister definition is invalid") }
            if let grace = try Self.exitGrace(plist) {
                guard grace < remaining else { throw NativeFailure("Remaining native retirement budget cannot cover the explicit exit grace") }
            }
            try Task.checkCancellation()
            didIssue = true
            lock.withLock { issued[record.label] = record }
            let value = try await d.command(["bootout", domain + "/" + record.label], remaining)
            guard value.status == 0, d.clock() < deadline else { throw NativeFailure("Native unregister command failed or expired") }
            try Task.checkCancellation()
        } catch { throw NativeLegacyBootoutFailure(disposition: didIssue ? .mayHaveApplied : .notIssued, message: error.localizedDescription) }
    }
    private func restore(_ record: NativeLegacyRegistration, seconds: Double) async throws {
        try checkLease(); try checkDefinitions()
        let deadline = d.clock() + seconds
        guard try await registration(record.label, seconds: seconds) == nil,
              try original(record.label) == record.definition, let copy = lock.withLock({ backups[record.label] }) else { throw NativeFailure("Native recovery has conflicting definitions or control state") }
        let disabled = try await d.command(["print-disabled", domain], deadline - d.clock())
        guard disabled.status == 0, disabled.stdout.count <= 1 << 20, disabled.stderr.count <= 65536,
              try !NativeLegacyLoadedJob.disabled(disabled.output, label: record.label) else { throw NativeFailure("Native recovery control state is unconfirmed") }
        let relative = String(copy.path.dropFirst(paths.home.appendingPathComponent(base).path.count + 1))
        guard try NativeLegacyProtected.read(anchor: paths.home, relative: base + "/" + relative, owner: d.owner, maximum: 1 << 20, privateFile: true) == record.definition else { throw NativeFailure("Native recovery backup changed") }
        let value = try await d.command(["bootstrap", domain, copy.path], deadline - d.clock())
        guard value.status == 0, d.clock() < deadline else { throw NativeFailure("Native recovery bootstrap failed or expired") }
        while d.clock() < deadline {
            // Bootstrap can precede a PID. Retry bounded startup observations;
            // no error or no-PID result is returned as absence/readiness, and
            // the coordinator still demands a full fresh-birth registration.
            if let current = try? await registration(record.label, seconds: deadline - d.clock()) {
                guard current.definition == record.definition else { throw NativeFailure("Native recovery definition differs") }; return
            }
            try await d.pause(min(0.02, deadline - d.clock()))
        }
        throw NativeFailure("Native recovery startup expired")
    }
    private func ready(_ record: NativeLegacyRegistration, nodes: [NativeTransferIdentity], seconds: Double) async throws -> Bool {
        let deadline = d.clock() + seconds
        while d.clock() < deadline {
            try Task.checkCancellation()
            guard try await registration(record.label, seconds: deadline - d.clock()) == record,
                  try nodes.allSatisfy({ try d.same($0) }) else { throw NativeFailure("Restored native registration changed") }
            let forest = try NativeLegacyRetirement.forest(record, owner: d.owner, io: makeIO())
            if record.port == 8780 {
                if try !status(record) { try await d.pause(min(0.02, deadline - d.clock())); continue }
            } else { try await shim(record, seconds: deadline - d.clock()) }
            if try forest.allSatisfy({ try d.same($0) && NativeLegacyRetirementSystem.sameExecution(d.identity($0.pid), $0) && sockets($0).isIdle }) { return d.clock() < deadline }
            try await d.pause(min(0.02, deadline - d.clock()))
        }
        throw NativeFailure("Restored native readiness expired")
    }
}

/// The native Code service persists paused after its processes close. Legacy
/// readers deliberately retain their narrower whitelist; an unknown state in
/// either schema still cannot establish idle ownership.
final class NativeInstallWorkReader: @unchecked Sendable {
    private let paths: NativePaths, lock = NSLock()
    private var generation: [String] = [], cached: NativeTransferWork?
    init(paths: NativePaths) { self.paths = paths }
    private func stamp() throws -> [String] {
        let parent = try NativeLegacyProtected.directory(anchor: paths.data, relative: "", owner: getuid())
        defer { close(parent) }
        return try ["uniapi.sqlite", "uniapi.sqlite-wal", "uniapi.sqlite-journal"].map { name in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 && errno == ENOENT && name != "uniapi.sqlite" { return "absent" }
            guard fd >= 0 else { throw NativeFailure("Native install work census is unavailable") }; defer { close(fd) }
            try NativeLegacyProtected.validateFile(fd, owner: getuid(), maximum: 16 * 1024 * 1024 * 1024, empty: true)
            var value = stat(); guard fstat(fd, &value) == 0 else { throw NativeFailure("Native install work census metadata is unavailable") }
            return "\(value.st_dev):\(value.st_ino):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)"
        }
    }
    func read() throws -> NativeTransferWork {
        try lock.withLock {
            try Task.checkCancellation()
            let before = try stamp()
            if before == generation, let cached { try Task.checkCancellation(); return cached }
            let snapshot = try SQLiteSnapshotCore(paths.database)
            let db = try NativeDatabase(url: snapshot.database, readOnly: true)
            func count(_ sql: String) throws -> Int {
                let rows = try db.query(sql)
                guard rows.count == 1, case .number(let n) = rows[0]["n"], n.isFinite, n >= 0, n.rounded() == n, n < Double(Int.max) else { throw NativeFailure("Native install census has an invalid count") }
                return Int(n)
            }
            let value = NativeTransferWork(jobs: try count("SELECT COUNT(*) AS n FROM jobs WHERE status IN ('running','queued')"),
                                           code: try count("SELECT COUNT(*) AS n FROM code_threads WHERE status IN ('starting','running','waiting')"))
            guard try count("SELECT COUNT(*) AS n FROM jobs WHERE status IS NULL OR status NOT IN ('queued','running','done','failed','cancelled')") == 0,
                  try count("SELECT COUNT(*) AS n FROM code_threads WHERE status IS NULL OR status NOT IN ('idle','starting','running','waiting','error','paused')") == 0 else { throw NativeFailure("Native install work census contains unknown state") }
            guard try stamp() == before else { throw NativeFailure("Native install work changed during its private census") }
            try Task.checkCancellation(); generation = before; cached = value; return value
        }
    }
}

enum NativeInstallServiceSockets {
    // A NativeOwnership lease is a bound, unlistening IPv4 socket without a
    // peer. Exempt only this shape; CLOSE_WAIT/FIN/SYN and pending accepts stay
    // busy, as do every upstream socket and every CLOSED socket on the shim.
    static func isLease(_ socket: socket_fdinfo, backend: Bool) -> Bool {
        let tcp = socket.psi.soi_proto.pri_tcp, ip = tcp.tcpsi_ini
        return backend && socket.psi.soi_kind == SOCKINFO_TCP && tcp.tcpsi_state == TSI_S_CLOSED && ip.insi_vflag == INI_IPV4 &&
            UInt16(bigEndian: UInt16(truncatingIfNeeded: ip.insi_lport)) == 8780 && ip.insi_fport == 0 &&
            ip.insi_laddr.ina_46.i46a_addr4.s_addr == inet_addr("127.0.0.1") && ip.insi_faddr.ina_46.i46a_addr4.s_addr == 0 &&
            socket.psi.soi_qlen == 0 && socket.psi.soi_incqlen == 0
    }
    static func read(_ node: NativeTransferIdentity, backend: String) throws -> NativeTransferSockets {
        guard try NativeTransferProcessSystem.sameInstance(node) else { throw NativeFailure("Native install socket owner disappeared") }
        let required = proc_pidinfo(node.pid, PROC_PIDLISTFDS, 0, nil, 0), stride = MemoryLayout<proc_fdinfo>.stride
        guard required > 0, required < 8 << 20 else { throw NativeFailure("Native install socket inventory is unavailable") }
        var descriptors = [proc_fdinfo](repeating: .init(), count: Int(required) / stride + 64)
        let copied = proc_pidinfo(node.pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * stride))
        guard copied > 0, Int(copied) < descriptors.count * stride, Int(copied) % stride == 0 else { throw NativeFailure("Native install socket inventory is incomplete") }
        var result = NativeTransferSockets(), leases = 0
        for descriptor in descriptors.prefix(Int(copied) / stride) where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var socket = socket_fdinfo(); let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(node.pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size else { throw NativeFailure("Native install socket changed") }
            guard socket.psi.soi_kind == SOCKINFO_TCP else { continue }
            if isLease(socket, backend: NativeLegacyRetirementSystem.canonical(URL(fileURLWithPath: node.executable)) == NativeLegacyRetirementSystem.canonical(URL(fileURLWithPath: backend))) { leases += 1; continue }
            if socket.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN {
                result.listeningPorts.insert(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)))
                guard socket.psi.soi_qlen >= 0, socket.psi.soi_incqlen >= 0 else { throw NativeFailure("Native install pending accepts are unknown") }
                result.pendingAccepts += Int(socket.psi.soi_qlen) + Int(socket.psi.soi_incqlen)
            } else { result.activeTCP += 1 }
        }
        guard leases <= 1, try NativeTransferProcessSystem.sameInstance(node) else { throw NativeFailure("Native install ownership lease is ambiguous") }; return result
    }
}
