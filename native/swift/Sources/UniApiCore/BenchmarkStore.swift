import Foundation
import Darwin
import CryptoKit

actor BenchmarkStore {
    let paths: NativePaths
    private var historySignature = "", history: [JSONValue] = []
    private var rowsSignature = "", cachedRows: [JSONValue]?
    private let cacheByteLimit: Int64, cacheRowLimit: Int
    init(paths: NativePaths, cacheByteLimit: Int64 = 8 * 1024 * 1024, cacheRowLimit: Int = 10_000) {
        self.paths = paths
        self.cacheByteLimit = max(0, min(8 * 1024 * 1024, cacheByteLimit))
        self.cacheRowLimit = max(0, min(10_000, cacheRowLimit))
    }
    func state(_ name: String, fallback: JSONValue = [:]) -> JSONValue { (try? BenchmarkDisk.json(paths.bench.appendingPathComponent("state/" + name + ".json"))) ?? fallback }
    func save(_ name: String, _ value: JSONValue) throws {
        try paths.assertWritable()
        try NativeFile.writeAtomic(try value.encoded(pretty: true), to: paths.bench.appendingPathComponent("state/" + name + ".json"))
    }
    func catalog() -> JSONValue { (try? BenchmarkDisk.json(paths.data.appendingPathComponent("models.json"))) ?? [:] }
    func saveCatalog(_ provider: String, _ entry: JSONValue) throws {
        try paths.assertWritable(); var value = catalog(); value[provider] = entry
        try NativeFile.writeAtomic(try value.encoded(pretty: true), to: paths.data.appendingPathComponent("models.json"))
        try save("models", value)
    }
    func seedCalibration() throws {
        var mine = state("calib")
        let legacy = (try? BenchmarkDisk.json(paths.data.appendingPathComponent("calib.json"))) ?? [:]
        for (key, value) in legacy.object where mine[key].isNull { if let n = BenchmarkMath.number(value), n > 0.05 && n < 1 { mine[key] = value } }
        if !paths.readOnly { try save("calib", mine) }
    }
    func calibration(_ key: String) -> Double {
        let value = state("calib")[key].double
        return value > 0.05 && value < 1 ? value : 0.22
    }
    func calibrate(_ key: String, characters: Int, tokens: Double) throws {
        guard characters >= 500 else { return }; let measured = tokens / Double(characters)
        guard measured > 0.05 && measured < 1 else { return }
        var value = state("calib"); let old = BenchmarkMath.number(value[key]); value[key] = .number(((old.map { ($0 + measured) / 2 } ?? measured) * 100_000).rounded() / 100_000)
        try save("calib", value)
    }
    func quirk(_ key: String, _ flag: String? = nil) throws -> JSONValue {
        var values = state("quirks")
        if let flag { var item = values[key]; item[flag] = true; values[key] = item; try save("quirks", values) }
        return values[key]
    }
    func append(_ row: JSONValue) throws {
        try appendJSON(row, to: paths.bench.appendingPathComponent("results/results.jsonl"))
    }
    func event(_ kind: String, message: String, fields: JSONObject = [:]) throws {
        var value = fields; value["kind"] = .string(kind); value["msg"] = .string(message); value["ts"] = .string(BenchmarkMath.iso(Date()))
        try appendJSON(.object(value), to: paths.bench.appendingPathComponent("logs/events.jsonl"))
    }
    private func appendJSON(_ value: JSONValue, to url: URL) throws {
        try paths.assertWritable()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw NativeFailure("Benchmark ledger cannot be opened") }
        defer { close(fd) }
        var info = stat(); guard fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG else { throw NativeFailure("Benchmark ledger must be a regular file") }
        guard flock(fd, LOCK_EX) == 0 else { throw NativeFailure("Benchmark ledger cannot be locked") }
        defer { flock(fd, LOCK_UN) }
        var data = try value.encoded(); data.append(10)
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw NativeFailure("Benchmark ledger write failed") }; offset += written
            }
        }
        guard fsync(fd) == 0 else { throw NativeFailure("Benchmark ledger checkpoint failed") }
    }
    func rows() throws -> [JSONValue] {
        try Task.checkCancellation()
        var descriptors: [Int32?] = [], signatures: [String] = [], bytes: Int64 = 0
        defer { descriptors.compactMap { $0 }.forEach { close($0) } }
        // Summary, raw inspection and curves share one small immutable ledger
        // generation. Every lookup still admits the current descriptors, so a
        // replacement/link/append cannot inherit an earlier cached payload.
        for file in [paths.bench.appendingPathComponent("results/results.jsonl"), paths.data.appendingPathComponent("results.jsonl")] {
            guard let fd = try ledgerDescriptor(file) else {
                descriptors.append(nil); signatures.append("absent"); continue
            }
            descriptors.append(fd)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else { throw NativeFailure("Benchmark history must be a regular file") }
            signatures.append(Self.signature(info))
            bytes = bytes > cacheByteLimit || info.st_size > cacheByteLimit - bytes ? cacheByteLimit + 1 : bytes + info.st_size
        }
        let signature = signatures.joined(separator: "|")
        if signature == rowsSignature, let cachedRows { try Task.checkCancellation(); return cachedRows }
        cachedRows = nil; rowsSignature = ""
        var result: [JSONValue] = []
        for fd in descriptors.compactMap({ $0 }) {
            try StatisticsImporter.lines(descriptor: fd, maximumRowBytes: 16 * 1024 * 1024) { result.append($0) }
        }
        let rows = BenchmarkFold.orderedUnique(result)
        let stable = descriptors.enumerated().allSatisfy { index, fd in
            guard let fd else { return true }
            var info = stat()
            return fstat(fd, &info) == 0 && Self.signature(info) == signatures[index]
        }
        // Large/live ledgers still return every row, but do not retain another
        // full copy or pin a generation that changed while it was being read.
        if stable, bytes <= cacheByteLimit, rows.count <= cacheRowLimit {
            rowsSignature = signature; cachedRows = rows
        }
        return rows
    }
    private static func signature(_ info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    private func ledgerDescriptor(_ file: URL) throws -> Int32? {
        let filePath = file.standardizedFileURL.path
        let repository = paths.root.standardizedFileURL
        let repositoryPrefix = repository.path.hasSuffix("/") ? repository.path : repository.path + "/"
        let root = filePath.hasPrefix(repositoryPrefix) ? repository : paths.data.standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard filePath.hasPrefix(prefix) else { throw NativeFailure("Benchmark ledger escapes selected storage") }
        let components = filePath.dropFirst(prefix.count).split(separator: "/").map(String.init)
        guard let name = components.last, !components.contains(".."), !components.contains(".") else { throw NativeFailure("Invalid benchmark ledger path") }
        // Only the explicitly selected root may be an intentional alias. Hold
        // its descriptor and refuse links in every child directory and file.
        var parent = open(root.resolvingSymlinksInPath().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if parent < 0 { if errno == ENOENT { return nil }; throw NativeFailure("Benchmark storage root is unavailable") }
        defer { close(parent) }
        for component in components.dropLast() {
            let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), code = errno
            if next < 0 { if code == ENOENT { return nil }; throw NativeFailure("Benchmark ledger ancestry is linked or unavailable") }
            close(parent); parent = next
        }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC), code = errno
        if fd < 0 { if code == ENOENT { return nil }; throw NativeFailure("Benchmark history is unavailable or linked") }
        return fd
    }
    func runHistory() throws -> [JSONValue] {
        try Task.checkCancellation()
        let files = [paths.bench.appendingPathComponent("results/results.jsonl"), paths.data.appendingPathComponent("results.jsonl")]
        var descriptors: [Int32?] = [], signatures: [String] = []
        defer { for fd in descriptors.compactMap({ $0 }) { close(fd) } }
        // Validate descriptors even on a cache hit: replacing a regular ledger
        // with a link must not inherit the old payload through identical dates.
        for file in files {
            guard let fd = try ledgerDescriptor(file) else {
                descriptors.append(nil); signatures.append("absent"); continue
            }
            descriptors.append(fd)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NativeFailure("Benchmark history must be a regular file") }
            signatures.append("\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)")
        }
        let signature = signatures.joined(separator: "|")
        if signature == historySignature { try Task.checkCancellation(); return history }
        var headers: [JSONValue] = [], identities = Set<String>()
        for descriptor in descriptors.compactMap({ $0 }) {
            try StatisticsImporter.lines(descriptor: descriptor, maximumRowBytes: 16 * 1024 * 1024) { row in
                guard case .object = row else { return }
                let identity = row["id"].string.isEmpty ? SHA256.hash(data: (try? row.encoded()) ?? Data()).map { String(format: "%02x", $0) }.joined() : row["id"].string
                guard identities.insert(identity).inserted else { return }
                let fields = ["id", "run_id", "ts", "ts_end", "provider", "model", "tier", "ok"]
                headers.append(.object(Dictionary(uniqueKeysWithValues: fields.compactMap { key in row.object[key].map { (key, $0) } })))
            }
        }
        // Hash full rows for dedup only. Synthetic IDs would reorder ties and a
        // second dedup after projection would merge different raw/curve rows.
        let ordered = headers.enumerated().sorted { a, b in
            let at = BenchmarkMath.timestamp(a.element["ts"].string), bt = BenchmarkMath.timestamp(b.element["ts"].string)
            if at != bt { return at < bt }
            let ae = BenchmarkMath.timestamp(a.element["ts_end"].string), be = BenchmarkMath.timestamp(b.element["ts_end"].string)
            if ae != be { return ae < be }
            let ai = a.element["id"].string, bi = b.element["id"].string
            return ai == bi ? a.offset < b.offset : ai < bi
        }.map(\.element)
        history = BenchmarkFold.runHistory(ordered); historySignature = signature
        return history
    }
}

enum BenchmarkDisk {
    static func json(_ file: URL, limit: Int = 32 * 1024 * 1024) throws -> JSONValue {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Benchmark configuration is unavailable") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= limit else { throw NativeFailure("Benchmark configuration must be a bounded regular file") }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }; if count < 0 && errno == EINTR { continue }
            guard count > 0, bytes.count + count <= limit else { throw NativeFailure("Benchmark configuration read failed") }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        return try JSONValue.decode(bytes)
    }
}
