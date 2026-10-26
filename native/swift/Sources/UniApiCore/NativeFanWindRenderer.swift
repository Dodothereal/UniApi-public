import Foundation
import QuartzCore

/// Static particle artwork and compositor-only motion. The container must be an
/// independent child of an unflipped AppKit host, never its backing layer.
@MainActor public final class NativeFanWindRenderer {
    public static let animationKey = "uniapi.fan.wind"
    private struct Particle {
        let layer: CALayer
        let trail: CAGradientLayer
        let mask: CAShapeLayer
        let dot: CAShapeLayer
    }
    private let container: CALayer
    private let particles: [Particle]
    private let now: () -> Double
    private var clock = NativeVisualClock()
    private var rate: Double?
    private var lengthFactor = 0.35
    private var opacity: Float = 0
    private var bounds = CGRect.zero
    private var scale: CGFloat = 1
    private var color = CGColor(gray: 0, alpha: 0)

    // A recording layer factory lets fixtures observe actual production add and
    // remove calls without assuming render-server retention on unattached layers.
    public init(container: CALayer, particleLayer: (Int) -> CALayer = { _ in CALayer() },
                now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.container = container; self.now = now
        container.masksToBounds = true
        // Canvas has downward-positive Y. Flip only this owned child coordinate
        // space; AppKit continues to own the unchanged root geometry.
        container.isGeometryFlipped = true
        container.opacity = 0
        particles = (0..<18).map { index in
            let layer = particleLayer(index), trail = CAGradientLayer()
            let mask = CAShapeLayer(), dot = CAShapeLayer()
            mask.lineWidth = 1.2; mask.lineCap = .round
            mask.fillColor = nil; mask.strokeColor = CGColor(gray: 1, alpha: 1)
            trail.mask = mask
            layer.addSublayer(trail); layer.addSublayer(dot)
            container.addSublayer(layer)
            return Particle(layer: layer, trail: trail, mask: mask, dot: dot)
        }
    }

    public func update(rpm: Double, reduceMotion: Bool, visible: Bool) {
        let next = reduceMotion || !visible || !rpm.isFinite ? 0 : max(0, rpm) / 3000
        let length = rpm.isNaN ? 0.35 : max(0.35, min(1.8, rpm / 4500))
        let alpha: Float = rpm > 0 && !reduceMotion ? 1 : 0
        guard rate != next || lengthFactor != length || opacity != alpha else { return }
        let time = now(); guard time.isFinite else { return }
        clock.update(at: time, rate: next)
        let restyle = lengthFactor != length
        rate = next; lengthFactor = length; opacity = alpha
        changeLayers(elapsed: clock.value(at: time), restyle: restyle)
    }

    public func stop() {
        guard rate != 0 else { return }
        let time = now(); guard time.isFinite else { return }
        clock.update(at: time, rate: 0); rate = 0
        changeLayers(elapsed: clock.value(at: time), restyle: false)
    }

    public func layout(in bounds: CGRect, contentsScale: CGFloat, color: CGColor) {
        guard bounds.origin.x.isFinite, bounds.origin.y.isFinite,
              bounds.width.isFinite, bounds.height.isFinite,
              bounds.midX.isFinite, bounds.midY.isFinite,
              bounds.width >= 0, bounds.height >= 0,
              contentsScale.isFinite, contentsScale > 0,
              (1 / contentsScale).isFinite else { return }
        guard self.bounds != bounds || scale != contentsScale || self.color != color else { return }
        let time = now(); guard time.isFinite else { return }
        self.bounds = bounds; scale = contentsScale; self.color = color
        changeLayers(elapsed: clock.value(at: time), restyle: true)
    }

    private func changeLayers(elapsed: Double, restyle: Bool) {
        guard elapsed.isFinite else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        container.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        container.bounds = CGRect(origin: .zero, size: bounds.size)
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
        container.contentsScale = scale; container.opacity = opacity
        let mediaTime = CACurrentMediaTime()
        for (index, particle) in particles.enumerated() {
            if restyle { style(particle, index: index) }
            let duration = 7.2 + Double(index % 3) * 0.45
            let offset = Double(index * 1733 % 8000) / 1000
            let progress = (elapsed + offset).truncatingRemainder(dividingBy: duration) / duration
            let x = (-80 + progress * 560) / 400 * Double(bounds.width)
            let y = (Double(16 + index % 6 * 23) + sin(progress * .pi * 2 + Double(index % 3) * 0.4) * 9) / 150 * Double(bounds.height)
            particle.layer.removeAnimation(forKey: Self.animationKey)
            particle.layer.position = CGPoint(x: x, y: y)
            guard let rate, rate > 0, !bounds.isEmpty else { continue }
            let period = duration / rate
            guard period.isFinite, period > 0 else { continue }
            let horizontal = CABasicAnimation(keyPath: "position.x")
            horizontal.fromValue = -80 / 400 * Double(bounds.width)
            horizontal.toValue = 480 / 400 * Double(bounds.width)
            horizontal.duration = period
            horizontal.timingFunction = CAMediaTimingFunction(name: .linear)
            let vertical = CAKeyframeAnimation(keyPath: "position.y")
            // Linear interpolation of sine has error <= A*(2*pi/N)^2/8.
            // Choose N from the actual point height for a <=0.005pt bound.
            let amplitude = 9 * Double(bounds.height) / 150
            let required = ceil(.pi * sqrt(amplitude / (2 * 0.005)))
            guard required.isFinite, required < Double(Int.max - 1) else { continue }
            let segments = max(128, Int(required))
            vertical.values = (0...segments).map { step in
                let phase = Double(step) / Double(segments)
                return (Double(16 + index % 6 * 23) + sin(phase * 2 * .pi + Double(index % 3) * 0.4) * 9) / 150 * Double(bounds.height)
            }
            vertical.keyTimes = (0...segments).map { NSNumber(value: Double($0) / Double(segments)) }
            vertical.calculationMode = .linear; vertical.duration = period
            vertical.timingFunction = CAMediaTimingFunction(name: .linear)
            let animation = CAAnimationGroup()
            animation.animations = [horizontal, vertical]
            animation.duration = period; animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.timeOffset = progress * period
            animation.beginTime = particle.layer.convertTime(mediaTime, from: nil)
            particle.layer.add(animation, forKey: Self.animationKey)
        }
    }

    private func style(_ particle: Particle, index: Int) {
        let length = 46 * lengthFactor / 400 * Double(bounds.width)
        let radius: CGFloat = index % 3 == 0 ? 1.25 : 0.8
        let extent = CGFloat(length) + 0.6 + radius
        particle.layer.bounds = CGRect(x: -length - 0.6, y: -radius, width: extent, height: radius * 2)
        particle.layer.anchorPoint = CGPoint(x: (CGFloat(length) + 0.6) / extent, y: 0.5)
        particle.layer.contentsScale = scale
        // A tight gradient backing clips the stroke's antialiased edge a second
        // time. One raster pixel of backing preserves coverage without moving
        // the physical path or either gradient endpoint.
        let padding = 1 / scale
        particle.trail.frame = CGRect(x: -length - 0.6, y: -0.6, width: length + 1.2, height: 1.2)
            .insetBy(dx: -padding, dy: -padding)
        particle.trail.contentsScale = scale; particle.mask.contentsScale = scale
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.6 + padding, y: 0.6 + padding))
        path.addLine(to: CGPoint(x: CGFloat(length) + 0.6 + padding, y: 0.6 + padding))
        particle.mask.frame = particle.trail.bounds; particle.mask.path = path
        let alpha = CGFloat(0.35 + Double(index % 4) * 0.2)
        let tint = color.copy(alpha: color.alpha * alpha) ?? color
        particle.trail.colors = [color.copy(alpha: 0) ?? color, tint]
        particle.trail.locations = [0, 1]
        particle.trail.startPoint = CGPoint(x: (0.6 + padding) / particle.trail.bounds.width, y: 0.5)
        particle.trail.endPoint = CGPoint(x: (CGFloat(length) + 0.6 + padding) / particle.trail.bounds.width, y: 0.5)
        let dotBounds = CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)
        particle.dot.bounds = dotBounds; particle.dot.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        particle.dot.position = .zero
        particle.dot.path = CGPath(ellipseIn: dotBounds, transform: nil)
        particle.dot.fillColor = tint; particle.dot.contentsScale = scale
    }
}
