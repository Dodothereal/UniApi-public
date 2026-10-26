import Foundation

/// yt-dlp writes progress to stderr, whose read chunks need not be whole lines.
/// Keep a bounded partial line and only the newest pending percentage.
final class NativeTranscriptionDownloadProgress: @unchecked Sendable {
    let stream: AsyncStream<Double>
    private let continuation: AsyncStream<Double>.Continuation
    private let lock = NSLock()
    private struct Line { var bytes: [UInt8] = []; var discarding = false }
    private var lines: [Bool: Line] = [:]
    private var finished = false
    init() {
        let pair = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func receive(_ bytes: Data, isError: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        var line = lines[isError] ?? Line()
        for byte in bytes {
            if byte == 10 || byte == 13 { flush(&line) }
            else if !line.discarding {
                if line.bytes.count < 4096 { line.bytes.append(byte) }
                else { line.bytes.removeAll(keepingCapacity: true); line.discarding = true }
            }
        }
        lines[isError] = line
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        for key in [false, true] { var line = lines[key] ?? Line(); flush(&line) }
        lines.removeAll(); finished = true; continuation.finish()
    }
    private func flush(_ line: inout Line) {
        defer { line.bytes.removeAll(keepingCapacity: true); line.discarding = false }
        guard !line.discarding else { return }
        let text = String(decoding: line.bytes, as: UTF8.self)
        guard let range = text.range(of: "\\[download\\]\\s+([\\d.]+)%", options: .regularExpression),
              let percent = Double(text[range].replacingOccurrences(of: "[^0-9.]", with: "", options: .regularExpression)), percent.isFinite, (0...100).contains(percent) else { return }
        continuation.yield(percent)
    }
}
