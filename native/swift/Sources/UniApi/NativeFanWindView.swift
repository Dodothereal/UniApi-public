import AppKit
import QuartzCore
import SwiftUI
import UniApiCore

struct NativeFanWindView: NSViewRepresentable {
    let rpm: Double
    let reduceMotion: Bool
    let visible: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> WindView { WindView(frame: .zero) }
    func updateNSView(_ view: WindView, context: Context) {
        view.configure(rpm: rpm, reduceMotion: reduceMotion, visible: visible,
                       tint: NSColor(Theme.accent), dark: colorScheme == .dark)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WindView, context: Context) -> CGSize? {
        // 400/150 are the particle formula's design units, not a card minimum.
        proposal.replacingUnspecifiedDimensions()
    }
    static func dismantleNSView(_ view: WindView, coordinator: ()) { view.stop() }

    final class WindView: NSView {
        private let particles = CALayer()
        private var renderer: NativeFanWindRenderer!
        private var rpm: Double = 0
        private var reduceMotion = false
        private var motionVisible = false
        private var tint = NSColor.clear

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer!.addSublayer(particles)
            renderer = NativeFanWindRenderer(container: particles)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); synchronize() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); needsLayout = true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronize() }
        override func viewDidHide() { super.viewDidHide(); synchronize() }
        override func viewDidUnhide() { super.viewDidUnhide(); synchronize() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); synchronize() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); synchronize() }

        func configure(rpm: Double, reduceMotion: Bool, visible: Bool, tint: NSColor, dark: Bool) {
            self.rpm = rpm; self.reduceMotion = reduceMotion; motionVisible = visible; self.tint = tint
            let name: NSAppearance.Name = dark ? .darkAqua : .aqua
            if appearance?.name != name { appearance = NSAppearance(named: name) }
            synchronize()
        }
        func stop() { renderer.stop() }
        private func synchronize() {
            guard let renderer else { return }
            var color = CGColor(gray: 0, alpha: 0)
            effectiveAppearance.performAsCurrentDrawingAppearance { color = tint.cgColor }
            renderer.layout(in: bounds, contentsScale: window?.backingScaleFactor ?? 2, color: color)
            renderer.update(rpm: rpm, reduceMotion: reduceMotion,
                            visible: motionVisible && window != nil && !isHiddenOrHasHiddenAncestor)
        }
    }
}
