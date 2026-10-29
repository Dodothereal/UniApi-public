import XCTest
import Combine
import UniApiCore
@testable import UniApiPresentation

@MainActor private final class StatisticsRefreshReceiptFixture: NativeStatsModelService {
    let events: NativeEvents
    var scanID = "initial"
    var failOperation = false
    private(set) var calls: [String] = []
    private var held: CheckedContinuation<Void, Never>?
    var isHeld: Bool { held != nil }
    init(events: NativeEvents) { self.events = events }
    func release() { let continuation = held; held = nil; continuation?.resume() }
    func handle(_ operation: String, input: JSONObject) async throws -> JSONValue {
        calls.append(operation)
        if operation == "refresh" || operation == "rescan" {
            scanID = "completed-" + operation
            // The production service publishes before returning its receipt.
            // Hold that return until the event-owned read has visibly committed.
            await events.publish("stats.scanned", ["scanId": .string(scanID)])
            await withCheckedContinuation { held = $0 }
            if failOperation { throw NativeFailure("Synthetic refresh failure") }
            return ["ok": true, "scan": ["scanId": .string(scanID)]]
        }
        if operation == "bench" { return ["scan": .string(scanID)] }
        return ["loaded": true, "source": input["source"] ?? "all", "range": input["range"] ?? 0,
                "scan": ["scanId": .string(scanID)]]
    }
}

@MainActor final class StatisticsRefreshObservationTests: XCTestCase {
    private let scope = NativeStatsScope(source: "all", range: 0)
    private func payload(_ scanID: String, source: String = "all", range: Int = 0) -> JSONValue {
        ["loaded": true, "source": .string(source), "range": .number(Double(range)), "scan": ["scanId": .string(scanID)]]
    }
    private func publish(_ scanID: String, to admission: inout NativeStatsRefreshAdmission) {
        admission.readStarted()
        admission.published(payload: payload(scanID), benchmark: ["scan": .string(scanID)], failed: false)
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFailure("Refresh observation fixture timed out") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    func testSuccessfulReceiptSurvivesEventReadSupersedingManualRequest() async throws {
        for (mode, operation) in [(NativeStatsLoadMode.refresh, "refresh"), (.rebuild, "rescan")] {
            let events = NativeEvents(), service = StatisticsRefreshReceiptFixture(events: events)
            let model = NativeStatsModel(service: service)
            await model.begin(events: events) { await model.load(source: "all", range: 0, model: nil) }
            var admission = NativeStatsRefreshAdmission(scope: scope)
            var receipts: [String] = []
            let observed = model.$busy.dropFirst().sink { busy in
                if busy { admission.readStarted() }
                else { admission.published(payload: model.payload, benchmark: model.benchmark, failed: !model.error.isEmpty) }
            }
            let manual = Task {
                await model.load(source: "all", range: 0, model: nil, mode: mode, operationCompleted: {
                    receipts.append($0); admission.operationCompleted(scanID: $0)
                })
                admission.operationReturned()
            }
            do {
                try await waitFor { service.isHeld && !model.busy && model.payload["scan"]["scanId"].string == "completed-" + operation }
                XCTAssertTrue(receipts.isEmpty)
                XCTAssertEqual(admission.status, .pending, "A visible event read alone is not a successful operation receipt")
                XCTAssertEqual(model.benchmark["scan"], .string("completed-" + operation))
                service.release(); await manual.value
                XCTAssertEqual(receipts, ["completed-" + operation])
                XCTAssertEqual(admission.status, .ready)
                XCTAssertEqual(service.calls, ["overview", "bench", operation, "overview", "bench"], "The stale manual read must not query again")
                XCTAssertTrue(model.error.isEmpty)
            } catch {
                manual.cancel(); service.release(); model.stop(); await manual.value; observed.cancel(); throw error
            }
            observed.cancel(); model.stop()
        }
    }

    func testFailedOperationCannotAdmitEvenAnAlreadyPublishedMatchingPair() async throws {
        let events = NativeEvents(), service = StatisticsRefreshReceiptFixture(events: events)
        service.failOperation = true
        let model = NativeStatsModel(service: service)
        await model.begin(events: events) { await model.load(source: "all", range: 0, model: nil) }
        var admission = NativeStatsRefreshAdmission(scope: scope)
        var receipts: [String] = []
        let observed = model.$busy.dropFirst().sink { busy in
            if busy { admission.readStarted() }
            else { admission.published(payload: model.payload, benchmark: model.benchmark, failed: !model.error.isEmpty) }
        }
        let manual = Task {
            await model.load(source: "all", range: 0, model: nil, mode: .refresh, operationCompleted: {
                receipts.append($0); admission.operationCompleted(scanID: $0)
            })
            admission.operationReturned()
        }
        do {
            try await waitFor { service.isHeld && !model.busy && model.payload["scan"]["scanId"] == "completed-refresh" }
            XCTAssertEqual(admission.status, .pending)
            service.release(); await manual.value
            XCTAssertTrue(receipts.isEmpty)
            XCTAssertEqual(admission.status, .incomplete, "A superseded failed operation has no success receipt")
        } catch {
            manual.cancel(); service.release(); model.stop(); await manual.value; observed.cancel(); throw error
        }
        observed.cancel(); model.stop()
    }

    func testReceiptBeforeCommitWaitsForCoherentPublication() {
        var admission = NativeStatsRefreshAdmission(scope: scope)
        admission.readStarted()
        admission.operationCompleted(scanID: "wanted")
        admission.operationReturned()
        XCTAssertEqual(admission.status, .pending)
        admission.published(payload: payload("wanted"), benchmark: [:], failed: false)
        XCTAssertEqual(admission.status, .ready)
    }

    func testRetainedContentAndDifferentScanCannotSatisfyReceipt() {
        var admission = NativeStatsRefreshAdmission(scope: scope)
        admission.published(payload: payload("wanted"), benchmark: [:], failed: false)
        admission.operationCompleted(scanID: "wanted")
        XCTAssertEqual(admission.status, .pending, "There was no new read/publication")
        publish("old", to: &admission)
        XCTAssertEqual(admission.status, .pending)
        publish("wanted", to: &admission)
        XCTAssertEqual(admission.status, .ready)
        admission.readStarted()
        XCTAssertEqual(admission.status, .pending, "A newer read revokes an undrawn ready candidate")
        admission.published(payload: payload("unrelated"), benchmark: [:], failed: false)
        XCTAssertEqual(admission.status, .pending)
    }

    func testOnlyLatestPublicationCanJoinDelayedReceipt() {
        var admission = NativeStatsRefreshAdmission(scope: scope)
        publish("wanted", to: &admission)
        publish("unrelated", to: &admission)
        admission.operationCompleted(scanID: "wanted")
        admission.operationReturned()
        XCTAssertEqual(admission.status, .pending)
    }

    func testScopeMismatchAndDepartureRejectLateCompletions() {
        for mismatched in [payload("wanted", source: "codex"), payload("wanted", range: 7)] {
            var admission = NativeStatsRefreshAdmission(scope: scope)
            admission.readStarted(); admission.operationCompleted(scanID: "wanted")
            admission.published(payload: mismatched, benchmark: [:], failed: false)
            XCTAssertEqual(admission.status, .cancelled)
            publish("wanted", to: &admission)
            XCTAssertEqual(admission.status, .cancelled)
        }
        var departed = NativeStatsRefreshAdmission(scope: scope)
        publish("wanted", to: &departed)
        departed.cancel(); departed.operationCompleted(scanID: "wanted"); departed.operationReturned()
        XCTAssertEqual(departed.status, .cancelled)
    }

    func testFailedReadAndMissingReceiptNeverReportReady() {
        var failedRead = NativeStatsRefreshAdmission(scope: scope)
        failedRead.readStarted(); failedRead.operationCompleted(scanID: "wanted")
        failedRead.published(payload: payload("wanted"), benchmark: [:], failed: true)
        XCTAssertEqual(failedRead.status, .failed)
        var failedOperation = NativeStatsRefreshAdmission(scope: scope)
        failedOperation.readStarted()
        failedOperation.published(payload: payload("old"), benchmark: [:], failed: true)
        failedOperation.operationReturned()
        XCTAssertEqual(failedOperation.status, .failed)
        var missingReceipt = NativeStatsRefreshAdmission(scope: scope)
        publish("wanted", to: &missingReceipt); missingReceipt.operationReturned()
        XCTAssertEqual(missingReceipt.status, .incomplete)
    }

    func testDetailWithoutIdentityAndMissingBenchmarkRemainIncomplete() {
        let detailScope = NativeStatsScope(source: "all", range: 0, model: "example")
        var detail = NativeStatsRefreshAdmission(scope: detailScope)
        var detailPayload = payload("wanted"); detailPayload["model"] = "example"; detailPayload["scan"] = .null
        detail.readStarted(); detail.published(payload: detailPayload, benchmark: [:], failed: false)
        detail.operationCompleted(scanID: "wanted")
        XCTAssertEqual(detail.status, .incomplete)
        var missingBenchmark = NativeStatsRefreshAdmission(scope: scope)
        missingBenchmark.readStarted(); missingBenchmark.operationCompleted(scanID: "wanted")
        missingBenchmark.published(payload: payload("wanted"), benchmark: .null, failed: false)
        XCTAssertEqual(missingBenchmark.status, .incomplete)
    }
}
