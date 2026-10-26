import AppKit
import QuartzCore
import SwiftUI

/// Keep persistent opacity on the compositor instead of scheduling a SwiftUI
/// body update every frame when the reading itself has not changed.
struct NativePulseView: NSViewRepresentable {
    let color: Color
    let size: CGFloat
    let active: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> PulseView { PulseView(frame: .zero) }
    func updateNSView(_ view: PulseView, context: Context) {
        view.configure(color: NSColor(color), active: active, dark: colorScheme == .dark)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PulseView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? size, height: proposal.height ?? size)
    }
    static func dismantleNSView(_ view: PulseView, coordinator: ()) { view.stop() }

    final class PulseView: NSView {
        private let dot = CAShapeLayer()
        private let animationKey = "uniapi.status.opacity"
        private var color = NSColor.clear
        private var requested = false
        private var animating = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer!.addSublayer(dot)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); synchronize() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronize() }
        override func viewDidHide() { super.viewDidHide(); synchronize() }
        override func viewDidUnhide() { super.viewDidUnhide(); synchronize() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); synchronize() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); synchronize() }

        func configure(color: NSColor, active: Bool, dark: Bool) {
            self.color = color
            requested = active
            let name: NSAppearance.Name = dark ? .darkAqua : .aqua
            if appearance?.name != name { appearance = NSAppearance(named: name) }
            synchronize()
        }

        func stop() {
            dot.removeAnimation(forKey: animationKey)
            animating = false
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.opacity = 1
            CATransaction.commit()
        }

        private func synchronize() {
            let valid = bounds.width.isFinite && bounds.height.isFinite && bounds.width > 0 && bounds.height > 0
            CATransaction.begin(); CATransaction.setDisableActions(true)
            dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            dot.bounds = CGRect(origin: .zero, size: valid ? bounds.size : .zero)
            dot.position = valid ? CGPoint(x: bounds.midX, y: bounds.midY) : .zero
            dot.path = valid ? CGPath(ellipseIn: dot.bounds, transform: nil) : nil
            dot.contentsScale = window?.backingScaleFactor ?? 2
            effectiveAppearance.performAsCurrentDrawingAppearance { dot.fillColor = color.cgColor }
            dot.opacity = 1
            CATransaction.commit()

            let shouldAnimate = requested && valid && window != nil && !isHiddenOrHasHiddenAncestor
            guard shouldAnimate != animating else { return }
            guard shouldAnimate else { stop(); return }
            let animation = CABasicAnimation(keyPath: "opacity")
            animation.fromValue = Float(0.35)
            animation.toValue = Float(1)
            animation.duration = NativeMotion.cycle / 2
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            // Match the original shared wall-clock phase, including reentry;
            // hiding/reduced motion shows a fully opaque stationary dot.
            let elapsed = Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: NativeMotion.cycle)
            animation.beginTime = dot.convertTime(CACurrentMediaTime(), from: nil) - elapsed
            dot.add(animation, forKey: animationKey)
            animating = true
        }
    }
}
