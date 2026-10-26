import Foundation

/// Installed older shims can deliver their complete Content-Length body without
/// closing the server side. The native update alone uses the existing HTTP
/// transport's acknowledged client cancellation; legacy EOF proof stays strict.
enum NativeUpdateHealthProbe {
    static func get(timeout: Double, transport: any ShimTransport = ShimURLSessionTransport(),
                    clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) async throws -> JSONValue {
        guard timeout.isFinite, timeout > 0, timeout <= 30 else { throw NativeFailure("Invalid native update health deadline") }
        let began = clock(), deadline = began + timeout
        guard began.isFinite, deadline.isFinite else { throw NativeFailure("Invalid native update health clock") }
        func remaining() throws -> Double {
            try Task.checkCancellation()
            let now = clock()
            guard now.isFinite, now >= began, now < deadline else { throw NativeFailure("Native update health deadline expired") }
            return deadline - now
        }
        func check() throws { _ = try remaining() }
        let request = ShimHTTPRequest(url: URL(string: "http://127.0.0.1:8823/healthz")!, method: "GET",
                                      headers: ["Connection": "close", "Accept": "application/json", "Accept-Encoding": "identity"],
                                      timeout: try remaining())
        let response: ShimUpstream
        do { response = try await transport.open(request) }
        catch { try check(); throw error } // The shared transport drains failed opens.
        do {
            try check()
            guard response.status == 200 else { throw NativeFailure("Native update shim health was not successful") }
            let encoding = response.headers.filter { $0.key.lowercased() == "content-encoding" }.map(\.value)
            guard encoding.count <= 1, encoding.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).lowercased() == "identity" }) else {
                throw NativeFailure("Unsupported native update health encoding")
            }
            // body() always cancels and awaits transport invalidation, including
            // size/cancellation errors. Cleanup may consume the remaining budget.
            let bytes = try await response.body(limit: 65_536)
            try check()
            let value = try JSONValue.decode(bytes)
            try check()
            return value
        } catch {
            // Header rejection occurs before body() owns cleanup. Repeated
            // cancellation/drain after a body error is deliberately idempotent.
            response.cancel(); await response.waitForCompletion()
            try check()
            throw error
        }
    }
}
