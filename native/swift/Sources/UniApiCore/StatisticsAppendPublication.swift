import Foundation

extension StatisticsUsage {
    /// Swift String equality normalizes Unicode; SQLite and the importer also
    /// expose the chosen spelling and floating-point bits to downstream folds.
    func matchesBytes(of other: Self) -> Bool {
        func same(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }
        func optional(_ a: String?, _ b: String?) -> Bool {
            switch (a, b) { case (nil, nil): return true; case let (a?, b?): return same(a, b); default: return false }
        }
        return same(id, other.id) && same(source, other.source) && same(model, other.model)
            && same(project, other.project) && same(session, other.session) && same(effort, other.effort)
            && same(rawDay, other.rawDay) && sidechain == other.sidechain
            && optional(timing, other.timing) && optional(streamTiming, other.streamTiming)
            && [ts, input, output, thinking, cacheWrite, cacheRead, webSearch, webFetch].map(\.bitPattern)
                == [other.ts, other.input, other.output, other.thinking, other.cacheWrite, other.cacheRead, other.webSearch, other.webFetch].map(\.bitPattern)
            && [durationMs, streamDurationMs, streamOutputTokens].map { $0?.bitPattern }
                == [other.durationMs, other.streamDurationMs, other.streamOutputTokens].map { $0?.bitPattern }
    }
}

/// In-process membership with no false negatives. A positive is uncertainty,
/// never permission to drop a row: the caller falls back to full SQL assembly.
struct StatisticsRecordMembership {
    private var words: [UInt64]
    init(wordCount: Int = 131_072) { words = .init(repeating: 0, count: max(1, wordCount)) }
    private func positions(_ key: String) -> [Int] {
        // String's hash shares its canonical equality with the existing Set.
        // This filter is never serialized or shared with another process.
        var value = UInt64(bitPattern: Int64(key.hashValue))
        return (0..<4).map { _ in
            value &+= 0x9e3779b97f4a7c15
            var z = value
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return Int((z ^ (z >> 31)) % UInt64(words.count * 64))
        }
    }
    func mayContain(_ key: String) -> Bool {
        positions(key).allSatisfy { words[$0 >> 6] & (1 << ($0 & 63)) != 0 }
    }
    mutating func insert(_ key: String) {
        for position in positions(key) { words[position >> 6] |= 1 << (position & 63) }
    }
}

/// Bounded provenance for the existing long-string interner. All four fields
/// share one namespace, just as they do in the full path. Eviction would lose
/// precedence evidence, so budget exhaustion disables reuse for the generation.
struct StatisticsInternerOrigins {
    private(set) var entries: [String: StatisticsAppendPublication.Representative]?
    private(set) var payloadBytes = 0
    let maximumBytes: Int
    init(enabled: Bool = true, maximumBytes: Int = 16 << 20) {
        entries = enabled && maximumBytes >= 0 ? [:] : nil; self.maximumBytes = maximumBytes
    }
    mutating func note(_ key: String, representative: String, path: String) {
        guard entries != nil else { return }
        let cost = key.utf8.count + representative.utf8.count + path.utf8.count + 256
        guard cost <= maximumBytes - payloadBytes else { entries = nil; return }
        payloadBytes += cost
        entries![key] = StatisticsAppendPublication.Representative(value: representative, firstPath: path)
        if entries!.capacity > (maximumBytes - payloadBytes) / 96 { entries = nil }
    }
}

struct StatisticsAppendPublication {
    struct Representative { let value: String; var firstPath: String }
    private var membership: StatisticsRecordMembership
    private var representatives: [String: Representative]
    private let maximumBytes: Int
    private var estimatedBytes: Int
    let schema: String
    var generation: Int = -1

    init?(keys: Set<String>, interned: [String: String], firstPaths: [String: String], schema: String,
          maximumBytes: Int = 16 << 20, bloomWords: Int = 131_072) {
        var origins = StatisticsInternerOrigins(maximumBytes: maximumBytes)
        for (key, value) in interned {
            guard let path = firstPaths[key] else { return nil }
            origins.note(key, representative: value, path: path)
            guard origins.entries != nil else { return nil }
        }
        self.init(keys: keys, origins: origins, schema: schema, bloomWords: bloomWords)
    }
    init?(keys: Set<String>, origins: StatisticsInternerOrigins, schema: String, bloomWords: Int = 131_072) {
        guard let entries = origins.entries else { return nil }
        var filter = StatisticsRecordMembership(wordCount: bloomWords)
        for key in keys { filter.insert(key) }
        membership = filter; representatives = entries; estimatedBytes = origins.payloadBytes
        maximumBytes = origins.maximumBytes; self.schema = schema
    }

    mutating func admit(_ record: StatisticsUsage, path: String, after maximumTimestamp: Double) -> StatisticsUsage? {
        guard record.source == "codex", record.ts.isFinite, record.ts > maximumTimestamp else { return nil }
        let key = record.source + ":" + record.id
        guard !membership.mayContain(key) else { return nil }
        func canonical(_ value: String) -> String? {
            guard value.utf8.count > 15 else { return value }
            if var entry = representatives[value] {
                if path.utf8.lexicographicallyPrecedes(entry.firstPath.utf8) {
                    guard value.utf8.elementsEqual(entry.value.utf8) else { return nil }
                    // Keeping the old later path is conservative if a longer
                    // spelling would grow retained provenance: future variants
                    // can only cause another full fallback, never false reuse.
                    if path.utf8.count <= entry.firstPath.utf8.count {
                        entry.firstPath = path; representatives[value] = entry
                    }
                }
                return entry.value
            }
            let cost = value.utf8.count * 2 + path.utf8.count + 256
            guard cost <= maximumBytes - estimatedBytes else { return nil }
            estimatedBytes += cost
            representatives[value] = Representative(value: value, firstPath: path)
            // Growth can double the dictionary allocation. The conservative
            // per-entry charge plus this explicit bound covers that boundary.
            guard representatives.capacity <= (maximumBytes - estimatedBytes) / 96 else { return nil }
            return value
        }
        guard let model = canonical(record.model), let project = canonical(record.project),
              let session = canonical(record.session), let effort = canonical(record.effort) else { return nil }
        var result = record
        result.model = model; result.project = project; result.session = session; result.effort = effort
        membership.insert(key)
        return result
    }
}
