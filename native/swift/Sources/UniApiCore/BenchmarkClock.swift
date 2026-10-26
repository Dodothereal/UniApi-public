import Foundation

/// Formatters keep fixed options and all access is serialized. Reconstructing
/// one for each comparison made sorting a small ledger take seconds.
final class BenchmarkClock: @unchecked Sendable {
    static let shared = BenchmarkClock()
    private let lock = NSLock()
    private let fraction = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    private var values: [String: Double] = [:]
    private init() {
        fraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        whole.formatOptions = [.withInternetDateTime]
    }
    func timestamp(_ text: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        if let value = values[text] { return value }
        let value = (fraction.date(from: text) ?? whole.date(from: text))?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
        if text.utf8.count <= 256 {
            if values.count >= 4096 { values.removeAll(keepingCapacity: true) }
            values[text] = value
        }
        return value
    }
    func iso(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return fraction.string(from: date)
    }
}
