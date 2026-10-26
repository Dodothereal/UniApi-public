import Foundation
import Darwin

enum ArenaSandbox {
    static let hidden: Set<String> = [".claude", ".cache", "node_modules", ".git", "__pycache__", ".venv", "venv"]
    static let disallowed = ["AskUserQuestion", "EnterPlanMode", "ExitPlanMode", "EnterWorktree", "ExitWorktree"]
    static let scrubbed = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL", "CLAUDE_CODE_MAX_CONTEXT_TOKENS"]
    static func resolve(_ url: URL, depth: Int = 0) throws -> URL {
        guard depth <= 40 else { throw NativeFailure("Workspace link loop") }
        // Foundation's standardization may turn /private/var back into /var.
        // That is a real macOS symlink, so normalizing before resolving it can
        // create an apparent loop. Walk lexical components in filesystem order.
        let parts = url.pathComponents.filter { $0 != "/" }, fm = FileManager.default
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, part) in parts.enumerated() {
            if part == "." { continue }
            if part == ".." { current = current.deletingLastPathComponent(); continue }
            let next = current.appendingPathComponent(part); var info = stat()
            if lstat(next.path, &info) != 0 { current = next; continue }
            if info.st_mode & S_IFMT == S_IFLNK {
                let target = try fm.destinationOfSymbolicLink(atPath: next.path)
                let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target) : current.appendingPathComponent(target)
                let rest = parts.dropFirst(index + 1).reduce(resolved) { $0.appendingPathComponent($1) }
                return try resolve(rest, depth: depth + 1)
            }
            current = next
        }
        return current
    }
    static func file(_ path: String, workspace: URL, home: URL, serve: Bool = false) throws -> URL {
        let input = path == "~" || path.hasPrefix("~/") ? home.path + String(path.dropFirst()) : path
        let candidate = input.hasPrefix("/") ? URL(fileURLWithPath: input) : workspace.appendingPathComponent(input)
        let root = try resolve(workspace), result = try resolve(candidate)
        guard result.path == root.path || result.path.hasPrefix(root.path + "/") else { throw NativeFailure("Outside the contestant workspace") }
        var info = stat()
        if lstat(result.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink > 1 { throw NativeFailure("Hard-linked workspace files are not permitted") }
        if serve { let relative = String(result.path.dropFirst(root.path.count)).split(separator: "/").map(String.init); guard !relative.contains(where: { hidden.contains($0) }) else { throw NativeFailure("Private workspace directories are not served") } }
        return result
    }
    static func offendingPath(_ name: String, input: JSONValue, workspace: URL, home: URL) -> String? {
        if name == "Bash" { return nil }
        for key in ["file_path", "path", "notebook_path", "directory", "cwd"] {
            let path = input[key].string
            if !path.isEmpty && (try? file(path, workspace: workspace, home: home)) == nil { return path }
        }
        let pattern = input["pattern"].string
        if ["Glob", "Grep"].contains(name) && (pattern.hasPrefix("/") || pattern.hasPrefix("~") || pattern.contains("..")) { return pattern }
        return nil
    }
    static func settings(_ runtime: NativeRuntime, workspace: URL, route: String, model: String) throws -> (JSONValue, [String: String]) {
        var settings = try CodeRoutes.settings(runtime, route: route, model: model), env = CodeRoutes.environment(runtime, claude: true)
        let cache = workspace.appendingPathComponent(".cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for (name, folder) in ["XDG_CACHE_HOME": "xdg", "npm_config_cache": "npm", "PNPM_HOME": "pnpm", "UV_CACHE_DIR": "uv", "PIP_CACHE_DIR": "pip", "TMPDIR": "tmp", "CARGO_HOME": "cargo", "GOCACHE": "go", "PYTHONPYCACHEPREFIX": "python"] {
            let url = cache.appendingPathComponent(folder); try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); env[name] = url.path
        }
        var read: [String] = [workspace.path, "/usr", "/bin", "/sbin", "/System", "/Library/Developer", "/opt/homebrew"]
        for name in ["node", "python3", "git", "pnpm", "npm", "uv", "unzip"] { if let tool = runtime.process.which(name) { let resolved = try resolve(tool); read.append(resolved.deletingLastPathComponent().path) } }
        for relative in [".nvm", ".local/share/pnpm/store", ".local/share/uv"] {
            let url = runtime.paths.home.appendingPathComponent(relative); if FileManager.default.fileExists(atPath: url.path) { read.append(url.path) }
        }
        settings["sandbox"] = ["enabled": true, "failIfUnavailable": true, "autoAllowBashIfSandboxed": true, "allowUnsandboxedCommands": false, "network": ["allowLocalBinding": true], "filesystem": ["denyRead": [.string(runtime.paths.home.path)], "allowRead": .array(Array(Set(read)).sorted().map(JSONValue.string))], "credentials": ["envVars": .array(scrubbed.map { ["name": .string($0), "mode": "deny"] })]]
        return (settings, env)
    }
    static var initialization: JSONValue { ["systemPromptSnapshot": true, "forwardSubagentText": false, "sdkMcpServers": ["arena"], "hooks": ["PreToolUse": [["hookCallbackIds": ["arena-path-guard"]]]]] }
    static var presentTool: JSONValue {
        ["name": "present", "description": "Show the judge a workspace file, HTTP(S) URL or text. Call when finished; multiple presentations are supported.", "inputSchema": ["type": "object", "additionalProperties": false, "required": ["kind", "title"], "properties": ["kind": ["type": "string", "enum": ["file", "url", "text"]], "title": ["type": "string", "minLength": 1, "maxLength": 120], "path": ["type": "string"], "url": ["type": "string"], "text": ["type": "string"], "note": ["type": "string", "maxLength": 2000]]]]
    }
    static func present(_ input: JSONValue, workspace: URL, home: URL) throws -> JSONValue {
        guard case .object = input, Set(input.object.keys).isSubset(of: ["kind", "title", "path", "url", "text", "note"]), input.object.allSatisfy({ if case .string = $0.value { return true }; return false }) else { throw NativeFailure("Presentation fields must be strings matching the present tool schema") }
        let title = input["title"].string.trimmingCharacters(in: .whitespacesAndNewlines), kind = input["kind"].string
        guard !title.isEmpty, title.count <= 120, ["file", "url", "text"].contains(kind), input["note"].string.count <= 2000 else { throw NativeFailure("Invalid presentation") }
        var value: JSONValue = ["kind": .string(kind), "title": .string(title)]
        if !input["note"].string.isEmpty { value["note"] = input["note"] }
        if kind == "file" {
            guard !input["path"].string.isEmpty else { throw NativeFailure("A file presentation needs a path") }
            let file = try self.file(input["path"].string, workspace: workspace, home: home, serve: true)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw NativeFailure("Presentation file does not exist") }
            value["path"] = .string(String(file.path.dropFirst(try resolve(workspace).path.count + 1)))
        } else if kind == "url" {
            guard let url = URL(string: input["url"].string), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw NativeFailure("Only HTTP(S) URLs can be presented") }; value["url"] = .string(url.absoluteString)
        } else { let text = input["text"].string.trimmingCharacters(in: .whitespacesAndNewlines); guard !text.isEmpty else { throw NativeFailure("A text presentation needs text") }; value["text"] = .string(String(text.prefix(20000))) }
        return value
    }
    static func files(workspace: URL, home: URL) throws -> [JSONValue] {
        var files: [JSONValue] = []
        func walk(_ directory: URL, relative: String, depth: Int) throws {
            guard depth <= 8, files.count < 3000 else { return }
            for item in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !hidden.contains(item.lastPathComponent) {
                let rel = relative.isEmpty ? item.lastPathComponent : relative + "/" + item.lastPathComponent
                guard let file = try? self.file(rel, workspace: workspace, home: home, serve: true), let info = try? file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { continue }
                if info.isDirectory == true { try walk(file, relative: rel, depth: depth + 1) }
                else if info.isRegularFile == true { files.append(["path": .string(rel), "size": .number(Double(info.fileSize ?? 0))]) }
                if files.count >= 3000 { break }
            }
        }
        try walk(workspace, relative: "", depth: 0); return files
    }
    static func preview(_ relative: String, workspace: URL, home: URL) throws -> JSONValue {
        let url = try file(relative, workspace: workspace, home: home, serve: true), info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? Int.max) <= 25 * 1024 * 1024 else { throw NativeFailure("Workspace preview exceeds 25 MiB or is not a regular file") }
        let mime = mimeType(url)
        let kind = mime == "text/html" ? "html" : mime.hasPrefix("image/") ? "image" : mime == "application/pdf" ? "pdf" : mime.hasPrefix("audio/") ? "audio" : mime.hasPrefix("video/") ? "video" : "text"
        let asset = try readAsset(relative, workspace: workspace, home: home, limit: 256 * 1024), bytes = asset.data
        return ["path": .string(url.path), "fileName": .string(url.lastPathComponent), "mimeType": .string(mime), "kind": .string(kind), "size": .number(Double(info.fileSize ?? 0)), "text": .string(String(decoding: bytes, as: UTF8.self)), "truncated": .bool((info.fileSize ?? 0) > bytes.count)]
    }
    static func mimeType(_ url: URL) -> String {
        ["html": "text/html", "htm": "text/html", "xhtml": "application/xhtml+xml", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript", "json": "application/json", "wasm": "application/wasm", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "ico": "image/x-icon", "webp": "image/webp", "svg": "image/svg+xml", "pdf": "application/pdf", "mp3": "audio/mpeg", "wav": "audio/wav", "mp4": "video/mp4", "webm": "video/webm", "md": "text/markdown"][url.pathExtension.lowercased()] ?? "text/plain"
    }
    static func readAsset(_ relative: String, workspace: URL, home: URL, limit: Int = 25 * 1024 * 1024) throws -> NativeArenaAsset {
        let root = try resolve(workspace), target = try file(relative, workspace: root, home: home, serve: true)
        let parts = String(target.path.dropFirst(root.path.count)).split(separator: "/").map(String.init)
        guard !parts.isEmpty else { throw NativeFailure("An artifact must be a regular workspace file") }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw NativeFailure("Workspace unavailable") }
        defer { Darwin.close(directory) }
        // Resolve benign links first, then walk descriptors without following
        // links. A contestant cannot swap an ancestor to expose outside files.
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw NativeFailure("Workspace directory changed") }
            Darwin.close(directory); directory = next
        }
        let descriptor = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeFailure("Artifact unavailable") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_size >= 0, info.st_size <= 25 * 1024 * 1024 else { Darwin.close(descriptor); throw NativeFailure("Artifact is not a private regular file within 25 MiB") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        let data = try handle.read(upToCount: max(0, min(limit, 25 * 1024 * 1024))) ?? Data()
        return NativeArenaAsset(data: data, mime: mimeType(target), name: target.lastPathComponent)
    }
}

public struct NativeArenaAsset: Sendable { public let data: Data; public let mime: String; public let name: String }
public enum NativeArenaArtifacts {
    public static func read(runtime: NativeRuntime, slotID: String, path: String) throws -> NativeArenaAsset {
        guard let slot = try runtime.db.query("SELECT * FROM arena_slots WHERE id=?", [.string(slotID)]).first else { throw NativeFailure("Slot no longer exists") }
        let root = runtime.paths.data.appendingPathComponent("arena/matches"), expected = try runtime.paths.containedFile((slot["match_id"] ?? .null).string + "/slot-\((slot["idx"] ?? .null).int)", in: root)
        guard try ArenaSandbox.resolve(URL(fileURLWithPath: (slot["workdir"] ?? .null).string)) == ArenaSandbox.resolve(expected) else { throw NativeFailure("Invalid slot workspace") }
        return try ArenaSandbox.readAsset(path, workspace: expected, home: runtime.paths.home)
    }
}

actor ArenaSemaphore {
    private let limit: Int
    private var active = Set<UUID>(), queue: [(UUID, CheckedContinuation<UUID, Error>)] = []
    init(_ limit: Int) { self.limit = max(1, limit) }
    func acquire() async throws -> UUID {
        try Task.checkCancellation(); let id = UUID()
        if active.count < limit { active.insert(id); return id }
        return try await withTaskCancellationHandler(operation: { try await withCheckedThrowingContinuation { queue.append((id, $0)) } }, onCancel: { Task { await self.cancel(id) } })
    }
    private func cancel(_ id: UUID) { if let i = queue.firstIndex(where: { $0.0 == id }) { let item = queue.remove(at: i); item.1.resume(throwing: CancellationError()) } }
    func release(_ id: UUID) { guard active.remove(id) != nil else { return }; if !queue.isEmpty { let next = queue.removeFirst(); active.insert(next.0); next.1.resume(returning: next.0) } }
}
