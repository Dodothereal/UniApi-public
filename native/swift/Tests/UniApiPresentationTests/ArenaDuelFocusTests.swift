import AppKit
import XCTest
@testable import UniApiPresentation

@MainActor final class ArenaDuelFocusTests: XCTestCase {
    func testMissingOrNeutralFocusAllowsVoting() async {
        let root = NSView()
        let neutral = NSView()
        root.addSubview(neutral)
        root.addSubview(NSScrollView())

        XCTAssertEqual(NativeArenaDuelFocus.vote(for: .leftArrow, characters: nil, firstResponder: nil), .left)
        XCTAssertEqual(NativeArenaDuelFocus.vote(for: .rightArrow, characters: nil, firstResponder: neutral), .right)
        XCTAssertEqual(NativeArenaDuelFocus.vote(for: nil, characters: "t", firstResponder: neutral), .tie)
        XCTAssertEqual(NativeArenaDuelFocus.vote(for: nil, characters: "T", firstResponder: nil), .tie)
        XCTAssertNil(NativeArenaDuelFocus.vote(for: .upArrow, characters: nil, firstResponder: neutral))
        XCTAssertNil(NativeArenaDuelFocus.vote(for: .downArrow, characters: "t", firstResponder: nil))
    }

    func testScrollViewAndItsNestedRespondersReceiveVerticalArrowsButDoNotBlockVotes() async {
        let root = NSView()
        let scroll = NSScrollView()
        root.addSubview(scroll)
        let content = NSView()
        let nested = NSView()
        let responder = NSResponder()
        scroll.documentView = content
        content.addSubview(nested)
        responder.nextResponder = nested

        XCTAssertTrue(NativeArenaDuelFocus.routesVerticalArrow(to: scroll, firstResponder: scroll, pointer: .zero, in: root))
        XCTAssertTrue(NativeArenaDuelFocus.routesVerticalArrow(to: scroll, firstResponder: nested, pointer: .zero, in: root))
        XCTAssertTrue(NativeArenaDuelFocus.routesVerticalArrow(to: scroll, firstResponder: responder, pointer: .zero, in: root))
        XCTAssertEqual(NativeArenaDuelFocus.vote(for: .leftArrow, characters: nil, firstResponder: responder), .left)
        XCTAssertNil(NativeArenaDuelFocus.vote(for: .downArrow, characters: nil, firstResponder: nested))
    }

    func testVerticalArrowsUseHoveredBlankSpaceWhenNoPaneHasFocus() async {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let left = NSScrollView(frame: NSRect(x: 0, y: 20, width: 145, height: 140))
        let right = NSScrollView(frame: NSRect(x: 155, y: 20, width: 145, height: 140))
        root.addSubview(left)
        root.addSubview(right)
        func routes(to pane: NSScrollView, focus: NSResponder? = nil, x: CGFloat, y: CGFloat = 90) -> Bool {
            NativeArenaDuelFocus.routesVerticalArrow(to: pane, firstResponder: focus, pointer: NSPoint(x: x, y: y), in: root)
        }
        XCTAssertTrue(routes(to: left, x: 140))
        XCTAssertTrue(routes(to: right, x: 285))
        XCTAssertFalse(routes(to: left, x: 150))
        XCTAssertFalse(routes(to: right, x: 150))
        XCTAssertFalse(routes(to: left, x: 140, y: 165))
        XCTAssertTrue(routes(to: right, focus: right, x: 140))
        XCTAssertFalse(routes(to: left, focus: right, x: 140))
        left.isHidden = true
        XCTAssertFalse(routes(to: left, x: 140))
    }
}
