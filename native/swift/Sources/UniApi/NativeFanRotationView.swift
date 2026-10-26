import AppKit
import QuartzCore
import SwiftUI
import UniApiCore

struct NativeFanRotationView: NSViewRepresentable {
    let rpm: Double
    let size: CGFloat
    let reduceMotion: Bool
    let visible: Bool
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> FanImageView { FanImageView(frame: .zero) }

    func updateNSView(_ view: FanImageView, context: Context) {
        view.configure(rpm: rpm, size: size, reduceMotion: reduceMotion, visible: visible,
                       tint: NSColor(Theme.dim), dark: colorScheme == .dark)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FanImageView, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? natural.width, height: proposal.height ?? natural.height)
    }

    static func dismantleNSView(_ view: FanImageView, coordinator: ()) { view.stop() }

    final class FanImageView: NSView {
        private let rotor = CALayer()
        private var renderer: NativeFanRotationRenderer!
        private var glyphSize: CGFloat?
        private var image: NSImage?
        private var tint = NSColor.clear
        private var rpm: Double = 0
        private var reduceMotion = false
        private var motionVisible = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            layer!.addSublayer(rotor)
            renderer = NativeFanRotationRenderer(layer: rotor)
            needsDisplay = true
            setAccessibilityElement(false)
        }

        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { false }
        override var wantsUpdateLayer: Bool { true }
        override var intrinsicContentSize: NSSize { image?.size ?? NSSize(width: 28, height: 28) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsDisplay = true; synchronize() }
        override func viewDidHide() { super.viewDidHide(); synchronize() }
        override func viewDidUnhide() { super.viewDidUnhide(); synchronize() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); needsDisplay = true }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
        override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsDisplay = true }

        override func updateLayer() {
            guard let renderer else { return }
            let scale = window?.backingScaleFactor ?? 2
            renderer.layout(in: bounds, contentsScale: scale)
            let raster = NativeFanLayerImage.rasterize(bounds: bounds, scale: scale, appearance: effectiveAppearance) { context in
                guard let image else { return }
                let rect = NSRect(x: bounds.midX - image.size.width / 2, y: bounds.midY - image.size.height / 2,
                                  width: image.size.width, height: image.size.height)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                context.setBlendMode(.sourceIn)
                context.setFillColor(tint.cgColor)
                context.fill(bounds)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            rotor.contents = raster
            CATransaction.commit()
        }

        func configure(rpm: Double, size: CGFloat, reduceMotion: Bool, visible: Bool, tint: NSColor, dark: Bool) {
            if glyphSize != size {
                glyphSize = size
                image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
                    guard let context = NSGraphicsContext.current?.cgContext,
                          let path = NativeIconPaths.all["fan"] else { return false }
                    context.saveGState(); defer { context.restoreGState() }
                    context.translateBy(x: 0, y: bounds.height)
                    context.scaleBy(x: bounds.width / 24, y: -bounds.height / 24)
                    context.addPath(path)
                    context.setStrokeColor(NSColor.black.cgColor)
                    context.setLineWidth(1.75)
                    context.setLineCap(.round); context.setLineJoin(.round)
                    context.strokePath()
                    return true
                }
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
            let name: NSAppearance.Name = dark ? .darkAqua : .aqua
            if appearance?.name != name { appearance = NSAppearance(named: name) }
            if self.tint != tint { self.tint = tint; needsDisplay = true }
            self.rpm = rpm; self.reduceMotion = reduceMotion; motionVisible = visible
            synchronize()
        }

        func stop() { renderer.stop() }

        private func synchronize() {
            // The shared native visibility probe still owns occlusion/scroll
            // policy. Detachment also freezes the retained clock immediately.
            renderer?.update(rpm: rpm, reduceMotion: reduceMotion,
                             visible: motionVisible && window != nil && !isHiddenOrHasHiddenAncestor)
        }
    }
}

/// Static glyph drawing at layout/appearance boundaries. The rotor alone owns
/// the transform, so AppKit remains free to position the untransformed host.
@MainActor enum NativeFanLayerImage {
    static func rasterize(bounds: NSRect, scale: CGFloat, appearance: NSAppearance,
                          draw: @MainActor (CGContext) -> Void) -> CGImage? {
        guard bounds.width.isFinite, bounds.height.isFinite, scale.isFinite,
              bounds.width > 0, bounds.height > 0, scale > 0 else { return nil }
        let width = ceil(bounds.width * scale), height = ceil(bounds.height * scale)
        guard width.isFinite, height.isFinite, width < CGFloat(Int.max), height < CGFloat(Int.max) else { return nil }
        guard let bitmap = CGContext(data: nil, width: Int(width), height: Int(height),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        bitmap.scaleBy(x: scale, y: scale)
        bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
        appearance.performAsCurrentDrawingAppearance { draw(bitmap) }
        return bitmap.makeImage()
    }
}
