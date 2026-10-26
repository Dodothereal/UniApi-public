import UniApiCore

// Share the production models with headless tests without constructing an app
// runtime, registering jobs or substituting copied model source.
protocol NativeBenchmarkModelService: Sendable {
    func start() async throws
    func handle(_ operation: String, input: JSONObject) async throws -> JSONValue
}

extension NativeBenchmarkService: NativeBenchmarkModelService {}
