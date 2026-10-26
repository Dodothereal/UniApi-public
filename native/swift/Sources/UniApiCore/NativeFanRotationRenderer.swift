import Foundation
import QuartzCore

/// Only telemetry/visibility boundaries touch the model layer. Core Animation
/// presents the intervening frames without invalidating a SwiftUI view graph.
@MainActor public final class NativeFanRotationRenderer {
    public static let animationKey = "uniapi.fan.rotation"
    private let layer: CALayer
    private let direction: Double
    private let now: () -> Double
    private var clock = NativeVisualClock()
    private var rate: Double?

    public init(layer: CALayer, clockwise: Bool = true, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.layer = layer; direction = clockwise ? -1 : 1; self.now = now
    }

    public func update(rpm: Double, reduceMotion: Bool, visible: Bool) {
        synchronize(rate: reduceMotion || !visible ? 0 : NativeVisualClock.fanRate(rpm))
    }

    public func stop() { synchronize(rate: 0) }

    /// The supplied layer is an independent compositor child, never an AppKit
    /// backing layer whose anchor/position are controlled by view layout.
    public func layout(in bounds: CGRect, contentsScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.bounds = CGRect(origin: .zero, size: bounds.size)
        layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.contentsScale = contentsScale
        CATransaction.commit()
    }

    private func synchronize(rate next: Double) {
        guard rate != next else { return }
        let time = now()
        guard time.isFinite else { return }
        clock.update(at: time, rate: next)
        rate = next
        // Unflipped AppKit hosts have upward-positive coordinates. The default
        // retains SwiftUI's clockwise spin; the menu keeps its original CCW spin.
        let angle = direction * clock.value(at: time).truncatingRemainder(dividingBy: 1) * 2 * Double.pi
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: Self.animationKey)
        layer.setValue(angle, forKeyPath: "transform.rotation.z")
        if next > 0 {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = angle
            animation.toValue = angle + direction * 2 * Double.pi
            animation.duration = 1 / next
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.add(animation, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }
}
