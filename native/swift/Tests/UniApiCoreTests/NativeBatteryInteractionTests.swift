import XCTest
@testable import UniApiCore

final class NativeBatteryInteractionTests: XCTestCase {
    private let levels = [25, 50, 80, 85, 90, 95, 100]

    func testConfirmedTargetRequiresAnAffirmativeWholePercentage() {
        let invalid: [Double?] = [nil, .nan, .infinity, -.infinity, 0, -1, 101, 80.5]
        for raw in invalid {
            XCTAssertNil(NativeBatteryTargetInteraction.confirmedTarget(raw))
        }
        for value in [1, 25, 50, 80, 100] {
            XCTAssertEqual(NativeBatteryTargetInteraction.confirmedTarget(Double(value)), value)
        }
    }

    func testNullPolicyCannotAdmitAnyTargetCommand() {
        var interaction = NativeBatteryTargetInteraction()
        let enabled = NativeBatteryTargetInteraction.confirmedTarget(nil) != nil
        interaction.pointerChanged(to: 95, current: 100, levels: levels, enabled: enabled)
        XCTAssertNil(interaction.pointerReleased(at: 95, current: 100, levels: levels, enabled: enabled))
        interaction.keyDown(.home, current: 100, levels: levels, enabled: enabled)
        XCTAssertNil(interaction.keyUp(.home, current: 100, levels: levels, enabled: enabled))
        XCTAssertNil(interaction.adjust(.down, current: 100, levels: levels, enabled: enabled))
        XCTAssertNil(interaction.pending)
    }

    func testPointerDraftHasNoRequestUntilReleaseAndOnlyOneRequest() {
        var interaction = NativeBatteryTargetInteraction()
        var requests: [Int] = []
        interaction.pointerChanged(to: 84, current: 80, levels: levels, enabled: true)
        interaction.pointerChanged(to: 92, current: 80, levels: levels, enabled: true)
        XCTAssertEqual(interaction.draft, 90)
        XCTAssertNil(interaction.pending)
        if let value = interaction.pointerReleased(at: 94, current: 80, levels: levels, enabled: true) { requests.append(value) }
        if let value = interaction.pointerReleased(at: 94, current: 80, levels: levels, enabled: true) { requests.append(value) }
        XCTAssertEqual(requests, [95])
        XCTAssertNil(interaction.draft)
        XCTAssertEqual(interaction.pending, 95)
    }

    func testEscapeSinksContinuedPointerMovementThroughRelease() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: 90, current: 80, levels: levels, enabled: true)
        interaction.cancel()
        for value in [95.0, 50, 100] {
            interaction.pointerChanged(to: value, current: 80, levels: levels, enabled: true)
            XCTAssertNil(interaction.draft)
        }
        XCTAssertNil(interaction.pointerReleased(at: 100, current: 80, levels: levels, enabled: true))
        XCTAssertNil(interaction.pending)
        interaction.pointerChanged(to: 90, current: 80, levels: levels, enabled: true)
        XCTAssertEqual(interaction.pointerReleased(at: 90, current: 80, levels: levels, enabled: true), 90)
    }

    func testLostCaptureClearsDraftWithoutCommitting() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: 90, current: 80, levels: levels, enabled: true)
        interaction.endPointerSequence()
        XCTAssertNil(interaction.draft)
        XCTAssertNil(interaction.pending)
        XCTAssertNil(interaction.pointerReleased(at: 90, current: 80, levels: levels, enabled: true))
    }

    func testResetNotificationBeforeReleaseDoesNotClearTheDraftInline() throws {
        var interaction = NativeBatteryTargetInteraction()
        var commands: [Int] = []
        interaction.pointerChanged(to: 95, current: 80, levels: levels, enabled: true)
        // The view captures this ticket on reset and schedules cleanup separately.
        let resetTicket = try XCTUnwrap(interaction.pointerSequenceID)
        XCTAssertEqual(interaction.draft, 95)
        if let value = interaction.pointerReleased(at: 95, current: 80, levels: levels, enabled: true) { commands.append(value) }
        interaction.endPointerSequence(ifMatching: resetTicket)
        XCTAssertEqual(commands, [95])
        XCTAssertEqual(interaction.pending, 95)
    }

    func testDeferredResetFromPreviousSequenceCannotClearANewDraft() throws {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: 80, current: 80, levels: levels, enabled: true)
        let previous = try XCTUnwrap(interaction.pointerSequenceID)
        XCTAssertNil(interaction.pointerReleased(at: 80, current: 80, levels: levels, enabled: true))
        interaction.pointerChanged(to: 95, current: 80, levels: levels, enabled: true)
        XCTAssertNotEqual(interaction.pointerSequenceID, previous)
        interaction.endPointerSequence(ifMatching: previous)
        XCTAssertEqual(interaction.draft, 95)
        XCTAssertEqual(interaction.pointerReleased(at: 95, current: 80, levels: levels, enabled: true), 95)
    }

    func testDeferredCaptureLossCancelsWithoutAnyReleaseRequest() throws {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: 95, current: 80, levels: levels, enabled: true)
        let resetTicket = try XCTUnwrap(interaction.pointerSequenceID)
        interaction.endPointerSequence(ifMatching: resetTicket)
        XCTAssertNil(interaction.draft)
        XCTAssertNil(interaction.pending)
        XCTAssertNil(interaction.pointerReleased(at: 95, current: 80, levels: levels, enabled: true))
    }

    func testResetTicketDoesNotClearEscapeLatchBeforeCleanupOrRelease() throws {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: 95, current: 80, levels: levels, enabled: true)
        let resetTicket = try XCTUnwrap(interaction.pointerSequenceID)
        interaction.cancel()
        interaction.pointerChanged(to: 100, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.draft)
        XCTAssertEqual(interaction.pointerSequenceID, resetTicket)
        XCTAssertNil(interaction.pointerReleased(at: 100, current: 80, levels: levels, enabled: true))
        interaction.endPointerSequence(ifMatching: resetTicket)
        XCTAssertNil(interaction.pending)
    }

    func testCancelledSequencesNeverReachTheCommandSink() {
        var interaction = NativeBatteryTargetInteraction()
        var commands: [Int] = []
        func sink(_ value: Int?) { if let value { commands.append(value) } }
        interaction.pointerChanged(to: 95, current: 80, levels: levels, enabled: true)
        interaction.cancel()
        interaction.pointerChanged(to: 100, current: 80, levels: levels, enabled: true)
        sink(interaction.pointerReleased(at: 100, current: 80, levels: levels, enabled: true))
        interaction.keyDown(.up, current: 80, levels: levels, enabled: true)
        interaction.blur()
        sink(interaction.keyUp(.up, current: 80, levels: levels, enabled: true))
        interaction.keyDown(.right, current: 80, levels: levels, enabled: true)
        interaction.cancel()
        sink(interaction.keyUp(.right, current: 80, levels: levels, enabled: true))
        sink(interaction.adjust(.up, current: 80, levels: levels, enabled: false))
        XCTAssertEqual(commands, [])
    }

    func testKeyboardHoldUsesDraftAndCommitsOnceOnKeyUp() {
        var interaction = NativeBatteryTargetInteraction()
        var requests: [Int] = []
        interaction.keyDown(.right, current: 80, levels: levels, enabled: true)
        for _ in 0..<2 { interaction.keyDown(.right, repeating: true, current: 80, levels: levels, enabled: true) }
        XCTAssertEqual(interaction.draft, 95)
        XCTAssertNil(interaction.pending)
        if let value = interaction.keyUp(.right, current: 80, levels: levels, enabled: true) { requests.append(value) }
        if let value = interaction.keyUp(.right, current: 80, levels: levels, enabled: true) { requests.append(value) }
        XCTAssertEqual(requests, [95])
    }

    func testUpAndDownDraftAlongTheActualSupportedLevels() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.keyDown(.up, current: 80, levels: levels, enabled: true)
        XCTAssertEqual(interaction.draft, 85)
        XCTAssertEqual(interaction.keyUp(.up, current: 80, levels: levels, enabled: true), 85)
        interaction.commitFinished()
        interaction.keyDown(.down, current: 85, levels: levels, enabled: true)
        XCTAssertEqual(interaction.draft, 80)
        XCTAssertEqual(interaction.keyUp(.down, current: 85, levels: levels, enabled: true), 80)
    }

    func testHomeEndAndLeftDraftWithoutRequestOnPress() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.keyDown(.home, current: 80, levels: levels, enabled: true)
        XCTAssertEqual(interaction.draft, 25)
        XCTAssertNil(interaction.pending)
        XCTAssertEqual(interaction.keyUp(.home, current: 80, levels: levels, enabled: true), 25)
        interaction.commitFinished()
        interaction.keyDown(.end, current: 25, levels: levels, enabled: true)
        XCTAssertEqual(interaction.draft, 100)
        XCTAssertEqual(interaction.keyUp(.end, current: 25, levels: levels, enabled: true), 100)
        interaction.commitFinished()
        interaction.keyDown(.left, current: 100, levels: levels, enabled: true)
        XCTAssertEqual(interaction.keyUp(.left, current: 100, levels: levels, enabled: true), 95)
    }

    func testKeyboardEscapeSinksHeldRepeatsAndRelease() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.keyDown(.right, current: 80, levels: levels, enabled: true)
        interaction.cancel()
        interaction.keyDown(.right, repeating: true, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.draft)
        XCTAssertNil(interaction.keyUp(.right, current: 80, levels: levels, enabled: true))
        interaction.keyDown(.right, current: 80, levels: levels, enabled: true)
        XCTAssertEqual(interaction.keyUp(.right, current: 80, levels: levels, enabled: true), 85)
    }

    func testBlurCancelsKeyboardAndPointerWithoutAnOrphanRepeatRestart() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.keyDown(.right, current: 80, levels: levels, enabled: true)
        interaction.blur()
        interaction.keyDown(.right, repeating: true, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.draft)
        XCTAssertNil(interaction.keyUp(.right, current: 80, levels: levels, enabled: true))
        interaction.pointerChanged(to: 90, current: 80, levels: levels, enabled: true)
        interaction.blur()
        interaction.pointerChanged(to: 95, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.pointerReleased(at: 95, current: 80, levels: levels, enabled: true))
    }

    func testNoRequestWhenTargetIsUnchangedOrBecomesCurrentDuringDraft() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: 80, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.pointerReleased(at: 80, current: 80, levels: levels, enabled: true))
        interaction.keyDown(.up, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.keyUp(.up, current: 85, levels: levels, enabled: true))
        interaction.keyDown(.end, current: 100, levels: levels, enabled: true)
        XCTAssertNil(interaction.keyUp(.end, current: 100, levels: levels, enabled: true))
        XCTAssertNil(interaction.adjust(.up, current: 100, levels: levels, enabled: true))
        XCTAssertNil(interaction.pending)
    }

    func testReadOnlyGateRejectsPointerKeyboardAndAccessibilityRequests() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: 95, current: 80, levels: levels, enabled: false)
        XCTAssertNil(interaction.draft)
        XCTAssertNil(interaction.pointerReleased(at: 95, current: 80, levels: levels, enabled: false))
        interaction.keyDown(.up, current: 80, levels: levels, enabled: false)
        XCTAssertNil(interaction.keyUp(.up, current: 80, levels: levels, enabled: false))
        XCTAssertNil(interaction.adjust(.up, current: 80, levels: levels, enabled: false))
        XCTAssertNil(interaction.pending)
    }

    func testDisablingMidGestureThenReenablingCannotCommitTheOldDraft() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: 90, current: 80, levels: levels, enabled: true)
        interaction.cancel()
        interaction.pointerChanged(to: 95, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.pointerReleased(at: 95, current: 80, levels: levels, enabled: true))
        interaction.keyDown(.right, current: 80, levels: levels, enabled: true)
        interaction.cancel()
        interaction.keyDown(.right, repeating: true, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.keyUp(.right, current: 80, levels: levels, enabled: true))
    }

    func testReleaseChecksTheCurrentReadOnlyGate() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: 90, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.pointerReleased(at: 90, current: 80, levels: levels, enabled: false))
        interaction.keyDown(.right, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.keyUp(.right, current: 80, levels: levels, enabled: false))
    }

    func testPendingRequestBlocksASecondSequenceUntilCallerFinishes() {
        var interaction = NativeBatteryTargetInteraction()
        XCTAssertEqual(interaction.adjust(.up, current: 80, levels: levels, enabled: true), 85)
        XCTAssertNil(interaction.adjust(.up, current: 80, levels: levels, enabled: true))
        interaction.pointerChanged(to: 95, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.pointerReleased(at: 95, current: 80, levels: levels, enabled: true))
        interaction.keyDown(.up, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.keyUp(.up, current: 80, levels: levels, enabled: true))
        interaction.commitFinished()
        XCTAssertEqual(interaction.adjust(.up, current: 85, levels: levels, enabled: true), 90)
    }

    func testMultipleHeldKeysProduceOneRequestOnLastRelease() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.keyDown(.right, current: 80, levels: levels, enabled: true)
        interaction.keyDown(.up, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.keyUp(.right, current: 80, levels: levels, enabled: true))
        XCTAssertEqual(interaction.keyUp(.up, current: 80, levels: levels, enabled: true), 90)
    }

    func testInvalidCoordinatesAndEmptyLevelsCannotCreateRequests() {
        var interaction = NativeBatteryTargetInteraction()
        interaction.pointerChanged(to: .nan, current: 80, levels: levels, enabled: true)
        XCTAssertNil(interaction.pointerReleased(at: .infinity, current: 80, levels: levels, enabled: true))
        interaction.keyDown(.end, current: 80, levels: [], enabled: true)
        XCTAssertNil(interaction.keyUp(.end, current: 80, levels: [], enabled: true))
        XCTAssertNil(interaction.adjust(.up, current: 80, levels: [], enabled: true))
    }
}
