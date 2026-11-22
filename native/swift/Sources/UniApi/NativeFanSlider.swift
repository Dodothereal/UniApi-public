import AppKit
import SwiftUI

enum NativeFanSliderKey: Equatable { case decrement, increment, start, end, cancel }

/// A target set on a ruler. AppKit owns tracking, focus and accessibility; the
/// cell draws the graduated scale and the cursor. Drag values stay drafts until
/// native tracking ends.
struct NativeFanSlider: NSViewRepresentable {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let enabled: Bool
    let label: String
    /// Values snap to multiples of this above the lower bound.
    var step: Double = 100
    let editingChanged: (Bool) -> Void
    let keyPressed: (NativeFanSliderKey) -> Void
    /// AppKit keeps half a knob of travel clear at each end. Pad the slider by
    /// this much on both sides and its scale ends on the surrounding edges.
    static let overhang: CGFloat = 10

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> FanSlider {
        let slider = FanSlider(frame: .zero)
        slider.cell = FanSliderCell()
        slider.isContinuous = true
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.changed(_:))
        slider.began = { context.coordinator.parent.editingChanged(true) }
        slider.ended = { context.coordinator.parent.editingChanged(false) }
        slider.pressed = { context.coordinator.parent.keyPressed($0) }
        return slider
    }
    func updateNSView(_ slider: FanSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = bounds.lowerBound
        slider.maxValue = bounds.upperBound
        slider.isEnabled = enabled
        if !slider.tracking { slider.doubleValue = max(bounds.lowerBound, min(bounds.upperBound, value)) }
        slider.setAccessibilityLabel(label)
        slider.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FanSlider, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: 40)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: NativeFanSlider
        init(_ parent: NativeFanSlider) { self.parent = parent }
        @objc func changed(_ sender: FanSlider) {
            guard parent.enabled else { return }
            if sender.tracking && sender.cancelled { sender.doubleValue = sender.startingValue; sender.needsDisplay = true; return }
            let lower = parent.bounds.lowerBound, upper = parent.bounds.upperBound
            let raw = sender.doubleValue
            let step = max(parent.step, .leastNormalMagnitude)
            let stepped = raw >= upper ? upper : lower + ((raw - lower) / step).rounded() * step
            parent.value = max(lower, min(upper, stepped))
            // VoiceOver's native increment/decrement action has no mouse loop.
            if !sender.tracking { parent.editingChanged(false) }
        }
    }
    final class FanSlider: NSSlider {
        var began: (() -> Void)?, ended: (() -> Void)?
        var pressed: ((NativeFanSliderKey) -> Void)?
        private(set) var tracking = false
        private(set) var cancelled = false
        private(set) var startingValue = 0.0
        private var hoverArea: NSTrackingArea?
        override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 40) }
        override var acceptsFirstResponder: Bool { isEnabled }
        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            window?.makeFirstResponder(self)
            tracking = true; cancelled = false; startingValue = doubleValue; began?()
            // Confine Escape interception to this control's native tracking.
            // Once cancelled, later native drag actions and release cannot apply.
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.tracking, event.keyCode == 53 else { return event }
                self.cancelTracking(); return nil
            }
            defer {
                if let monitor { NSEvent.removeMonitor(monitor) }
                tracking = false
                if cancelled { doubleValue = startingValue } else { ended?() }
                needsDisplay = true
            }
            super.mouseDown(with: event)
        }
        private func cancelTracking() {
            cancelled = true; doubleValue = startingValue; pressed?(.cancel); needsDisplay = true
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { if tracking { cancelTracking() } else { pressed?(.cancel) }; return }
            guard isEnabled else { return }
            switch event.keyCode {
            case 123, 125: pressed?(.decrement)
            case 124, 126: pressed?(.increment)
            case 115: pressed?(.start)
            case 119: pressed?(.end)
            default: super.keyDown(with: event)
            }
        }
        override func updateTrackingAreas() {
            if let hoverArea { removeTrackingArea(hoverArea) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
            addTrackingArea(area); hoverArea = area
            super.updateTrackingAreas()
        }
        override func mouseEntered(with event: NSEvent) { (cell as? FanSliderCell)?.hovering = true; needsDisplay = true }
        override func mouseExited(with event: NSEvent) { (cell as? FanSliderCell)?.hovering = false; needsDisplay = true }
    }
    final class FanSliderCell: NSSliderCell {
        var hovering = false
        private var active: Bool { isEnabled && (hovering || isHighlighted) }
        private func paint(_ token: Color, opacity: CGFloat = 1) -> NSColor {
            let color = NSColor(token)
            return color.withAlphaComponent(color.alphaComponent * opacity * (isEnabled ? 1 : 0.45))
        }
        /// The first 1-2-5 step whose ticks stay at least four points apart.
        private func graduation(_ width: CGFloat) -> Double {
            let span = maxValue - minValue
            guard span.isFinite, span > 0, width > 8 else { return 0 }
            let least = span / Double(width) * 4
            var power = pow(10, floor(log10(max(least, .leastNormalMagnitude))))
            guard power.isFinite, power > 0 else { return 0 }
            for _ in 0..<4 {
                for factor in [1.0, 2, 5] where factor * power >= least { return factor * power }
                power *= 10
            }
            return 0
        }
        /// Where the cursor's centre rests at the lowest and highest value.
        /// AppKit keeps its own travel, so the scale is drawn to match it.
        private func travel(_ rect: NSRect) -> (lower: CGFloat, upper: CGFloat) {
            let inset = min(knobThickness / 2, rect.width / 2)
            return ((rect.minX + inset).rounded(), (rect.maxX - inset).rounded())
        }
        override func knobRect(flipped: Bool) -> NSRect {
            let native = super.knobRect(flipped: flipped)
            let height: CGFloat = active ? 26 : 22
            return NSRect(x: (native.midX - 5).rounded(), y: (controlView?.bounds.midY ?? native.midY) - height / 2, width: 10, height: height)
        }
        override func drawBar(inside rect: NSRect, flipped: Bool) {
            let middle = controlView?.bounds.midY ?? rect.midY
            let ends = travel(rect)
            let bar = NSRect(x: ends.lower, y: flipped ? middle - 6 : middle + 2, width: max(1, ends.upper - ends.lower), height: 4)
            paint(Theme.track).setFill(); bar.fill()
            let reach = max(0, min(bar.width, knobRect(flipped: flipped).midX - bar.minX))
            paint(Theme.ink).setFill()
            NSRect(x: bar.minX, y: bar.minY, width: reach, height: bar.height).fill()
            // Ticks stand on real values: every step, taller on each fifth.
            let minor = graduation(bar.width)
            guard minor > 0 else { return }
            paint(Theme.faint).setFill()
            var index = (minValue / minor).rounded(.up)
            while index * minor <= maxValue + minor * 1e-9 {
                let x = bar.minX + CGFloat((index * minor - minValue) / (maxValue - minValue)) * (bar.width - 1)
                let height: CGFloat = Int(index) % 5 == 0 ? 6 : 3
                NSRect(x: x.rounded(), y: flipped ? middle + 1 : middle - 1 - height, width: 1, height: height).fill()
                index += 1
            }
        }
        override func drawKnob(_ rect: NSRect) {
            // A slide-rule cursor: a clear window with the signal hairline.
            let window = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            paint(Theme.canvas, opacity: active ? 1 : 0.86).setFill(); window.fill()
            paint(active ? Theme.ink : Theme.ruleStrong).setStroke(); window.lineWidth = 1; window.stroke()
            paint(Theme.signal).setFill()
            NSRect(x: rect.midX - 1, y: rect.minY + 3, width: 2, height: rect.height - 6).fill()
        }
    }
}
