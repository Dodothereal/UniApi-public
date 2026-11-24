import SwiftUI
import AppKit
import WebKit
import UniApiCore
import UniApiPresentation

/// An AppKit scroll surface lets streaming content grow without interpreting
/// layout-driven bounds changes as a user's scroll. Selection, scroller drag,
/// trackpad/wheel and keyboard up/down continue to use the native responder.
struct NativeCodeScroll<Content: View>: NSViewRepresentable {
    let content: Content
    var jump: Int = 0
    let follows: Binding<Bool>?
    var padding: EdgeInsets
    var scrollsOnHover: Bool
    @Environment(\.nativePageActivation) private var activation
    @Environment(\.nativeMotionVisible) private var motionVisible
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.colorScheme) private var colorScheme
    init(jump: Int = 0, follows: Binding<Bool>? = nil,
         padding: EdgeInsets = .init(top: 12, leading: 12, bottom: 12, trailing: 12),
         scrollsOnHover: Bool = false, @ViewBuilder content: () -> Content) {
        self.jump = jump; self.follows = follows; self.padding = padding; self.scrollsOnHover = scrollsOnHover; self.content = content()
    }
    func makeCoordinator() -> Coordinator { Coordinator(follows: follows) }
    func makeNSView(context: Context) -> Scroll {
        let scroll = Scroll(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = false; scroll.drawsBackground = false; scroll.autohidesScrollers = true
        scroll.documentView = context.coordinator.host; scroll.contentView.postsBoundsChangedNotifications = true
        scroll.didLayout = { [weak coordinator = context.coordinator, weak scroll] in if let scroll { coordinator?.layout(scroll) } }
        context.coordinator.observe(scroll); context.coordinator.jump = jump
        updateNSView(scroll, context: context); return scroll
    }
    func updateNSView(_ scroll: Scroll, context: Context) {
        let coordinator = context.coordinator
        coordinator.binding = follows
        coordinator.scrollsOnHover = scrollsOnHover && activation.active
        if coordinator.jump != jump { coordinator.jump = jump; coordinator.policy.jumpToBottom() }
        // A nested NSHostingView starts a new environment. Forward policy and
        // appearance explicitly so retained transcripts cannot keep child
        // image reads/motion active or silently lose the chosen density/theme.
        // The measure is applied by the coordinator: the scroll view has no
        // width yet when it is first made, and a resize arrives without an update.
        let content = content, padding = padding, activation = activation, motionVisible = motionVisible, reducedMotion = reducedMotion, density = density, colorScheme = colorScheme
        coordinator.root = { width in
            AnyView(content.padding(padding).frame(width: width, alignment: .topLeading).fixedSize(horizontal: false, vertical: true).frame(maxHeight: .infinity, alignment: .topLeading)
                .environment(\.nativePageActivation, activation)
                .environment(\.nativeMotionVisible, motionVisible)
                .environment(\.nativeReducedMotion, reducedMotion)
                .environment(\.nativeInterfaceDensity, density)
                .environment(\.colorScheme, colorScheme))
        }
        coordinator.apply(max(1, scroll.contentSize.width))
        coordinator.layout(scroll)
        DispatchQueue.main.async { [weak coordinator, weak scroll] in if let scroll { coordinator?.layout(scroll) } }
    }
    static func dismantleNSView(_ scroll: Scroll, coordinator: Coordinator) {
        scroll.didLayout = nil; coordinator.stop()
    }
    final class Scroll: NSScrollView {
        var didLayout: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); super.mouseDown(with: event) }
        override func layout() { super.layout(); didLayout?() }
        override func keyDown(with event: NSEvent) {
            let viewport = contentSize.height, current = contentView.bounds.origin.y, maximum = max(0, (documentView?.frame.height ?? 0) - viewport)
            let target: CGFloat?
            switch event.keyCode { case 126: target = current - 40; case 125: target = current + 40; case 116: target = current - viewport * 0.85; case 121: target = current + viewport * 0.85; case 115: target = 0; case 119: target = maximum; default: target = nil }
            if let target { contentView.scroll(to: NSPoint(x: 0, y: min(maximum, max(0, target)))); reflectScrolledClipView(contentView) } else { super.keyDown(with: event) }
        }
    }
    final class Host: NSHostingView<AnyView> { var resized: (() -> Void)?; override func invalidateIntrinsicContentSize() { super.invalidateIntrinsicContentSize(); resized?() } }
    final class Coordinator {
        let host = Host(rootView: AnyView(EmptyView()))
        var policy = CodeScrollPolicy(), binding: Binding<Bool>?, jump = 0, updating = false, layingOut = false
        var scrollsOnHover = false
        var root: ((CGFloat) -> AnyView)?
        private var measure: CGFloat = 0
        func apply(_ width: CGFloat) {
            guard let root else { return }
            measure = width; updating = true; host.rootView = root(width); updating = false
        }
        private var observer: NSObjectProtocol?
        private var keys: Any?
        init(follows: Binding<Bool>?) { binding = follows; host.isFlipped = true }
        func observe(_ scroll: Scroll) {
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self, weak scroll] _ in
                guard let self, let scroll, !self.updating, !self.layingOut else { return }
                let distance = max(0, self.host.frame.height - scroll.contentView.bounds.maxY)
                self.policy.userScrolled(distanceToBottom: Double(distance)); self.publish()
            }
            host.resized = { [weak self, weak scroll] in DispatchQueue.main.async { if let scroll { self?.layout(scroll) } } }
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak scroll] event in
                // A retained window can still have this reader as its responder
                // while a sheet or another window owns the incoming key event.
                guard let scroll, let window = scroll.window, event.window === window,
                      window.isVisible, !window.isMiniaturized, !NSApp.isHidden,
                      [UInt16(126), 125, 116, 121, 115, 119].contains(event.keyCode),
                      event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty else { return event }
                if self?.scrollsOnHover == true, event.keyCode == 125 || event.keyCode == 126 {
                    guard window.isKeyWindow, window.attachedSheet == nil, let root = window.contentView,
                          NativeArenaDuelFocus.routesVerticalArrow(to: scroll, firstResponder: window.firstResponder,
                                                                 pointer: root.convert(window.mouseLocationOutsideOfEventStream, from: nil),
                                                                 in: root) else { return event }
                    scroll.keyDown(with: event); return nil
                }
                guard let responder = window.firstResponder as? NSView else { return event }
                if let text = responder as? NSTextView, text.isEditable { return event }
                var view: NSView? = responder
                while let candidate = view, candidate !== scroll {
                    if candidate is WKWebView || candidate is NSScrollView { return event }
                    view = candidate.superview
                }
                guard view === scroll else { return event }
                scroll.keyDown(with: event); return nil
            }
        }
        func layout(_ scroll: Scroll) {
            guard !layingOut else { return }; layingOut = true; defer { layingOut = false }
            let width = max(1, scroll.contentSize.width), viewport = scroll.contentSize.height, old = host.frame.height, offset = scroll.contentView.bounds.origin.y
            if abs(measure - width) > 0.5 { apply(width) }
            if abs(host.frame.width - width) > 0.5 { host.setFrameSize(NSSize(width: width, height: old)) }
            host.layoutSubtreeIfNeeded()
            let fitted = max(viewport, host.fittingSize.height)
            guard fitted.isFinite else { return }
            if abs(host.frame.height - fitted) > 0.5 { host.setFrameSize(NSSize(width: width, height: fitted)) }
            let target = binding == nil ? min(max(0, fitted - viewport), offset)
                : policy.target(oldHeight: Double(old), newHeight: Double(fitted), viewport: Double(viewport), oldOffset: Double(offset))
            if abs(Double(offset) - target) > 0.5 { scroll.contentView.scroll(to: NSPoint(x: 0, y: target)); scroll.reflectScrolledClipView(scroll.contentView) }
            publish()
        }
        private func publish() { let value = policy.follows; if let binding, binding.wrappedValue != value { DispatchQueue.main.async { [weak self] in self?.binding?.wrappedValue = value } } }
        func stop() { root = nil; if let observer { NotificationCenter.default.removeObserver(observer) }; if let keys { NSEvent.removeMonitor(keys) }; keys = nil; observer = nil; host.resized = nil }
        deinit { stop() }
    }
}
