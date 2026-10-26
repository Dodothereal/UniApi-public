import SwiftUI
import AppKit
import UniApiCore

private struct NativeReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// An app preference may reduce motion further, never override the OS's
    /// accessibility request. SwiftUI's system value is intentionally read-only.
    var nativeReducedMotion: Bool {
        get { accessibilityReduceMotion || self[NativeReducedMotionKey.self] }
        set { self[NativeReducedMotionKey.self] = newValue }
    }
}

/// Recovered native timings. These are applied at the changing component,
/// never as a transaction on the application's root or its data store.
enum NativeMotion {
    static let press = Animation.easeOut(duration: 0.12)
    static let hover = Animation.easeOut(duration: 0.13)
    static let toggle = Animation.spring(duration: 0.22)
    static let segmented = Animation.spring(duration: 0.3)
    static let number = Animation.spring(NativeNumberHost.transitionSpring)
    static let bar = Animation.spring(duration: 0.6)
    static let barUpdate = Animation.spring(duration: 0.5)
    static let sidebar = Animation.spring(duration: 0.34, bounce: 0.08)
    static let isolation = Animation.easeOut(duration: 0.25)
    static let cycle: Double = 2.2

    static func firstDelay(_ seconds: Double) -> Double {
        seconds.isFinite ? min(0.35, max(0, seconds)) : 0
    }

    static func fraction(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    static func withoutAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }

    static func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

private struct NativeMotionVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Pages may additionally set this to false when retained behind another tab.
    var nativeMotionVisible: Bool {
        get { self[NativeMotionVisibleKey.self] }
        set { self[NativeMotionVisibleKey.self] = newValue }
    }
}

private struct NativeVisibilityProbe: NSViewRepresentable {
    var changed: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.changed = changed
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.changed = changed
        view.scheduleCheck()
    }

    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) {
        view.stop()
    }

    final class VisibilityView: NSView {
        var changed: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var scheduled = false
        private var lastValue: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observe() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observe() }
        override func viewDidHide() { super.viewDidHide(); scheduleCheck() }
        override func viewDidUnhide() { super.viewDidUnhide(); scheduleCheck() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); scheduleCheck() }
        override func setFrameOrigin(_ origin: NSPoint) { super.setFrameOrigin(origin); scheduleCheck() }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            changed = nil
        }

        private func observe() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            let center = NotificationCenter.default
            func listen(_ name: Notification.Name, object: AnyObject?) {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    self?.scheduleCheck()
                })
            }
            if let window {
                listen(NSWindow.didChangeOcclusionStateNotification, object: window)
                listen(NSWindow.didMiniaturizeNotification, object: window)
                listen(NSWindow.didDeminiaturizeNotification, object: window)
                listen(NSWindow.willCloseNotification, object: window)
            }
            listen(NSApplication.didHideNotification, object: NSApp)
            listen(NSApplication.didUnhideNotification, object: NSApp)
            var ancestor = superview
            while let view = ancestor {
                if let clip = view as? NSClipView {
                    // A view can remain mounted while scrolling outside its clip.
                    clip.postsBoundsChangedNotifications = true
                    listen(NSView.boundsDidChangeNotification, object: clip)
                }
                ancestor = view.superview
            }
            scheduleCheck()
        }

        func scheduleCheck() {
            guard !scheduled else { return }
            scheduled = true
            // Updating SwiftUI state synchronously during layout is forbidden.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scheduled = false
                let visible = self.window.map {
                    $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
                } ?? false
                let value = visible && !NSApp.isHidden && !self.isHiddenOrHasHiddenAncestor
                    && !self.visibleRect.isEmpty
                guard value != self.lastValue else { return }
                self.lastValue = value
                self.changed?(value)
            }
        }
    }
}

private struct NativeVisibilityModifier: ViewModifier {
    @Environment(\.nativeMotionVisible) private var inheritedVisibility
    @State private var visible: Bool

    init(initiallyVisible: Bool) { _visible = State(initialValue: initiallyVisible) }

    func body(content: Content) -> some View {
        content
            .environment(\.nativeMotionVisible, inheritedVisibility && visible)
            .background {
                NativeVisibilityProbe { visible = $0 }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
    }
}

enum NativeEntrance {
    case page, row, grow, growVertical, rule, fade

    var animation: Animation {
        switch self {
        case .page: return .easeOut(duration: 0.16)
        case .row: return .spring(duration: 0.5)
        case .grow, .growVertical: return NativeMotion.bar
        case .rule: return .spring(duration: 0.65)
        case .fade: return .easeOut(duration: 0.25)
        }
    }
    var settlement: Double { self == .page ? 0.22 : self == .rule ? 0.75 : 0.7 }
}

private struct NativeEntranceModifier: ViewModifier {
    var kind: NativeEntrance
    var delay: Double
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    @State private var revealed = false
    @State private var settled = false
    private var allowed: Bool { !reduceMotion && visible }

    func body(content: Content) -> some View {
        let final = revealed || settled || !allowed
        content
            .opacity(final || kind == .grow || kind == .growVertical || kind == .rule ? 1 : kind == .page ? 0.96 : 0)
            .offset(y: final ? 0 : (kind == .page ? 2 : (kind == .row ? 9 : 0)))
            .scaleEffect(x: !final && (kind == .grow || kind == .rule) ? 0 : 1,
                         y: !final && kind == .growVertical ? 0 : 1,
                         anchor: kind == .growVertical ? .bottom : .leading)
            .animation(allowed && !settled ? kind.animation : nil, value: revealed)
            .animation(nil, value: settled)
            .task(id: allowed) {
                guard allowed, !revealed, !settled else {
                    NativeMotion.withoutAnimation { revealed = true; settled = true }
                    return
                }
                do {
                    await Task.yield()
                    try await NativeMotion.sleep(NativeMotion.firstDelay(delay))
                    try Task.checkCancellation()
                    revealed = true
                    // A hidden window must never depend on animation completion
                    // to show its content when it becomes visible again.
                    try await NativeMotion.sleep(kind.settlement)
                    try Task.checkCancellation()
                    NativeMotion.withoutAnimation { settled = true }
                } catch { /* SwiftUI cancels the task on unmount or policy change. */ }
            }
    }
}

extension View {
    func nativeMotionVisibility(initiallyVisible: Bool = true) -> some View {
        modifier(NativeVisibilityModifier(initiallyVisible: initiallyVisible))
    }
    func nativeEntrance(_ kind: NativeEntrance = .page, delay: Double = 0) -> some View {
        modifier(NativeEntranceModifier(kind: kind, delay: delay))
    }
}

/// Only whole, actual formatted values enter Text. There is no Animatable
/// scalar, invented zero seed, rounding sequence, or unit-changing formatter.
struct NativeNumberText: View {
    var text: String
    var font: Font = Theme.mono(12)
    var color: Color = Theme.ink
    var delay: Double = 0
    var animation: Animation = NativeMotion.number
    var isolateLayout = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    @State private var displayed: String?
    @State private var firstDeadline: Double?
    @State private var animateDigits = true
    private var allowed: Bool { !reduceMotion && visible }

    private struct Request: Equatable { var text: String; var allowed: Bool }

    var body: some View {
        ZStack(alignment: .leading) {
            // Reserve the complete formatted width before a delayed first reveal.
            Text(text).hidden().accessibilityHidden(true)
            if isolateLayout && animation == NativeMotion.number {
                // The hidden Text keeps the same font metrics and baselines.
                // Frequently changing telemetry rolls on compositor layers
                // instead of relaying every frame through the page.
                Text(text).hidden().accessibilityHidden(true)
                    .overlay {
                        NativeNumberHost(text: allowed ? (displayed ?? "") : text,
                                         font: font, color: color,
                                         animation: allowed && animateDigits ? animation : nil)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            } else {
                Text(allowed ? (displayed ?? "") : text)
                    .contentTransition(allowed && animateDigits ? .numericText() : .identity)
                    .animation(allowed && animateDigits ? animation : nil, value: displayed)
            }
        }
        .font(font).foregroundStyle(color).monospacedDigit().lineLimit(1)
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
        .task(id: Request(text: text, allowed: allowed)) {
            guard allowed else {
                NativeMotion.withoutAnimation { displayed = text; animateDigits = false }
                return
            }
            guard displayed != text else { return }
            do {
                if displayed == nil {
                    // Keep the original deadline if a poll changes the target
                    // during the delay; frequent polls cannot postpone it forever.
                    let now = ProcessInfo.processInfo.systemUptime
                    let deadline = firstDeadline ?? (now + NativeMotion.firstDelay(delay))
                    firstDeadline = deadline
                    try await NativeMotion.sleep(max(0, deadline - now))
                }
                try Task.checkCancellation()
                animateDigits = true
                displayed = text
                try await NativeMotion.sleep(0.8)
                try Task.checkCancellation()
                NativeMotion.withoutAnimation { animateDigits = false }
            } catch { /* A changed target cancels the old delayed write. */ }
        }
        .onDisappear {
            NativeMotion.withoutAnimation { displayed = text; animateDigits = false }
        }
    }
}

struct TickerText: View {
    var text: String
    var font: Font
    var color: Color = Theme.ink
    var body: some View { NativeNumberText(text: text, font: font, color: color) }
}

struct NativeStatusDot: View {
    var color: Color
    var size: CGFloat = 6
    var pulse: Bool = false
    var body: some View {
        if pulse {
            NativePulseBody(color: color, size: size)
                .nativeMotionVisibility(initiallyVisible: false)
        } else {
            Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

private struct NativePulseBody: View {
    var color: Color
    var size: CGFloat
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    private var allowed: Bool { !reduceMotion && visible }
    var body: some View {
        NativePulseView(color: color, size: size, active: allowed)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct ShimmerText: View {
    var text: String
    var font: Font = Theme.mono(11)
    var body: some View {
        NativeShimmerBody(text: text, font: font)
            .nativeMotionVisibility(initiallyVisible: false)
    }
}

private struct NativeShimmerBody: View {
    var text: String
    var font: Font
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    private var allowed: Bool { !reduceMotion && visible }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !allowed)) { context in
            Text(text).font(font).foregroundStyle(Theme.muted)
                .overlay {
                    if allowed {
                        GeometryReader { geometry in
                            let width = geometry.size.width
                            let phase = context.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: NativeMotion.cycle) / NativeMotion.cycle
                            LinearGradient(colors: [.clear, Theme.ink.opacity(0.85), .clear],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: max(40, width * 0.35))
                                .offset(x: -width * 0.4 + width * 1.5 * phase)
                        }
                        .mask(Text(text).font(font))
                        .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}
