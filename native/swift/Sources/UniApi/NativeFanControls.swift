import SwiftUI
import AppKit
import UniApiCore

/// One fan as an instrument: the dial sweeps to the measured speed, the signal
/// needle rests on the target, and the target is set on the ruler beneath.
struct NativeFanInstrument: View {
    let fan: JSONValue
    let enabled: Bool
    let duration: Int
    let apply: (Double) -> Void
    @State private var draft: Double?
    @State private var editing = false
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    private var minimum: Double { fan["minimum"].double }
    private var maximum: Double { max(minimum + 1, fan["maximum"].double) }
    private var target: Double { fan["target"].double > 0 ? fan["target"].double : max(minimum, fan["actual"].double) }
    private var name: String { "Fan \(fan["id"].int + 1)" }
    private func fraction(_ rpm: Double) -> Double { NativeMotion.fraction((rpm - minimum) / (maximum - minimum)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeInstrumentHang()
            HStack(spacing: 7) {
                MicroLabel(name)
                NativeSpinningFan(rpm: fan["actual"].double, size: 14).frame(width: 14, height: 14).nativeMotionVisibility(initiallyVisible: false)
                Spacer(minLength: 8)
                MicroLabel([0, 3].contains(fan["mode"].int) ? "Hardware auto" : "Forced", color: Theme.faint)
                    .accessibilityLabel("Hardware mode: \([0, 3].contains(fan["mode"].int) ? "Automatic" : "Forced")")
            }
            HStack(alignment: .center, spacing: 20) {
                dial
                VStack(alignment: .leading, spacing: 5) {
                    MicroLabel(draft == nil ? "Target" : "Release to set")
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        NativeNumberText(text: rpm(draft ?? target), font: Theme.readout(24), isolateLayout: true)
                        MicroLabel("RPM")
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            NativeFanSlider(value: Binding(get: { draft ?? target }, set: { editing = false; draft = max(minimum, min(maximum, $0)) }), bounds: minimum...maximum, enabled: enabled, label: "\(name) target RPM", editingChanged: { changed in
                if !changed, enabled, let draft { apply(draft); self.draft = nil }
            }, keyPressed: { key in
                if key == .cancel { draft = nil; return }
                guard enabled else { return }
                let value = key == .start ? minimum : key == .end ? maximum : max(minimum, min(maximum, target + (key == .decrement ? -100 : 100)))
                draft = nil; apply(value)
            })
            .padding(.horizontal, -NativeFanSlider.overhang).padding(.top, 6)
            HStack { Text(rpm(minimum)); Spacer(); Text(rpm(maximum)) }
                .font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
            if invalid {
                Text("Enter \(Int(minimum))–\(Int(maximum)) RPM.").font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg)
                    .padding(.top, 6).accessibilityAddTraits(.updatesFrequently)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var dial: some View {
        Dial(fraction: fraction(fan["actual"].double), size: 148, needle: false) {
            VStack(spacing: 2) {
                ZStack {
                    Text(rpm(max(9999, maximum))).font(Theme.readout(34)).hidden().accessibilityHidden(true)
                    if editing {
                        TextField("RPM", text: $text).font(Theme.readout(34)).multilineTextAlignment(.center).textFieldStyle(.plain).focused($fieldFocused).accessibilityLabel("\(name) target RPM").onAppear { fieldFocused = true; DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) } }.onSubmit { commitText() }.onKeyPress(.escape) { editing = false; invalid = false; return .handled }.onChange(of: fieldFocused) { _, focused in if !focused { editing = false; invalid = false } }.onChange(of: text) { _, _ in invalid = false }
                            .overlay(alignment: .bottom) { Theme.signal.frame(height: 1).offset(y: 2) }
                    } else {
                        Button { if enabled { text = String(format: "%.0f", fan["actual"].double); editing = true } } label: { NativeNumberText(text: rpm(fan["actual"].double), font: Theme.readout(34), isolateLayout: true) }.buttonStyle(.plain).disabled(!enabled).pointingHand(enabled).help("Type a target RPM")
                            .accessibilityLabel("\(name) speed").accessibilityValue(rpm(fan["actual"].double) + " RPM")
                    }
                }
                .fixedSize()
                MicroLabel("RPM")
            }
            .offset(y: 4)
        }
        .overlay {
            // The kit needle follows the reading; here it marks the target.
            Theme.signal.frame(width: 2, height: 15).offset(y: -148 / 2 + 9.5)
                .rotationEffect(.degrees(-120 + 240 * fraction(draft ?? target)))
                .animation(reduceMotion || !visible || draft != nil ? nil : NativeMotion.barUpdate, value: target)
                .accessibilityHidden(true)
        }
    }
    private func commitText() { guard enabled, let value = NativeHardwareDisplayPolicies.typedFanRPM(text, minimum: minimum, maximum: maximum) else { invalid = true; return }; apply(value); editing = false; invalid = false }
    private func rpm(_ value: Double) -> String { value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0))) }
}

/// The rule a reading hangs from, with its two-point tick.
struct NativeInstrumentHang: View {
    var tint: Color = Theme.ink
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rule()
            tint.frame(width: 2, height: 7)
        }
        .frame(height: 7, alignment: .top).padding(.bottom, 9).accessibilityHidden(true)
    }
}

/// A thermometer laid flat: 20 to 100 degrees Celsius in four-degree ticks,
/// filled to the reading, with the signal needle on now.
struct NativeThermalScale: View {
    var celsius: Double?
    var fahrenheit: Bool
    var color: Color = Theme.ink
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    static func fraction(_ celsius: Double?) -> Double { NativeMotion.fraction(((celsius ?? 20) - 20) / 80) }
    var body: some View {
        let value = Self.fraction(celsius)
        VStack(spacing: 5) {
            Scale(fraction: value, color: color, ticks: true)
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        if celsius != nil {
                            Theme.signal.frame(width: 2, height: 11)
                                .offset(x: min(geometry.size.width - 2, max(0, geometry.size.width * value - 1)), y: -3)
                                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: value)
                        }
                    }
                }
            GeometryReader { geometry in
                ForEach([20, 40, 60, 80, 100], id: \.self) { mark in
                    Text(String(fahrenheit ? Int((Double(mark) * 1.8 + 32).rounded()) : mark))
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).fixedSize()
                        .frame(width: 40, alignment: mark == 20 ? .leading : mark == 100 ? .trailing : .center)
                        .offset(x: geometry.size.width * CGFloat(mark - 20) / 80 - (mark == 20 ? 0 : mark == 100 ? 40 : 20))
                }
            }
            .frame(height: 13)
        }
        .accessibilityHidden(true)
    }
}

struct NativeCurveNumber: View {
    let value: Double
    let unit: String
    var bounds: ClosedRange<Double> = 0...100
    var disabled = false
    var label = ""
    let commit: (Double) -> Void
    @State private var text = ""
    @State private var cancelled = false
    @FocusState private var focused: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            TextField(unit, text: $text).textFieldStyle(.plain).font(Theme.readout(17)).foregroundStyle(disabled ? Theme.muted : Theme.ink)
                .multilineTextAlignment(.trailing).focused($focused).frame(width: 30).padding(.vertical, 3)
                .overlay(alignment: .bottom) { (focused ? Theme.signal : disabled ? Color.clear : Theme.ruleStrong).frame(height: 1) }
                .disabled(disabled).accessibilityLabel(label.isEmpty ? unit : label)
                .onSubmit { save() }
                .onChange(of: focused) { old, new in
                    if new { cancelled = false }
                    if old && !new && !cancelled { save() }
                }
                .onKeyPress(.escape) { cancelled = true; text = JSONValue.number(value).string; focused = false; return .handled }
            MicroLabel(unit)
        }.onAppear { text = JSONValue.number(value).string }.onChange(of: value) { _, next in if !focused { text = JSONValue.number(next).string } }
    }
    private func save() {
        guard !disabled, let parsed = NativeHardwareDisplayPolicies.curveTextValue(text, bounds: bounds) else { text = JSONValue.number(value).string; return }
        let submitted = max(bounds.lowerBound, min(bounds.upperBound, parsed.rounded()))
        commit(submitted); text = JSONValue.number(submitted).string
    }
}

struct NativeSpinningFan: View {
    let rpm: Double
    var size: CGFloat = 28
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var body: some View {
        NativeFanRotationView(rpm: rpm, size: size, reduceMotion: reduceMotion, visible: visible)
            .accessibilityHidden(true)
    }
}
