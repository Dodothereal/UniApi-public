import Foundation
import NaturalLanguage

public struct NativeAudioPCM: Sendable {
    public static let rate = 16000
    public let data: Data
    public var samples: Int { data.count / 2 }
    public var duration: Double { Double(samples) / Double(Self.rate) }
    public init(data: Data) { self.data = data.count % 2 == 0 ? data : Data(data.dropLast()) }
    public func bounds() -> [Range<Int>] {
        let chunk = 45 * Self.rate, snap = Int(1.5 * Double(Self.rate)), window = 320
        guard samples > 0 else { return [] }
        var cuts = [0]
        data.withUnsafeBytes { buffer in
            for target in stride(from: chunk, to: samples, by: chunk) {
                let low = max(window, target - snap), high = min(samples - window, target + snap)
                if high <= low { cuts.append(min(target, samples)); continue }
                var best = target, bestEnergy = Double.infinity
                for center in stride(from: low, through: high, by: window / 2) {
                    var energy: Double = 0
                    for index in (center - window)..<(center + window) {
                        let sample = Double(Int16(littleEndian: buffer.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                        energy += sample * sample
                    }
                    if energy < bestEnergy { bestEnergy = energy; best = center }
                }
                cuts.append(best)
            }
        }
        cuts.append(samples)
        return zip(cuts, cuts.dropFirst()).compactMap { $0 < $1 ? $0..<$1 : nil }
    }
    public func wav(_ range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= samples, !range.isEmpty else { throw NativeFailure("Invalid audio chunk") }
        let body = data.subdata(in: (range.lowerBound * 2)..<(range.upperBound * 2))
        var header = Data()
        func ascii(_ text: String) { header.append(contentsOf: text.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; withUnsafeBytes(of: &v) { header.append(contentsOf: $0) } }
        ascii("RIFF"); word(UInt32(body.count + 36)); ascii("WAVEfmt ")
        word(UInt32(16)); word(UInt16(1)); word(UInt16(1)); word(UInt32(Self.rate))
        word(UInt32(Self.rate * 2)); word(UInt16(2)); word(UInt16(16)); ascii("data"); word(UInt32(body.count))
        header.append(body); return header
    }
}

public enum NativeTranscriptMetrics {
    public static func words(_ text: String) -> Int {
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text
        var count = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) { count += 1 }
            return true
        }
        return count
    }
    public static func augment(_ row: JSONObject) -> JSONObject {
        var result = row
        let count = words((row["text"] ?? "").string)
        let elapsed = row["transcribe_ms"] ?? .null
        let numeric: Bool
        if case .number = elapsed { numeric = true } else { numeric = false }
        let valid = row["status"]?.string == "done" && numeric && elapsed.double.isFinite && elapsed.double > 0
        result["wordCount"] = .number(Double(count))
        result["transcribe_ms"] = valid ? elapsed : .null
        let rate = valid ? Double(count) * 60000 / elapsed.double : .nan
        result["wordsPerMinute"] = rate.isFinite ? .number(rate) : .null
        return result
    }
}

public struct NativeASRResponse: Sendable {
    public var status: Int
    public var body: Data
    public var retryAfter: TimeInterval?
    public init(status: Int, body: Data, retryAfter: TimeInterval? = nil) { self.status = status; self.body = body; self.retryAfter = retryAfter }
}

public actor NativeWisprASR {
    public typealias Transport = @Sendable (URLRequest) async throws -> NativeASRResponse
    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    private let transport: Transport
    private let sleep: Sleeper
    public init(transport: @escaping Transport, sleep: Sleeper? = nil) {
        self.transport = transport
        self.sleep = sleep ?? { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) }
    }
    public func transcribe(_ pcm: NativeAudioPCM, language: String?, token: String, completed: [Int: String] = [:], progress: @escaping @Sendable (Int, Int, Int?, String?) async throws -> Void) async throws -> JSONValue {
        let ranges = pcm.bounds()
        guard !ranges.isEmpty else { throw NativeFailure("No audio decoded") }
        var outputs = [String?](repeating: nil, count: ranges.count)
        for (index, text) in completed where outputs.indices.contains(index) { outputs[index] = text }
        var done = outputs.compactMap { $0 }.count
        if done > 0 { try await progress(done, ranges.count, nil, nil) }
        let todo = ranges.indices.filter { outputs[$0] == nil }
        // Keep all eight slots busy, rather than waiting for the slowest
        // member of each batch before admitting another chunk.
        try await withThrowingTaskGroup(of: (Int, String?).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                group.addTask { [self] in (index, try await self.attempt(pcm.wav(ranges[index]), language: language, token: token, tries: 5, base: 0.3)) }
            }
            for index in todo.prefix(8) { enqueue(index); next += 1 }
            for try await (index, text) in group {
                if let text { outputs[index] = text; done += 1; try await progress(done, ranges.count, index, text) }
                if next < todo.count { enqueue(todo[next]); next += 1 }
            }
        }
        for sweep in 0..<4 {
            let missing = outputs.indices.filter { outputs[$0] == nil }
            if missing.isEmpty { break }
            try await sleep(Double(3 + sweep * 4))
            for index in missing {
                try Task.checkCancellation()
                if let text = try await attempt(pcm.wav(ranges[index]), language: language, token: token, tries: 7, base: 0.8) {
                    outputs[index] = text; done += 1; try await progress(done, ranges.count, index, text)
                }
            }
        }
        try Task.checkCancellation()
        let parts = outputs.map { $0 ?? "" }
        let text = parts.joined(separator: " ").replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression).replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let gaps = outputs.indices.filter { outputs[$0] == nil }.map { JSONValue.number(Double(ranges[$0].lowerBound / NativeAudioPCM.rate)) }
        return ["text": .string(text), "parts": .array(parts.map(JSONValue.string)), "gaps": .array(gaps), "totalSec": .number(pcm.duration)]
    }
    private func attempt(_ wav: Data, language: String?, token: String, tries: Int, base: TimeInterval) async throws -> String? {
        var body: JSONValue = ["audio": .string(wav.base64EncodedString()), "prompt": ""]
        if let language, !language.isEmpty { body["language"] = .string(language) }
        var request = URLRequest(url: URL(string: "https://api.wisprflow.ai/llm/asr")!)
        request.httpMethod = "POST"; request.timeoutInterval = 90; request.httpBody = try body.encoded()
        request.setValue("application/json", forHTTPHeaderField: "content-type"); request.setValue(token, forHTTPHeaderField: "authorization")
        for number in 0..<tries {
            try Task.checkCancellation()
            do {
                let response = try await transport(request)
                if response.status == 200 { return (try JSONValue.decode(response.body))["content"].string }
                if response.status == 401 { throw NativeFailure("Wispr Flow session expired (HTTP 401); open Wispr Flow and sign in again") }
                if response.status != 408 && response.status != 429 && response.status < 500 { return nil }
                if number == tries - 1 { return nil }
                let delay = response.retryAfter.flatMap { $0 > 0 && $0.isFinite ? min($0, 15) : nil } ?? base * pow(2, Double(number))
                try await sleep(delay)
            } catch is CancellationError { throw CancellationError() }
            catch let error as NativeFailure { if error.message.contains("HTTP 401") { throw error }; if number == tries - 1 { return nil }; try await sleep(base * pow(2, Double(number))) }
            catch { if number == tries - 1 { return nil }; try await sleep(base * pow(2, Double(number))) }
        }
        return nil
    }
}
