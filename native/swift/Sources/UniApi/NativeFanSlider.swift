import AppKit
import SwiftUI

enum NativeFanSliderKey: Equatable { case decrement, increment, start, end, cancel }

/// AppKit owns tracking, focus and accessibility; the cell changes only the
/// web track/thumb drawing. Drag values stay drafts until native tracking ends.
struct NativeFanSlider: NSViewRepresentable {
    @Binding var value: Double
    let bounds: ClosedRange<Double>
    let enabled: Bool
    let label: String
    let editingChanged: (Bool) -> Void
    let keyPressed: (NativeFanSliderKey) -> Void

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
            let stepped = raw >= upper ? upper : lower + ((raw - lower) / 100).rounded() * 100
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
        private func paint(_ token: Color, opacity: CGFloat) -> NSColor {
            let color = NSColor(token)
            return color.withAlphaComponent(color.alphaComponent * opacity)
        }
        override func knobRect(flipped: Bool) -> NSRect {
            let native = super.knobRect(flipped: flipped)
            let height: CGFloat = isEnabled && (hovering || isHighlighted) ? 28 : 22
            return NSRect(x: native.midX - 7, y: (controlView?.bounds.midY ?? native.midY) - height / 2, width: 14, height: height)
        }
        override func drawBar(inside rect: NSRect, flipped: Bool) {
            let track = NSRect(x: rect.minX, y: (controlView?.bounds.midY ?? rect.midY) - 3, width: rect.width, height: 6)
            paint(Theme.track, opacity: isEnabled ? 1 : 0.45).setFill()
            NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
            let fill = NSRect(x: track.minX, y: track.minY, width: max(0, min(track.width, knobRect(flipped: flipped).midX - track.minX)), height: 6)
            NSColor(Theme.pairPalette[6]).withAlphaComponent(isEnabled ? 1 : 0.45).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        }
        override func drawKnob(_ rect: NSRect) {
            let alpha: CGFloat = isEnabled ? 1 : 0.45
            if isEnabled && (hovering || isHighlighted) {
                NSColor(Theme.pairPalette[6]).withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -5, dy: -5), xRadius: 10, yRadius: 10).fill()
            }
            NSColor(Theme.surface).withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            NSColor(Theme.pairPalette[6]).withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 3), xRadius: 3, yRadius: 3).fill()
            paint(Theme.border, opacity: alpha).setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            outline.lineWidth = 1; outline.stroke()
        }
    }
}
