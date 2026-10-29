import Foundation
import CryptoKit
import Darwin

/// Ephemeral parser state, never a transcript index or on-disk checkpoint.
/// The state excludes the EOF tail: a valid unterminated row can cease to be
/// valid when another writer appends bytes without a separating newline.
struct StatisticsCodexCheckpoint: Sendable {
    fileprivate let path: String, stamp: StatisticsCodexFileStamp
    fileprivate let digest: [UInt8], tailBytes: Int
    fileprivate let state: StatisticsCodexReader.Snapshot
    let estimatedBytes: Int
    var length: Int64 { stamp.size }
    var mtime: Double { stamp.mtime }
}

fileprivate struct StatisticsCodexFileStamp: Sendable, Equatable {
    let device: Int64, inode: UInt64, size: Int64
    let mode: UInt32, owner: UInt32, group: UInt32, links: UInt64
    let modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
    init(_ s: stat) {
        device = Int64(s.st_dev); inode = UInt64(s.st_ino); size = Int64(s.st_size)
        mode = UInt32(s.st_mode); owner = s.st_uid; group = s.st_gid; links = UInt64(s.st_nlink)
        modified = Int64(s.st_mtimespec.tv_sec); modifiedNanos = Int64(s.st_mtimespec.tv_nsec)
        changed = Int64(s.st_ctimespec.tv_sec); changedNanos = Int64(s.st_ctimespec.tv_nsec)
    }
    var mtime: Double { Double(modified) * 1000 + Double(modifiedNanos) / 1e6 }
    func sameFile(as other: Self) -> Bool {
        device == other.device && inode == other.inode && mode == other.mode && owner == other.owner && group == other.group && links == other.links
    }
}

struct StatisticsCodexAppendRead: Sendable {
    let result: StatisticsReadResult
    let checkpoint: StatisticsCodexCheckpoint?
    let validatedPrefixBytes: Int64, decodedBytes: Int64
    // Byte-identical decoded records, including the previous provisional EOF
    // row. A validated file prefix alone does not establish this property.
    var appendedRecordOffset: Int? = nil
}

/// Only the service actor owns this cache. Commit after the corresponding file
/// transaction succeeds; a rollback must not advance the parser's revision.
struct StatisticsCodexAppendCache {
    static let maximumFiles = 4
    private struct Entry {
        let sourcePath: String, revision: String, checkpoint: StatisticsCodexCheckpoint
        let rowOrderSchema: String?
        var access: UInt64
    }
    private let maximumBytes: Int, maximumEntries: Int
    private var entries: [String: Entry] = [:], serial: UInt64 = 0
    private(set) var estimatedBytes = 0
    var count: Int { entries.count }
    init(maximumBytes: Int = 16 << 20, maximumEntries: Int = Self.maximumFiles) {
        self.maximumBytes = max(0, maximumBytes); self.maximumEntries = max(0, maximumEntries)
    }
    mutating func remove(_ path: String) {
        if let old = entries.removeValue(forKey: path) { estimatedBytes -= old.checkpoint.estimatedBytes }
    }
    mutating func removeAll() { entries.removeAll(); estimatedBytes = 0 }
    mutating func retain(_ paths: Set<String>) { for path in Array(entries.keys) where !paths.contains(path) { remove(path) } }
    mutating func checkpoint(path: String, sourcePath: String, revision: String, mtime: Double, size: Double) -> StatisticsCodexCheckpoint? {
        guard var entry = entries[path] else { return nil }
        guard !revision.isEmpty, entry.revision == revision, entry.sourcePath == sourcePath,
              entry.checkpoint.mtime == mtime, Double(entry.checkpoint.length) == size else { remove(path); return nil }
        serial &+= 1; entry.access = serial; entries[path] = entry
        return entry.checkpoint
    }
    func hasOrderedRows(path: String, revision: String, schema: String) -> Bool {
        guard let entry = entries[path] else { return false }
        return entry.revision == revision && entry.rowOrderSchema == schema
    }
    mutating func commit(_ checkpoint: StatisticsCodexCheckpoint?, path: String, sourcePath: String, revision: String, mtime: Double, size: Double, rowOrderSchema: String? = nil) {
        remove(path)
        guard let checkpoint, maximumEntries > 0, !revision.isEmpty, checkpoint.path == sourcePath,
              checkpoint.mtime == mtime, Double(checkpoint.length) == size,
              checkpoint.estimatedBytes <= maximumBytes else { return }
        while entries.count >= maximumEntries || estimatedBytes > maximumBytes - checkpoint.estimatedBytes {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            remove(oldest)
        }
        serial &+= 1
        entries[path] = Entry(sourcePath: sourcePath, revision: revision, checkpoint: checkpoint, rowOrderSchema: rowOrderSchema, access: serial)
        estimatedBytes += checkpoint.estimatedBytes
    }
}

enum StatisticsCodexAppend {
    static func read(_ url: URL, checkpoint: StatisticsCodexCheckpoint? = nil,
                     afterPrefixValidation: (() throws -> Void)? = nil) throws -> StatisticsCodexAppendRead {
        // Archives retain their strict complete-frame decoder and never enter
        // the plain-file checkpoint path.
        guard url.lastPathComponent.hasSuffix(".jsonl") else {
            return StatisticsCodexAppendRead(result: try StatisticsImporter.read(url, source: "codex"), checkpoint: nil, validatedPrefixBytes: 0, decodedBytes: 0)
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw NativeFailure("Usage ledger is unavailable or linked") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NativeFailure("Usage ledger must be a regular file") }
        let before = StatisticsCodexFileStamp(info)
        var buffer = [UInt8](repeating: 0, count: 1 << 20), hasher = SHA256()
        var accepted: StatisticsCodexCheckpoint?
        var acceptedTail = Data()
        if let checkpoint, checkpoint.path == url.path, before.sameFile(as: checkpoint.stamp), before.size > checkpoint.length {
            var remaining = checkpoint.length
            let tailStart = checkpoint.length - Int64(checkpoint.tailBytes)
            while remaining > 0 {
                try Task.checkCancellation()
                let count = Darwin.read(fd, &buffer, Int(min(remaining, Int64(buffer.count))))
                if count < 0 && errno == EINTR { continue }
                guard count >= 0 else { throw NativeFailure("Usage ledger read failed") }
                if count == 0 { break }
                hasher.update(data: Data(buffer.prefix(count)))
                let offset = checkpoint.length - remaining
                let start = max(0, tailStart - offset)
                if start < Int64(count) { acceptedTail.append(contentsOf: buffer[Int(start)..<count]) }
                remaining -= Int64(count)
            }
            let prefixHasher = hasher
            if remaining == 0, Array(prefixHasher.finalize()) == checkpoint.digest { accepted = checkpoint }
        }
        if accepted == nil {
            guard lseek(fd, 0, SEEK_SET) == 0 else { throw NativeFailure("Usage ledger cannot be reread") }
            hasher = SHA256(); acceptedTail = Data()
        }
        // Isolated tests can mutate their own file at this exact open-FD
        // boundary. Production callers omit the synchronous observation seam.
        if accepted != nil { try afterPrefixValidation?() }
        let (first, stable) = try parse(fd, url: url, before: before, checkpoint: accepted, tail: acceptedTail, hasher: hasher, buffer: &buffer)
        if accepted != nil, !stable {
            // Concurrent appends or replacement cannot authorize cached state.
            // Drain a fresh full read on the already owned descriptor, matching
            // the ordinary reader even if the pathname has since disappeared.
            guard lseek(fd, 0, SEEK_SET) == 0 else { throw NativeFailure("Usage ledger cannot be reread") }
            guard fstat(fd, &info) == 0 else { throw NativeFailure("Usage ledger is unavailable") }
            return try parse(fd, url: url, before: StatisticsCodexFileStamp(info), checkpoint: nil, hasher: SHA256(), buffer: &buffer).0
        }
        return first
    }

    private static func parse(_ fd: Int32, url: URL, before: StatisticsCodexFileStamp,
                              checkpoint: StatisticsCodexCheckpoint?, tail initialTail: Data = Data(), hasher initialHasher: SHA256,
                              buffer: inout [UInt8]) throws -> (StatisticsCodexAppendRead, Bool) {
        let reader = checkpoint.map { StatisticsCodexReader(snapshot: $0.state) } ?? StatisticsCodexReader()
        var hasher = initialHasher, tail = initialTail
        var length = checkpoint?.length ?? 0, decodedBytes = Int64(tail.count)
        let decoder = JSONDecoder()
        let previous: StatisticsReadResult? = checkpoint.map {
            let old = StatisticsCodexReader(snapshot: $0.state)
            if !initialTail.isEmpty, let row = try? decoder.decode(StatisticsEnvelope.self, from: initialTail).value { old.push(row) }
            return old.finish()
        }
        func push(_ bytes: Data) { if let row = try? decoder.decode(StatisticsEnvelope.self, from: bytes).value { reader.push(row) } }
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw NativeFailure("Usage ledger read failed") }
            let bytes = Data(buffer.prefix(count)); hasher.update(data: bytes)
            length += Int64(count); decodedBytes += Int64(count); tail.append(bytes)
            let newlines = tail.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Int] in
                guard let base = bytes.baseAddress else { return [] }
                var cursor = 0, offsets: [Int] = []
                while cursor < bytes.count, let end = memchr(base.advanced(by: cursor), 10, bytes.count - cursor) {
                    let index = base.distance(to: end); offsets.append(index); cursor = index + 1
                }
                return offsets
            }
            var start = tail.startIndex
            for distance in newlines {
                let end = tail.index(tail.startIndex, offsetBy: distance)
                push(Data(tail[start..<end])); start = tail.index(after: end)
            }
            if start != tail.startIndex { tail.removeSubrange(tail.startIndex..<start) }
        }
        // Copy the value state before the provisional EOF row, not the reader
        // reference. Retain only the tail length, not its potentially sensitive
        // body bytes. A later prefix-validation pass rereads that tail.
        let state = reader.snapshot()
        var candidate: StatisticsCodexCheckpoint?
        var after = stat(), named = stat()
        let stable = fstat(fd, &after) == 0 && lstat(url.path, &named) == 0
            && StatisticsCodexFileStamp(after) == before && StatisticsCodexFileStamp(named) == before && length == before.size
        if stable, tail.count <= 1 << 20,
           let stateBytes = state.estimatedBytes(limit: 16 << 20), stateBytes <= (16 << 20) - url.path.utf8.count - 512 {
            candidate = StatisticsCodexCheckpoint(path: url.path, stamp: before, digest: Array(hasher.finalize()), tailBytes: tail.count,
                                                   state: state, estimatedBytes: stateBytes + url.path.utf8.count + 512)
        }
        if !tail.isEmpty { push(tail) }
        let result = reader.finish()
        let offset: Int?
        if stable, let previous, previous.records.count <= result.records.count,
           zip(previous.records, result.records).allSatisfy({ $0.matchesBytes(of: $1) }) {
            offset = previous.records.count
        } else { offset = nil }
        return (StatisticsCodexAppendRead(result: result, checkpoint: candidate,
                                          validatedPrefixBytes: checkpoint?.length ?? 0, decodedBytes: decodedBytes,
                                          appendedRecordOffset: offset), stable)
    }
}
