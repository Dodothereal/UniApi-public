import Foundation

/// DSH v0 metadata reader. Transport/decompression belongs to StatisticsImporter.
final class StatisticsDeepSeekReader {
    private struct Header {
        var id: String, project: String
        var seedLength: Int, depth: Int
    }
    private struct Buckets: Equatable {
        var input: Double, output: Double, read: Double, write: Double, thinking: Double
    }
    private struct Sample {
        var usage: StatisticsUsage
        var buckets: Buckets
    }
    private struct Chunk {
        var key: String, time: Double, delta: Bool, valid: Bool
        var finish: String?
        var buckets: Buckets?
    }
    private static let maximum = 9_007_199_254_740_991.0
    private var header: Header?
    private var corrupt = false, nextSeq = 0, excluded = 0
    private var model = "unknown", effort = ""
    private var samples: [String: Sample] = [:], order: [String] = []
    // Only the current attempt's scalar metadata survives ingestion, never text/tool payloads.
    private var chunks: [Int: Chunk] = [:], chunkKey: String?, terminal = false

    func push(_ line: JSONValue) throws {
        guard !corrupt else { throw NativeFailure("DeepSeek session is corrupt") }
        do { try ingest(line) }
        catch { corrupt = true; throw error }
    }

    func finish() throws -> StatisticsReadResult {
        guard !corrupt, let header, nextSeq >= header.seedLength else {
            throw NativeFailure("DeepSeek session header or fork prefix is incomplete or invalid")
        }
        var result = StatisticsReadResult()
        result.excluded = excluded
        for key in order {
            guard let sample = samples[key] else { continue }
            if sample.usage.grand > 0 { result.records.append(sample.usage) }
            else { result.excluded += 1 }
        }
        return result
    }

    private static func integer(_ value: JSONValue, nonnegative: Bool = true) -> Int? {
        guard case .number(let n) = value, n.isFinite, n.rounded(.towardZero) == n,
              abs(n) <= maximum, !nonnegative || n >= 0 else { return nil }
        return Int(n)
    }
    private static func date(_ value: Double) -> Bool {
        value > 0 && value <= 8_640_000_000_000_000
    }
    private static func object(_ value: JSONValue) -> Bool {
        if case .object = value { return true }; return false
    }
    private static func text(_ value: JSONValue) -> String? {
        if case .string(let s) = value { return s }; return nil
    }
    private static func buckets(_ value: JSONValue) -> Buckets? {
        guard object(value), let input = integer(value["inputTokens"]),
              let output = integer(value["outputTokens"]) else { return nil }
        var optional: [Double] = []
        for name in ["cacheReadTokens", "cacheWriteTokens", "reasoningTokens"] {
            if let raw = value.object[name] {
                guard let n = integer(raw) else { return nil }; optional.append(Double(n))
            } else { optional.append(0) }
        }
        guard Double(input) + Double(output) + optional[0] + optional[1] <= maximum else { return nil }
        return Buckets(input: Double(input), output: Double(output), read: optional[0],
                       write: optional[1], thinking: min(Double(output), optional[2]))
    }

    private func ingest(_ line: JSONValue) throws {
        guard Self.object(line), let type = Self.text(line["type"]), !type.isEmpty else {
            throw NativeFailure("Invalid DeepSeek storage record")
        }
        if type == "session" {
            guard header == nil, Self.integer(line["version"]) == 0,
                  let id = Self.text(line["id"]), !id.isEmpty,
                  let created = Self.integer(line["createdAt"]), Self.date(Double(created)),
                  let depth = Self.integer(line["delegationDepth"]) else {
                throw NativeFailure("Unsupported or malformed DeepSeek session header")
            }
            if let cwd = line.object["cwd"], Self.text(cwd) == nil {
                throw NativeFailure("Malformed DeepSeek session directory metadata")
            }
            var seed = 0
            if let value = line.object["seedLength"] {
                guard let n = Self.integer(value) else { throw NativeFailure("Malformed DeepSeek fork boundary") }
                seed = n
            }
            header = Header(id: id, project: line["cwd"].string.isEmpty ? "unknown" : line["cwd"].string,
                            seedLength: seed, depth: depth)
            return
        }
        guard header != nil else { throw NativeFailure("DeepSeek header must precede events") }
        if ["text-chunks", "reasoning-chunks", "tool-call-chunks"].contains(type) {
            try packed(line, type: type); return
        }
        guard !type.hasSuffix("-chunks"), line.object["seq0"] == nil, line.object["time0"] == nil,
              line.object["version"] == nil else { throw NativeFailure("Unsupported DeepSeek packed record") }
        try event(line)
    }

    private func packed(_ line: JSONValue, type: String) throws {
        guard Set(line.object.keys) == Set(["type", "seq0", "time0", "data"]),
              let seq = Self.integer(line["seq0"]), let initial = Self.integer(line["time0"], nonnegative: false),
              Self.object(line["data"]) else { throw NativeFailure("Malformed DeepSeek packed envelope") }
        let data = line["data"], tool = type == "tool-call-chunks"
        var keys = Set(["turn", "step", "index", "dt", tool ? "args" : "texts"])
        if tool {
            keys.insert("id")
            guard Self.text(data["id"]) != nil else { throw NativeFailure("Malformed DeepSeek packed tool identity") }
            if data.object["name"] != nil {
                keys.insert("name")
                guard Self.text(data["name"]) != nil else { throw NativeFailure("Malformed DeepSeek packed tool name") }
            }
        }
        guard Set(data.object.keys) == keys, Self.integer(data["turn"]) != nil,
              Self.integer(data["step"]) != nil, Self.integer(data["index"]) != nil,
              case .array(let payload) = data[tool ? "args" : "texts"], !payload.isEmpty,
              case .array(let gaps) = data["dt"], gaps.count == payload.count - 1,
              payload.allSatisfy({ Self.text($0) != nil }) else { throw NativeFailure("Malformed DeepSeek packed data") }
        var time = initial
        for i in payload.indices {
            if i > 0 {
                guard let gap = Self.integer(gaps[i - 1], nonnegative: false),
                      abs(Double(time) + Double(gap)) <= Self.maximum else {
                    throw NativeFailure("Invalid DeepSeek packed clock")
                }
                time += gap
            }
            guard Double(seq) + Double(i) <= Self.maximum else { throw NativeFailure("DeepSeek packed sequence overflow") }
            var chunk: JSONValue = ["type": .string(tool ? "tool-call-delta" : type == "text-chunks" ? "text-delta" : "reasoning-delta"),
                                    "index": data["index"]]
            chunk[tool ? "argumentsDelta" : "text"] = payload[i]
            if tool { chunk["id"] = data["id"]; if data.object["name"] != nil { chunk["name"] = data["name"] } }
            try event(["type": "assistant/chunk", "seq": .number(Double(seq + i)), "time": .number(Double(time)),
                       "data": ["turn": data["turn"], "step": data["step"], "chunk": chunk]])
        }
    }

    private func event(_ line: JSONValue) throws {
        guard let seq = Self.integer(line["seq"]), seq == nextSeq,
              let time = Self.integer(line["time"], nonnegative: false),
              line.object["data"] != nil else { throw NativeFailure("Malformed or noncontiguous DeepSeek event") }
        nextSeq += 1
        let type = line["type"].string, data = line["data"]
        if type == "request/header" {
            let config = data["header"]["config"]
            guard Self.object(config), let value = Self.text(config["model"]), !value.isEmpty else {
                throw NativeFailure("Malformed DeepSeek request metadata")
            }
            model = value; effort = config["reasoningEffort"].string; return
        }
        if type == "request/context" {
            guard Self.object(data), let value = Self.text(data["model"]), !value.isEmpty else {
                throw NativeFailure("Malformed DeepSeek request context")
            }
            model = value; return
        }
        guard type == "assistant/chunk" || type == "assistant/message" else { return }
        guard Self.object(data), let turn = Self.integer(data["turn"]), let step = Self.integer(data["step"]) else {
            throw NativeFailure("Malformed DeepSeek assistant metadata")
        }
        guard let header, seq >= header.seedLength else { return }
        let key = "\(turn):\(step)", at = Double(time)
        if type == "assistant/chunk" {
            if terminal || chunkKey != key { chunks.removeAll(keepingCapacity: true); terminal = false; chunkKey = key }
            let chunk = data["chunk"], kind = chunk["type"].string
            var valid = Self.object(chunk), delta = false
            switch kind {
            case "text-delta", "reasoning-delta":
                valid = valid && Self.integer(chunk["index"]) != nil && Self.text(chunk["text"]) != nil
                delta = valid && !chunk["text"].string.isEmpty
            case "tool-call-delta":
                valid = valid && Self.integer(chunk["index"]) != nil && Self.text(chunk["argumentsDelta"]) != nil
                delta = valid && !chunk["argumentsDelta"].string.isEmpty
            case "block-start", "block-end": valid = valid && Self.integer(chunk["index"]) != nil
            case "usage": valid = valid && Self.buckets(chunk["usage"]) != nil
            case "finish": valid = valid && Self.text(chunk["reason"]["kind"]) != nil
            default: valid = false
            }
            let usage = kind == "usage" ? Self.buckets(chunk["usage"]) : nil
            chunks[seq] = Chunk(key: key, time: at, delta: delta, valid: valid,
                                finish: kind == "finish" ? chunk["reason"]["kind"].string : nil, buckets: usage)
            if kind == "usage" { update(key, at: at, value: chunk["usage"]) }
            if kind == "finish" { terminal = true }
            return
        }
        if let value = data.object["usage"] { update(key, at: at, value: value) }
        if var sample = samples[key] {
            let namedModel = data["message"]["source"]["model"].string
            if !namedModel.isEmpty { sample.usage.model = namedModel }
            clearStream(&sample.usage)
            if data.object["usage"] == nil || Self.buckets(data["usage"]) != nil,
               let duration = stream(line["sourceEventSeqs"], key: key, messageSeq: seq, at: at, usage: sample.buckets) {
                sample.usage.streamDurationMs = duration
                sample.usage.streamOutputTokens = sample.usage.output
                sample.usage.streamTiming = "dsh-host-chunk-clock"
            }
            samples[key] = sample
        }
        chunks.removeAll(keepingCapacity: true); chunkKey = nil; terminal = false
    }

    private func clearStream(_ row: inout StatisticsUsage) {
        row.streamDurationMs = nil; row.streamOutputTokens = nil; row.streamTiming = nil
    }
    private func update(_ key: String, at: Double, value: JSONValue) {
        guard let header, Self.date(at), let usage = Self.buckets(value) else {
            excluded += 1
            if var old = samples[key] { clearStream(&old.usage); samples[key] = old }
            return
        }
        var row = StatisticsUsage(id: "dsh:\(header.id):\(key)", source: "dsh", ts: at, model: model)
        row.project = header.project; row.session = "dsh:\(header.id)"; row.sidechain = header.depth > 0; row.effort = effort
        row.input = usage.input; row.output = usage.output; row.cacheRead = usage.read
        row.cacheWrite = usage.write; row.thinking = usage.thinking
        // Response duration and raw stream clocks are distinct; no step/request fallback.
        if samples[key] == nil { order.append(key) }
        samples[key] = Sample(usage: row, buckets: usage)
    }
    private func stream(_ references: JSONValue, key: String, messageSeq: Int, at: Double, usage: Buckets) -> Double? {
        guard chunkKey == key, usage.output > 0, Self.date(at), case .array(let raw) = references,
              !raw.isEmpty, raw.count == chunks.count else { return nil }
        var seen = Set<Int>(), previousSeq = -1, previousTime = -Double.infinity
        var first: Double?, last: Double?, deltas = 0, reported: Buckets?
        for (offset, value) in raw.enumerated() {
            guard let seq = Self.integer(value), seq < messageSeq, seq > previousSeq, seen.insert(seq).inserted,
                  let chunk = chunks[seq], chunk.key == key, chunk.valid, Self.date(chunk.time),
                  chunk.time >= previousTime else { return nil }
            if let finish = chunk.finish {
                guard offset == raw.count - 1, ["stop", "tool-calls", "max-tokens"].contains(finish) else { return nil }
            } else if offset == raw.count - 1 { return nil }
            if let buckets = chunk.buckets { reported = buckets }
            if chunk.delta { first = first ?? chunk.time; last = chunk.time; deltas += 1 }
            previousSeq = seq; previousTime = chunk.time
        }
        guard seen == Set(chunks.keys), at >= previousTime, reported == usage, deltas >= 2,
              let first, let last, last > first else { return nil }
        return last - first
    }
}
