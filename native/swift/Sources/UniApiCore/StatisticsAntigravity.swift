import Foundation

enum StatisticsWireValue { case integer(UInt64), bytes(Data) }
struct StatisticsWire {
    var fields: [Int: [StatisticsWireValue]] = [:]
    init(_ data: Data = Data()) throws {
        let data = [UInt8](data); var at = 0
        while at < data.count {
            let tag = try Self.varint(data, &at), field = Int(tag >> 3), kind = tag & 7
            guard field > 0 else { throw NativeFailure("Invalid Antigravity protobuf field") }
            let value: StatisticsWireValue
            if kind == 0 { value = .integer(try Self.varint(data, &at)) }
            else if [1, 2, 5].contains(kind) {
                let length = kind == 2 ? try Self.varint(data, &at) : kind == 1 ? 8 : 4
                guard length <= UInt64(data.count - at) else { throw NativeFailure("Truncated Antigravity protobuf field") }
                value = .bytes(Data(data[at..<(at + Int(length))])); at += Int(length)
            } else { throw NativeFailure("Unsupported Antigravity protobuf type") }
            fields[field, default: []].append(value)
        }
    }
    static func varint(_ data: [UInt8], _ at: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in 0..<10 {
            guard at < data.count else { throw NativeFailure("Truncated Antigravity varint") }
            let byte = data[at]; at += 1
            guard shift < 9 || byte <= 1 else { throw NativeFailure("Antigravity varint overflow") }
            value |= UInt64(byte & 127) << (shift * 7)
            if byte < 128 { return value }
        }
        throw NativeFailure("Antigravity varint overflow")
    }
    func data(_ field: Int) -> Data { if case .bytes(let b) = fields[field]?.first { return b }; return Data() }
    func text(_ field: Int) -> String { String(decoding: data(field), as: UTF8.self) }
    func number(_ field: Int) -> Double { if case .integer(let n) = fields[field]?.first, n <= 9_007_199_254_740_991 { return Double(n) }; return 0 }
    func child(_ field: Int) throws -> StatisticsWire { try StatisticsWire(data(field)) }
    var timestamp: Double { number(1) * 1000 + floor(number(2) / 1_000_000) }
    var duration: Double? {
        let seconds = fields[1]?.first ?? .integer(0), nanos = fields[2]?.first ?? .integer(0)
        guard case .integer(let s) = seconds, case .integer(let n) = nanos,
              s <= 9_007_199_254_740_991, n < 1_000_000_000 else { return nil }
        return Double(s) * 1000 + Double(n) / 1_000_000
    }
    func indices() throws -> [Int] {
        var out: [Int] = []
        for value in fields[2] ?? [] {
            switch value {
            case .integer(let n): if n <= UInt64(Int.max) { out.append(Int(n)) }
            case .bytes(let bytes): let b = [UInt8](bytes); var at = 0; while at < b.count { let n = try Self.varint(b, &at); if n <= UInt64(Int.max) { out.append(Int(n)) } }
            }
        }
        return out
    }
}

extension StatisticsImporter {
    static func generation(_ data: Data, steps: [Int: Data], session: String, project: String, sidechain: Bool) throws -> StatisticsUsage? {
        let gen = try StatisticsWire(data), chat = try gen.child(1), usage = try chat.child(4)
        let input = usage.number(2), output = usage.number(3), read = usage.number(5), write = usage.number(4)
        guard input + output + read + write > 0 else { return nil }
        var ts = try chat.child(9).child(4).timestamp
        for idx in try gen.indices() where ts == 0 { ts = try StatisticsWire(steps[idx] ?? Data()).child(1).timestamp }
        guard statisticsValidDate(ts) else { return nil }
        let model = [chat.text(19), chat.text(22), chat.text(21)].first { !$0.isEmpty } ?? "unknown (model \(Int(chat.number(3))))"
        let id = usage.text(11).isEmpty ? usage.text(7) : usage.text(11)
        guard !id.isEmpty else { return nil }
        var e = StatisticsUsage(id: "antigravity:\(id)", source: "antigravity", ts: ts, model: model)
        e.project = project; e.session = "antigravity:\(session)"; e.sidechain = sidechain
        e.input = input; e.output = output; e.cacheRead = read; e.cacheWrite = write; e.thinking = min(output, usage.number(9)); e.timing = "recorded"
        // Damaged optional clocks cannot invalidate the strict usage envelope
        // or the other clock. Only each nested Duration decode is optional.
        let wait = chat.fields[11] != nil ? (try? chat.child(11).duration) : nil
        let stream = chat.fields[12] != nil ? (try? chat.child(12).duration) : nil
        // Field 12 belongs to this generation's output and excludes its
        // first-token wait. It remains usable when field 11 is unavailable.
        if let stream, stream.isFinite, stream > 0, output > 0 {
            e.streamDurationMs = stream; e.streamOutputTokens = output; e.streamTiming = "antigravity-stream-duration"
        }
        if let wait, let stream, wait + stream > 0 { e.durationMs = wait + stream }
        return e
    }
    static func antigravity(_ url: URL) throws -> StatisticsReadResult {
        let db = try StatisticsSourceDatabase(url)
        let metaRow = try db.rows("SELECT data FROM trajectory_metadata_blob LIMIT 1").first
        let meta = try StatisticsWire(Data(base64Encoded: metaRow?["data"]?.string ?? "") ?? Data())
        let trajectory = try db.rows("SELECT trajectory_id FROM trajectory_meta LIMIT 1").first?["trajectory_id"]?.string
        let uri = meta.text(7).isEmpty ? try meta.child(1).text(1) : meta.text(7)
        let project = uri.hasPrefix("file:") ? URL(string: uri)?.path ?? uri : uri.isEmpty ? "unknown" : uri
        var steps: [Int: Data] = [:]
        for r in try db.rows("SELECT idx,metadata FROM steps") { steps[r["idx"]?.int ?? 0] = Data(base64Encoded: r["metadata"]?.string ?? "") ?? Data() }
        var result = StatisticsReadResult()
        for r in try db.rows("SELECT data FROM gen_metadata ORDER BY idx") {
            if let e = try generation(Data(base64Encoded: r["data"]?.string ?? "") ?? Data(), steps: steps, session: trajectory ?? url.deletingPathExtension().lastPathComponent, project: project, sidechain: !meta.text(5).isEmpty || !meta.data(8).isEmpty) { result.records.append(e) }
            else { result.excluded += 1 }
        }
        return result
    }
}
