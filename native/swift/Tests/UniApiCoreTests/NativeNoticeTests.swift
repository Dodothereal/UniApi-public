import XCTest
@testable import UniApiCore

final class NativeNoticeTests: XCTestCase {
    func testOverflowUsesSameExitAndRetainsAtMostFourActive() {
        var q = NativeNoticeQueue()
        for i in 0..<6 { q.push("Message \(i)", now: 10) }
        XCTAssertEqual(q.rows.count, 6)
        XCTAssertEqual(q.rows.filter { $0.leaving == nil }.map(\.text), (2..<6).map { "Message \($0)" })
        XCTAssertEqual(q.nextDeadline, 10.16)
        q.advance(now: 10.16)
        XCTAssertEqual(q.rows.map(\.text), (2..<6).map { "Message \($0)" })
    }
    func testErrorAndNormalLifetimeThenFade() {
        var q = NativeNoticeQueue()
        q.push("Saved", kind: .success, now: 2)
        q.push("Failed", kind: .error, now: 2)
        q.advance(now: 5.2)
        XCTAssertEqual(q.rows.first?.leaving, 5.2)
        XCTAssertNil(q.rows.last?.leaving)
        q.advance(now: 5.37)
        XCTAssertEqual(q.rows.map(\.text), ["Failed"])
        q.advance(now: 20)
        XCTAssertTrue(q.rows.isEmpty)
        XCTAssertNil(q.nextDeadline)
    }
    func testDismissDuringEntranceIsIdempotentAndDoesNotAffectNewRows() {
        var q = NativeNoticeQueue()
        let id = q.push("Old", now: 0)!
        q.dismiss(id, now: 0.01); q.dismiss(id, now: 0.1)
        XCTAssertEqual(q.rows[0].leaving, 0.01)
        let next = q.push("New", now: 0.02)!
        XCTAssertNotEqual(id, next)
        q.advance(now: 0.18)
        XCTAssertEqual(q.rows.map(\.id), [next])
    }
    func testDuplicateErrorsDoNotExtendLifetimeButNewErrorsAfterDismissAreVisible() {
        var q = NativeNoticeQueue()
        let id = q.push("Reader unavailable", kind: .error, now: 0)!
        XCTAssertNil(q.push("Reader unavailable", kind: .error, now: 5))
        XCTAssertEqual(q.rows[0].expires, 6)
        q.dismiss(id, now: 5)
        XCTAssertNotNil(q.push("Reader unavailable", kind: .error, now: 5.01))
        XCTAssertEqual(q.rows.filter { $0.leaving == nil }.count, 1)
    }
    func testEmptyAndInvalidClockInputsAreIgnored() {
        var q = NativeNoticeQueue()
        XCTAssertNil(q.push(" \n", now: 0))
        XCTAssertNil(q.push("Never", now: .infinity))
        q.advance(now: .nan)
        XCTAssertTrue(q.rows.isEmpty)
    }
}
