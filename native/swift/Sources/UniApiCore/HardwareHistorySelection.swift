import Foundation

/// UI query identity travels with each response: changing a range must never
/// offer the preceding range's data for display or export while a read is held.
public struct NativeFanHistorySelection: Sendable {
    private var scope: String?
    private var request: UUID?
    private var value: JSONValue = .null
    private var error: String?
    public init() {}
    public mutating func begin(scope: String) -> UUID {
        if self.scope != scope { value = .null; error = nil }
        self.scope = scope
        let id = UUID(); request = id; return id
    }
    @discardableResult public mutating func resolve(_ id: UUID, value: JSONValue) -> Bool {
        guard request == id else { return false }
        self.value = value; error = nil; return true
    }
    @discardableResult public mutating func reject(_ id: UUID, message: String) -> Bool {
        guard request == id else { return false }
        error = message; return true
    }
    public func value(for scope: String) -> JSONValue { self.scope == scope ? value : .null }
    public func error(for scope: String) -> String? { self.scope == scope ? error : nil }
}
