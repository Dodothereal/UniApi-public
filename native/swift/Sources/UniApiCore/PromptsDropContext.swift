import Foundation

/// One dialog owns every callback in a drop group. Changing payload context
/// invalidates the whole group rather than invalidating siblings per item.
public struct NativePromptsDropContext: Sendable {
    public struct Ticket: Equatable, Sendable {
        public let prompt: String
        public let dialog: UUID
        fileprivate let generation: UInt64
    }
    private var generation: UInt64 = 0
    public private(set) var ticket: Ticket?
    public init() {}
    @discardableResult public mutating func begin(prompt: String, dialog: UUID) -> Ticket {
        invalidate()
        let value = Ticket(prompt: prompt, dialog: dialog, generation: generation)
        ticket = value
        return value
    }
    public mutating func invalidate() { generation &+= 1; ticket = nil }
    public func accepts(_ captured: Ticket, prompt: String?, dialog: UUID?, saving: Bool) -> Bool {
        !saving && ticket == captured && captured.prompt == prompt && captured.dialog == dialog
    }
}
