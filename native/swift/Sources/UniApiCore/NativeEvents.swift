import Foundation

public struct NativeEvent: Sendable {
    public var topic: String
    public var data: JSONValue
    public var timestamp: Double
}

public actor NativeEvents {
    private var consumers: [UUID: AsyncStream<NativeEvent>.Continuation] = [:]
    public init() {}
    public func stream() -> AsyncStream<NativeEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            consumers[id] = continuation
            continuation.onTermination = { [weak self] _ in Task { await self?.remove(id) } }
        }
    }
    private func remove(_ id: UUID) { consumers.removeValue(forKey: id) }
    public func publish(_ topic: String, _ data: JSONValue) {
        let event = NativeEvent(topic: topic, data: data, timestamp: Date().timeIntervalSince1970 * 1000)
        for consumer in consumers.values { consumer.yield(event) }
    }
}
