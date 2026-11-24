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

    func testClickTargetsUseVisiblePaneBoundsRatherThanTextOrChrome() async {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let left = NSScrollView(frame: NSRect(x: 0, y: 20, width: 145, height: 140))
        let right = NSScrollView(frame: NSRect(x: 155, y: 20, width: 145, height: 140))
        root.addSubview(left)
        root.addSubview(right)
        let panes = [left, right]

        XCTAssertTrue(NativeArenaDuelFocus.readingPane(at: NSPoint(x: 140, y: 90), in: root, among: panes) === left)
        XCTAssertTrue(NativeArenaDuelFocus.readingPane(at: NSPoint(x: 285, y: 90), in: root, among: panes) === right)
        XCTAssertNil(NativeArenaDuelFocus.readingPane(at: NSPoint(x: 150, y: 90), in: root, among: panes))
        XCTAssertNil(NativeArenaDuelFocus.readingPane(at: NSPoint(x: 140, y: 165), in: root, among: panes))
        left.isHidden = true
        XCTAssertNil(NativeArenaDuelFocus.readingPane(at: NSPoint(x: 140, y: 90), in: root, among: panes))
    }
}
