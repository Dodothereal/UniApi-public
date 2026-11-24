import AppKit
import WebKit

@MainActor package enum NativeArenaDuelFocus {
    package static func preservesArrowKeys(for firstResponder: NSResponder?, excludingScrollViews: Bool = false) -> Bool {
        var responder = firstResponder
        while let candidate = responder {
            if (!excludingScrollViews && candidate is NSScrollView) || candidate is NSTextView || candidate is NSTextField || candidate is WKWebView {
                return true
            }
            if let view = candidate as? NSView {
                responder = view.superview
            } else {
                responder = candidate.nextResponder
            }
        }
        return false
    }

    package static func readingPane(at point: NSPoint, in coordinateView: NSView, among panes: [NSScrollView]) -> NSScrollView? {
        panes.first {
            let localPoint = $0.convert(point, from: coordinateView)
            return !$0.isHiddenOrHasHiddenAncestor && $0.bounds.contains(localPoint) && $0.visibleRect.contains(localPoint)
        }
    }
}
