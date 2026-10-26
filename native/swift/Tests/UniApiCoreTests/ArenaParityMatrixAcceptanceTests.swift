import Foundation
import XCTest
@testable import UniApiCore

final class ArenaParityMatrixAcceptanceTests: XCTestCase {
    private func golden() throws -> JSONValue {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/arena-web-golden.json")
        let value = try JSONValue.decode(Data(contentsOf: path)); XCTAssertEqual(value["schema"], 1); return value
    }
    private func runtime() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arena-matrix-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: .init(root: root, home: root.appendingPathComponent("home")))
        try FileManager.default.createDirectory(at: runtime.paths.home, withIntermediateDirectories: true)
        try runtime.providers.mutate { $0["providers"] = [["id": "matrix-route", "api_key": "fixture-only", "proxy": ["format": "anthropic", "models": .array((0..<12).map { .string("m\($0)") })]]] }
        addTeardownBlock { await runtime.jobs.suspendForShutdown(); try? FileManager.default.removeItem(at: root) }
        return runtime
    }
    private func service(_ runtime: NativeRuntime) -> NativeArenaService {
        NativeArenaService(runtime: runtime, channelFactory: { _,_,_,_,_ in
            CodeFixtureChannel { frame in
                if frame["type"] == "control_request" {
                    return [["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": ["hooks_applied": true, "models": []]]]]
                }
                if frame["type"] == "user" {
                    return [["type": "assistant", "message": ["content": [["type": "text", "text": "Offline matrix answer"]]]], ["type": "result", "subtype": "success", "is_error": false, "usage": [:]]]
                }
                return []
            }
        }, notification: { _ in true })
    }
    private func settled(_ service: NativeArenaService, id: JSONValue) async throws {
        for _ in 0..<500 {
            let state = try await service.handle("match", input: ["id": id])["status"].string
            if state == "done" { return }
            if ["failed", "cancelled"].contains(state) { throw NativeFailure("Injected matrix match failed: " + state) }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw NativeFailure("Injected matrix match did not settle")
    }
    private func differences(_ actual: JSONValue, _ expected: JSONValue, _ path: String) -> [String] {
        switch (actual, expected) {
        case let (.number(a), .number(b)): return abs(a - b) <= max(1e-10, abs(b) * 1e-12) ? [] : [path + ": number"]
        case let (.array(a), .array(b)):
            var result = a.count == b.count ? [String]() : [path + ": array count"]
            for i in 0..<min(a.count, b.count) { result += differences(a[i], b[i], path + "/\(i)") }
            return result
        case let (.object(a), .object(b)):
            var result = Set(a.keys) == Set(b.keys) ? [String]() : [path + ": object keys"]
            for key in b.keys.sorted() { result += differences(a[key] ?? .null, b[key]!, path + "/" + key) }
            return result
        default: return actual == expected ? [] : [path + ": value/type"]
        }
    }
    private func compare(_ actual: JSONValue, _ expected: JSONValue, _ path: String) {
        let errors = differences(actual, expected, path)
        XCTAssertTrue(errors.isEmpty, errors.prefix(20).joined(separator: "; "))
    }

    func testActualWebMultiwayEloTiesFailuresHistoriesAndModeScopesGolden() throws {
        let fixture = try golden(), cases = fixture["rankingCases"].array
        XCTAssertEqual(cases.count, 147)
        for item in cases {
            let records = item["records"].array
            XCTAssertTrue(records.allSatisfy(ArenaRanking.valid), item["name"].string)
            let actual = ArenaRanking.standings(records, mode: item["mode"].string)
            compare(.array(actual), item["expected"], item["name"].string)
        }
    }

    func testGoldenComparatorPreservesRankingOrderCountersAndWholeRows() throws {
        let item = try XCTUnwrap(try golden()["rankingCases"].array.first { $0["name"] == "n8/strict/all" })
        let rows = item["expected"].array
        XCTAssertEqual(rows.count, 8)
        XCTAssertFalse(differences(.array(rows), .array(Array(rows.reversed())), "reverse").isEmpty)
        var changed = rows; changed[0]["draws"] = .number(changed[0]["draws"].double + 1)
        XCTAssertFalse(differences(.array(changed), .array(rows), "counter").isEmpty)
        changed = rows; changed[0] = .object(changed[0].object.filter { $0.key != "failures" })
        XCTAssertFalse(differences(.array(changed), .array(rows), "missing-field").isEmpty)
        let actual = ArenaRanking.standings(item["records"].array)
        XCTAssertEqual(actual.map { $0["key"] }, rows.map { $0["key"] })
        let actualFirst = try XCTUnwrap(actual.first), expectedFirst = try XCTUnwrap(rows.first)
        XCTAssertEqual(Set(actualFirst.object.keys), Set(expectedFirst.object.keys))
    }

    func testEveryTwoThroughEightChosenAndRandomCountUsesDistinctConfiguredSlots() async throws {
        let runtime = try runtime(), service = service(runtime), store = try ArenaStore(runtime: runtime)
        for n in 2...8 {
            let chosen: JSONValue = .array((0..<n).map { ["route": "matrix-route", "model": .string("m\($0)")] })
            for mode in ["chosen", "random"] {
                let match = try await service.handle("match.create", input: ["mode": .string(mode), "count": .number(Double(n)), "prompt": "Offline matrix", "notify": false, "contestants": chosen])
                let slots = try store.slots(match["id"])
                XCTAssertEqual(slots.count, n, "\(mode)/\(n)")
                XCTAssertEqual(Set(slots.map(ArenaContestantPolicy.key)).count, n)
                XCTAssertEqual(slots.map { $0["idx"].int }, Array(0..<n))
                if mode == "chosen" { XCTAssertEqual(Set(slots.map(ArenaContestantPolicy.key)), Set(chosen.array.map(ArenaContestantPolicy.key))) }
                try await settled(service, id: match["id"])
            }
        }
    }

    func testChosenInvalidCountsUnknownsAndDuplicatesRefuseWithoutQueueWrites() async throws {
        let runtime = try runtime(), service = service(runtime)
        let cases: [[JSONValue]] = [[], [["route": "matrix-route", "model": "m0"]],
            (0..<9).map { ["route": "matrix-route", "model": .string("m\($0)")] },
            [["route": "matrix-route", "model": "m0"], ["route": "matrix-route", "model": "m0"]],
            [["route": "matrix-route", "model": "m0"], ["route": "unknown", "model": "m1"]]]
        try await service.start()
        for contestants in cases {
            let beforeMatches = try runtime.db.query("SELECT id FROM arena_matches").count
            let beforeJobs = try await runtime.jobs.list(app: "arena").count
            do { _ = try await service.handle("match.create", input: ["mode": "chosen", "prompt": "Offline refusal", "notify": false, "contestants": .array(contestants)]); XCTFail("Invalid selection accepted") } catch {}
            XCTAssertEqual(try runtime.db.query("SELECT id FROM arena_matches").count, beforeMatches)
            let afterJobs = try await runtime.jobs.list(app: "arena").count
            XCTAssertEqual(afterJobs, beforeJobs)
        }
    }

    func testRandomExclusionsAtEveryCountAdmitExactlyEnoughAndRefuseOneTooFew() async throws {
        let runtime = try runtime(), service = service(runtime), store = try ArenaStore(runtime: runtime)
        let catalog = try await service.handle("state")["contestants"].array
        for n in 2...8 {
            let allowed = Array(catalog.prefix(n)), allowedKeys = Set(allowed.map(ArenaContestantPolicy.key))
            let excluded = catalog.filter { !allowedKeys.contains(ArenaContestantPolicy.key($0)) }.map { JSONValue.string(ArenaContestantPolicy.key($0)) }
            _ = try await service.handle("settings", input: ["excluded": .array(excluded)])
            let match = try await service.handle("match.create", input: ["mode": "random", "count": .number(Double(n)), "prompt": "Offline exact pool", "notify": false])
            XCTAssertEqual(Set(try store.slots(match["id"]).map(ArenaContestantPolicy.key)), allowedKeys)
            try await settled(service, id: match["id"])
            _ = try await service.handle("settings", input: ["excluded": .array(excluded + [.string(ArenaContestantPolicy.key(allowed[0]))])])
            let count = try runtime.db.query("SELECT id FROM arena_matches").count
            do { _ = try await service.handle("match.create", input: ["mode": "random", "count": .number(Double(n)), "prompt": "Offline insufficient pool", "notify": false]); XCTFail("Insufficient pool accepted") } catch {}
            XCTAssertEqual(try runtime.db.query("SELECT id FROM arena_matches").count, count)
        }
    }

    func testIntegerDefaultSettingsMatchActualWebClampsPartialUpdatesAndNotify() async throws {
        let runtime = try runtime(), service = service(runtime), store = try ArenaStore(runtime: runtime)
        for item in try golden()["settingsCases"].array where !item["fractional"].bool {
            try store.set("defaults", item["current"])
            let state = try await service.handle("settings", input: ["defaults": item["patch"]])
            compare(state["defaults"], item["expected"], item["name"].string)
        }
    }

    func testIntegerCreationDefaultsAndOverridesMatchActualWebOracle() async throws {
        let runtime = try runtime(), service = service(runtime), store = try ArenaStore(runtime: runtime)
        let cases = try golden()["creationCases"].array
        for name in ["numeric-string-request", "numeric-string-saved", "null-request-uses-saved", "null-request-uses-numeric-string-saved"] {
            let item = try XCTUnwrap(cases.first { $0["name"].string == name })
            compare(item["expected"], ["count": 4, "timeout_s": 180, "max_turns": 15, "notify": false], name + "/oracle-control")
        }
        for name in ["boolean-empty-request", "boolean-request-over-saved", "empty-request-over-saved", "whitespace-request-over-saved", "boolean-empty-saved"] {
            let item = try XCTUnwrap(cases.first { $0["name"].string == name })
            compare(item["expected"], ["count": 2, "timeout_s": 120, "max_turns": 5, "notify": false], name + "/oracle-control")
        }
        for item in cases where !item["fractional"].bool {
            try store.set("defaults", item["defaults"])
            var input = item["request"].object; input["mode"] = "random"; input["prompt"] = "Offline defaults"
            let match = try await service.handle("match.create", input: input)
            let actual: JSONValue = ["count": .number(Double(try store.slots(match["id"]).count)), "timeout_s": match["timeout_s"], "max_turns": match["max_turns"], "notify": match["notify"]]
            compare(actual, item["expected"], item["name"].string)
            try await settled(service, id: match["id"])
        }
    }

    /// Retains the original truncation witness as an ordinary web-oracle check,
    /// including half boundaries, huge finite values and guarded settings types.
    func testFractionalDefaultAndCreationRoundingMatchActualWebOracle() async throws {
        let runtime = try runtime(), service = service(runtime), store = try ArenaStore(runtime: runtime)
        for item in try golden()["settingsCases"].array where item["fractional"].bool {
            try store.set("defaults", item["current"])
            let state = try await service.handle("settings", input: ["defaults": item["patch"]])
            compare(state["defaults"], item["expected"], "settings/" + item["name"].string)
        }
        for item in try golden()["creationCases"].array where item["fractional"].bool {
            try store.set("defaults", item["defaults"])
            var input = item["request"].object; input["mode"] = "random"; input["prompt"] = "Offline fractional witness"
            let match = try await service.handle("match.create", input: input)
            let actual: JSONValue = ["count": .number(Double(try store.slots(match["id"]).count)), "timeout_s": match["timeout_s"], "max_turns": match["max_turns"], "notify": match["notify"]]
            compare(actual, item["expected"], "creation/" + item["name"].string)
            try await settled(service, id: match["id"])
        }
        // Nonfinite values cannot arrive in JSON, but direct Swift callers must
        // not trap an Int conversion or destroy valid saved numeric defaults.
        for number in [Double.nan, .infinity, -.infinity] {
            let saved: JSONValue = ["count": 4, "timeoutMin": 9, "maxTurns": 33, "notify": false]
            try store.set("defaults", saved)
            let patch: JSONValue = ["count": .number(number), "timeoutMin": .number(number), "maxTurns": .number(number)]
            let state = try await service.handle("settings", input: ["defaults": patch])
            compare(state["defaults"], saved, "nonfinite-settings-fallback")
            let match = try await service.handle("match.create", input: ["mode": "random", "prompt": "Offline nonfinite fallback", "count": .number(number), "timeoutMin": .number(number), "maxTurns": .number(number), "notify": false])
            XCTAssertEqual(try store.slots(match["id"]).count, 4)
            XCTAssertEqual(match["timeout_s"], 540); XCTAssertEqual(match["max_turns"], 33)
            try await settled(service, id: match["id"])
        }
        let before = try store.get("defaults")
        do { _ = try await service.handle("settings", input: ["defaults": ["unknown-limit": 3]]); XCTFail("Unknown defaults key accepted") } catch {}
        XCTAssertEqual(try store.get("defaults"), before)
    }

    func testDedicatedRouteCheckSuccessEmptyQuotaAndTransportRefusalWithoutNetwork() async throws {
        let runtime = try runtime(), fixture = MatrixCheckFixture()
        fixture.replies = ["good": .response(200, ["content": [["type": "text", "text": "OK"]]]), "empty": .response(200, ["content": []]), "quota": .response(429, ["error": ["message": "Fixture quota refused"]]), "transport": .failure(.cannotConnectToHost)]
        fixture.register(); defer { fixture.unregister() }
        try fixture.provider(runtime)
        let service = service(runtime), selections: JSONValue = .array(["good", "empty", "quota", "transport"].map { ["route": "matrix-check", "model": .string($0)] })
        let result = try await service.handle("check", input: ["contestants": selections])["results"].array
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result.map { $0["ok"].bool }, [true, false, false, false])
        XCTAssertEqual(result[0]["message"], "Responded"); XCTAssertEqual(result[2]["message"], "Fixture quota refused")
        XCTAssertFalse(result[3]["message"].string.isEmpty)
        let requests = fixture.requests()
        XCTAssertEqual(requests.count, 4, "Custom fixture protocol must intercept; its scheme cannot reach a network")
        for (request, body) in fixture.records() {
            XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.path, "/v1/messages")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture-only")
            XCTAssertEqual(body["max_tokens"], 8); XCTAssertEqual(body["messages"].array.count, 1)
            XCTAssertEqual(body["messages"].array[0]["role"], "user")
        }
        XCTAssertTrue(try runtime.db.query("SELECT id FROM arena_matches").isEmpty)
        let jobs = try await runtime.jobs.list(app: "arena"); XCTAssertTrue(jobs.isEmpty)
    }

    func testDedicatedHeldRouteCheckCancellationStopsTransportAndReturnsFailure() async throws {
        let runtime = try runtime(), fixture = MatrixCheckFixture(); fixture.replies = ["held": .hold]
        fixture.register(); defer { fixture.unregister() }; try fixture.provider(runtime)
        let service = service(runtime)
        let task = Task { try await service.handle("check", input: ["contestants": [["route": "matrix-check", "model": "held"]]]) }
        defer { task.cancel() }
        for _ in 0..<500 {
            if fixture.requests().count == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(fixture.requests().count, 1, "Held custom-scheme fixture must actually start")
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result["results"].array.count, 1); XCTAssertEqual(result["results"].array[0]["ok"], false)
        XCTAssertFalse(result["results"].array[0]["message"].string.isEmpty)
        for _ in 0..<500 {
            if fixture.stops() == 1 { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(fixture.stops(), 1)
        XCTAssertTrue(try runtime.db.query("SELECT id FROM arena_matches").isEmpty)
        let jobs = try await runtime.jobs.list(app: "arena"); XCTAssertTrue(jobs.isEmpty)
    }

    func testSubscriptionUnknownAndRevokedRouteChecksNeverStartTransport() async throws {
        let runtime = try runtime(), fixture = MatrixCheckFixture(); fixture.replies = ["good": .response(200, ["content": [["text": "OK"]]])]
        fixture.register(); defer { fixture.unregister() }; try fixture.provider(runtime)
        try runtime.providers.mutate { document in
            var providers = document["providers", default: []].array
            providers[0]["disabled"] = true; document["providers"] = .array(providers)
        }
        let service = service(runtime)
        let result = try await service.handle("check", input: ["contestants": [["route": "subscription", "model": "sonnet"], ["route": "matrix-check", "model": "good"], ["route": "unknown", "model": "good"]]])["results"].array
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0]["route"], "subscription")
        XCTAssertEqual(result[0]["ok"], true); XCTAssertEqual(result[0]["skipped"], true)
        XCTAssertTrue(fixture.requests().isEmpty)
    }
}

private enum MatrixCheckReply { case response(Int, JSONValue), failure(URLError.Code), hold }

/// The non-network scheme prevents fallback to DNS or loopback even if a
/// platform does not support globally registered protocols on its shared session.
private final class MatrixCheckFixture: @unchecked Sendable {
    let id = UUID().uuidString.lowercased()
    var replies: [String: MatrixCheckReply] = [:]
    private let lock = NSLock()
    private var received: [(URLRequest, JSONValue)] = [], stopped = 0
    func register() { MatrixCheckProtocol.registry.add(self) }
    func unregister() { MatrixCheckProtocol.registry.remove(id) }
    func provider(_ runtime: NativeRuntime) throws {
        try runtime.providers.mutate { $0["providers"] = [["id": "matrix-check", "api_key": "fixture-only", "proxy": ["format": "anthropic", "models": .array(replies.keys.sorted().map(JSONValue.string)), "direct_url": .string("uniapi-arena-fixture://" + id)]]] }
    }
    func body(_ request: URLRequest) throws -> JSONValue {
        if let data = request.httpBody { return try JSONValue.decode(data) }
        guard let stream = request.httpBodyStream else { throw NativeFailure("Missing fixture request body") }
        stream.open(); defer { stream.close() }; var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0, data.count + count <= 8192 else { throw NativeFailure("Unbounded fixture request body") }
            if count == 0 { break }; data.append(contentsOf: buffer.prefix(count))
        }
        return try JSONValue.decode(data)
    }
    func begin(_ request: URLRequest) throws -> MatrixCheckReply {
        let input = try body(request)
        return lock.withLock { received.append((request, input)); return replies[input["model"].string] ?? .failure(.badURL) }
    }
    func stop() { lock.withLock { stopped += 1 } }
    func requests() -> [URLRequest] { lock.withLock { received.map { $0.0 } } }
    func records() -> [(URLRequest, JSONValue)] { lock.withLock { received } }
    func stops() -> Int { lock.withLock { stopped } }
}

private final class MatrixCheckRegistry: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: MatrixCheckFixture] = [:]
    func add(_ value: MatrixCheckFixture) {
        lock.lock(); values[value.id] = value; let first = values.count == 1; lock.unlock()
        if first { _ = URLProtocol.registerClass(MatrixCheckProtocol.self) }
    }
    func remove(_ id: String) {
        lock.lock(); values.removeValue(forKey: id); let empty = values.isEmpty; lock.unlock()
        if empty { URLProtocol.unregisterClass(MatrixCheckProtocol.self) }
    }
    func get(_ id: String) -> MatrixCheckFixture? { lock.withLock { values[id] } }
}

private final class MatrixCheckProtocol: URLProtocol, @unchecked Sendable {
    static let registry = MatrixCheckRegistry()
    private var fixture: MatrixCheckFixture?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "uniapi-arena-fixture" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = Self.registry.get(url.host ?? "") else { client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return }
        self.fixture = fixture
        do {
            switch try fixture.begin(request) {
            case .hold: return
            case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
            case .response(let status, let body):
                guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else { throw NativeFailure("Invalid fixture response") }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: try body.encoded()); client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { fixture?.stop() }
}
