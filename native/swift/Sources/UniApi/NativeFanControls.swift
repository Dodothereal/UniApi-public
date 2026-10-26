import SwiftUI
import AppKit
import UniApiCore

struct NativeFanSpeedCard: View {
    let fan: JSONValue
    let enabled: Bool
    let duration: Int
    let apply: (Double) -> Void
    @State private var draft: Double?
    @State private var editing = false
    @State private var text = ""
    @State private var invalid = false
    @FocusState private var fieldFocused: Bool
    private var minimum: Double { fan["minimum"].double }
    private var maximum: Double { max(minimum + 1, fan["maximum"].double) }
    private var target: Double { fan["target"].double > 0 ? fan["target"].double : max(minimum, fan["actual"].double) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Fan \(fan["id"].int + 1)").font(Theme.ui(14, weight: .medium))
                Spacer(minLength: 8)
                Text("Hardware mode: \([0, 3].contains(fan["mode"].int) ? "Automatic" : "Forced")").font(Theme.ui(10)).foregroundStyle(Theme.muted)
            }
            ZStack {
                NativeFanWind(rpm: fan["actual"].double).nativeMotionVisibility(initiallyVisible: false)
                VStack(spacing: 0) {
            HStack(spacing: 10) {
                NativeSpinningFan(rpm: fan["actual"].double).frame(width: 28, height: 28)
                ZStack {
                Text(rpm(max(9999, maximum))).font(Theme.ui(32, weight: .medium)).hidden().accessibilityHidden(true)
                if editing {
                    TextField("Actual RPM", text: $text).font(Theme.ui(32, weight: .medium)).textFieldStyle(.plain).focused($fieldFocused).accessibilityLabel("Fan \(fan["id"].int + 1) target RPM").onAppear { fieldFocused = true; DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil) } }.onSubmit { commitText() }.onKeyPress(.escape) { editing = false; invalid = false; return .handled }.onChange(of: fieldFocused) { _, focused in if !focused { editing = false; invalid = false } }.onChange(of: text) { _, _ in invalid = false }
                } else {
                    Button { if enabled { text = String(format: "%.0f", fan["actual"].double); editing = true } } label: { NativeNumberText(text: rpm(fan["actual"].double), font: Theme.ui(32, weight: .medium), isolateLayout: true) }.buttonStyle(.plain).disabled(!enabled).help("Edit fan target RPM")
                }
                }
                Text("RPM").font(Theme.ui(10)).foregroundStyle(Theme.muted)
            }.frame(maxWidth: .infinity).padding(.top, 20).padding(.bottom, 16)
            NativeFanSlider(value: Binding(get: { draft ?? target }, set: { editing = false; draft = max(minimum, min(maximum, $0)) }), bounds: minimum...maximum, enabled: enabled, label: "Fan \(fan["id"].int + 1) target RPM", editingChanged: { changed in
                if !changed, enabled, let draft { apply(draft); self.draft = nil }
            }, keyPressed: { key in
                if key == .cancel { draft = nil; return }
                guard enabled else { return }
                let value = key == .start ? minimum : key == .end ? maximum : max(minimum, min(maximum, target + (key == .decrement ? -100 : 100)))
                draft = nil; apply(value)
            }).padding(.horizontal, 8).padding(.top, 16)
            HStack { Text(rpm(minimum) + " RPM"); Spacer(); Text("Target " + rpm(draft ?? target)); Spacer(); Text(rpm(maximum) + " RPM") }.font(Theme.ui(10)).foregroundStyle(Theme.muted).padding(.top, 6).padding(.bottom, 8)
            if invalid { Text("Enter \(Int(minimum))–\(Int(maximum)) RPM.").font(Theme.ui(11)).foregroundStyle(Theme.warnFg).accessibilityAddTraits(.updatesFrequently) }
                }
            }
        }.padding(.horizontal, 28).padding(.bottom, 14)
    }
    private func commitText() { guard enabled, let value = NativeHardwareDisplayPolicies.typedFanRPM(text, minimum: minimum, maximum: maximum) else { invalid = true; return }; apply(value); editing = false; invalid = false }
    private func rpm(_ value: Double) -> String { value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0))) }
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
        HStack(spacing: 4) {
            TextField(unit, text: $text).textFieldStyle(.plain).font(Theme.ui(16)).focused($focused).frame(width: 40).padding(.vertical, 3)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.input).frame(height: 1) }
                .disabled(disabled).accessibilityLabel(label.isEmpty ? unit : label)
                .onSubmit { save() }
                .onChange(of: focused) { old, new in
                    if new { cancelled = false }
                    if old && !new && !cancelled { save() }
                }
                .onKeyPress(.escape) { cancelled = true; text = JSONValue.number(value).string; focused = false; return .handled }
            Text(unit).font(Theme.mono(10)).foregroundStyle(Theme.muted)
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

struct NativeFanWind: View {
    let rpm: Double
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var body: some View {
        NativeFanWindView(rpm: rpm, reduceMotion: reduceMotion, visible: visible)
            .clipped().allowsHitTesting(false).accessibilityHidden(true)
    }
}
