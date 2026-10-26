import XCTest
@testable import UniApiPresentation

@MainActor final class PageLifetimeTests: XCTestCase {
    func testBackgroundHasNoPageAndCloseReopenRetainsOnlyExistingPage() {
        var state = NativePresentationState(visible: false)
        XCTAssertFalse(state.visible); XCTAssertFalse(state.retainsPage)
        state.close()
        XCTAssertFalse(state.retainsPage)
        state.show()
        let retainedGeneration = state.generation
        state.close()
        XCTAssertEqual(state.generation, retainedGeneration)
        XCTAssertFalse(state.visible); XCTAssertTrue(state.retainsPage)
        state.show()
        XCTAssertTrue(state.visible); XCTAssertTrue(state.retainsPage)
        XCTAssertEqual(state.generation, retainedGeneration)
        state.discard()
        XCTAssertFalse(state.visible); XCTAssertFalse(state.retainsPage)
        state.show()
        XCTAssertTrue(state.visible); XCTAssertTrue(state.retainsPage)
        XCTAssertNotEqual(state.generation, retainedGeneration, "Even coalesced Quit/show changes the mounted page identity")
    }

    func testOwnedSheetKeepsWorkActiveWithoutRequiringKeyWindowOrActiveApp() {
        func active(presented: Bool = true, visible: Bool = true, mini: Bool = false,
                    hidden: Bool = false, exposed: Bool = true, sheet: Bool = false) -> Bool {
            NativePageActivityPolicy.active(presented: presented, visible: visible, miniaturized: mini,
                appHidden: hidden, exposed: exposed, ownedSheetVisible: sheet)
        }
        XCTAssertTrue(active())
        XCTAssertFalse(active(exposed: false))
        XCTAssertTrue(active(exposed: false, sheet: true))
        XCTAssertFalse(active(presented: false, sheet: true))
        XCTAssertFalse(active(visible: false, sheet: true))
        XCTAssertFalse(active(mini: true, sheet: true))
        XCTAssertFalse(active(hidden: true, sheet: true))
    }

    func testSuspendedHeldSuccessAndErrorCannotReplaceReenteredData() async {
        let scope = NativePageReadScope()
        let old = scope.begin()!
        scope.suspend()
        XCTAssertNil(scope.begin())
        scope.resume()
        let fresh = scope.begin()!
        var published = "current"
        if scope.accepts(fresh) { published = "fresh" }
        if scope.accepts(old) { published = "stale success" }
        XCTAssertEqual(published, "fresh")
        var error: String?
        if scope.accepts(old) { error = "stale error" }
        XCTAssertNil(error)
        scope.resume()
        XCTAssertTrue(scope.accepts(fresh), "Repeated active entry must not invalidate another current task lane")
    }

    func testReadLanesReplaceOwnRequestAndDoNotCancelOtherReads() {
        let scope = NativePageReadScope()
        let status = scope.begin("status")!, oldHistory = scope.begin("history")!
        let history = scope.begin("history")!
        XCTAssertTrue(scope.accepts(status)); XCTAssertTrue(scope.accepts(history))
        XCTAssertFalse(scope.accepts(oldHistory))
        scope.invalidate("status")
        XCTAssertFalse(scope.accepts(status)); XCTAssertTrue(scope.accepts(history))
        scope.suspend(); scope.suspend(); scope.resume()
        XCTAssertFalse(scope.accepts(history))
    }

    func testCancelledCallerCannotDispatchOrPublishEvenIfServiceIgnoresCancellation() async {
        let scope = NativePageReadScope()
        let entered = expectation(description: "held read entered")
        var release: CheckedContinuation<Void, Never>?
        var published = false
        let task = Task { @MainActor in
            guard let ticket = scope.begin() else { return }
            await withCheckedContinuation { continuation in release = continuation; entered.fulfill() }
            published = scope.accepts(ticket)
            XCTAssertNil(scope.begin("next batch"))
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel(); release?.resume(); await task.value
        XCTAssertFalse(published)
        XCTAssertNotNil(scope.begin("new caller"))
    }

    func testTaskAndChangeDeliveryShareOneResumeBarrierAndLateStopCannotAffectNewEntry() {
        let scope = NativePageReadScope(), owner = NativePageWorkOwner()
        var activation = NativePageActivation(active: false), stops = 0
        XCTAssertFalse(owner.synchronize(activation, reads: scope, suspended: { stops += 1 }))
        XCTAssertNil(scope.begin())
        activation.setActive(true)
        let first = activation
        // Task arrives before onChange: it must resume reads itself.
        XCTAssertTrue(owner.synchronize(first, reads: scope, suspended: { stops += 1 }))
        let oldRead = scope.begin()!
        let priorStops = stops
        XCTAssertTrue(owner.synchronize(first, reads: scope, suspended: { stops += 1 }))
        XCTAssertEqual(stops, priorStops, "Late onChange must not stop the newly started task")
        XCTAssertTrue(scope.accepts(oldRead))
        // SwiftUI may coalesce these two publications. Generation still
        // differentiates this entry from the old visible lifetime.
        activation.setActive(false); activation.setActive(true)
        XCTAssertTrue(owner.synchronize(activation, reads: scope, suspended: { stops += 1 }))
        let freshRead = scope.begin()!
        XCTAssertFalse(scope.accepts(oldRead)); XCTAssertTrue(scope.accepts(freshRead))
        owner.suspend(first, reads: scope, suspended: { stops += 1 })
        XCTAssertTrue(scope.accepts(freshRead))
        XCTAssertFalse(owner.synchronize(first, reads: scope, suspended: { stops += 1 }))
        XCTAssertTrue(scope.accepts(freshRead))
        owner.suspend(activation, reads: scope, suspended: { stops += 1 })
        XCTAssertNil(scope.begin())
    }

    func testPanelCompletionLeaseRejectsQueuedSuccessAfterQuitAndIsSingleUse() {
        let closing = NativePagePanelLease()
        closing.invalidate()
        XCTAssertFalse(closing.consume(), "Queued OK must not write after its page was discarded")
        let ordinary = NativePagePanelLease()
        XCTAssertTrue(ordinary.consume())
        XCTAssertFalse(ordinary.consume(), "A duplicate callback cannot admit a second write")
    }

    func testExportStartedBeforePageDiscardCannotAdoptReopenedPresentation() {
        let panels = NativePagePanels()
        let old = panels.capture()
        XCTAssertTrue(panels.isCurrent(old))
        panels.invalidatePresentation()
        let reopened = panels.capture()
        XCTAssertFalse(panels.isCurrent(old))
        XCTAssertTrue(panels.isCurrent(reopened))
    }
}
