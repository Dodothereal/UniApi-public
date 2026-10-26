/// Local slider interaction only. A returned target is the sole request boundary;
/// callers retain ownership of service admission and recovery.
public struct NativeBatteryTargetInteraction: Sendable {
    public enum Key: Hashable, Sendable { case left, right, up, down, home, end }
    private enum Pointer: Equatable, Sendable { case idle, dragging, cancelled }

    public private(set) var draft: Int?
    public private(set) var pending: Int?
    private var pointer: Pointer = .idle
    private var pointerGeneration: UInt64 = 0
    private var heldKeys: Set<Key> = []
    private var keyboardCancelled = false

    public init() {}

    public static func confirmedTarget(_ raw: Double?) -> Int? {
        guard let raw, raw.isFinite, raw.rounded() == raw, (1...100).contains(raw) else { return nil }
        return Int(raw)
    }

    public var hasPointerSequence: Bool { pointer != .idle }
    public var pointerSequenceID: UInt64? { pointer == .idle ? nil : pointerGeneration }

    public mutating func pointerChanged(to value: Double, current: Int, levels: [Int], enabled: Bool) {
        if pointer == .idle { pointerGeneration &+= 1 }
        guard pointer != .cancelled else { return }
        guard enabled, pending == nil, let next = nearest(value, levels: levels) else {
            cancel()
            pointer = .cancelled
            return
        }
        if pointer == .idle {
            heldKeys.removeAll()
            keyboardCancelled = false
            pointer = .dragging
        }
        draft = next
    }

    public mutating func pointerReleased(at value: Double, current: Int, levels: [Int], enabled: Bool) -> Int? {
        let active = pointer == .dragging
        endPointerSequence()
        guard active, let next = nearest(value, levels: levels) else { return nil }
        return request(next, current: current, levels: levels, enabled: enabled)
    }

    /// Gesture-state reset also covers loss of capture without an onEnded callback.
    public mutating func endPointerSequence() {
        if pointer != .idle { draft = nil }
        pointer = .idle
    }

    /// A deferred capture-loss callback must not clear a later pointer sequence.
    public mutating func endPointerSequence(ifMatching sequence: UInt64) {
        guard pointerSequenceID == sequence else { return }
        endPointerSequence()
    }

    public mutating func keyDown(_ key: Key, repeating: Bool = false, current: Int, levels: [Int], enabled: Bool) {
        guard pointer == .idle else { return }
        // A repeat after blur has no matching press and cannot start a new draft.
        guard !repeating || heldKeys.contains(key) else { return }
        heldKeys.insert(key)
        guard enabled, pending == nil else { cancel(); return }
        guard !keyboardCancelled else { return }
        draft = stepped(key, from: draft ?? current, levels: levels)
    }

    public mutating func keyUp(_ key: Key, current: Int, levels: [Int], enabled: Bool) -> Int? {
        guard heldKeys.remove(key) != nil, heldKeys.isEmpty else { return nil }
        let next = draft
        let cancelled = keyboardCancelled
        draft = nil
        keyboardCancelled = false
        guard !cancelled, pointer == .idle, let next else { return nil }
        return request(next, current: current, levels: levels, enabled: enabled)
    }

    /// Escape and disabled transitions sink the remainder of the current sequence.
    public mutating func cancel() {
        draft = nil
        if pointer != .idle { pointer = .cancelled }
        if !heldKeys.isEmpty { keyboardCancelled = true }
    }

    public mutating func blur() {
        cancel()
        heldKeys.removeAll()
        keyboardCancelled = false
    }

    /// Accessibility adjustments are discrete gestures, with the same request gate.
    public mutating func adjust(_ key: Key, current: Int, levels: [Int], enabled: Bool) -> Int? {
        guard pointer == .idle, heldKeys.isEmpty, let next = stepped(key, from: current, levels: levels) else { return nil }
        return request(next, current: current, levels: levels, enabled: enabled)
    }

    public mutating func commitFinished() { pending = nil }

    private mutating func request(_ next: Int, current: Int, levels: [Int], enabled: Bool) -> Int? {
        guard enabled, pending == nil, next != current, allowed(levels).contains(next) else { return nil }
        pending = next
        return next
    }

    private func allowed(_ levels: [Int]) -> [Int] {
        Array(Set(levels.filter { (1...100).contains($0) })).sorted()
    }

    private func nearest(_ value: Double, levels: [Int]) -> Int? {
        guard value.isFinite else { return nil }
        return allowed(levels).min { abs(Double($0) - value) < abs(Double($1) - value) }
    }

    private func stepped(_ key: Key, from value: Int, levels: [Int]) -> Int? {
        let values = allowed(levels)
        switch key {
        case .home: return values.first
        case .end: return values.last
        case .right, .up: return values.first { $0 > value } ?? values.last
        case .left, .down: return values.last { $0 < value } ?? values.first
        }
    }
}
