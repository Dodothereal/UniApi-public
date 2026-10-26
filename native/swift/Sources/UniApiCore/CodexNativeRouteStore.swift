import Foundation
import Darwin

/// Owns only the six transport scalars. Defaults and provider tables retain
/// their independent owner. Status never repairs a journal: only an explicit
/// mutation, under the shared config lock, may resolve an interrupted rename.
final class NativeCodexRouteStore: @unchecked Sendable {
    let configPath: URL, stateDirectory: URL
    let catalog: NativeCodexCatalogStore
    var journalPath: URL { stateDirectory.appendingPathComponent("routing-journal.json") }
    private let paths: NativePaths
    private let mutex = NSLock()
    private let publicationHook: (@Sendable (NativeCodexPublicationPoint) throws -> Void)?

    init(paths: NativePaths, publicationHook: (@Sendable (NativeCodexPublicationPoint) throws -> Void)? = nil) {
        self.paths = paths
        configPath = SwitcherDisk.codexHome(paths).appendingPathComponent("config.toml")
        stateDirectory = paths.data.appendingPathComponent("codex/native-route", isDirectory: true)
        catalog = NativeCodexCatalogStore(bridgeHome: stateDirectory, providersFile: paths.providers)
        self.publicationHook = publicationHook
    }

    static func baseURL(port: Int = 8823, token: String) -> String { "http://127.0.0.1:\(port)/_uniapi/codex/\(token)/v1" }
    func baseURL(port: Int = 8823) throws -> String { Self.baseURL(port: port, token: try NativeCodexRoutingSecret.load(paths)) }

    private static func installed(port: Int, token: String) -> JSONObject {
        ["openai_base_url": .string(baseURL(port: port, token: token)), "model_catalog_json": .null,
         "features.multi_agent": true, "features.multi_agent_v2": false,
         "features.responses_websockets": false, "features.responses_websockets_v2": false]
    }

    private struct Snapshot {
        let bytes: Data, text: String, document: JSONObject, values: JSONObject
    }
    private func snapshot() throws -> Snapshot {
        let bytes = try SwitcherDisk.read(configPath)
        guard let text = String(data: bytes, encoding: .utf8) else { throw NativeFailure("Codex configuration must contain UTF-8 text") }
        let document = try NativeTOML.parse(text), values = NativeTOML.transportValues(document)
        try validateValues(values)
        if let features = document["features"], case .object = features {} else if document["features"] != nil {
            throw NativeFailure("Codex features must be a table; configuration was preserved")
        }
        return Snapshot(bytes: bytes, text: text, document: document, values: values)
    }
    private func validateValues(_ values: JSONObject) throws {
        guard Set(values.keys) == Set(NativeTOML.transportPaths.keys), values.allSatisfy({ key, value in
            if value.isNull { return true }
            if key.hasPrefix("features.") { if case .bool = value { return true }; return false }
            if case .string = value { return true }; return false
        }) else { throw NativeFailure("Invalid Codex transport field types; configuration was preserved") }
    }
    private func assertUnowned(_ snapshot: Snapshot) throws {
        guard snapshot.values["openai_base_url"] == .null || snapshot.values["openai_base_url"] == "" else {
            throw NativeFailure("Codex transport has another owner; disconnect it through its journal-aware owner before connecting UniApi")
        }
        guard snapshot.values["model_catalog_json"] == .null else { throw NativeFailure("The Codex model catalog belongs to another owner") }
        guard snapshot.document["model_provider"] == nil || snapshot.document["model_provider"] == "openai" else {
            throw NativeFailure("The selected Codex provider belongs to another route")
        }
    }

    // Check managed directories even on reads, but never create them on status.
    // This prevents a planted journal/backup directory from redirecting writes.
    private func validateDirectories(create: Bool) throws {
        for directory in [paths.data, paths.data.appendingPathComponent("codex"), stateDirectory] {
            var info = stat()
            if lstat(directory.path, &info) != 0 {
                guard errno == ENOENT else { throw NativeFailure("Cannot inspect native route storage") }
                if !create { continue }
                try createDirectoryDurably(directory)
                guard lstat(directory.path, &info) == 0 else { throw NativeFailure("Cannot inspect native route storage") }
            }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o022 == 0 else {
                throw NativeFailure("Native route storage must use owned, unlinked directories without other writers")
            }
            try assertNoExtendedACL(directory)
            if create {
                // A prior mkdir may have succeeded just before its parent sync
                // failed. Seeing the directory on retry is not durable proof.
                try synchronizeDirectory(directory)
                try synchronizeDirectory(directory.deletingLastPathComponent())
            }
        }
    }
    private func privateFile(_ file: URL) throws {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o777 == 0o600 else { throw NativeFailure("Native route recovery files must be private regular files") }
        try assertNoExtendedACL(file)
    }
    private func assertNoExtendedACL(_ file: URL) throws {
        // Mode 0600 alone is insufficient on macOS: an inherited allow ACL can
        // expose the full original config. Fail closed rather than rewriting an
        // operator's ACL, including deny-only ACLs whose intent we do not own.
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Cannot inspect native route storage permissions") }
        defer { close(fd) }
        errno = 0
        let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED), code = errno
        if let acl { _ = acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl == nil, code == ENOENT else { throw NativeFailure("Native route storage must not have extended ACLs") }
    }
    private func createDirectoryDurably(_ directory: URL) throws {
        var missing: [URL] = [], cursor = directory, info = stat()
        while lstat(cursor.path, &info) != 0 {
            guard errno == ENOENT else { throw NativeFailure("Cannot inspect native route storage parents") }
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent.path != cursor.path else { throw NativeFailure("Cannot create native route storage root") }
            cursor = parent
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw NativeFailure("Native route storage parent must be an unlinked directory") }
        for child in missing.reversed() {
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try synchronizeDirectory(child)
            try synchronizeDirectory(child.deletingLastPathComponent())
        }
    }
    private func journal() throws -> JSONValue? {
        try validateDirectories(create: false)
        var info = stat()
        if lstat(journalPath.path, &info) != 0 {
            if errno == ENOENT { return nil }; throw NativeFailure("Cannot inspect native route journal")
        }
        try privateFile(journalPath)
        let value = try JSONValue.decode(SwitcherDisk.read(journalPath, missing: false, limit: 65536))
        let keys: Set<String> = ["version", "configPath", "generation", "phase", "previous", "installed", "port", "backupPath", "backupSHA256"]
        guard Set(value.object.keys) == keys, value["version"] == 1,
              value["configPath"] == .string(configPath.path),
              case .string(let generation) = value["generation"], UUID(uuidString: generation)?.uuidString == generation,
              ["pending-install", "committed", "pending-restore"].contains(value["phase"].string),
              case .number(let port) = value["port"], port >= 1, port <= 65535, port.rounded() == port,
              case .object(let previous) = value["previous"], case .object(let installed) = value["installed"],
              installed == Self.installed(port: Int(port), token: try NativeCodexRoutingSecret.load(paths)) else { throw NativeFailure("Invalid native Codex route recovery journal") }
        try validateValues(previous)
        let backup = stateDirectory.appendingPathComponent("config-" + generation + ".toml")
        guard value["backupPath"] == .string(backup.path) else { throw NativeFailure("Native route backup identity does not match its journal") }
        try privateFile(backup)
        let bytes = try SwitcherDisk.read(backup, missing: false)
        guard value["backupSHA256"] == .string(SwitcherDisk.hash(bytes)), let text = String(data: bytes, encoding: .utf8) else {
            throw NativeFailure("Native route backup is missing or changed")
        }
        let document = try NativeTOML.parse(text)
        guard NativeTOML.transportValues(document) == previous else { throw NativeFailure("Native route backup does not match the previous transport") }
        try assertUnowned(Snapshot(bytes: bytes, text: text, document: document, values: previous))
        return value
    }

    /// An acknowledged install never accepts previous values as proof of a
    /// rollback. Otherwise an independent user edit could release ownership.
    private func connected(_ snapshot: Snapshot, journal: JSONValue) throws -> Bool {
        if snapshot.values == journal["installed"].object { return true }
        if journal["phase"] != "committed", snapshot.values == journal["previous"].object { return false }
        throw NativeFailure("Codex owned transport changed outside UniApi; recovery is paused and the edit was preserved")
    }
    private func reconcile(_ snapshot: Snapshot, journal: JSONValue?) throws -> JSONValue? {
        guard var journal else { return nil }
        if try !connected(snapshot, journal: journal) {
            try assertCurrent(snapshot.bytes)
            try removeJournal(); return nil
        }
        if journal["phase"] != "committed" {
            try assertCurrent(snapshot.bytes)
            journal["phase"] = "committed"; try saveJournal(journal)
        }
        return journal
    }
    private func saveJournal(_ value: JSONValue) throws {
        try NativeFile.writeAtomic(try value.encoded(pretty: true), to: journalPath)
        // NativeFile performs best-effort directory sync; ownership requires a
        // checked durable journal before publishing a config or acknowledging it.
        try synchronizeDirectory(stateDirectory)
    }
    private func removeJournal() throws {
        try FileManager.default.removeItem(at: journalPath)
        // Persist release before acknowledging it, just as config publication
        // persists its directory entry before recording committed ownership.
        try synchronizeDirectory(stateDirectory)
    }
    private func result(_ snapshot: Snapshot, journal: JSONValue?) throws -> JSONValue {
        let owned = try journal.map { try connected(snapshot, journal: $0) } ?? false
        return ["ok": true, "connected": .bool(owned), "owned": .bool(owned), "readOnly": .bool(paths.readOnly),
                "phase": journal?["phase"] ?? .null, "configSHA256": .string(SwitcherDisk.hash(snapshot.bytes)),
                "baseUrl": owned ? .string("http://127.0.0.1:\(journal!["port"].int)/_uniapi/codex/<private>/v1") : .null,
                "canRestore": .bool(owned && !paths.readOnly)]
    }
    func status() throws -> JSONValue {
        mutex.lock(); defer { mutex.unlock() }
        // SwitcherDisk.locked creates a lock file, so even that is inappropriate
        // for this read-only path. An inconsistent concurrent read fails closed.
        let snapshot = try snapshot(); return try result(snapshot, journal: journal())
    }

    func connect(expectedConfigSHA256: String, port: Int = 8823) throws -> JSONValue {
        mutex.lock(); defer { mutex.unlock() }
        try paths.assertWritable()
        guard (1...65535).contains(port) else { throw NativeFailure("Invalid native Codex route port") }
        return try SwitcherDisk.locked(configPath) {
            let before = try snapshot(), existing = try journal()
            // An already-owned route needs no new handoff receipt. A changed
            // requested port still requires restore followed by a fresh receipt.
            if let existing, try connected(before, journal: existing) {
                guard existing["port"] == .number(Double(port)) else { throw NativeFailure("Restore the owned Codex route before changing its port") }
                let saved = try reconcile(before, journal: existing)
                return try result(before, journal: saved)
            }
            guard expectedConfigSHA256 == SwitcherDisk.hash(before.bytes) else {
                throw NativeFailure("Codex configuration changed after the bridge handoff; obtain a new configuration receipt")
            }
            try assertUnowned(before)
            _ = try reconcile(before, journal: existing)
            let installed = Self.installed(port: port, token: try NativeCodexRoutingSecret.load(paths, create: true))
            let output = try NativeTOML.patchTransport(before.text, values: installed)
            try validateDirectories(create: true)
            let generation = UUID().uuidString, backup = stateDirectory.appendingPathComponent("config-" + generation + ".toml")
            try NativeFile.writeAtomic(before.bytes, to: backup)
            try synchronizeDirectory(stateDirectory)
            try privateFile(backup)
            var pending: JSONValue = ["version": 1, "configPath": .string(configPath.path), "generation": .string(generation),
                "phase": "pending-install", "previous": .object(before.values), "installed": .object(installed), "port": .number(Double(port)),
                "backupPath": .string(backup.path), "backupSHA256": .string(SwitcherDisk.hash(before.bytes))]
            try saveJournal(pending)
            try publishConfig(Data(output.utf8), expected: before.bytes, operation: .select)
            let published = try snapshot()
            guard published.values == installed else { throw NativeFailure("Codex transport changed after publication; pending ownership was preserved for review") }
            pending["phase"] = "committed"; try saveJournal(pending)
            return try result(published, journal: pending)
        }
    }

    func restore() throws -> JSONValue {
        mutex.lock(); defer { mutex.unlock() }
        try paths.assertWritable()
        return try SwitcherDisk.locked(configPath) {
            let before = try snapshot()
            guard var pending = try reconcile(before, journal: journal()) else { return try result(before, journal: nil) }
            let output = try NativeTOML.patchTransport(before.text, values: pending["previous"].object)
            pending["phase"] = "pending-restore"; try saveJournal(pending)
            try publishConfig(Data(output.utf8), expected: before.bytes, operation: .restore)
            let restored = try snapshot()
            guard restored.values == pending["previous"].object else { throw NativeFailure("Codex transport changed after restoration; pending ownership was preserved for review") }
            try removeJournal()
            return try result(restored, journal: nil)
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Cannot open native route directory for synchronization") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw NativeFailure("Cannot synchronize native route directory") }
    }
    private func assertCurrent(_ expected: Data) throws {
        // This is an immediate byte comparison under the shared advisory lock,
        // not a filesystem CAS against editors which ignore that lock. POSIX
        // rename cannot condition publication on the destination's prior bytes.
        guard try SwitcherDisk.read(configPath) == expected else { throw NativeFailure("Configuration changed during this operation; the other edit was preserved") }
    }
    private func publishConfig(_ data: Data, expected: Data, operation: NativeCodexWriteOperation) throws {
        // NativeFile's atomic journal/backup writer has no rename seam. Stage
        // config explicitly so the fault hook and whole-byte CAS occur at the
        // actual rename, after writing and synchronizing the private temporary.
        let directory = configPath.deletingLastPathComponent(), temporary = directory.appendingPathComponent(".uniapi-route-" + UUID().uuidString + ".tmp")
        try assertNoExtendedACL(directory)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeFailure("Cannot prepare private Codex transport update") }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw NativeFailure("Cannot write Codex transport update") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw NativeFailure("Cannot synchronize Codex transport update") }
        try publicationHook?(.beforeConfigRename(operation))
        try assertCurrent(expected)
        guard rename(temporary.path, configPath.path) == 0 else { throw NativeFailure("Cannot publish Codex transport update") }
        try synchronizeDirectory(directory)
        try publicationHook?(.afterConfigRename(operation))
    }
}
