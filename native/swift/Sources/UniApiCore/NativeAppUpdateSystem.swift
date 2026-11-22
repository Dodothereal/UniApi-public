import Foundation
import CryptoKit
import Darwin

extension NativeAppUpdateIO {
    public static func production(paths: NativePaths) -> NativeAppUpdateIO {
        let reader = NativeInstallServiceRetirement.nativeWork(paths: paths)
        return .init(
            currentVersion: { NativeAppUpdateSystem.currentVersion() },
            unavailable: { NativeAppUpdateSystem.unavailable(paths: paths) },
            latest: { try await NativeAppUpdateSystem.latest() },
            text: { try await NativeAppUpdateSystem.text($0) },
            download: { try await NativeAppUpdateSystem.download($0, to: $1, progress: $2) },
            digest: { try NativeAppUpdateSystem.digest($0) },
            extract: { try await NativeAppUpdateSystem.extract($0, into: $1) },
            validate: { try await NativeAppUpdateSystem.validate($0) },
            work: {
                let work = try await Task.detached(priority: .utility) { try reader() }.value
                return .init(jobs: work.jobs, code: work.code)
            },
            launch: { try NativeAppUpdateSystem.launch(package: $0, result: $1, log: $2, application: Bundle.main.bundleURL) })
    }
}

enum NativeAppUpdateSystem {
    static func currentVersion(bundle: Bundle = .main) -> NativeAppVersion? {
        guard bundle.bundleIdentifier == NativeAppUpdatePolicy.bundleIdentifier,
              let text = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return nil }
        return NativeAppVersion(text)
    }
    static func unavailable(paths: NativePaths, bundle: Bundle = .main) -> String? {
        if paths.readOnly { return "Updates are unavailable in read-only mode." }
        guard currentVersion(bundle: bundle) != nil, bundle.bundleURL.lastPathComponent == "UniApi.app" else {
            return "Updates apply to the installed UniApi app, not to a development build."
        }
        guard (try? NativeServiceUpdate.isNativeInstallation(paths: paths)) == true else {
            return "Install UniApi once with its installer. Later updates can use this button."
        }
        return nil
    }
    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }
    static func latest() async throws -> NativeAppVersion {
        var request = URLRequest(url: NativeAppUpdatePolicy.latestURL)
        request.httpMethod = "HEAD"
        let session = session(); defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let url = http.url,
              let version = NativeAppUpdatePolicy.version(fromReleaseURL: url) else {
            throw NativeFailure("GitHub did not report a published UniApi release")
        }
        return version
    }
    static func text(_ url: URL) async throws -> String {
        let session = session(); defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 4096,
              let text = String(data: data, encoding: .utf8) else { throw NativeFailure("The release checksum could not be read") }
        return text
    }
    static func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NativeFailure("Cannot create the private update download") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try await NativeLocalWhisperModels.download(url, handle, NativeAppUpdatePolicy.maximumPackageBytes) { fraction, _ in progress(fraction) }
        guard fsync(fd) == 0 else { throw NativeFailure("Cannot sync the update download") }
        try handle.close()
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func run(_ executable: String, _ arguments: [String]) async throws -> Int32 {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
    static func extract(_ archive: URL, into folder: URL) async throws {
        guard try await run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path]) == 0 else { throw NativeFailure("The update package could not be unpacked") }
    }
    private static func kind(_ url: URL) -> mode_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_mode & S_IFMT : nil
    }
    /// The package must be the published layout: a real production bundle with
    /// a valid signature seal next to the guarded installer that transfers it.
    static func validate(_ package: URL) async throws -> NativeAppVersion {
        let app = package.appendingPathComponent("UniApi.app", isDirectory: true)
        guard kind(package) == S_IFDIR, kind(app) == S_IFDIR,
              kind(app.appendingPathComponent("Contents/MacOS/UniApiNative")) == S_IFREG,
              kind(package.appendingPathComponent("install.sh")) == S_IFREG,
              kind(package.appendingPathComponent("tools/install-native.sh")) == S_IFREG else { throw NativeFailure("The update package is incomplete") }
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == NativeAppUpdatePolicy.bundleIdentifier,
              let text = plist["CFBundleShortVersionString"] as? String, let version = NativeAppVersion(text) else {
            throw NativeFailure("The update package is not a production UniApi app")
        }
        guard try await run("/usr/bin/codesign", ["--verify", "--strict", app.path]) == 0 else { throw NativeFailure("The update package failed signature verification") }
        return version
    }

    static let installer = """
    set -u
    package="$1"; result="$2"; log="$3"; application="$4"; version="$5"
    sleep 1
    status=failed
    if /bin/bash "$package/install.sh" --install >"$log" 2>&1; then status=installed; fi
    temporary="$result.$$"
    printf '{"status":"%s","version":"%s","finishedAt":%s}\\n' "$status" "$version" "$(date +%s)" >"$temporary" && mv -f "$temporary" "$result"
    if [ "$status" = installed ]; then rm -rf "$(dirname "$package")"; fi
    if launchctl print "gui/$(id -u)/app.devved.uniapi-server" >/dev/null 2>&1; then /usr/bin/open "$application"; fi
    """

    /// The guarded retirement refuses a service that owns an unknown child and
    /// launchd stops the service's process group. The installer therefore runs
    /// in its own session, re-parented to launchd by a short-lived intermediate.
    static func launch(package: URL, result: URL, log: URL, application: URL) throws {
        guard let text = (try? Data(contentsOf: package.appendingPathComponent("UniApi.app/Contents/Info.plist")))
                .flatMap({ try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] })?["CFBundleShortVersionString"] as? String,
              let version = NativeAppVersion(text) else { throw NativeFailure("The staged update is no longer valid") }
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let inherited = ProcessInfo.processInfo.environment
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "UNIAPI_NATIVE_APPLICATIONS": application.deletingLastPathComponent().path]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR"] { if let value = inherited[key] { environment[key] = value } }
        let arguments = ["/bin/sh", "-c", "/bin/bash -c \"$0\" uniapi-update \"$@\" </dev/null >/dev/null 2>&1 &", installer,
                         package.path, result.path, log.path, application.path, version.description]
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw NativeFailure("Cannot prepare the update installer") }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t(), mask = sigset_t()
        sigemptyset(&defaults); sigemptyset(&mask)
        for value in [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE] { sigaddset(&defaults, value) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 else { throw NativeFailure("Cannot isolate the update installer") }
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw NativeFailure("Cannot prepare the update installer") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", descriptor == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0) == 0 else { throw NativeFailure("Cannot prepare the update installer") }
        }
        guard posix_spawn_file_actions_addchdir_np(&actions, "/") == 0 else { throw NativeFailure("Cannot prepare the update installer") }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let status = argv.withUnsafeBufferPointer { args in envp.withUnsafeBufferPointer { env in
            posix_spawn(&pid, "/bin/sh", &actions, &attributes, UnsafeMutablePointer(mutating: args.baseAddress!), UnsafeMutablePointer(mutating: env.baseAddress!))
        } }
        guard status == 0 else { throw NativeFailure("Cannot start the update installer: " + String(cString: strerror(status))) }
        var exit: Int32 = 0
        while waitpid(pid, &exit, 0) < 0 && errno == EINTR {}
        guard exit & 0x7f == 0, (exit >> 8) & 0xff == 0 else { throw NativeFailure("The update installer did not start") }
    }
}
