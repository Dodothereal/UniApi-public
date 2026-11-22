import Foundation
import CryptoKit
import Darwin

/// Three numeric components, matching the release packager's version contract.
public struct NativeAppVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]) else { return nil }
        self.major = major; self.minor = minor; self.patch = patch
    }
    public var description: String { "\(major).\(minor).\(patch)" }
    public static func < (left: Self, right: Self) -> Bool {
        (left.major, left.minor, left.patch) < (right.major, right.minor, right.patch)
    }
}

/// Pure release naming and admission rules for the published macOS package.
public enum NativeAppUpdatePolicy {
    public static let repository = "Dodothereal/UniApi-public"
    public static let bundleIdentifier = "app.devved.uniapi.hub"
    public static let maximumPackageBytes: Int64 = 512 * 1024 * 1024
    public static var latestURL: URL { URL(string: "https://github.com/\(repository)/releases/latest")! }

    /// GitHub answers `releases/latest` with a redirect to `releases/tag/vX.Y.Z`.
    public static func version(fromReleaseURL url: URL) -> NativeAppVersion? {
        let parts = url.path.split(separator: "/").map(String.init)
        guard url.scheme == "https", url.host == "github.com", parts.count == 5,
              parts[0] + "/" + parts[1] == repository, parts[2] == "releases", parts[3] == "tag",
              parts[4].hasPrefix("v") else { return nil }
        return NativeAppVersion(String(parts[4].dropFirst()))
    }
    public static func packageName(_ version: NativeAppVersion) -> String { "UniApi-macos-\(version).zip" }
    public static func packageURL(_ version: NativeAppVersion) -> URL {
        URL(string: "https://github.com/\(repository)/releases/download/v\(version)/\(packageName(version))")!
    }
    public static func checksumURL(_ version: NativeAppVersion) -> URL {
        URL(string: packageURL(version).absoluteString + ".sha256")!
    }
    /// `shasum` format: 64 hexadecimal digits, two spaces and the package name.
    public static func checksum(_ text: String, version: NativeAppVersion) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count == 1 else { return nil }
        let fields = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[1] == packageName(version) || fields[1] == "*" + packageName(version) else { return nil }
        let digest = fields[0].lowercased()
        guard digest.count == 64, digest.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return digest
    }
    public static func isNewer(_ latest: NativeAppVersion, than current: NativeAppVersion?) -> Bool {
        guard let current else { return false }
        return latest > current
    }
    /// A check at most every six hours unless the user asks.
    public static func shouldCheck(lastCheckedAt: Double?, now: Double, automatic: Bool) -> Bool {
        guard automatic else { return false }
        guard let lastCheckedAt, lastCheckedAt <= now else { return true }
        return now - lastCheckedAt >= 6 * 3600 * 1000
    }
    public static func busyMessage(jobs: Int, code: Int) -> String {
        var parts: [String] = []
        if jobs > 0 { parts.append("\(jobs) " + (jobs == 1 ? "job" : "jobs")) }
        if code > 0 { parts.append("\(code) coding " + (code == 1 ? "turn" : "turns")) }
        return "Waiting for " + parts.joined(separator: " and ") + " to finish. The update installs as soon as UniApi is idle."
    }
    /// Describes an update that did not complete, from the installer's own
    /// log. Only the installer's explicit statements say what was restored;
    /// an exit status or a missing report is never read as a rollback.
    public static func failureMessage(log: String, path: String) -> String {
        let lines = log.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let details = path.isEmpty ? "" : " Log: " + path
        if lines.contains(where: { $0.contains("recovery is incomplete") || $0.contains("current app and definitions retained") }) {
            return "The update failed and the installer could not fully restore the previous installation. Its backups were kept; check the installation before using UniApi further." + details
        }
        if lines.contains(where: { $0.contains("previous app/service definitions and running PIDs restored") }) {
            return "The update failed. The installer restored the previous version and its services, and kept data and settings." + details
        }
        guard let reason = lines.last else {
            return "The update did not complete and the installer left no report, so the state of the installation is unknown." + details
        }
        return "The update was not installed. The installer reported: " + String(reason.prefix(240)) + details
    }
}

public struct NativeAppUpdateWork: Sendable, Equatable {
    public var jobs: Int, code: Int
    public init(jobs: Int, code: Int) { self.jobs = jobs; self.code = code }
    public var idle: Bool { jobs == 0 && code == 0 }
}

public struct NativeAppUpdateIO: Sendable {
    /// The installed production version, or nil when this process cannot be updated in place.
    public var currentVersion: @Sendable () -> NativeAppVersion?
    /// A reason the running bundle cannot update itself, or nil when it can.
    public var unavailable: @Sendable () -> String?
    public var latest: @Sendable () async throws -> NativeAppVersion
    public var text: @Sendable (URL) async throws -> String
    public var download: @Sendable (URL, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    public var digest: @Sendable (URL) throws -> String
    public var extract: @Sendable (URL, URL) async throws -> Void
    /// Validates the extracted package and returns its bundle version.
    public var validate: @Sendable (URL) async throws -> NativeAppVersion
    public var work: @Sendable () async throws -> NativeAppUpdateWork
    /// Starts the package installer outside this service's process forest.
    public var launch: @Sendable (URL, URL, URL) throws -> Void
    public var now: @Sendable () -> Double
    public var sleep: @Sendable (Double) async throws -> Void
    public init(currentVersion: @escaping @Sendable () -> NativeAppVersion?, unavailable: @escaping @Sendable () -> String?,
                latest: @escaping @Sendable () async throws -> NativeAppVersion, text: @escaping @Sendable (URL) async throws -> String,
                download: @escaping @Sendable (URL, URL, @escaping @Sendable (Double) -> Void) async throws -> Void,
                digest: @escaping @Sendable (URL) throws -> String, extract: @escaping @Sendable (URL, URL) async throws -> Void,
                validate: @escaping @Sendable (URL) async throws -> NativeAppVersion,
                work: @escaping @Sendable () async throws -> NativeAppUpdateWork,
                launch: @escaping @Sendable (URL, URL, URL) throws -> Void,
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 },
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) {
        self.currentVersion = currentVersion; self.unavailable = unavailable; self.latest = latest; self.text = text
        self.download = download; self.digest = digest; self.extract = extract; self.validate = validate
        self.work = work; self.launch = launch; self.now = now; self.sleep = sleep
    }
}

/// Finds, verifies and stages the newest published package, then hands the
/// transfer to that package's guarded installer. This actor never replaces a
/// bundle or controls a service itself.
public actor NativeAppUpdater {
    public enum Phase: String, Sendable { case idle, checking, current, downloading, ready, waiting, installing, failed, unavailable }
    private let runtime: NativeRuntime
    private let io: NativeAppUpdateIO
    private var phase = Phase.idle
    private var latest: NativeAppVersion?
    private var staged: NativeAppVersion?
    private var progress = 0.0
    private var message = ""
    private var checkedAt: Double?
    private var result: JSONValue = .null
    private var operation: Task<Void, Never>?
    private var installation: Task<Void, Never>?
    private var generation = 0

    public init(runtime: NativeRuntime, io: NativeAppUpdateIO? = nil) {
        self.runtime = runtime
        self.io = io ?? .production(paths: runtime.paths)
    }

    private var updates: URL { runtime.paths.data.appendingPathComponent("updates", isDirectory: true) }
    private var resultFile: URL { updates.appendingPathComponent("last-result.json") }
    private func stage(_ version: NativeAppVersion) -> URL { updates.appendingPathComponent(version.description, isDirectory: true) }
    private func package(_ version: NativeAppVersion) -> URL { stage(version).appendingPathComponent("UniApi-macos-\(version)", isDirectory: true) }

    public func state() -> JSONValue {
        let current = io.currentVersion()
        return ["phase": .string(phase.rawValue), "current": current.map { .string($0.description) } ?? .null,
                "latest": latest.map { .string($0.description) } ?? .null,
                "staged": staged.map { .string($0.description) } ?? .null,
                "available": .bool(latest.map { NativeAppUpdatePolicy.isNewer($0, than: current) } ?? false),
                "progress": .number(progress), "message": .string(message),
                "checkedAt": checkedAt.map(JSONValue.number) ?? .null, "result": result]
    }
    private func publish() async { await runtime.events.publish("update.state", state()) }
    private func set(_ next: Phase, _ text: String = "") async { phase = next; message = text; await publish() }

    /// Reads the outcome a finished installer left behind and removes staged
    /// packages that are no longer newer than the running app.
    public func start() async {
        if let reason = io.unavailable() { phase = .unavailable; message = reason; await publish(); return }
        if let saved = try? NativeFile.readJSON(resultFile), !saved.isNull {
            result = saved
            if saved["status"].string != "installed" { phase = .failed; message = failureText(saved) }
        }
        let current = io.currentVersion()
        let found = ((try? FileManager.default.contentsOfDirectory(atPath: updates.path)) ?? []).compactMap { NativeAppVersion($0) }.sorted(by: >)
        for version in found {
            // Only the newest package that is still exactly what was verified is kept.
            if staged == nil, NativeAppUpdatePolicy.isNewer(version, than: current), await retained(version) { staged = version; continue }
            try? FileManager.default.removeItem(at: stage(version))
        }
        if let staged, phase != .failed { latest = staged; progress = 1; phase = .ready }
        await publish()
    }
    private static let sealed = ["install.sh", "tools/install-native.sh"]
    private func manifest(_ version: NativeAppVersion) -> URL { stage(version).appendingPathComponent("verified.json") }
    private func seal(_ version: NativeAppVersion) throws -> JSONValue {
        var files: JSONObject = [:]
        for name in Self.sealed { files[name] = .string(try io.digest(package(version).appendingPathComponent(name))) }
        return ["version": .string(version.description), "files": .object(files)]
    }
    /// A package staged by an earlier run counts only when its record, its
    /// installer scripts and the bundle's signature and version still agree.
    private func retained(_ version: NativeAppVersion) async -> Bool {
        guard let saved = try? NativeFile.readJSON(manifest(version)), !saved.isNull, let now = try? seal(version), saved == now else { return false }
        return (try? await io.validate(package(version))) == version
    }
    private func log(_ version: String) -> URL? {
        NativeAppVersion(version).map { runtime.paths.logs.appendingPathComponent("update-\($0).log") }
    }
    private func failureText(_ saved: JSONValue) -> String {
        guard let log = log(saved["version"].string) else { return NativeAppUpdatePolicy.failureMessage(log: "", path: "") }
        let text = (try? Data(contentsOf: log)).map { String(decoding: $0.suffix(16_384), as: UTF8.self) } ?? ""
        return NativeAppUpdatePolicy.failureMessage(log: text, path: log.path)
    }
    public func acknowledgeResult() async {
        result = .null; try? FileManager.default.removeItem(at: resultFile)
        if phase == .failed { phase = staged != nil ? .ready : .idle; message = "" }
        await publish()
    }

    /// Checks for a release and stages it so that installing takes one click.
    public func check(automatic: Bool = false) async {
        guard phase != .unavailable, operation == nil, installation == nil else { return }
        if automatic, !NativeAppUpdatePolicy.shouldCheck(lastCheckedAt: checkedAt, now: io.now(), automatic: true) { return }
        generation += 1
        let run = generation
        operation = Task { [weak self] in await self?.performCheck(run, automatic: automatic) }
        await operation?.value
    }
    private func performCheck(_ run: Int, automatic: Bool) async {
        defer { if generation == run { operation = nil } }
        let previous = phase
        do {
            await set(.checking, "Checking GitHub for the newest release")
            let found = try await io.latest()
            guard generation == run else { return }
            latest = found; checkedAt = io.now()
            guard NativeAppUpdatePolicy.isNewer(found, than: io.currentVersion()) else {
                staged = nil; await set(.current, ""); return
            }
            try await prepare(found, run: run)
        } catch is CancellationError {
            if generation == run { await set(previous == .checking || previous == .downloading ? .idle : previous) }
        } catch {
            guard generation == run else { return }
            // A background check must not replace a staged update with an error.
            if automatic, staged != nil { await set(.ready) }
            else { await set(.failed, error.localizedDescription) }
        }
    }
    private func prepare(_ version: NativeAppVersion, run: Int) async throws {
        try runtime.paths.assertWritable()
        let folder = stage(version), bundle = package(version)
        if staged == version, FileManager.default.fileExists(atPath: bundle.appendingPathComponent("install.sh").path) {
            await set(.ready); return
        }
        progress = 0
        await set(.downloading, "Downloading UniApi \(version)")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let published = try await io.text(NativeAppUpdatePolicy.checksumURL(version))
            guard let expected = NativeAppUpdatePolicy.checksum(published, version: version) else { throw NativeFailure("The published checksum for UniApi \(version) is not valid") }
            let archive = folder.appendingPathComponent(NativeAppUpdatePolicy.packageName(version))
            try await io.download(NativeAppUpdatePolicy.packageURL(version), archive) { [weak self] fraction in
                Task { await self?.report(fraction, run: run) }
            }
            try Task.checkCancellation()
            guard try io.digest(archive) == expected else { throw NativeFailure("The downloaded update does not match its published checksum") }
            try await io.extract(archive, folder)
            try? FileManager.default.removeItem(at: archive)
            let bundled = try await io.validate(bundle)
            guard bundled == version else { throw NativeFailure("The downloaded package is not UniApi \(version)") }
            try Task.checkCancellation()
            try NativeFile.writeAtomic(try seal(version).encoded(), to: manifest(version))
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
        guard generation == run else { return }
        staged = version; progress = 1
        await set(.ready)
    }
    private func report(_ fraction: Double, run: Int) async {
        guard generation == run, phase == .downloading, fraction.isFinite else { return }
        let next = min(1, max(progress, fraction))
        guard next - progress >= 0.01 || next == 1 else { return }
        progress = next; await publish()
    }

    /// Installs the staged update once no job or coding turn is active.
    /// `hide` dismisses the presentation the guarded installer refuses to replace.
    public func install(hide: @escaping @Sendable () async -> Void) async {
        guard phase == .ready || phase == .failed, installation == nil, let version = staged,
              NativeAppUpdatePolicy.isNewer(version, than: io.currentVersion()) else { return }
        installation = Task { [weak self] in await self?.performInstall(version, hide: hide) }
    }
    public func cancelInstall() async {
        guard phase == .waiting else { return }
        installation?.cancel(); installation = nil
        await set(.ready)
    }
    private func performInstall(_ version: NativeAppVersion, hide: @escaping @Sendable () async -> Void) async {
        do {
            while true {
                try Task.checkCancellation()
                let work = try await io.work()
                if work.idle { break }
                await set(.waiting, NativeAppUpdatePolicy.busyMessage(jobs: work.jobs, code: work.code))
                try await io.sleep(2)
            }
            // Cancel stays possible while the staged package is checked again.
            let kept = await retained(version)
            try Task.checkCancellation()
            guard kept else {
                staged = nil; try? FileManager.default.removeItem(at: stage(version))
                throw NativeFailure("The downloaded update changed after it was verified. Check for updates again.")
            }
            result = .null; try? FileManager.default.removeItem(at: resultFile)
            await set(.installing, "Installing UniApi \(version)")
            await hide()
            let log = runtime.paths.logs.appendingPathComponent("update-\(version).log")
            try io.launch(package(version), resultFile, log)
            // A successful transfer replaces this process. Still being here
            // means it did not complete; only the installer's log says how far it got.
            var waited = 0.0
            while waited < 300 {
                try await io.sleep(1); waited += 1
                if let saved = try? NativeFile.readJSON(resultFile), !saved.isNull {
                    result = saved; installation = nil
                    if saved["status"].string == "installed" { await set(.current) } else { await set(.failed, failureText(saved)) }
                    return
                }
            }
            installation = nil
            await set(.failed, "The installer has not reported a result after five minutes, so the state of the installation is unknown. Check the log before continuing: " + log.path)
        } catch is CancellationError {
        } catch {
            installation = nil
            await set(.failed, error.localizedDescription)
        }
    }
}
