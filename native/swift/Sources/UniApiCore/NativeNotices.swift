import Foundation

public enum NativeNoticeKind: String, Sendable { case info, success, error }

public struct NativeNotice: Identifiable, Equatable, Sendable {
    public let id: Int
    public let text: String
    public let kind: NativeNoticeKind
    public let expires: Double
    public var leaving: Double?
}

/// A clock-driven queue keeps overflow, dismissal and timeout on the same exit
/// path. Keeping expired rows for the fade also prevents an entrance dismissal
/// from making the surrounding stack jump.
public struct NativeNoticeQueue: Sendable {
    public private(set) var rows: [NativeNotice] = []
    private var sequence = 0
    public static let fadeDuration = 0.16
    public init() {}
    public var nextDeadline: Double? {
        rows.map { $0.leaving.map { $0 + Self.fadeDuration } ?? $0.expires }.min()
    }
    @discardableResult public mutating func push(_ text: String, kind: NativeNoticeKind = .info, now: Double) -> Int? {
        advance(now: now)
        guard now.isFinite, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Concurrent service failures can repeat one diagnostic. Keep its first
        // lifetime instead of perpetually postponing dismissal.
        if kind == .error, rows.contains(where: { $0.kind == kind && $0.text == text && $0.leaving == nil }) { return nil }
        sequence += 1
        rows.append(.init(id: sequence, text: text, kind: kind, expires: now + (kind == .error ? 6 : 3.2)))
        for id in rows.filter({ $0.leaving == nil }).dropLast(4).map(\.id) { dismiss(id, now: now) }
        return sequence
    }
    public mutating func dismiss(_ id: Int, now: Double) {
        guard now.isFinite, let i = rows.firstIndex(where: { $0.id == id }), rows[i].leaving == nil else { return }
        rows[i].leaving = now
    }
    public mutating func advance(now: Double) {
        guard now.isFinite else { return }
        for i in rows.indices where rows[i].leaving == nil && rows[i].expires <= now { rows[i].leaving = rows[i].expires }
        rows.removeAll { $0.leaving.map { now >= $0 + Self.fadeDuration } ?? false }
    }
}
