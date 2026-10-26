import Foundation
import Darwin

public struct NativePaths: Sendable {
    static var launchctl: URL { URL(fileURLWithPath: "/bin/launchctl") }
    static var xcrun: URL { URL(fileURLWithPath: "/usr/bin/xcrun") }
    static var xcodeSelect: URL { URL(fileURLWithPath: "/usr/bin/xcode-select") }
    static var codesign: URL { URL(fileURLWithPath: "/usr/bin/codesign") }
    static var systemPython3: URL { URL(fileURLWithPath: "/usr/bin/python3") }
    public let root: URL
    public let home: URL
    public let readOnly: Bool
    private let dataLocation: URL
    private let providerLocation: URL
    public var data: URL { dataLocation }
    public var database: URL { data.appendingPathComponent("uniapi.sqlite") }
    public var providers: URL { providerLocation }
    public var bench: URL { data.appendingPathComponent("bench", isDirectory: true) }
    public var logs: URL { data.appendingPathComponent("logs", isDirectory: true) }
    public var tmp: URL { data.appendingPathComponent("tmp", isDirectory: true) }
    func statisticsDeepSeekHome(environment: [String: String]) -> URL {
        guard let configured = environment["DSH_HOME"], !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return home.appendingPathComponent(".dsh", isDirectory: true) }
        if configured == "~" { return home }
        if configured.hasPrefix("~/") || configured.hasPrefix("~\\") { return home.appendingPathComponent(String(configured.dropFirst(2)), isDirectory: true).standardizedFileURL }
        return URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
    }
    public init(root: URL, home: URL? = nil, readOnly: Bool = false, dataRoot: URL? = nil, providersFile: URL? = nil) {
        self.root = root.standardizedFileURL
        self.home = home ?? FileManager.default.homeDirectoryForCurrentUser
        self.readOnly = readOnly
        dataLocation = (dataRoot ?? root.appendingPathComponent("data", isDirectory: true)).standardizedFileURL
        providerLocation = (providersFile ?? root.appendingPathComponent("providers.json")).standardizedFileURL
    }
    public static func discover(environment env: [String: String] = ProcessInfo.processInfo.environment) -> NativePaths {
        let home = env["UNIAPI_NATIVE_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.homeDirectoryForCurrentUser
        let readOnly = env["UNIAPI_NATIVE_READ_ONLY"] == "1" || CommandLine.arguments.contains("--read-only") || Bundle.main.object(forInfoDictionaryKey: "UniApiReadOnlyPreview") as? Bool == true
        let root = env["UNIAPI_ROOT"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent("UniApi")
        return NativePaths(root: root, home: home, readOnly: readOnly,
                           dataRoot: env["UNIAPI_DATA"].map { URL(fileURLWithPath: $0, isDirectory: true) },
                           providersFile: env["UNIAPI_PROVIDERS"].map { URL(fileURLWithPath: $0) })
    }
    public func ensureDirectories() throws {
        guard !readOnly else { return }
        let folders = [root, data, providers.deletingLastPathComponent(), bench, logs, tmp]
        // Validate each managed component before creating any folders. The
        // selected roots may live on another volume, but their children must
        // not silently redirect writes through a planted link.
        for folder in folders {
            var info = stat()
            if lstat(folder.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw NativeFailure("Managed storage must use unlinked directories") }
            } else if errno != ENOENT { throw NativeFailure("Managed storage could not be inspected") }
        }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    }
    public func assertWritable() throws { if readOnly { throw NativeFailure("This runtime is read-only") } }
    public func containedFile(_ relative: String, in directory: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { throw NativeFailure("Invalid relative file path") }
        let baseURL = directory.standardizedFileURL.resolvingSymlinksInPath()
        var componentURL = baseURL
        for component in relative.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            var info = stat()
            if lstat(componentURL.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw NativeFailure("Linked files are not allowed in managed storage")
            }
        }
        let result = componentURL.standardizedFileURL
        let base = baseURL.path + "/"
        guard result.path.hasPrefix(base) else { throw NativeFailure("File path escapes its directory") }
        return result
    }
}

public enum NativeFile {
    public static func writeAtomic(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(permissions))
        guard fd >= 0 else { throw NativeFailure("Cannot create private temporary file: \(String(cString: strerror(errno)))") }
        var savedError: Int32 = 0
        data.withUnsafeBytes { buffer in
            var position = 0
            while position < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: position), buffer.count - position)
                if count < 0 { if errno == EINTR { continue }; savedError = errno; break }
                position += count
            }
        }
        if fsync(fd) != 0 && savedError == 0 { savedError = errno }
        close(fd)
        guard savedError == 0 else { throw NativeFailure("Cannot save file: \(String(cString: strerror(savedError)))") }
        guard rename(temporary.path, url.path) == 0 else { throw NativeFailure("Cannot publish file: \(String(cString: strerror(errno)))") }
        let dirFD = open(url.deletingLastPathComponent().path, O_RDONLY)
        if dirFD >= 0 { _ = fsync(dirFD); close(dirFD) }
    }
    public static func readJSON(_ url: URL) throws -> JSONValue { try JSONValue.decode(Data(contentsOf: url)) }
}
