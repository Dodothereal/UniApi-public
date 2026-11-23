import SwiftUI
import UniApiCore

/// Unavailable choices still need readable explanations; the Button itself
/// retains disabled input and accessibility semantics without dimming its label.
struct NativeModelChoiceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Sheet data and presentation travel in one value so the first presentation
/// cannot capture the previous payload from a separate Boolean transaction.
struct NativePresentedValue: Identifiable {
    let id = UUID()
    let value: JSONValue
}

enum NativeNumberFormat {
    static func decimal(_ value: Double) -> String {
        guard value.isFinite else { return "-" }
        return value.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0...2)))
    }
    static func compact(_ value: Double) -> String {
        guard value.isFinite else { return "-" }
        let magnitude = abs(value)
        if magnitude >= 1_000_000_000 { return decimal(value / 1_000_000_000) + "B" }
        if magnitude >= 1_000_000 { return decimal(value / 1_000_000) + "M" }
        if magnitude >= 1_000 { return decimal(value / 1_000) + "k" }
        return decimal(value)
    }
}

/// The legacy call shape is retained, but the renderer transitions between real
/// strings instead of interpolating its Double through unmeasured readings.
struct CountUpText: View {
    var value: Double?
    var format: (Double) -> String
    var font: Font
    var color: Color = Theme.ink
    var duration: Double = 0.5
    var delay: Double = 0
    var body: some View {
        NativeNumberText(text: value.flatMap { $0.isFinite ? format($0) : nil } ?? "-",
                         font: font, color: color, delay: delay,
                         animation: .spring(duration: duration.isFinite && duration > 0 ? duration : 0.5))
    }
}

struct ModelChip: View {
    var model: String
    var color: Color
    var onRemove: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: onRemove) {
            HStack(spacing: 6) {
                StatusDot(color: hovering ? Theme.failFg : color)
                Text(model).font(Theme.mono(11)).lineLimit(1)
                NativeIcon(systemName: "xmark", size: 8)
            }
            .foregroundStyle(hovering ? Theme.failFg : Theme.dim)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(hovering ? Theme.surfaceFor(Theme.fail) : Theme.subtle,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand(enabled)
        .onHover { hovering = $0 && enabled }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityLabel("Remove " + model).help("Remove " + model + " from the next run")
    }
}

/// Only use this for user-managed API keys. Browser credentials are references
/// and must never be passed to a key pill, even masked.
struct NativeKeyPill: View {
    var key: String
    var onCopy: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var masked: String {
        key.count > 14 ? String(key.prefix(10)) + "..." + String(key.suffix(4)) : key
    }
    var body: some View {
        Button(action: onCopy) {
            HStack(spacing: 5) {
                NativeIcon(systemName: "key.horizontal", size: 9)
                Text(hovering ? "copy full key" : masked).font(Theme.mono(10))
                    .lineLimit(1).truncationMode(.middle).frame(width: 108, alignment: .leading)
            }
            .foregroundStyle(hovering ? Theme.ink : Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(hovering ? Theme.subtle2 : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))
        }
        .buttonStyle(.plain).pointingHand(enabled).onHover { hovering = $0 && enabled }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityLabel("Copy API key").help("Copy the full API key")
    }
}

struct NativeScrollRail<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.horizontal) { HStack(spacing: 6) { content() }.padding(.horizontal, 10) }
            .scrollIndicators(.hidden)
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 10)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 10)
                }
            }
    }
}
