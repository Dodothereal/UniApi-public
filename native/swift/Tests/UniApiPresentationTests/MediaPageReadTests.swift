import XCTest
import UniApiCore
@testable import UniApiPresentation

@MainActor private final class HeldMediaRead {
    private var continuation: CheckedContinuation<JSONValue, Error>?
    private var result: Result<JSONValue, Error>?
    private(set) var entered = false
    func read() async throws -> JSONValue {
        entered = true
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func release(_ result: Result<JSONValue, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
    func waitForEntry() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while !entered {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw NativeFailure("Held media read did not start") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

@MainActor private final class MediaReadFixture {
    let model = NativeMediaPageReads()
    private var reads: [HeldMediaRead] = []
    private var tasks: [Task<Void, Never>] = []
    func held() -> HeldMediaRead { let read = HeldMediaRead(); reads.append(read); return read }
    func start(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let task = Task { await operation() }; tasks.append(task); return task
    }
    func close() async {
        tasks.forEach { $0.cancel() }
        reads.forEach { $0.release(.failure(CancellationError())) }
        for task in tasks { await task.value }
    }
}

@MainActor final class MediaPageReadTests: XCTestCase {
    private func fixture() -> MediaReadFixture {
        let value = MediaReadFixture()
        addTeardownBlock { await value.close() }
        return value
    }
    private func failure(_ text: String) -> Result<JSONValue, Error> { .failure(NativeFailure(text)) }

    func testPreviewOwnerIsCapturedBeforeTaskAdmissionAndCurrentSelectionStillWorks() async throws {
        let f = fixture(), model = f.model
        model.select("A")
        let old = try XCTUnwrap(model.beginPreview())
        model.select("B")
        var reads = 0, sheets: [JSONValue] = []
        await model.preview(owner: old, read: { reads += 1; return "wrong A" },
                            publish: { sheets.append($0) })
        XCTAssertEqual(reads, 0); XCTAssertTrue(sheets.isEmpty)
        let current = try XCTUnwrap(model.beginPreview())
        await model.preview(owner: current, read: { reads += 1; return "current B" },
                            publish: { sheets.append($0) })
        XCTAssertEqual(reads, 1); XCTAssertEqual(sheets, ["current B"]); XCTAssertNil(model.previewError)
    }

    func testHeldPreviewSuccessAndErrorCannotCrossSelectionOrSameIDReentry() async throws {
        for outcome in [Result<JSONValue, Error>.success("obsolete"), failure("obsolete failure")] {
            for returnToA in [false, true] {
                let f = fixture(), model = f.model, held = f.held()
                model.select("A"); let owner = try XCTUnwrap(model.beginPreview())
                var sheets: [JSONValue] = []
                let task = f.start {
                    await model.preview(owner: owner, read: { try await held.read() },
                                        publish: { sheets.append($0) })
                }
                try await held.waitForEntry()
                model.select("B"); if returnToA { model.select("A") }
                held.release(outcome); await task.value
                XCTAssertTrue(sheets.isEmpty); XCTAssertNil(model.previewError)
            }
        }
    }

    func testPreviewSuspensionRejectsHeldReplyAndDoesNotBlockResumedPreview() async throws {
        for outcome in [Result<JSONValue, Error>.success("obsolete"), failure("hidden failure")] {
            let f = fixture(), model = f.model, held = f.held()
            model.select("A"); let old = try XCTUnwrap(model.beginPreview())
            var sheets: [JSONValue] = []
            let task = f.start {
                await model.preview(owner: old, read: { try await held.read() },
                                    publish: { sheets.append($0) })
            }
            try await held.waitForEntry(); model.scope.suspend()
            XCTAssertNil(model.beginPreview())
            model.scope.resume()
            let current = try XCTUnwrap(model.beginPreview())
            await model.preview(owner: current, read: { "resumed" },
                                publish: { sheets.append($0) })
            held.release(outcome); await task.value
            XCTAssertEqual(sheets, ["resumed"]); XCTAssertNil(model.previewError)
        }
    }

    func testNewPreviewIntentSupersedesHeldSuccessAndFailureWithinSamePrompt() async throws {
        for outcome in [Result<JSONValue, Error>.success("first"), failure("first failure")] {
            let f = fixture(), model = f.model, held = f.held()
            model.select("A"); let first = try XCTUnwrap(model.beginPreview())
            var sheets: [JSONValue] = []
            let task = f.start {
                await model.preview(owner: first, read: { try await held.read() },
                                    publish: { sheets.append($0) })
            }
            try await held.waitForEntry()
            let latest = try XCTUnwrap(model.beginPreview())
            await model.preview(owner: latest, read: { "latest" },
                                publish: { sheets.append($0) })
            held.release(outcome); await task.value
            XCTAssertEqual(sheets, ["latest"]); XCTAssertNil(model.previewError)
        }
    }

    func testHTMLOpenAndSVGOpenRejectObsoletePresentationButAllowCurrentPreview() async throws {
        for record: JSONValue in [["kind": "html", "path": "private.html"], ["kind": "image", "mimeType": "image/svg+xml", "path": "private.svg"]] {
            let f = fixture(), model = f.model, held = f.held()
            model.select("A"); let owner = try XCTUnwrap(model.beginPreview())
            var sheets: [JSONValue] = [], external: [JSONValue] = []
            let task = f.start {
                await model.open(fileName: record["path"].string, owner: owner, read: { try await held.read() }, present: { sheets.append($0) },
                                 external: { external.append($0) }, commandFailure: { XCTFail($0) })
            }
            try await held.waitForEntry(); model.select("B")
            held.release(.success(record)); await task.value
            XCTAssertTrue(sheets.isEmpty); XCTAssertTrue(external.isEmpty)
            let current = try XCTUnwrap(model.beginPreview())
            await model.open(fileName: record["path"].string, owner: current, read: { record }, present: { sheets.append($0) },
                             external: { external.append($0) }, commandFailure: { XCTFail($0) })
            XCTAssertEqual(sheets, [record]); XCTAssertTrue(external.isEmpty)
        }
    }

    func testAcceptedExternalOpenRetainsCommandOwnershipAcrossSelectionAndSuspension() async throws {
        let f = fixture(), model = f.model, held = f.held()
        model.select("A"); let owner = try XCTUnwrap(model.beginPreview())
        var external: [JSONValue] = []
        let record: JSONValue = ["kind": "pdf", "path": "private.pdf"]
        let task = f.start {
            await model.open(fileName: record["path"].string, owner: owner, read: { try await held.read() }, present: { _ in XCTFail("External document became a preview") },
                             external: { external.append($0) }, commandFailure: { XCTFail($0) })
        }
        try await held.waitForEntry(); model.select("B"); model.scope.suspend()
        held.release(.success(record)); await task.value
        XCTAssertEqual(external, [record]); XCTAssertNil(model.previewError)
    }

    func testHTMLAndSVGOpenFailureCannotPublishAfterItsPromptOrReadLifetimeRetires() async throws {
        for fileName in ["private.html", "private.htm", "private.xhtml", "private.svg"] {
            for suspend in [false, true] {
                let f = fixture(), model = f.model, held = f.held()
                model.select("A"); let owner = try XCTUnwrap(model.beginPreview())
                var commandFailures: [String] = []
                let task = f.start {
                    await model.open(fileName: fileName, owner: owner, read: { try await held.read() },
                                     present: { _ in XCTFail("Unexpected preview") }, external: { _ in XCTFail("Unexpected external open") },
                                     commandFailure: { commandFailures.append($0) })
                }
                try await held.waitForEntry()
                if suspend { model.scope.suspend(); model.scope.resume() } else { model.select("B") }
                held.release(failure("obsolete document failure")); await task.value
                XCTAssertTrue(commandFailures.isEmpty); XCTAssertNil(model.previewError)
                let current = try XCTUnwrap(model.beginPreview())
                await model.open(fileName: fileName, owner: current, read: { throw NativeFailure("current document failure") },
                                 present: { _ in XCTFail("Unexpected preview") }, external: { _ in XCTFail("Unexpected external open") },
                                 commandFailure: { commandFailures.append($0) })
                XCTAssertEqual(model.previewError, "current document failure"); XCTAssertTrue(commandFailures.isEmpty)
            }
        }
    }

    func testExternalOpenFailureKeepsCommandOwnershipAcrossNavigationPreviewAndDetailRetry() async throws {
        for fileName in ["private.pdf", "private.png", "private.bin"] {
            let f = fixture(), model = f.model, held = f.held()
            model.select("A"); let owner = try XCTUnwrap(model.beginPreview())
            var commandError: String?, commandFailures = 0
            let task = f.start {
                await model.open(fileName: fileName, owner: owner, read: { try await held.read() },
                                 present: { _ in XCTFail("Unexpected preview") }, external: { _ in XCTFail("Failed resolution opened a file") },
                                 commandFailure: { commandError = $0; commandFailures += 1 })
            }
            try await held.waitForEntry(); model.select("B"); model.scope.suspend()
            held.release(failure("external command failure")); await task.value
            XCTAssertEqual(commandError, "external command failure"); XCTAssertEqual(commandFailures, 1); XCTAssertNil(model.previewError)
            model.scope.resume()
            let current = try XCTUnwrap(model.beginPreview())
            await model.preview(owner: current, read: { "current preview" }, publish: { XCTAssertEqual($0, "current preview") })
            await model.loadDetail(read: { _ in "current detail" }, publish: { XCTAssertEqual($0, "current detail") })
            XCTAssertEqual(commandError, "external command failure"); XCTAssertEqual(commandFailures, 1)
            XCTAssertNil(model.detailError); XCTAssertNil(model.previewError)
        }
    }

    func testDetailFailureBelongsToSelectionAndSuccessfulSameSelectionRetryClearsIt() async throws {
        let f = fixture(), model = f.model
        model.select("A")
        var failed = 0, values: [JSONValue] = []
        await model.loadDetail(read: { _ in throw NativeFailure("A detail failure") }, publish: { values.append($0) }, failed: { failed += 1 })
        XCTAssertEqual(model.detailError, "A detail failure"); XCTAssertEqual(failed, 1)
        await model.loadDetail(read: { id in .string(id + " retry") }, publish: { values.append($0) })
        XCTAssertNil(model.detailError); XCTAssertEqual(values, ["A retry"])
        await model.loadDetail(read: { _ in throw NativeFailure("A failed again") }, publish: { values.append($0) })
        XCTAssertEqual(model.detailError, "A failed again")
        model.select(nil); XCTAssertNil(model.detailError)
        model.select("B")
        await model.loadDetail(read: { id in .string(id) }, publish: { values.append($0) })
        XCTAssertNil(model.detailError); XCTAssertEqual(values, ["A retry", "B"])
    }

    func testHeldDetailFailureCannotOverwriteNewSelectionOrSameIDReentry() async throws {
        for returnToA in [false, true] {
            let f = fixture(), model = f.model, held = f.held()
            model.select("A")
            var values: [JSONValue] = [], failed = 0
            let task = f.start { await model.loadDetail(read: { _ in try await held.read() }, publish: { values.append($0) }, failed: { failed += 1 }) }
            try await held.waitForEntry(); model.select("B"); if returnToA { model.select("A") }
            let current = try XCTUnwrap(model.selection)
            await model.loadDetail(read: { .string($0) }, publish: { values.append($0) })
            held.release(failure("old detail failure")); await task.value
            XCTAssertEqual(values, [.string(current)]); XCTAssertEqual(failed, 0); XCTAssertNil(model.detailError)
        }
    }

    func testDetailRetryPreservesIndependentPreviewFailure() async throws {
        let f = fixture(), model = f.model
        model.select("A")
        let owner = try XCTUnwrap(model.beginPreview())
        await model.preview(owner: owner, read: { throw NativeFailure("preview failure") }, publish: { _ in XCTFail("Unexpected preview") })
        await model.loadDetail(read: { _ in throw NativeFailure("detail failure") }, publish: { _ in })
        XCTAssertEqual(model.detailError, "detail failure")
        await model.loadDetail(read: { _ in "accepted detail" }, publish: { _ in })
        XCTAssertNil(model.detailError); XCTAssertEqual(model.previewError, "preview failure")
        model.select("B"); XCTAssertNil(model.previewError)
    }

    func testCancelledPreviewAndInactiveDetailDoNotPublishOrStartANewRead() async throws {
        let f = fixture(), model = f.model, held = f.held()
        model.select("A"); let owner = try XCTUnwrap(model.beginPreview())
        var sheets: [JSONValue] = []
        let task = f.start { await model.preview(owner: owner, read: { try await held.read() }, publish: { sheets.append($0) }) }
        try await held.waitForEntry(); task.cancel(); held.release(.success("cancelled")); await task.value
        XCTAssertTrue(sheets.isEmpty)
        model.scope.suspend()
        var reads = 0
        await model.loadDetail(read: { _ in reads += 1; return "inactive" }, publish: { _ in XCTFail("Inactive publication") })
        XCTAssertEqual(reads, 0); XCTAssertNil(model.beginPreview())
        model.scope.resume()
        await model.loadDetail(read: { _ in "current" }, publish: { XCTAssertEqual($0, "current") })
    }
}
