import Foundation

/// A closed window retains one destination's draft. Quit deliberately discards
/// that destination while the independently owned Core work keeps running.
package struct NativePresentationState: Equatable {
    package private(set) var visible: Bool
    package private(set) var retainsPage: Bool
    package private(set) var generation: UInt64 = 0

    package init(visible: Bool) { self.visible = visible; retainsPage = visible }
    package mutating func show() { visible = true; retainsPage = true }
    package mutating func close() { visible = false }
    package mutating func discard() { visible = false; retainsPage = false; generation &+= 1 }
}

package enum NativePageActivityPolicy {
    package static func active(presented: Bool, visible: Bool, miniaturized: Bool,
                               appHidden: Bool, exposed: Bool, ownedSheetVisible: Bool) -> Bool {
        presented && visible && !miniaturized && !appHidden && (exposed || ownedSheetVisible)
    }
}

package struct NativePageActivation: Equatable {
    package private(set) var active: Bool
    package private(set) var generation: UInt64 = 0
    package init(active: Bool = true) { self.active = active }
    package mutating func setActive(_ next: Bool) {
        guard next != active else { return }
        active = next; generation &+= 1
    }
}

@MainActor package final class NativePagePanelLease {
    package private(set) var valid = true
    package init() {}
    package func invalidate() { valid = false }
    package func consume() -> Bool {
        guard valid else { return false }; valid = false; return true
    }
}

/// Both task dispatch and SwiftUI change delivery enter this same synchronous
/// barrier. Their relative order cannot stop a newly resumed listener, and a
/// delayed callback cannot rewind an already newer activity generation.
@MainActor package final class NativePageWorkOwner {
    private var current: NativePageActivation?
    private var stopped = false
    package init() {}
    @discardableResult package func synchronize(_ next: NativePageActivation, reads: NativePageReadScope?, suspended: () -> Void) -> Bool {
        if let current, next.generation < current.generation { return false }
        if current != next {
            if current != nil && !stopped || !next.active { reads?.suspend(); suspended() }
            current = next; stopped = !next.active
            if next.active { reads?.resume() }
        } else if stopped && next.active {
            stopped = false; reads?.resume()
        }
        return next.active && !stopped
    }
    package func suspend(_ expected: NativePageActivation, reads: NativePageReadScope?, suspended: () -> Void) {
        guard current == expected, !stopped else { return }
        stopped = true; reads?.suspend(); suspended()
    }
}

/// Reads have separate lanes so a history refresh cannot supersede a status
/// read. Suspension rejects both stale successes and errors, even when a service
/// finishes an await after its caller was cancelled. Commands keep their own
/// service ownership and must not be run through this read-only admission gate.
@MainActor package final class NativePageReadScope {
    package struct Ticket {
        fileprivate let lifetime: UUID
        fileprivate let lane: String
        fileprivate let sequence: UInt64
    }
    private var lifetime = UUID()
    private var sequences: [String: UInt64] = [:]
    package private(set) var active = true

    package init() {}
    package func resume() {
        guard !active else { return }
        active = true; lifetime = UUID(); sequences.removeAll()
    }
    package func suspend() {
        guard active else { return }
        active = false; lifetime = UUID(); sequences.removeAll()
    }
    package func begin(_ lane: String = "page") -> Ticket? {
        guard active, !Task.isCancelled else { return nil }
        let next = (sequences[lane] ?? 0) &+ 1; sequences[lane] = next
        return Ticket(lifetime: lifetime, lane: lane, sequence: next)
    }
    package func accepts(_ ticket: Ticket) -> Bool {
        active && !Task.isCancelled && ticket.lifetime == lifetime && sequences[ticket.lane] == ticket.sequence
    }
    package func invalidate(_ lane: String) { sequences[lane] = (sequences[lane] ?? 0) &+ 1 }
}
