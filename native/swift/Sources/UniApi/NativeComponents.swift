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

// Contract entry points. Actions supplied by pages stay in this scrolling
// content; the shell owns titlebar controls and sidebar chrome separately.
struct NativePage<Content: View>: View {
    var title: String
    var subtitle: String
    var maxWidth: CGFloat
    var readiness: NativePageReadiness
    var showsHeader: Bool
    var backTitle: String
    var backAction: (() -> Void)?
    @Environment(\.nativePageVisit) private var visit
    @Environment(\.nativeInterfaceDensity) private var density
    private let content: Content
    private let actions: AnyView

    init(title: String, subtitle: String = "", maxWidth: CGFloat = 820, readiness: NativePageReadiness = .pending, showsHeader: Bool = true, backTitle: String = "Back", back: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, maxWidth: maxWidth, readiness: readiness, showsHeader: showsHeader, backTitle: backTitle, back: back,
                  actions: { EmptyView() }, content: content)
    }

    init<Actions: View>(title: String, subtitle: String = "", maxWidth: CGFloat = 820,
         readiness: NativePageReadiness = .pending, showsHeader: Bool = true, backTitle: String = "Back", back: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.maxWidth = maxWidth
        self.readiness = readiness
        self.showsHeader = showsHeader
        self.backTitle = backTitle
        self.backAction = back
        self.content = content()
        self.actions = AnyView(actions())
    }

    var body: some View {
        GeometryReader { viewport in
        ScrollView {
            VStack(alignment: .leading, spacing: density.pageGap) {
                if let backAction {
                    Button(action: backAction) {
                        HStack(spacing: 6) { NativeIcon("arrow-left", size: 14); Text(backTitle) }
                    }.buttonStyle(T3Button(.ghost))
                }
                if showsHeader {
                    PageHeader(title: title, subtitle: subtitle.isEmpty ? nil : subtitle) { actions }
                }
                content
            }
            .padding(.horizontal, density.pageMargin).padding(.top, density.pageGap).padding(.bottom, 44)
            .frame(width: max(0, min(maxWidth, viewport.size.width)), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .nativeEntrance(.page)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .font(Theme.ui(13))
        .buttonStyle(T3Button(.outline))
        .tint(Theme.accent)
        .nativeMotionVisibility()
        .background(alignment: .topLeading) {
            if let visit, NativeUIReadiness.shared.enabled {
                NativeReadinessProbe(visit: visit, readiness: readiness)
                    .frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        }
    }
}

struct NativeCard<Content: View>: View {
    var title: String
    private let content: Content

    init(title: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if !title.isEmpty {
                    Text(title).font(Theme.ui(14, weight: .medium))
                        .foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                }
                content
            }
        }
    }
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

struct NativeValueTile: View {
    var label: String
    var value: Double?
    var unit: String
    var detail: String
    var accent: Color
    var delay: Double
    var format: (Double) -> String

    init(label: String, value: Double?, unit: String = "", detail: String = "",
         accent: Color = Theme.accent, delay: Double = 0,
         format: @escaping (Double) -> String = NativeNumberFormat.decimal) {
        self.label = label
        self.value = value
        self.unit = unit
        self.detail = detail
        self.accent = accent
        self.delay = delay
        self.format = format
    }

    private var reading: String { value.flatMap { $0.isFinite ? format($0) : nil } ?? "-" }

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    StatusDot(color: accent, size: 5)
                    Text(label).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    NativeNumberText(text: reading, font: Theme.mono(22, weight: .semibold), delay: delay)
                    if !unit.isEmpty {
                        Text(unit).font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                if !detail.isEmpty {
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([reading, unit, detail].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

struct NativeError: View {
    var message: String
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            NativeIcon(systemName: "exclamationmark.circle").foregroundStyle(Theme.failFg)
                .accessibilityHidden(true)
            Text(message).font(Theme.ui(12.5)).foregroundStyle(Theme.failFg)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.surfaceFor(Theme.fail), in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .accessibilityElement(children: .combine).accessibilityLabel("Error: " + message)
    }
}

struct NativeEmptyState: View {
    var title: String
    var detail: String
    var icon: String = "tray"
    var body: some View { EmptyState(icon: icon, title: title, detail: detail) }
}

struct NativeReadFailureState: View {
    let icon: String
    let title: String
    let detail: String
    let retryTitle: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                NativeIcon(icon, size: 24).foregroundStyle(Theme.muted).accessibilityHidden(true)
                Text(title).font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.accessibilityElement(children: .combine)
            Button(retryTitle, action: retry).buttonStyle(T3Button(.outline))
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 48)
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 10) {
            NativeIcon(systemName: icon, size: 24)
                .foregroundStyle(Theme.muted.opacity(0.8)).accessibilityHidden(true)
            Text(title).font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
        .accessibilityElement(children: .combine)
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

struct StatTile: View {
    var label: String
    var value: Double?
    var format: (Double) -> String
    var detail: String
    var accent: Color = Theme.accent
    var body: some View {
        NativeValueTile(label: label, value: value, detail: detail, accent: accent, format: format)
    }
}

/// A horizontal bar's track never scales. Only the fill and optional measured
/// spread grow together; zero remains truly empty rather than a minimum pill.
struct NativeGrowBar: View {
    var fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 6
    var delay: Double = 0
    var spread: ClosedRange<Double>? = nil
    var entrance: Bool = true
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                ZStack(alignment: .leading) {
                    if let spread {
                        let lower = NativeMotion.fraction(spread.lowerBound)
                        let upper = NativeMotion.fraction(spread.upperBound)
                        Capsule().fill(color.opacity(0.22))
                            .frame(width: geometry.size.width * max(0, upper - lower))
                            .offset(x: geometry.size.width * lower)
                    }
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * NativeMotion.fraction(fraction))
                }
                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: fraction)
                .modifier(OptionalBarEntrance(enabled: entrance, delay: delay))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

private struct OptionalBarEntrance: ViewModifier {
    var enabled: Bool
    var delay: Double
    @ViewBuilder func body(content: Content) -> some View {
        if enabled { content.nativeEntrance(.grow, delay: delay) } else { content }
    }
}

struct CapsuleBar: View {
    var fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 5
    var body: some View { NativeGrowBar(fraction: fraction, color: color, height: height, entrance: false) }
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

/// The HTML app's compact menu trigger, with AppKit retaining menu keyboard behavior.
struct NativeMenuSelect<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var width: CGFloat? = nil
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        Menu {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    if option.value == selection { Label { Text(option.label) } icon: { NativeIcon("check", size: 14) } }
                    else { Text(option.label) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first(where: { $0.value == selection })?.label ?? title).lineLimit(1)
                if width != nil { Spacer(minLength: 0) }
                NativeIcon("chevron-down", size: 12).foregroundStyle(Theme.muted)
            }
            .font(Theme.ui(12)).foregroundStyle(hovering ? Theme.ink : Theme.dim)
            .padding(.horizontal, 11).frame(width: width, height: 30)
            .background(hovering ? Theme.subtle2 : Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .opacity(enabled ? 1 : 0.45).onHover { hovering = $0 && enabled }
        .pointingHand(enabled).accessibilityLabel(title)
    }
}
