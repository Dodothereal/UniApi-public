import AppKit
import WebKit
import UniApiCore

@MainActor package enum NativeArenaDuelFocus {
    package static func vote(for key: NSEvent.SpecialKey?, characters: String?, firstResponder: NSResponder?) -> ArenaDuel.Choice? {
        guard !ownsNavigationKeys(firstResponder) else { return nil }
        switch key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case nil: return characters?.lowercased() == "t" ? .tie : nil
        default: return nil
        }
    }

    package static func routesVerticalArrow(to pane: NSScrollView, firstResponder: NSResponder?,
                                            pointer: NSPoint, in coordinateView: NSView) -> Bool {
        guard !ownsNavigationKeys(firstResponder), !pane.isHiddenOrHasHiddenAncestor else { return false }
        if let focusedScroll = firstView(from: firstResponder, matching: { $0 is NSScrollView }) {
            return focusedScroll === pane
        }
        let localPoint = pane.convert(pointer, from: coordinateView)
        return pane.bounds.contains(localPoint) && pane.visibleRect.contains(localPoint)
    }

    private static func ownsNavigationKeys(_ responder: NSResponder?) -> Bool {
        firstView(from: responder) { $0 is NSTextView || $0 is NSTextField || $0 is WKWebView } != nil
    }

    private static func firstView(from firstResponder: NSResponder?, matching: (NSView) -> Bool) -> NSView? {
        var responder = firstResponder
        while let candidate = responder {
            if let view = candidate as? NSView {
                if matching(view) { return view }
                responder = view.superview
            } else {
                responder = candidate.nextResponder
            }
        }
        return nil
    }
}
