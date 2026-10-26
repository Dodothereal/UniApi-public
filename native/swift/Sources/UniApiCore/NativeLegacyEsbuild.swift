import Foundation
import Darwin

/// TSX's build service is a leaf of its admitted Node process, not an arbitrary
/// program named esbuild. Follow the installed dependency links, never a pnpm
/// directory glob or a PATH lookup. No package code or binary is executed.
enum NativeLegacyEsbuild {
    static func matches(_ node: NativeTransferIdentity, service: NativeLegacyRegistration) -> Bool {
        guard service.label == NativeLegacyRetirement.labels[0], node.arguments.count == 3,
              node.arguments[1].hasPrefix("--service="), node.arguments[2] == "--ping" else { return false }
        do {
            let root = service.sourceRoot.standardizedFileURL.resolvingSymlinksInPath()
            let tsx = try dependency(root.appendingPathComponent("server/node_modules/tsx"), root: root, owner: node.uid)
            let tsxInfo = try package(tsx, root: root, owner: node.uid)
            guard tsxInfo["name"] == "tsx", case .string(let declared) = tsxInfo["dependencies"]["esbuild"], !declared.isEmpty else { return false }
            let esbuild = try dependency(tsx.deletingLastPathComponent().appendingPathComponent("esbuild"), root: root, owner: node.uid)
            let info = try package(esbuild, root: root, owner: node.uid)
            guard info["name"] == "esbuild", case .string(let version) = info["version"],
                  version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z"#, options: .regularExpression) != nil,
                  node.arguments[1] == "--service=" + version else { return false }
            // Both are explicitly named macOS optional dependencies, supporting
            // an installed native or Rosetta Node without guessing by basename.
            for architecture in ["arm64", "x64"] {
                let name = "@esbuild/darwin-" + architecture
                guard info["optionalDependencies"][name] == .string(version) else { continue }
                let link = esbuild.deletingLastPathComponent().appendingPathComponent(name)
                guard let platform = try? dependency(link, root: root, owner: node.uid) else { continue }
                let binary = platform.appendingPathComponent("bin/esbuild")
                guard canonical(node.executable) == binary.path, canonical(node.arguments[0]) == binary.path else { continue }
                let platformInfo = try package(platform, root: root, owner: node.uid)
                guard platformInfo["name"] == .string(name), platformInfo["version"] == .string(version),
                      platformInfo["os"] == .array([.string("darwin")]), platformInfo["cpu"] == .array([.string(architecture)]) else { return false }
                let relative = try relativePath(binary, root: root)
                let parent = try NativeLegacyProtected.directory(anchor: root, relative: String(relative.dropLast("/esbuild".count)), owner: node.uid)
                defer { close(parent) }
                let fd = openat(parent, "esbuild", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { return false }; defer { close(fd) }
                try NativeLegacyProtected.validateFile(fd, owner: node.uid, maximum: 256 << 20)
                var before = stat(), after = stat(), path = stat()
                guard fstat(fd, &before) == 0, before.st_mode & 0o111 != 0,
                      fstatat(parent, "esbuild", &path, AT_SYMLINK_NOFOLLOW) == 0, fstat(fd, &after) == 0,
                      NativeLegacyProtected.stable(before, path), NativeLegacyProtected.stable(before, after) else { return false }
                return true
            }
            return false
        } catch { return false }
    }
    private static func canonical(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private static func relativePath(_ path: URL, root: URL) throws -> String {
        guard path.path.hasPrefix(root.path + "/") else { throw NativeFailure("Build dependency escapes the selected source root") }
        return String(path.path.dropFirst(root.path.count + 1))
    }
    private static func dependency(_ link: URL, root: URL, owner: UInt32) throws -> URL {
        let path = link.standardizedFileURL.resolvingSymlinksInPath()
        let fd = try NativeLegacyProtected.directory(anchor: root, relative: relativePath(path, root: root), owner: owner)
        close(fd); return path
    }
    private static func package(_ directory: URL, root: URL, owner: UInt32) throws -> JSONValue {
        let relative = try relativePath(directory.appendingPathComponent("package.json"), root: root)
        return try JSONValue.decode(NativeLegacyProtected.read(anchor: root, relative: relative, owner: owner, maximum: 64 << 10))
    }
}
