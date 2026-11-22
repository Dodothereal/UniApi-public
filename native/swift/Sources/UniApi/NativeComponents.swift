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
    var eyebrow: String
    var maxWidth: CGFloat
    var readiness: NativePageReadiness
    var showsHeader: Bool
    var backTitle: String
    var backAction: (() -> Void)?
    @Environment(\.nativePageVisit) private var visit
    @Environment(\.nativeInterfaceDensity) private var density
    private let content: Content
    private let actions: AnyView

    init(title: String, subtitle: String = "", eyebrow: String = "", maxWidth: CGFloat = 960, readiness: NativePageReadiness = .pending, showsHeader: Bool = true, backTitle: String = "Back", back: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, eyebrow: eyebrow, maxWidth: maxWidth, readiness: readiness, showsHeader: showsHeader, backTitle: backTitle, back: back,
                  actions: { EmptyView() }, content: content)
    }

    init<Actions: View>(title: String, subtitle: String = "", eyebrow: String = "", maxWidth: CGFloat = 960,
         readiness: NativePageReadiness = .pending, showsHeader: Bool = true, backTitle: String = "Back", back: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.eyebrow = eyebrow
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
                    }.buttonStyle(Press(.quiet)).padding(.leading, -8)
                }
                if showsHeader {
                    PageHeader(title: title, subtitle: subtitle.isEmpty ? nil : subtitle, eyebrow: eyebrow) { actions }
                }
                content
            }
            .padding(.horizontal, density.pageMargin).padding(.top, density.pageMargin + 4).padding(.bottom, 56)
            .frame(width: max(0, min(maxWidth, viewport.size.width)), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .nativeEntrance(.page)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
        .foregroundStyle(Theme.ink)
        .font(Theme.ui(13))
        .buttonStyle(Press(.secondary))
        .tint(Theme.signal)
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

/// Page title block: eyebrow, expanded title, actions, then the tick rule.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var eyebrow: String = ""
    @ViewBuilder var trailing: () -> Trailing

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !eyebrow.isEmpty { MicroLabel(eyebrow) }
            Text(title).font(Theme.display()).tracking(-0.4).foregroundStyle(Theme.ink)
                .lineLimit(1).accessibilityAddTraits(.isHeader)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 20) {
                    heading.fixedSize(horizontal: true, vertical: true)
                    Spacer(minLength: 0)
                    HStack(spacing: 8) { trailing() }.fixedSize(horizontal: true, vertical: false)
                }
                VStack(alignment: .leading, spacing: 12) {
                    heading.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) { trailing() }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            TickRule().padding(.top, 14)
            if let subtitle {
                Text(subtitle).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading).padding(.top, 12)
            }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
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
         accent: Color = Theme.signal, delay: Double = 0,
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
        Readout(label: label, value: reading, unit: unit, detail: detail, size: .medium,
                tint: accent == Theme.signal ? nil : accent, delay: delay)
    }
}

struct NativeError: View {
    var message: String
    var body: some View { Notice(text: message, tone: .fail).accessibilityLabel("Error: " + message) }
}

struct NativeEmptyState: View {
    var title: String
    var detail: String
    var icon: String = "tray"
    var actionTitle: String? = nil
    var actionIcon: String = "plus"
    var action: (() -> Void)? = nil
    var body: some View {
        EmptyState(icon: icon, title: title, detail: detail,
                   actionTitle: actionTitle, actionIcon: actionIcon, action: action)
    }
}

struct NativeReadFailureState: View {
    let icon: String
    let title: String
    let detail: String
    let retryTitle: String
    let retry: () -> Void

    var body: some View {
        Blank(icon: icon, title: title, detail: detail, actionTitle: retryTitle, actionIcon: "refresh-cw", primary: false, action: retry)
    }
}

struct EmptyState: View {
    var icon: String
    var title: String
    var detail: String
    var actionTitle: String? = nil
    var actionIcon: String = "plus"
    var action: (() -> Void)? = nil
    var body: some View {
        Blank(icon: icon, title: title, detail: detail, actionTitle: actionTitle, actionIcon: actionIcon, action: action)
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
    var accent: Color = Theme.signal
    var body: some View {
        NativeValueTile(label: label, value: value, detail: detail, accent: accent, format: format)
    }
}

/// A horizontal bar's track never scales. Only the fill and optional measured
/// spread grow together; zero remains truly empty rather than a minimum pill.
struct NativeGrowBar: View {
    var fraction: Double
    var color: Color = Theme.ink
    var height: CGFloat = 4
    var delay: Double = 0
    var spread: ClosedRange<Double>? = nil
    var entrance: Bool = true
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.track)
                ZStack(alignment: .leading) {
                    if let spread {
                        let lower = NativeMotion.fraction(spread.lowerBound)
                        let upper = NativeMotion.fraction(spread.upperBound)
                        Rectangle().fill(color.opacity(0.25))
                            .frame(width: geometry.size.width * max(0, upper - lower))
                            .offset(x: geometry.size.width * lower)
                    }
                    Rectangle().fill(color)
                        .frame(width: geometry.size.width * NativeMotion.fraction(fraction))
                }
                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: fraction)
                .modifier(OptionalBarEntrance(enabled: entrance, delay: delay))
            }
            .clipShape(RoundedRectangle(cornerRadius: 1))
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
    var color: Color = Theme.ink
    var height: CGFloat = 4
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
                Rectangle().fill(hovering ? Theme.failFg : color).frame(width: 2, height: 10)
                Text(model).font(Theme.mono(11)).lineLimit(1)
                NativeIcon(systemName: "xmark", size: 8)
            }
            .foregroundStyle(hovering ? Theme.failFg : Theme.dim)
            .padding(.horizontal, 7).frame(height: 22)
            .background(hovering ? Theme.surfaceFor(Theme.fail) : Theme.hover,
                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
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
            .padding(.horizontal, 7).frame(height: 22)
            .background(hovering ? Theme.hover : .clear,
                        in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(Theme.ruleStrong))
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

/// Earlier name for `Pick`.
struct NativeMenuSelect<Value: Hashable>: View {
    var title: String
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var width: CGFloat? = nil
    var body: some View { Pick(title: title, selection: $selection, options: options, width: width) }
}
