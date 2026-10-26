import AppKit
import QuartzCore
import SwiftUI

/// Render actual SwiftUI glyphs only when a reading changes, then roll changed
/// digit columns on independent compositor layers. Static text and its SwiftUI
/// baseline remain exact; there is no per-frame SwiftUI update or invented value.
struct NativeNumberHost: NSViewRepresentable {
    static let transitionSpring = Spring(duration: 0.5)
    let text: String
    let font: Font
    let color: Color
    let animation: Animation?
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NumberView { NumberView(frame: .zero) }
    func updateNSView(_ view: NumberView, context: Context) {
        view.configure(text: text, font: font, color: color,
                       animate: animation != nil && !context.transaction.disablesAnimations, scheme: colorScheme)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NumberView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
    static func dismantleNSView(_ view: NumberView, coordinator: ()) { view.stop() }

    final class NumberView: NSView {
        private struct Request: Equatable {
            var text: String; var font: Font; var color: Color; var scheme: ColorScheme
        }
        private let canvas = CALayer()
        private let imageLayer = CALayer()
        private var request: Request?
        private var painted: Request?
        private var paintedSize = CGSize.zero
        private var paintedScale: CGFloat = 0
        private var image: CGImage?
        private var animate = false
        private var generation: UInt64 = 0
        private var transitioning = false
        private var metricShape = ""
        private var metricFont: Font?
        private var advances: [CGFloat] = []

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer!.addSublayer(canvas)
            canvas.addSublayer(imageLayer)
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func layout() { super.layout(); synchronize() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronize() }
        override func viewDidHide() { super.viewDidHide(); stop() }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); synchronize() }

        func configure(text: String, font: Font, color: Color, animate: Bool, scheme: ColorScheme) {
            request = Request(text: text, font: font, color: color, scheme: scheme)
            self.animate = animate
            let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
            if appearance?.name != name { appearance = NSAppearance(named: name) }
            synchronize()
        }
        func stop() {
            generation &+= 1
            transitioning = false
            CATransaction.begin(); CATransaction.setDisableActions(true)
            imageLayer.removeAllAnimations(); imageLayer.mask = nil
            canvas.sublayers?.filter { $0 !== imageLayer }.forEach { $0.removeFromSuperlayer() }
            CATransaction.commit()
        }
        private func artwork(_ value: String, request: Request, size: CGSize? = nil) -> ImageRenderer<some View> {
            let content = Text(value).font(request.font).monospacedDigit().foregroundStyle(request.color)
                .lineLimit(1).fixedSize().frame(width: size?.width, height: size?.height, alignment: .leading)
                .environment(\.colorScheme, request.scheme)
            return ImageRenderer(content: content)
        }
        private func columns(for request: Request) -> [CGFloat] {
            let shape = String(request.text.map { $0.isASCII && $0.isNumber ? Character("0") : $0 })
            if metricShape == shape, metricFont == request.font { return advances }
            var values: [CGFloat] = [0]
            for count in 1...max(1, request.text.count) {
                let renderer = artwork(String(request.text.prefix(count)), request: request)
                var width: CGFloat = 0
                renderer.render { size, _ in width = size.width }
                values.append(width)
            }
            metricShape = shape; metricFont = request.font; advances = values
            return values
        }
        private func synchronize() {
            guard let request, bounds.width.isFinite, bounds.height.isFinite,
                  bounds.width > 0, bounds.height > 0 else { stop(); return }
            let scale = window?.backingScaleFactor ?? 2
            guard scale.isFinite, scale > 0 else { stop(); return }
            if painted == request, paintedSize == bounds.size, paintedScale == scale {
                if !animate || window == nil || isHiddenOrHasHiddenAncestor { stop() }
                return
            }
            let renderer = artwork(request.text, request: request, size: bounds.size)
            renderer.scale = scale
            // Resolve AppKit-backed colors under the selected host appearance
            // as well as the SwiftUI renderer's color-scheme environment.
            var renderedImage: CGImage?
            effectiveAppearance.performAsCurrentDrawingAppearance { renderedImage = renderer.cgImage }
            guard let newImage = renderedImage else { return }
            let old = painted, oldImage = image, oldSize = paintedSize
            let interrupted = transitioning
            let previousComposite = interrupted ? snapshot(scale: scale) : nil
            stop()
            painted = request; paintedSize = bounds.size; paintedScale = scale; image = newImage
            CATransaction.begin(); CATransaction.setDisableActions(true)
            canvas.bounds = CGRect(origin: .zero, size: bounds.size)
            canvas.position = CGPoint(x: bounds.midX, y: bounds.midY)
            imageLayer.bounds = canvas.bounds
            imageLayer.position = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            imageLayer.contentsScale = scale; imageLayer.contents = newImage
            CATransaction.commit()
            guard animate, window != nil, !isHiddenOrHasHiddenAncestor,
                  let old, let oldImage, !old.text.isEmpty, old.text != request.text || interrupted,
                  old.font == request.font, old.color == request.color,
                  old.scheme == request.scheme else { return }
            let before = Array(old.text), after = Array(request.text)
            let compatible = !interrupted && oldSize == bounds.size && before.count == after.count && zip(before, after).allSatisfy { pair in
                let (a, b) = pair
                return a == b || (a.isASCII && a.isNumber && b.isASCII && b.isNumber)
            }
            if compatible {
                let positions = columns(for: request)
                let changed = after.indices.filter { before[$0] != after[$0] }
                roll(changed: changed.map { CGRect(x: positions[$0], y: 0, width: positions[$0 + 1] - positions[$0], height: bounds.height) }, old: oldImage, new: newImage, scale: scale)
            } else {
                crossfade(from: previousComposite ?? oldImage, scale: scale,
                          oldSize: previousComposite == nil ? oldSize : bounds.size)
            }
        }
        private func snapshot(scale: CGFloat) -> CGImage? {
            let width = ceil(bounds.width * scale), height = ceil(bounds.height * scale)
            guard width > 0, height > 0, width <= 8192, height <= 2048,
                  let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let shown = canvas.presentation() else { return nil }
            context.scaleBy(x: scale, y: scale)
            shown.render(in: context)
            return context.makeImage()
        }
        private func beginTransition() {
            transitioning = true
            let ticket = generation
            CATransaction.begin(); CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.generation == ticket else { return }
                    self.stop()
                }
            }
        }
        private func bitmap(_ contents: CGImage, scale: CGFloat, size: CGSize? = nil) -> CALayer {
            let extent = size ?? bounds.size
            let result = CALayer(); result.bounds = CGRect(origin: .zero, size: extent)
            result.position = CGPoint(x: extent.width / 2, y: extent.height / 2)
            result.contents = contents; result.contentsScale = scale
            return result
        }
        private func crossfade(from old: CGImage, scale: CGFloat, oldSize: CGSize) {
            beginTransition()
            let previous = bitmap(old, scale: scale, size: oldSize); canvas.addSublayer(previous); previous.opacity = 0
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
            fade.duration = 0.16; fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            previous.add(fade, forKey: "uniapi.number.fade")
            let incoming = CABasicAnimation(keyPath: "opacity"); incoming.fromValue = 0; incoming.toValue = 1
            incoming.duration = 0.16; incoming.timingFunction = fade.timingFunction
            imageLayer.add(incoming, forKey: "uniapi.number.fade-in")
            CATransaction.commit()
        }
        private func roll(changed: [CGRect], old: CGImage, new: CGImage, scale: CGFloat) {
            guard !changed.isEmpty else { return }
            let spring = NativeNumberHost.transitionSpring
            let duration = min(0.8, spring.settlingDuration)
            beginTransition()
            let holes = CGMutablePath(); holes.addRect(canvas.bounds)
            for rectangle in changed {
                holes.addRect(rectangle)
                let clip = CALayer(); clip.frame = rectangle; clip.masksToBounds = true; canvas.addSublayer(clip)
                for (contents, incoming) in [(old, false), (new, true)] {
                    let slice = bitmap(contents, scale: scale)
                    slice.position.x -= rectangle.minX
                    clip.addSublayer(slice)
                    let shift = CASpringAnimation(keyPath: "transform.translation.y")
                    shift.mass = spring.mass; shift.stiffness = spring.stiffness; shift.damping = spring.damping
                    shift.fromValue = incoming ? -bounds.height : 0
                    shift.toValue = incoming ? 0 : bounds.height
                    shift.duration = duration
                    slice.transform = CATransform3DMakeTranslation(0, incoming ? 0 : bounds.height, 0)
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = incoming ? 0 : 1; fade.toValue = incoming ? 1 : 0
                    fade.duration = 0.16; slice.opacity = incoming ? 1 : 0
                    let group = CAAnimationGroup(); group.animations = [shift, fade]; group.duration = duration
                    slice.add(group, forKey: "uniapi.number.digit")
                }
            }
            let mask = CAShapeLayer(); mask.frame = canvas.bounds; mask.path = holes; mask.fillRule = .evenOdd
            imageLayer.mask = mask
            CATransaction.commit()
        }
    }
}
