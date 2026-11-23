import AppKit
import WebKit

@MainActor package enum NativeArenaDuelFocus {
    package static func preservesArrowKeys(for firstResponder: NSResponder?) -> Bool {
        var responder = firstResponder
        while let candidate = responder {
            if candidate is NSScrollView || candidate is NSTextView || candidate is NSTextField || candidate is WKWebView {
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
}
