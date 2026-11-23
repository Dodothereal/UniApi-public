import AppKit
import XCTest
@testable import UniApiPresentation

@MainActor final class ArenaDuelFocusTests: XCTestCase {
    func testMissingOrNeutralFocusAllowsVoting() async {
        let root = NSView()
        let neutral = NSView()
        root.addSubview(neutral)
        root.addSubview(NSScrollView())

        XCTAssertFalse(NativeArenaDuelFocus.preservesArrowKeys(for: nil))
        XCTAssertFalse(NativeArenaDuelFocus.preservesArrowKeys(for: neutral))
    }

    func testScrollViewAndItsNestedRespondersKeepArrowKeys() async {
        let scroll = NSScrollView()
        let content = NSView()
        let nested = NSView()
        let responder = NSResponder()
        scroll.documentView = content
        content.addSubview(nested)
        responder.nextResponder = nested

        XCTAssertTrue(NativeArenaDuelFocus.preservesArrowKeys(for: scroll))
        XCTAssertTrue(NativeArenaDuelFocus.preservesArrowKeys(for: nested))
        XCTAssertTrue(NativeArenaDuelFocus.preservesArrowKeys(for: responder))
    }
}
