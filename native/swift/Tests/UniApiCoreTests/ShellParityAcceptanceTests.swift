import XCTest
@testable import UniApiCore

final class ShellParityAcceptanceTests: XCTestCase {
    private func fixture() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shell-parity-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
    }
    func testHomeExitDeleteAndReturnRefreshesTheCachedDomainWithinItsTTL() async throws {
        let runtime = try fixture()
        let media = NativeTranscriptionIO(token: { throw NativeFailure("No credential fixture") }, available: { [:] }, probe: { _ in throw NativeFailure("No provider") }, download: { _, _, _ in throw NativeFailure("No download") }, decode: { _, _ in throw NativeFailure("No decoder") })
        let transcription = NativeTranscriptionService(runtime: runtime, io: media, notify: { _ in XCTFail("No notification") })
        try await transcription.start()
        try runtime.db.execute("INSERT INTO transcripts(id,title,source,source_kind,status,created_at) VALUES ('old','Deleted transcript','fixture','url','failed',1)")
        let summaries = NativeHubSummaries(runtime: runtime, read: { domain in
            if domain == "transcribe" { return try await transcription.handle("summary") }
            return [:]
        })
        let entry = try await summaries.snapshot(force: true)
        XCTAssertEqual(entry["transcribe"]["count"], 1)
        _ = try await transcription.handle("delete", input: ["id": "old"])
        let retained = try await summaries.snapshot()
        XCTAssertEqual(retained["transcribe"]["count"], 1, "The control proves the regression is inside the freshness window")
        let returned = try await summaries.snapshot(force: true)
        XCTAssertEqual(returned["transcribe"]["count"], 0)
        XCTAssertTrue(returned["transcribe"]["lastTitle"].isNull)
    }
    func testHomeMutationsIncludeActualDeletionAndAdmissionTopicsButExcludeTokenTraffic() {
        for topic in ["transcribe.deleted", "transcribe.updated", "arena.match.deleted", "arena.match", "code.thread.deleted", "code.projects", "code.permission.resolved", "bench.started", "bench.finished", "bench.catalog", "stats.cached", "stats.failed", "job.updated", "switcher.changed"] { XCTAssertTrue(NativeShellPolicy.refreshesHome(topic), topic) }
        for topic in ["code.stream", "code.event", "arena.slot.event", "job.log", "job.progress", "stats.progress"] { XCTAssertFalse(NativeShellPolicy.refreshesHome(topic), topic) }
    }
    func testFailedRouteReadCannotBecomeSubscriptionOrDefaultSettings() {
        let fallback: JSONValue = ["settingsReadable": false, "currentName": "Anthropic subscription", "model": .null, "effort": .null]
        let failed = NativeShellPolicy.route(["error": "Corrupt settings"], dashboard: fallback)
        XCTAssertEqual(failed.name, "Route unavailable"); XCTAssertEqual(failed.model, "Model unavailable"); XCTAssertEqual(failed.effort, "unavailable")
        let loading = NativeShellPolicy.route(.null, dashboard: ["settingsReadable": true, "currentName": "Anthropic subscription"])
        XCTAssertEqual(loading.name, "Reading route…")
        let actual = NativeShellPolicy.route(["currentName": "Custom settings route", "snapshot": ["model": "model", "effort": "high"]], dashboard: fallback)
        XCTAssertEqual(actual.name, "Custom settings route"); XCTAssertEqual(actual.model, "model"); XCTAssertEqual(actual.effort, "high")
        let subscription = NativeShellPolicy.route(["currentName": "Anthropic subscription", "snapshot": [:]])
        XCTAssertEqual(subscription.effort, "default"); XCTAssertTrue(subscription.model.hasPrefix("No model pinned"))
    }
    func testFooterDistinguishesCheckingOwnedExternalLegacyDownAndFailedReads() {
        XCTAssertEqual(NativeShellPolicy.shim(.null).state, .checking)
        let owned = NativeShellPolicy.shim(["shim": ["ok": true, "owned": true, "providers": ["p", "q"]]])
        XCTAssertEqual(owned.state, .up); XCTAssertEqual(owned.text, "Owned Swift shim up · 2 routes")
        let external = NativeShellPolicy.shim(["shim": ["ok": true, "owned": false, "providers": []]])
        XCTAssertEqual(external.text, "Swift shim up · 0 routes")
        let legacy = NativeShellPolicy.shim(["shim": ["ok": false, "legacyPresent": true, "providers": ["old"]]])
        XCTAssertEqual(legacy.state, .legacy); XCTAssertEqual(legacy.text, "Legacy listener preserved · 1 routes")
        XCTAssertEqual(NativeShellPolicy.shim(["shim": ["ok": false]]).state, .down)
        XCTAssertEqual(NativeShellPolicy.shim(["error": "Cannot read providers"]).text, "Shim status unavailable")
    }
    func testExactJobCountIncludesMoreThanTwoHundredAndPropagatesStorageFailure() async throws {
        let runtime = try fixture()
        try runtime.db.transaction {
            for index in 0..<257 { try runtime.db.execute("INSERT INTO jobs(id,kind,app,title,lane,params,status,created_at) VALUES (?,'fixture','fixture','fixture','fixture','{}',?,?)", [.string("job-\(index)"), index == 256 ? "failed" : index < 128 ? "running" : "queued", .number(Double(index))]) }
        }
        let limited = try await runtime.jobs.list(statuses: ["running", "queued"]), exact = try await runtime.jobs.activeCount()
        XCTAssertEqual(limited.count, 200); XCTAssertEqual(exact, 256)
        try runtime.db.executeScript("DROP TABLE jobs")
        do { _ = try await runtime.jobs.activeCount(); XCTFail("A broken jobs table became zero active jobs") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    func testStartupDiagnosisRejectsPreviousProcessAndRetainsServiceFailure() {
        let health: JSONValue = ["schema": 2, "runtime": "swift", "pid": 42, "instance": "current", "ready": true]
        XCTAssertEqual(NativeShellPolicy.startup(readOnly: false, prepared: true, sessionError: nil, health: health, pid: 42, instance: "current"), "Ready")
        XCTAssertEqual(NativeShellPolicy.startup(readOnly: false, prepared: true, sessionError: nil, health: health, pid: 43, instance: "current"), "Startup not yet confirmed")
        XCTAssertEqual(NativeShellPolicy.startup(readOnly: false, prepared: true, sessionError: nil, health: health, pid: 42, instance: "new launch"), "Startup not yet confirmed")
        XCTAssertEqual(NativeShellPolicy.startup(readOnly: false, prepared: true, sessionError: "Transcription initialization failed", health: health, pid: 42, instance: "current"), "Startup failed: Transcription initialization failed")
        XCTAssertTrue(NativeShellPolicy.startup(readOnly: true, prepared: true, sessionError: nil, health: health, pid: 42, instance: "current").contains("not checked"))
    }
    func testOnlyConfirmedUnsupportedBatteryHidesAndRejectsSavedDestination() {
        XCTAssertTrue(NativeShellPolicy.admits("battery", batterySupported: .null))
        XCTAssertTrue(NativeShellPolicy.admits("battery", batterySupported: true))
        XCTAssertFalse(NativeShellPolicy.admits("battery", batterySupported: false))
        XCTAssertTrue(NativeShellPolicy.admits("home", batterySupported: false))
    }
    @MainActor func testHeldDropCannotCrossCancelPromptOrDialogAndKeepsMultiFileSiblings() {
        let fixture = ShellHeldDropFixture()
        fixture.open("A")
        let old = fixture.hold("A-file")
        fixture.cancel(); fixture.open("B"); old()
        XCTAssertEqual(fixture.files, [])
        let first = fixture.hold("B-one"), second = fixture.hold("B-two")
        first(); second(); first()
        XCTAssertEqual(fixture.files, ["B-one", "B-two"])
        let replaced = fixture.hold("late B")
        fixture.open("B"); replaced()
        XCTAssertEqual(fixture.files, [])
        let saving = fixture.hold("late save")
        fixture.context.invalidate(); fixture.saving = true; saving(); fixture.saving = false; saving()
        XCTAssertEqual(fixture.files, [])
        let dismissed = fixture.hold("late dismiss")
        fixture.cancel(); dismissed()
        XCTAssertEqual(fixture.files, [])
    }
}

@MainActor private final class ShellHeldDropFixture {
    var context = NativePromptsDropContext()
    var prompt: String?, dialog: UUID?, saving = false
    var files: [String] = []
    func open(_ prompt: String) { self.prompt = prompt; dialog = UUID(); files = []; context.begin(prompt: prompt, dialog: dialog!) }
    func cancel() { context.invalidate(); dialog = nil }
    func hold(_ file: String) -> () -> Void {
        if context.ticket == nil { context.begin(prompt: prompt!, dialog: dialog!) }
        let captured = context.ticket!
        return { [self] in
            if context.accepts(captured, prompt: prompt, dialog: dialog, saving: saving), !files.contains(file) { files.append(file) }
        }
    }
}
