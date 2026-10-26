import Foundation
import Darwin

/// Native selection is definition-based, never a fallback after a failed legacy
/// transport. Preparing an update neither starts a runtime nor controls services.
public enum NativeServiceUpdate {
    public static func isNativeInstallation(paths: NativePaths) throws -> Bool {
        try selection(paths: paths) != nil
    }
    public static func prepare(paths: NativePaths, application: URL) async -> JSONValue {
        do { return await prepare(paths: paths, application: application, dependencies: try .production(paths: paths, application: application)) }
        catch { return failure(error) }
    }
    public static func retire(paths: NativePaths, application: URL, instance: String, expectedDefinitionHashes: [String: String]) async -> JSONValue {
        do { return await retire(paths: paths, application: application, instance: instance, expectedDefinitionHashes: expectedDefinitionHashes, dependencies: try .production(paths: paths, application: application)) }
        catch { return failure(error) }
    }
    static func prepare(paths: NativePaths, application: URL, dependencies: NativeUpdateDependencies) async -> JSONValue {
        do {
            guard let selected = try selection(paths: paths) else { throw NativeFailure("The protected definitions do not select a native installation") }
            let context = try NativeInstallRetirementSystem(paths: paths, application: application, instance: selected.instance, dependencies: dependencies.system,
                expectedHashes: selected.hashes, gui: dependencies.gui, nativeStatus: dependencies.nativeStatus)
            var value = await NativeLegacyRetirement.prepare(paths: paths, io: context.makeIO())
            value["kind"] = "native"; value["oldInstance"] = .string(selected.instance)
            value["definitionHashes"] = .object(selected.hashes.mapValues(JSONValue.string)); value["safeToInstall"] = false
            return value
        } catch { return failure(error) }
    }
    static func retire(paths: NativePaths, application: URL, instance: String, expectedDefinitionHashes: [String: String], dependencies: NativeUpdateDependencies) async -> JSONValue {
        do {
            guard let selected = try selection(paths: paths), UUID(uuidString: instance)?.uuidString == selected.instance,
                  selected.hashes == expectedDefinitionHashes else { throw NativeFailure("The prepared native identity or definition hashes changed") }
            let context = try NativeInstallRetirementSystem(paths: paths, application: application, instance: selected.instance, dependencies: dependencies.system,
                expectedHashes: expectedDefinitionHashes, gui: dependencies.gui, nativeStatus: dependencies.nativeStatus)
            var value = await NativeLegacyRetirement.retire(paths: paths, io: context.makeIO(), retirementDeadline: 30, rollbackDeadline: 30)
            value["kind"] = "native"; value["oldInstance"] = .string(selected.instance)
            value["definitionHashes"] = .object(expectedDefinitionHashes.mapValues(JSONValue.string))
            return value
        } catch { return failure(error) }
    }
    private static func failure(_ error: Error) -> JSONValue {
        ["kind": "native", "status": "refused", "canPrepare": false, "safeToInstall": false, "message": .string(error.localizedDescription)]
    }
    struct Selection { let instance: String; let hashes: [String: String] }
    static func selection(paths: NativePaths) throws -> Selection? {
        guard let parent = try selectionDirectory(home: paths.home, owner: getuid()) else { return nil }
        defer { close(parent) }
        var nonces: [String] = [], hashes: [String: String] = [:], unmarked = false
        for label in NativeLegacyRetirement.labels {
            var info = stat()
            if fstatat(parent, label + ".plist", &info, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT else { throw NativeFailure("Native installation selection is unavailable") }; continue
            }
            let bytes = try NativeLegacyProtected.read(anchor: paths.home, relative: "Library/LaunchAgents/" + label + ".plist", owner: getuid(), maximum: 1 << 20)
            guard let plist = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any], plist["Label"] as? String == label,
                  plist["EnvironmentVariables"] == nil || plist["EnvironmentVariables"] is [String: String] else { throw NativeFailure("Native installation selection metadata is invalid") }
            let env = plist["EnvironmentVariables"] as? [String: String] ?? [:]
            if let value = env["UNIAPI_NATIVE_INSTALL_NONCE"] {
                guard let nonce = UUID(uuidString: value) else { throw NativeFailure("Native installation nonce is invalid") }; nonces.append(nonce.uuidString)
            } else { unmarked = true }
            hashes[label] = NativeLegacyRetirement.hash(bytes)
        }
        guard let nonce = nonces.first else { return nil }
        guard !unmarked, nonces.allSatisfy({ $0 == nonce }) else { throw NativeFailure("Mixed native installation definitions are unsafe") }
        return Selection(instance: nonce, hashes: hashes)
    }
    private static func selectionDirectory(home: URL, owner: UInt32) throws -> Int32? {
        var descriptors = [try NativeLegacyProtected.directory(anchor: home, relative: "", owner: owner)]
        var links: [(Int32, String, Int32)] = [], retained = false
        defer { for (index, fd) in descriptors.enumerated() where !retained || index != descriptors.count - 1 { close(fd) } }
        func admit(_ fd: Int32) throws -> stat {
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFDIR,
                  before.st_uid == owner, before.st_mode & 0o022 == 0 else { throw NativeFailure("Native selection ancestry is unsafe") }
            try NativeLegacyProtected.directoryACL(fd)
            guard fstat(fd, &after) == 0, NativeLegacyProtected.stable(before, after) else { throw NativeFailure("Native selection ancestry changed") }
            return after
        }
        func verifyLinks() throws {
            for fd in descriptors { _ = try admit(fd) }
            for (parent, name, child) in links {
                var named = stat(), opened = stat()
                guard fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, fstat(child, &opened) == 0,
                      NativeLegacyProtected.stable(named, opened) else { throw NativeFailure("Native selection ancestry was replaced") }
            }
        }
        for component in ["Library", "LaunchAgents"] {
            let parent = descriptors.last!, before = try admit(parent)
            var named = stat()
            if fstatat(parent, component, &named, AT_SYMLINK_NOFOLLOW) != 0 {
                let code = errno
                guard code == ENOENT, NativeLegacyProtected.stable(before, try admit(parent)) else { throw NativeFailure("Native selection directory inspection failed") }
                // Only this exact absent relative component selects legacy.
                // Errors opening an observed directory never become absence.
                try verifyLinks(); return nil
            }
            guard named.st_mode & S_IFMT == S_IFDIR else { throw NativeFailure("Native selection ancestry is linked or not a directory") }
            let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw NativeFailure("Native selection directory cannot be inspected") }
            descriptors.append(child); links.append((parent, component, child))
            guard NativeLegacyProtected.stable(named, try admit(child)) else { throw NativeFailure("Native selection directory changed while opening") }
        }
        try verifyLinks(); retained = true; return descriptors.last!
    }
}

struct NativeUpdateDependencies: Sendable {
    var system: NativeLegacySystemDependencies
    var gui: NativeUpdateGUIAdmission.Reader
    var nativeStatus: @Sendable (Int32, String) throws -> JSONValue
    static func production(paths: NativePaths, application: URL) throws -> Self {
        var system = try NativeLegacySystemDependencies.production(paths: paths)
        system.work = NativeInstallServiceRetirement.nativeWork(paths: paths)
        system.health = { port, seconds in
            guard port == 8823 else { throw NativeFailure("Native update health accepts only the shim endpoint") }
            return try await NativeUpdateHealthProbe.get(timeout: seconds)
        }
        let backend = application.appendingPathComponent("Contents/MacOS/UniApiNative").path
        system.sockets = { try NativeInstallServiceSockets.read($0, backend: backend) }
        return .init(system: system, gui: { try NativeUpdateGUIAdmission.read() }, nativeStatus: { _, _ in
            let bytes = try NativeLegacyProtected.read(anchor: paths.data, relative: "native-status.json", owner: getuid(), maximum: 65536)
            return try JSONValue.decode(bytes)
        })
    }
}

/// Internal only: injected legacy IO and every public legacy entry point retain
/// their Node/Python roles and sequential timing policy.
enum NativeRetirementRole: Sendable {
    case legacy
    case native(application: URL, instance: String)
    var isNative: Bool { if case .native = self { return true }; return false }
    func root(_ node: NativeTransferIdentity, service: NativeLegacyRegistration) -> Bool {
        guard case .native(let app, _) = self else { return false }
        let file = app.appendingPathComponent(service.port == 8780 ? "Contents/MacOS/UniApiNative" : "Contents/Resources/Helpers/uniapi-shim")
        return node.pid == service.pid && node.arguments == [file.path, service.port == 8780 ? "--background" : "--serve"] && NativeLegacyRetirementSystem.canonical(URL(fileURLWithPath: node.executable)) == NativeLegacyRetirementSystem.canonical(file)
    }
    func belongs(_ node: NativeTransferIdentity, service: NativeLegacyRegistration) -> Bool {
        if root(node, service: service) { return true }
        guard case .native(let app, _) = self, service.port == 8780 else { return false }
        let monitor = app.appendingPathComponent("Contents/Resources/Helpers/uniapi-fans")
        return node.pid != service.pid && node.arguments == [monitor.path, "--monitor"] && NativeLegacyRetirementSystem.canonical(URL(fileURLWithPath: node.executable)) == NativeLegacyRetirementSystem.canonical(monitor)
    }
}
