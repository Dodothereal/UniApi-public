import UniApiCore

// The production model and its tests share this boundary; no Arena engine or
// runtime is constructed by an injected model fixture.
protocol NativeArenaModelService: Sendable {
    func handle(_ operation: String, input: JSONObject) async throws -> JSONValue
}

extension NativeArenaService: NativeArenaModelService {}
