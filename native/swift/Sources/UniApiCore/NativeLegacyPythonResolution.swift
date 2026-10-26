import Foundation
import Darwin
import CryptoKit

/// Evidence can only be constructed by the bounded OS-selector resolver. It
/// reconciles one launchd stub with its real interpreter, never kernel identity.
struct NativeLegacyPythonResolution: Equatable, Sendable {
    let developerDirectory: String
    let selectedProgram: URL
    let interpreter: URL
    private let framework: FrameworkEvidence?

    private init(developerDirectory: String, selectedProgram: URL, interpreter: URL, framework: FrameworkEvidence? = nil) {
        self.developerDirectory = developerDirectory; self.selectedProgram = selectedProgram; self.interpreter = interpreter
        self.framework = framework
    }

    typealias Command = @Sendable (URL, [String], [String: String], Double) async throws -> NativeProcessResult

    static func resolve(home: URL, seconds: Double, clock: @escaping @Sendable () -> Double,
                        frameworkOwner: UInt32 = 0, frameworkAnchor: URL? = nil,
                        command: Command) async throws -> Self {
        let start = clock()
        guard seconds.isFinite, seconds > 0, seconds <= 30, start.isFinite else { throw NativeFailure("Invalid Python launcher resolution deadline") }
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        func remaining() throws -> Double {
            try Task.checkCancellation()
            let elapsed = clock() - start
            guard elapsed.isFinite, elapsed >= 0, elapsed < seconds else { throw NativeFailure("Python launcher resolution deadline expired or clock changed") }
            return seconds - elapsed
        }
        func path(_ result: NativeProcessResult) throws -> String {
            guard result.status == 0, !result.stdout.isEmpty, result.stdout.count <= 4096, result.stderr.count <= 4096,
                  var text = String(data: result.stdout, encoding: .utf8) else { throw NativeFailure("Python launcher selector lookup failed") }
            if text.hasSuffix("\n") { text.removeLast() }
            guard text.hasPrefix("/"), !text.contains("\0"), !text.contains("\n"), !text.contains("\r"),
                  text == URL(fileURLWithPath: text).standardizedFileURL.path else { throw NativeFailure("Python launcher selector returned an invalid path") }
            return text
        }
        let before = try path(try await command(NativePaths.xcodeSelect, ["-p"], environment, remaining()))
        let selected = try path(try await command(NativePaths.xcrun, ["--find", "python3"], environment, remaining()))
        let after = try path(try await command(NativePaths.xcodeSelect, ["-p"], environment, remaining()))
        _ = try remaining()
        let expected = URL(fileURLWithPath: before, isDirectory: true).appendingPathComponent("usr/bin/python3")
        guard before == after, selected == expected.path else { throw NativeFailure("Python launcher selection changed or is not the selected developer Python") }
        let developer = try existingCanonical(before), executable = try existingCanonical(selected)
        var directory = stat(), file = stat()
        guard lstat(developer.path, &directory) == 0, directory.st_mode & S_IFMT == S_IFDIR,
              lstat(executable.path, &file) == 0, file.st_mode & S_IFMT == S_IFREG, file.st_mode & 0o111 != 0,
              executable.path.hasPrefix(developer.path + "/") else { throw NativeFailure("Selected developer Python is unavailable or outside its installation") }
        _ = try remaining()
        if let layout = FrameworkLayout(developer: developer, launcher: executable) {
            let anchor = frameworkAnchor ?? URL(fileURLWithPath: "/", isDirectory: true)
            let snapshot = try layout.capture(anchor: anchor, owner: frameworkOwner, selected: expected)
            let requirement = "=anchor apple and identifier \"com.apple.python3\""
            for target in [layout.launcher, layout.app] {
                let result = try await command(NativePaths.codesign,
                    ["--verify", "--strict", "--all-architectures", "-R", requirement, target.path], environment, remaining())
                guard result.status == 0, result.stdout.count <= 4096, result.stderr.count <= 4096 else {
                    throw NativeFailure("Selected Python framework signature could not be verified")
                }
            }
            let finalDeveloper = try path(try await command(NativePaths.xcodeSelect, ["-p"], environment, remaining()))
            let finalSelected = try path(try await command(NativePaths.xcrun, ["--find", "python3"], environment, remaining()))
            let finalConfirmation = try path(try await command(NativePaths.xcodeSelect, ["-p"], environment, remaining()))
            guard before == finalDeveloper, before == finalConfirmation, selected == finalSelected,
                  try existingCanonical(before) == developer, try existingCanonical(selected) == executable,
                  try layout.capture(anchor: anchor, owner: frameworkOwner, selected: expected) == snapshot else {
                throw NativeFailure("Selected Python framework changed during verification")
            }
            _ = try remaining()
            return .init(developerDirectory: before, selectedProgram: expected, interpreter: layout.runtime,
                         framework: .init(launcher: executable, snapshot: snapshot))
        }
        return .init(developerDirectory: before, selectedProgram: expected, interpreter: executable)
    }

    static func supports(label: String, arguments: [String], root: URL) -> Bool {
        guard label == NativeLegacyRetirement.labels[1], arguments.first == NativePaths.systemPython3.path else { return false }
        let script: String
        if arguments.count == 2 { script = arguments[1] }
        else if arguments.count == 3, arguments[1] == "-u" { script = arguments[2] }
        else { return false }
        guard script.hasPrefix("/") else { return false }
        return canonical(URL(fileURLWithPath: script)) == canonical(root.appendingPathComponent("proxy/uniapi_shim.py"))
    }

    func applies(to registration: NativeLegacyRegistration) -> Bool {
        Self.supports(label: registration.label, arguments: registration.arguments, root: registration.sourceRoot) &&
        selectedProgram.path == URL(fileURLWithPath: developerDirectory).appendingPathComponent("usr/bin/python3").path &&
        canonical(selectedProgram) == (framework?.launcher ?? interpreter).path &&
        interpreter.path.hasPrefix(canonical(URL(fileURLWithPath: developerDirectory)) + "/")
    }

    func matches(_ node: NativeTransferIdentity, registration: NativeLegacyRegistration) -> Bool {
        guard applies(to: registration), node.pid == registration.pid, node.parent == 1,
              node.arguments.count == registration.arguments.count, let first = node.arguments.first,
              node.arguments.dropFirst() == registration.arguments.dropFirst() else { return false }
        return canonical(URL(fileURLWithPath: first)) == interpreter.path && canonical(URL(fileURLWithPath: node.executable)) == interpreter.path
    }

    private static func existingCanonical(_ path: String) throws -> URL {
        guard let value = realpath(path, nil) else { throw NativeFailure("Python launcher selection cannot be resolved") }
        defer { free(value) }
        // Existence comes from realpath; identity comparisons elsewhere use
        // Foundation's normalization of OS aliases such as /private/var.
        return URL(fileURLWithPath: canonical(URL(fileURLWithPath: String(cString: value))))
    }

    private struct FrameworkEvidence: Equatable, Sendable {
        let launcher: URL
        let snapshot: FrameworkSnapshot
    }

    private struct FrameworkSnapshot: Equatable, Sendable {
        var fingerprints: [String: String] = [:]
        var metadata: [String: Data] = [:]
    }

    private struct FrameworkLayout {
        let launcher: URL, runtime: URL, app: URL, frameworkInfo: URL, appInfo: URL
        let version: String
        init?(developer: URL, launcher: URL) {
            let prefix = developer.appendingPathComponent("Library/Frameworks/Python3.framework/Versions").path + "/"
            guard launcher.path.hasPrefix(prefix) else { return nil }
            let parts = launcher.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            guard parts.count == 3, parts[1] == "bin", parts[2] == "python" + parts[0],
                  Self.versionParts(parts[0]).count == 2 else { return nil }
            version = parts[0]; self.launcher = launcher
            let base = URL(fileURLWithPath: prefix).appendingPathComponent(version)
            app = base.appendingPathComponent("Resources/Python.app", isDirectory: true)
            runtime = app.appendingPathComponent("Contents/MacOS/Python")
            frameworkInfo = base.appendingPathComponent("Resources/Info.plist")
            appInfo = app.appendingPathComponent("Contents/Info.plist")
        }

        static func versionParts(_ value: String) -> [String] {
            let parts = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) }) else { return [] }
            return parts
        }

        func capture(anchor: URL, owner: UInt32, selected: URL) throws -> FrameworkSnapshot {
            guard try existingCanonical(runtime.path) == runtime, try existingCanonical(app.path) == app else {
                throw NativeFailure("Selected Python app has an unexpected link or location")
            }
            var result = FrameworkSnapshot()
            _ = try Self.read(selected, anchor: anchor, owner: owner, executable: true, selectionLink: true, snapshot: &result)
            for (file, executable) in [(launcher, true), (runtime, true), (frameworkInfo, false), (appInfo, false)] {
                let data = try Self.read(file, anchor: anchor, owner: owner, executable: executable, snapshot: &result)
                if !executable { result.metadata[file.path] = data }
            }
            func plist(_ url: URL) throws -> [String: Any] {
                guard let data = result.metadata[url.path],
                      let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                    throw NativeFailure("Selected Python bundle metadata is invalid")
                }
                return value
            }
            let framework = try plist(frameworkInfo), bundle = try plist(appInfo)
            guard let full = bundle["CFBundleVersion"] as? String,
                  Self.versionParts(full).count >= 2,
                  Self.versionParts(full).prefix(2).joined(separator: ".") == version,
                  bundle["CFBundleShortVersionString"] as? String == full,
                  framework["CFBundleVersion"] as? String == full,
                  framework["CFBundleShortVersionString"] as? String == full,
                  bundle["CFBundleIdentifier"] as? String == "com.apple.python3",
                  framework["CFBundleIdentifier"] as? String == "com.apple.python3",
                  bundle["CFBundleExecutable"] as? String == "Python",
                  bundle["CFBundlePackageType"] as? String == "APPL" else {
                throw NativeFailure("Selected Python framework and sealed app metadata disagree")
            }
            return result
        }

        private static func stamp(_ info: stat) -> String {
            "\(info.st_dev):\(info.st_ino):\(info.st_uid):\(info.st_gid):\(info.st_mode):\(info.st_nlink):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
        }

        private static func read(_ file: URL, anchor: URL, owner: UInt32, executable: Bool, selectionLink: Bool = false,
                                 snapshot: inout FrameworkSnapshot) throws -> Data {
            let base = anchor.standardizedFileURL.resolvingSymlinksInPath()
            let prefix = base.path == "/" ? "/" : base.path + "/"
            guard file.path.hasPrefix(prefix) else { throw NativeFailure("Python framework escapes its protected anchor") }
            let parts = file.path.dropFirst(prefix.count).split(separator: "/").map(String.init)
            guard parts.count > 1, parts.count <= 64, parts.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
                throw NativeFailure("Python framework path is invalid")
            }
            var fd = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw NativeFailure("Python framework anchor is unavailable") }
            defer { close(fd) }
            var current = base.path
            func directory(_ fd: Int32, path: String) throws {
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_uid == owner, info.st_mode & S_IFMT == S_IFDIR else {
                    throw NativeFailure("Python framework directory ownership is unsafe")
                }
                // /Applications is normally root:admin 0775. Its exact OS
                // policy is accepted; every installation descendant is protected.
                let applications = base.path == "/" && path == "/Applications" && owner == 0 && info.st_gid == 80 && info.st_mode & 0o7777 == 0o775
                guard info.st_mode & 0o022 == 0 || applications else { throw NativeFailure("Python framework directory permissions are unsafe") }
                try NativeLegacyProtected.directoryACL(fd)
                var after = stat()
                guard fstat(fd, &after) == 0, stamp(info) == stamp(after) else { throw NativeFailure("Python framework directory changed") }
                if let old = snapshot.fingerprints[path], old != stamp(after) { throw NativeFailure("Python framework path changed between reads") }
                snapshot.fingerprints[path] = stamp(after)
            }
            try directory(fd, path: current)
            for part in parts.dropLast() {
                let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw NativeFailure("Python framework directory is linked or unavailable") }
                close(fd); fd = next; current = (current == "/" ? "" : current) + "/" + part
                try directory(fd, path: current)
            }
            let name = parts.last!
            if selectionLink {
                var before = stat()
                guard fstatat(fd, name, &before, AT_SYMLINK_NOFOLLOW) == 0 else { throw NativeFailure("Python selection is unavailable") }
                if before.st_mode & S_IFMT == S_IFLNK {
                    guard before.st_uid == owner, before.st_nlink == 1 else { throw NativeFailure("Python selection link ownership is unsafe") }
                    var bytes = [UInt8](repeating: 0, count: 4097)
                    let count = readlinkat(fd, name, &bytes, bytes.count)
                    var after = stat()
                    guard count > 0, count <= 4096, fstatat(fd, name, &after, AT_SYMLINK_NOFOLLOW) == 0,
                          stamp(before) == stamp(after) else { throw NativeFailure("Python selection link changed") }
                    let data = Data(bytes.prefix(count))
                    snapshot.fingerprints[file.path] = stamp(after) + ":" + data.base64EncodedString()
                    return data
                }
            }
            let input = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard input >= 0 else { throw NativeFailure("Python framework file is linked or unavailable") }
            defer { close(input) }
            try NativeLegacyProtected.validateFile(input, owner: owner, maximum: executable ? 128 << 20 : 1 << 20)
            var before = stat()
            guard fstat(input, &before) == 0, !executable || before.st_mode & 0o111 != 0 else { throw NativeFailure("Python framework file is not executable") }
            var data = Data(), bytes = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = Darwin.read(input, &bytes, bytes.count)
                if count < 0 && errno == EINTR { continue }
                if count == 0 { break }
                guard count > 0, data.count + count <= before.st_size else { throw NativeFailure("Python framework file changed while reading") }
                data.append(contentsOf: bytes.prefix(count))
            }
            var after = stat(), atPath = stat()
            guard data.count == before.st_size, fstat(input, &after) == 0,
                  fstatat(fd, name, &atPath, AT_SYMLINK_NOFOLLOW) == 0,
                  stamp(before) == stamp(after), stamp(before) == stamp(atPath) else { throw NativeFailure("Python framework file changed while reading") }
            snapshot.fingerprints[file.path] = stamp(after) + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return data
        }
    }
}

private func canonical(_ value: URL) -> String { value.standardizedFileURL.resolvingSymlinksInPath().path }
