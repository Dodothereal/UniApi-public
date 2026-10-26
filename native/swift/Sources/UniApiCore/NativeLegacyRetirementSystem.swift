import Foundation
import Darwin
import CNativeSystem

extension NativeLegacyRetirementIO {
    /// Construction observes no services and creates no files. Every control
    /// remains behind the explicit coordinator's writable/exclusive admission.
    public static func production(paths: NativePaths) throws -> Self {
        try NativeLegacyRetirementSystem.make(paths: paths, dependencies: .production(paths: paths))
    }
}

struct NativeLegacySystemDependencies: Sendable {
    let owner: UInt32, home: URL
    var command: @Sendable ([String], Double) async throws -> NativeProcessResult
    var inspect: @Sendable (Double) async throws -> NativeTransferCheck
    var identity: @Sendable (Int32) throws -> NativeTransferIdentity
    var directory: @Sendable (NativeTransferIdentity) throws -> URL
    var same: @Sendable (NativeTransferIdentity) throws -> Bool
    var stopped: @Sendable (NativeTransferIdentity) throws -> Bool
    var children: @Sendable (Int32) throws -> [Int32]
    var sockets: @Sendable (NativeTransferIdentity) throws -> NativeTransferSockets
    var signal: @Sendable (NativeTransferIdentity, Int32) throws -> Void
    var fanOwner: @Sendable (Int32) throws -> Bool
    var work: @Sendable () throws -> NativeTransferWork
    var health: @Sendable (UInt16, Double) async throws -> JSONValue
    var absent: @Sendable () throws -> Void
    var pause: @Sendable (Double) async throws -> Void
    var clock: @Sendable () -> Double
    var resolveSystemPython: (@Sendable (Double) async throws -> NativeLegacyPythonResolution)? = nil

    static func production(paths: NativePaths) throws -> Self {
        guard let account = getpwuid(getuid()), let name = account.pointee.pw_dir else { throw NativeFailure("Cannot establish transfer user home") }
        let home = URL(fileURLWithPath: String(cString: name), isDirectory: true), owner = getuid()
        let work = NativeLegacyWorkReader(paths: paths)
        return .init(owner: owner, home: home, command: { args, seconds in
            guard seconds > 0 else { throw NativeFailure("Transfer command deadline expired") }
            return try await NativeProcess().run(NativePaths.launchctl, arguments: args, environment: ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], timeout: seconds)
        }, inspect: { seconds in
            let deadline = ProcessInfo.processInfo.systemUptime + seconds
            let get: @Sendable (String) async throws -> JSONValue = { path in
                try await NativeLegacyHTTPProbe.get(port: 8780, path: path, timeout: deadline - ProcessInfo.processInfo.systemUptime)
            }
            return try await NativeTransferCheck.inspect(get: get, shimGet: {
                try await NativeLegacyHTTPProbe.get(port: 8823, path: "/healthz", timeout: deadline - ProcessInfo.processInfo.systemUptime)
            })
        }, identity: { try NativeTransferProcessSystem.identity($0) }, directory: { try NativeTransferProcessSystem.directory($0) },
           same: { try NativeTransferProcessSystem.sameInstance($0) }, stopped: { try NativeTransferProcessSystem.stopped($0) },
           children: { try NativeTransferProcessSystem.children($0) }, sockets: { node in
               guard try NativeTransferProcessSystem.sameInstance(node) else { throw NativeFailure("Service disappeared during socket census") }
               let value = try NativeTransferProcessSystem.sockets(node.pid)
               guard try NativeTransferProcessSystem.sameInstance(node) else { throw NativeFailure("Service changed during socket census") }; return value
           }, signal: { node, number in
               let now = try NativeTransferProcessSystem.identity(node.pid)
               guard sameExecution(now, node), number != SIGSTOP || now.parent == node.parent else { throw NativeTransferFreezeFailure(applied: false, message: "Service changed before a control signal") }
               guard kill(node.pid, number) == 0 else { throw NativeTransferFreezeFailure(applied: false, message: "Owned service signal failed") }
           }, fanOwner: { pid in
               var value = stat()
               let path = NativeHardwareLocations(paths: paths).fanSocket(owner: pid)
               if lstat(path, &value) == 0 { return true }
               guard errno == ENOENT else { throw NativeFailure("Cannot establish temporary fan ownership") }; return false
           }, work: { try work.read() }, health: { port, seconds in
               try await NativeLegacyHTTPProbe.get(port: port, path: port == 8823 ? "/healthz" : "/api/health", timeout: seconds)
           }, absent: { try NativeOwnership.assertLegacyServerAbsent(); try NativeOwnership.assertLegacyServerAbsent(port: 8823) },
           pause: { try await Task.sleep(nanoseconds: UInt64(max(0, min($0, 30)) * 1e9)) }, clock: { ProcessInfo.processInfo.systemUptime },
           resolveSystemPython: { seconds in
               try await NativeLegacyPythonResolution.resolve(home: home, seconds: seconds, clock: { ProcessInfo.processInfo.systemUptime }, command: { executable, arguments, environment, timeout in
                   try await NativeProcess().run(executable, arguments: arguments, environment: environment, timeout: timeout)
               })
           })
    }
}

enum NativeLegacyRetirementSystem {
    static func sameExecution(_ a: NativeTransferIdentity, _ b: NativeTransferIdentity) -> Bool {
        a.pid == b.pid && a.uid == b.uid && a.bornSeconds == b.bornSeconds && a.bornMicroseconds == b.bornMicroseconds && a.executable == b.executable && a.arguments == b.arguments
    }
    static func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    static func make(paths: NativePaths, dependencies d: NativeLegacySystemDependencies) throws -> NativeLegacyRetirementIO {
        guard d.owner > 0, canonical(d.home) == canonical(paths.home) else { throw NativeFailure("Transfer home must belong to the selected local account") }
        let context = Context(paths: paths, dependencies: d)
        return .init(owner: d.owner, exclusive: { try context.exclusive() }, inspect: d.inspect,
            registration: { try await context.registration($0, seconds: $1) }, identity: d.identity, sameInstance: d.same, stopped: d.stopped,
            freeze: { node in
                try context.requireLease()
                guard try d.same(node), try !d.stopped(node), try d.identity(node.pid) == node else { throw NativeTransferFreezeFailure(applied: false, message: "Service changed before pause") }
                try d.signal(node, SIGSTOP)
                let until = d.clock() + 0.4
                do {
                    while try !d.stopped(node) {
                        try Task.checkCancellation()
                        guard d.clock() < until, try d.same(node) else { throw NativeFailure("Service pause deadline expired") }
                        usleep(1000)
                    }
                } catch { throw NativeTransferFreezeFailure(applied: true, message: "Owned service pause was not confirmed") }
            }, resume: { try context.requireLease(); try d.signal($0, SIGCONT) }, terminate: { try context.requireLease(); try d.signal($0, SIGKILL) }, children: d.children, sockets: d.sockets,
            temporaryFanOwner: d.fanOwner, work: d.work, bootout: { try await context.bootout($0, seconds: $1) },
            restore: { try await context.restore($0, seconds: $1) }, ready: { try await context.ready($0, nodes: $1, seconds: $2) },
            portsAbsent: d.absent, pause: d.pause,
            settlement: { try await context.settlement($0, seconds: $1) }, clock: d.clock)
    }

    private final class Context: @unchecked Sendable {
        let paths: NativePaths, d: NativeLegacySystemDependencies
        let lock = NSLock()
        var leaseFD: Int32 = -1
        var backups: [String: URL] = [:]
        var issuedRequests: [String: NativeLegacyRegistration] = [:]
        var baseRelative: String { "Library/Application Support/UniApi Native Transfer" }
        var base: URL { paths.home.appendingPathComponent(baseRelative, isDirectory: true) }
        var domain: String { "gui/\(d.owner)" }
        init(paths: NativePaths, dependencies: NativeLegacySystemDependencies) { self.paths = paths; d = dependencies }
        func exclusive() throws -> NativeLegacyRetirementLease {
            try paths.assertWritable()
            lock.lock(); defer { lock.unlock() }
            guard leaseFD < 0 else { throw NativeFailure("Another transfer owns these legacy services") }
            let parent = try NativeLegacyProtected.directory(anchor: paths.home, relative: baseRelative, owner: d.owner, create: true, privateLast: true)
            defer { close(parent) }
            let fd = openat(parent, "transfer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NativeFailure("Cannot open protected transfer lock") }
            do {
                try NativeLegacyProtected.validateFile(fd, owner: d.owner, maximum: 16, privateFile: true, empty: true)
                guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw NativeFailure("Another transfer owns these legacy services") }
            } catch { close(fd); throw error }
            leaseFD = fd
            return NativeLegacyRetirementLease { [self] in
                lock.lock(); let held = leaseFD; leaseFD = -1; lock.unlock()
                if held >= 0 { _ = flock(held, LOCK_UN); close(held) }
            }
        }
        func requireLease() throws {
            try lock.withLock {
                guard leaseFD >= 0 else { throw NativeFailure("Transfer controls require exclusive ownership") }
                let parent = try NativeLegacyProtected.directory(anchor: paths.home, relative: baseRelative, owner: d.owner, privateLast: true)
                defer { close(parent) }
                var held = stat(), path = stat()
                guard fstat(leaseFD, &held) == 0, fstatat(parent, "transfer.lock", &path, AT_SYMLINK_NOFOLLOW) == 0,
                      held.st_dev == path.st_dev, held.st_ino == path.st_ino, held.st_nlink == 1,
                      path.st_mode & S_IFMT == S_IFREG else { throw NativeFailure("Transfer lock path or inode changed") }
                try NativeLegacyProtected.validateFile(leaseFD, owner: d.owner, maximum: 16, privateFile: true, empty: true)
            }
        }
        func definitionPath(_ label: String) -> URL { paths.home.appendingPathComponent("Library/LaunchAgents/" + label + ".plist") }
        func original(_ label: String) throws -> Data {
            try NativeLegacyProtected.read(anchor: paths.home, relative: "Library/LaunchAgents/" + label + ".plist", owner: d.owner, maximum: 1 << 20)
        }
        func disabled(_ label: String, seconds: Double) async throws -> Bool {
            let value = try await d.command(["print-disabled", domain], seconds)
            guard value.status == 0, value.stdout.count <= 1 << 20 else { throw NativeFailure("Cannot establish legacy control state") }
            return try NativeLegacyLoadedJob.disabled(value.output, label: label)
        }
        private struct LoadedRegistration {
            let label: String
            let job: NativeLegacyLoadedJob, definition: Data
            let arguments: [String], environment: [String: String], workingDirectory: String?
        }
        private func loadedRegistration(_ label: String, seconds: Double) async throws -> LoadedRegistration? {
            guard NativeLegacyRetirement.labels.contains(label), seconds.isFinite, seconds > 0 else { throw NativeFailure("Invalid legacy registration query") }
            let deadline = d.clock() + seconds
            guard deadline.isFinite else { throw NativeFailure("Invalid legacy registration deadline") }
            let value = try await d.command(["print", domain + "/" + label], seconds)
            guard d.clock() < deadline, value.stdout.count <= 1 << 20, value.stderr.count <= 65536 else { throw NativeFailure("Legacy registration query exceeded its bound") }
            if value.status != 0 {
                guard NativeLegacyLoadedJob.isAbsent(value, label: label, owner: d.owner) else { throw NativeFailure("Legacy registration inspection failed") }
                return nil
            }
            let job = try NativeLegacyLoadedJob.parse(value.output, target: domain + "/" + label)
            let bytes = try original(label)
            // A recovery bootstraps only an immutable private copy. Subsequent
            // prepare/retire may recognize that owned copy without accepting an
            // arbitrary launchd source path or rewriting the original plist.
            if canonical(job.path) != canonical(definitionPath(label)) {
                let prefix = canonical(base) + "/", loaded = canonical(job.path)
                guard loaded.hasPrefix(prefix) else { throw NativeFailure("Loaded definition has an unowned source") }
                let relative = String(loaded.dropFirst(prefix.count)), parts = relative.split(separator: "/").map(String.init)
                guard parts.count == 2, UUID(uuidString: parts[0]) != nil, parts[1] == label + ".plist",
                      try NativeLegacyProtected.read(anchor: paths.home, relative: baseRelative + "/" + relative, owner: d.owner, maximum: 1 << 20, privateFile: true) == bytes else { throw NativeFailure("Loaded recovery definition does not match its original") }
            }
            guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
                  let argv = plist["ProgramArguments"] as? [String], !argv.isEmpty,
                  plist["WorkingDirectory"] == nil || plist["WorkingDirectory"] is String,
                  plist["EnvironmentVariables"] == nil || plist["EnvironmentVariables"] is [String: String],
                  plist["Label"] as? String == label,
                  plist["KeepAlive"] as? Bool == true, plist["Disabled"] as? Bool != true,
                  job.arguments == argv, canonical(job.program) == canonical(URL(fileURLWithPath: argv[0])) else { throw NativeFailure("Loaded legacy definition or environment disagrees") }
            // launchd permits an absent environment block; a present malformed
            // block must never become an empty dictionary through the fallback.
            let environment = plist["EnvironmentVariables"] as? [String: String] ?? [:]
            guard environment.allSatisfy({ job.environment[$0.key] == $0.value }) else { throw NativeFailure("Loaded legacy definition or environment disagrees") }
            let relevant = ["HOME", "UNIAPI_ROOT", "UNIAPI_DATA", "UNIAPI_PROVIDERS", "UNIAPI_PORT"]
            for key in relevant where environment[key] == nil {
                if let actual = job.environment[key] {
                    let expected: String
                    switch key { case "HOME": expected = paths.home.path; case "UNIAPI_ROOT": expected = paths.root.path; case "UNIAPI_DATA": expected = paths.data.path; case "UNIAPI_PROVIDERS": expected = paths.providers.path; default: expected = label == NativeLegacyRetirement.labels[0] ? "8780" : "8823" }
                    guard actual == expected else { throw NativeFailure("Inherited legacy routing differs from this transfer") }
                }
            }
            guard try await !disabled(label, seconds: deadline - d.clock()) else { throw NativeFailure("Disabled legacy control state cannot be retired") }
            guard d.clock() < deadline else { throw NativeFailure("Legacy registration query exceeded its bound") }
            return LoadedRegistration(label: label, job: job, definition: bytes, arguments: argv, environment: environment,
                                      workingDirectory: plist["WorkingDirectory"] as? String)
        }
        private func projectedRegistration(_ loaded: LoadedRegistration, directory: URL) -> NativeLegacyRegistration {
            func url(_ key: String, _ fallback: URL) -> URL { loaded.environment[key].map { URL(fileURLWithPath: $0, relativeTo: directory).standardizedFileURL } ?? fallback }
            return NativeLegacyRegistration(label: loaded.label, pid: loaded.job.pid, definitionPath: definitionPath(loaded.label),
                definition: loaded.definition, arguments: loaded.arguments, directory: directory,
                sourceRoot: url("UNIAPI_ROOT", paths.root), home: url("HOME", d.home), data: url("UNIAPI_DATA", paths.root.appendingPathComponent("data")),
                providers: url("UNIAPI_PROVIDERS", paths.root.appendingPathComponent("providers.json")), port: loaded.label == NativeLegacyRetirement.labels[0] ? 8780 : 8823)
        }
        func registration(_ label: String, seconds: Double) async throws -> NativeLegacyRegistration? {
            let deadline = d.clock() + seconds
            guard let loaded = try await loadedRegistration(label, seconds: seconds) else { return nil }
            let job = loaded.job, argv = loaded.arguments
            let identity = try d.identity(job.pid), cwd = try d.directory(identity)
            var pythonResolution: NativeLegacyPythonResolution?
            if let first = identity.arguments.first, canonical(URL(fileURLWithPath: first)) != canonical(job.program) {
                guard NativeLegacyPythonResolution.supports(label: label, arguments: argv, root: paths.root),
                      let resolve = d.resolveSystemPython else { throw NativeFailure("Loaded legacy kernel identity or directory disagrees") }
                pythonResolution = try await resolve(deadline - d.clock())
            }
            guard identity.uid == d.owner, identity.parent == 1,
                  identity.arguments.count == argv.count, let first = identity.arguments.first,
                  (pythonResolution.map { canonical(URL(fileURLWithPath: first)) == $0.interpreter.path && canonical(URL(fileURLWithPath: identity.executable)) == $0.interpreter.path } ?? (canonical(URL(fileURLWithPath: first)) == canonical(job.program))),
                  identity.arguments.dropFirst() == argv.dropFirst(),
                  loaded.workingDirectory.map({ canonical(cwd) == canonical(URL(fileURLWithPath: $0)) }) ?? true,
                  try d.same(identity), d.clock() < deadline else { throw NativeFailure("Loaded legacy kernel identity or directory disagrees") }
            var registration = projectedRegistration(loaded, directory: cwd)
            registration.pythonResolution = pythonResolution
            return registration
        }
        func settlement(_ record: NativeLegacyRegistration, seconds: Double) async throws -> NativeLegacyUnregisterObservation {
            try requireLease()
            guard lock.withLock({ issuedRequests[record.label] }) == record else { throw NativeFailure("Unregister observation requires an issued owned request") }
            guard let loaded = try await loadedRegistration(record.label, seconds: seconds) else { return .absent }
            // A stopped, accepted job can still be printed while its process
            // exits. This verifies only the captured registration's metadata;
            // querying its dying PID/CWD/selector here reintroduces that race.
            var projected = projectedRegistration(loaded, directory: record.directory)
            projected.pythonResolution = record.pythonResolution
            guard projected == record,
                  loaded.workingDirectory.map({ canonical(record.directory) == canonical(URL(fileURLWithPath: $0)) }) ?? true else {
                throw NativeFailure("Legacy registration changed while unregister was pending")
            }
            return .capturedRegistrationStillVisible
        }
        func bootout(_ record: NativeLegacyRegistration, seconds: Double) async throws {
            var issued = false
            do {
                try requireLease()
                try Task.checkCancellation()
                guard seconds.isFinite, seconds > 0 else { throw NativeFailure("Legacy unregister deadline expired") }
                let deadline = d.clock() + seconds
                guard deadline.isFinite, try await registration(record.label, seconds: seconds) == record else { throw NativeFailure("Legacy registration changed before bootout") }
                let generation = UUID().uuidString, relative = baseRelative + "/" + generation
                let fd = try NativeLegacyProtected.directory(anchor: paths.home, relative: relative, owner: d.owner, create: true, privateLast: true)
                defer { close(fd) }
                try NativeLegacyProtected.publish(record.definition, parent: fd, name: record.label + ".plist", owner: d.owner)
                let copy = paths.home.appendingPathComponent(relative + "/" + record.label + ".plist")
                lock.withLock { backups[record.label] = copy }
                let remaining = deadline - d.clock()
                guard remaining.isFinite, remaining > 0 else { throw NativeFailure("Legacy unregister deadline expired") }
                try Task.checkCancellation()
                // A throw/cancellation from the command transport cannot prove
                // launchctl did not issue or finish the unregister operation.
                issued = true
                lock.withLock { issuedRequests[record.label] = record }
                let value = try await d.command(["bootout", domain + "/" + record.label], remaining)
                guard value.status == 0, d.clock() < deadline else { throw NativeFailure("Legacy unregister command failed or expired") }
                try Task.checkCancellation()
            } catch {
                throw NativeLegacyBootoutFailure(disposition: issued ? .mayHaveApplied : .notIssued, message: error.localizedDescription)
            }
        }
        func restore(_ record: NativeLegacyRegistration, seconds: Double) async throws {
            try requireLease()
            let deadline = d.clock() + seconds
            guard try await registration(record.label, seconds: seconds) == nil, try await !disabled(record.label, seconds: deadline - d.clock()),
                  try original(record.label) == record.definition, let copy = lock.withLock({ backups[record.label] }) else { throw NativeFailure("Legacy recovery has conflicting control or definition state") }
            let relative = String(copy.path.dropFirst(base.path.count + 1))
            guard try NativeLegacyProtected.read(anchor: paths.home, relative: baseRelative + "/" + relative, owner: d.owner, maximum: 1 << 20, privateFile: true) == record.definition else { throw NativeFailure("Legacy recovery backup identity changed") }
            let value = try await d.command(["bootstrap", domain, copy.path], deadline - d.clock())
            guard value.status == 0, d.clock() < deadline else { throw NativeFailure("Legacy recovery bootstrap failed or expired") }
            // Bootstrap may report success before its fresh process exists.
            while d.clock() < deadline {
                if let current = try? await registration(record.label, seconds: deadline - d.clock()) {
                    guard current.definition == record.definition else { throw NativeFailure("Recovery started a conflicting definition") }
                    return
                }
                try await d.pause(min(0.02, max(0, deadline - d.clock())))
            }
            throw NativeFailure("Legacy recovery process startup expired")
        }
        func ready(_ record: NativeLegacyRegistration, nodes: [NativeTransferIdentity], seconds: Double) async throws -> Bool {
            let deadline = d.clock() + seconds
            while d.clock() < deadline {
                try Task.checkCancellation()
                guard try await registration(record.label, seconds: deadline - d.clock()) == record,
                      try nodes.allSatisfy({ try d.same($0) }) else { throw NativeFailure("Restored registration changed before readiness") }
                // tsx may create its server child after bootstrap returned.
                // Discover only fresh verified descendants of the same root.
                var current = [try d.identity(record.pid)], seen = Set<Int32>(), index = 0
                while index < current.count {
                    let node = current[index]; index += 1
                    guard current.count <= 8, seen.insert(node.pid).inserted, node.uid == d.owner,
                          NativeLegacyRetirement.belongs(node, service: record), try d.same(node), try !d.stopped(node) else { throw NativeFailure("Restored readiness forest contains unknown work") }
                    let sockets = try d.sockets(node)
                    guard sockets.listeningPorts.isSubset(of: [record.port]) else { throw NativeFailure("Restored readiness owns an unexpected listener") }
                    for pid in try d.children(node.pid) {
                        let child = try d.identity(pid); guard child.parent == node.pid else { throw NativeFailure("Restored readiness parent changed") }; current.append(child)
                    }
                }
                let listeners = try current.filter { try d.sockets($0).listeningPorts.contains(record.port) }
                if !listeners.isEmpty {
                    let value = try await d.health(record.port, deadline - d.clock())
                    let isHub = record.label == NativeLegacyRetirement.labels[0]
                    guard value["ok"].bool, value["service"] == .string(isHub ? "uniapi-server" : "uniapi-shim"),
                          !isHub || value["apps"].array.contains("code") else { throw NativeFailure("Restored health is not owned by its kernel listener") }
                    if isHub || !value["pid"].isNull {
                        guard case .number(let pid) = value["pid"], pid.isFinite, pid > 1, pid.rounded() == pid,
                              listeners.contains(where: { Double($0.pid) == pid }) else { throw NativeFailure("Restored health PID is not its kernel listener") }
                    }
                    // The close-delimited probe has completed. Wait for its own
                    // server descriptor cleanup before returning/future freeze.
                    if try current.allSatisfy({ try d.same($0) && sameExecution(d.identity($0.pid), $0) && d.sockets($0).isIdle }) { return d.clock() < deadline }
                }
                try await d.pause(min(0.02, max(0, deadline - d.clock())))
            }
            throw NativeFailure("Restored PID readiness deadline expired")
        }
    }
}

private func sameExecution(_ a: NativeTransferIdentity, _ b: NativeTransferIdentity) -> Bool { NativeLegacyRetirementSystem.sameExecution(a, b) }
