import SwiftUI

/// One prerequisite of a page: something that must be true before the page works.
struct NativeSetupStep: Identifiable {
    var id: String
    var title: String
    var detail: String = ""
    var done: Bool
    var busy: Bool = false
    var busyText: String = "Working…"
    var progress: Double? = nil
    var cancel: (() -> Void)? = nil
    /// False keeps the action visible but unavailable, with the reason in `detail`.
    var enabled: Bool = true
    var actionTitle: String = ""
    var actionIcon: String? = nil
    var action: (() -> Void)? = nil
}

/// The prerequisites of a page as one numbered list. The first open step owns
/// the primary action; later steps wait. Callers drop the list once every step
/// is done, so a working page never shows it.
struct NativeSetup: View {
    var title: String = ""
    var steps: [NativeSetupStep]

    var body: some View {
        let next = steps.first { !$0.done }?.id
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty {
                Text(title).font(Theme.ui(Theme.textSm, weight: .semibold)).foregroundStyle(Theme.ink)
                    .padding(.bottom, 10).accessibilityAddTraits(.isHeader)
            }
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                Theme.rule.frame(height: 1)
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        if step.done { NativeIcon("check", size: 13).foregroundStyle(Theme.okFg) }
                        else { Text("\(index + 1)").font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(step.id == next ? Theme.ink : Theme.faint) }
                    }
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(step.done ? Theme.okFg.opacity(0.45) : step.id == next ? Theme.ink : Theme.border, lineWidth: 1))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(Theme.ui(Theme.textSm, weight: .medium))
                            .foregroundStyle(step.done ? Theme.muted : step.id == next ? Theme.ink : Theme.dim)
                        if !step.detail.isEmpty {
                            Text(step.detail).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if step.busy {
                        if let progress = step.progress {
                            NativeTickMeter(fraction: progress, color: Theme.accent, height: 8).frame(width: 140)
                                .accessibilityLabel(step.title).accessibilityValue(String(format: "%.0f percent", progress * 100))
                        } else { ShimmerText(text: step.busyText) }
                        if let cancel = step.cancel { Button("Cancel", action: cancel).buttonStyle(T3Button(.outline)) }
                    }
                    else if !step.done, let action = step.action, !step.actionTitle.isEmpty {
                        Button(step.actionTitle, nativeIcon: step.actionIcon ?? "arrow-right", action: action)
                            .buttonStyle(T3Button(step.id == next ? .primary : .outline))
                            .disabled(step.id != next || !step.enabled)
                    }
                }
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1), \(step.title)" + (step.done ? ", done" : ""))
            }
            Theme.rule.frame(height: 1)
        }
    }
}

/// A list with a right-hand inspector for the selected row. The inspector
/// replaces page jumps, sheets and inline expanders: one place for a row's
/// details and its actions. Escape closes it. Below `stackBelow` it covers
/// the list instead of squeezing it.
struct NativeInspectorSplit<Main: View, Inspector: View>: View {
    var open: Bool
    var width: CGFloat = 360
    var stackBelow: CGFloat = 720
    var onClose: () -> Void
    @ViewBuilder var main: () -> Main
    @ViewBuilder var inspector: () -> Inspector
    @Environment(\.nativeReducedMotion) private var reduced

    var body: some View {
        GeometryReader { geometry in
            let stacked = geometry.size.width < stackBelow
            HStack(spacing: 0) {
                if !(stacked && open) {
                    // A fixed width: content wider than its share is clipped, never pushed over the inspector.
                    main().frame(width: max(0, geometry.size.width - (open ? width : 0)), alignment: .topLeading)
                        .frame(maxHeight: .infinity, alignment: .topLeading).clipped()
                        // A clicked row leaves key focus in the list, so Escape and arrows reach this split.
                        .focusable().focusEffectDisabled()
                }
                if open {
                    inspector()
                        .frame(width: stacked ? geometry.size.width : width)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Theme.surface)
                        .overlay(alignment: .leading) { Theme.border.frame(width: 1) }
                        .transition(reduced ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
            // Escape closes it from the list as well; a clicked row leaves focus there.
            .onExitCommand { if open { onClose() } }
            .animation(reduced ? nil : NativeMotion.toggle, value: open)
        }
    }
}

/// The inspector's frame: what is selected, a close control, scrolling
/// details, and the selection's actions pinned to the foot.
struct NativeInspector<Content: View, Actions: View>: View {
    var title: String
    var caption: String = ""
    var icon: String? = nil
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                if let icon { NativeIcon(icon, size: 15).foregroundStyle(Theme.muted).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.ui(Theme.textSm, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    if !caption.isEmpty { Text(caption).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle) }
                }
                Spacer(minLength: 8)
                T3IconButton(system: "x", help: "Close", size: 13, action: onClose)
            }
            .padding(.leading, 16).padding(.trailing, 10).frame(height: Theme.barHeight)
            .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content() }
                    .padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            }.scrollContentBackground(.hidden)
            HStack(spacing: 8) { actions() }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
        }
    }
}

/// A fact in an inspector: label on the left, value on the right, one rule below.
struct NativeFact: View {
    var label: String
    var value: String
    var mono = false
    var tone: Color = Theme.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(value).font(mono ? Theme.mono(Theme.textXs) : Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(tone)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

/// An icon button that opens a menu: the place for a page's rare actions.
struct NativeIconMenu<Items: View>: View {
    var icon: String = "ellipsis"
    var help: String = "More"
    @ViewBuilder var items: () -> Items
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        Menu { items() } label: {
            NativeIcon(icon, size: 15).foregroundStyle(hovering ? Theme.ink : Theme.muted)
                .frame(width: Theme.control, height: Theme.control)
                .background(hovering ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .opacity(enabled ? 1 : 0.4).onHover { hovering = $0 && enabled }
        .help(help).accessibilityLabel(help)
    }
}

private struct NativeRouteStackedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var nativeRouteStacked: Bool {
        get { self[NativeRouteStackedKey.self] }
        set { self[NativeRouteStackedKey.self] = newValue }
    }
}

/// Separates two stops of a route line. Hidden when the line stacks.
struct NativeRouteArrow: View {
    @Environment(\.nativeRouteStacked) private var stacked
    var body: some View {
        if !stacked { NativeIcon("arrow-right", size: 13).foregroundStyle(Theme.faint).accessibilityHidden(true) }
    }
}

/// One route, read left to right: the tool, then each choice that decides
/// where its requests go. The choices are the controls, and one action on
/// the right applies them. Stacks when the line does not fit.
struct NativeRouteLine<Stops: View, Action: View>: View {
    var tool: String
    var icon: String = "terminal"
    @ViewBuilder var stops: () -> Stops
    @ViewBuilder var action: () -> Action
    private var lead: some View {
        HStack(spacing: 8) {
            NativeIcon(icon, size: 15).foregroundStyle(Theme.muted).accessibilityHidden(true)
            Text(tool).font(Theme.ui(Theme.textSm, weight: .semibold)).lineLimit(1)
        }.fixedSize()
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                lead
                NativeRouteArrow()
                stops()
                Spacer(minLength: 12)
                action()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { lead; Spacer(minLength: 8); action() }
                HStack(spacing: 10) { stops() }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { lead; Spacer(minLength: 8); action() }
                stops()
            }.environment(\.nativeRouteStacked, true)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) }
    }
}

// MARK: - Board

/// A board: the main column and, beside it, a fixed pane that describes the
/// selection, or the whole range when nothing is selected. The pane moves
/// under the column on narrow windows.
struct NativeBoard<Main: View, Pane: View, Actions: View>: View {
    static var paneWidth: CGFloat { 320 }
    static func wide(_ width: CGFloat) -> Bool { width >= 920 }
    static func mainWidth(_ width: CGFloat) -> CGFloat { wide(width) ? width - paneWidth - 1 : width }
    var width: CGFloat
    var showsPane = true
    /// Arrow keys step through the table when set.
    var onMove: ((Int) -> Void)? = nil
    @Environment(\.nativeInterfaceDensity) private var density
    @ViewBuilder var main: () -> Main
    @ViewBuilder var pane: () -> Pane
    @ViewBuilder var actions: () -> Actions
    var body: some View {
        let wide = Self.wide(width)
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    main()
                    if !wide, showsPane {
                        // Stacked, the pane keeps the page margin its sections are inset from.
                        Group { pane().padding(.top, 24); actions() }.padding(.horizontal, max(0, density.pageMargin - 16))
                    }
                }.padding(.bottom, 32).frame(maxWidth: .infinity, alignment: .topLeading)
            }.scrollContentBackground(.hidden)
            .focusable(onMove != nil).focusEffectDisabled()
            .onMoveCommand { direction in onMove?(direction == .down ? 1 : direction == .up ? -1 : 0) }
            if wide, showsPane {
                VStack(spacing: 0) {
                    ScrollView { pane().frame(maxWidth: .infinity, alignment: .topLeading) }.scrollContentBackground(.hidden)
                    actions()
                }
                .frame(width: Self.paneWidth).frame(maxHeight: .infinity, alignment: .top)
                .overlay(alignment: .leading) { Theme.rule.frame(width: 1) }
            }
        }
        .font(Theme.ui(12)).foregroundStyle(Theme.ink)
    }
}

struct NativeHeroFact: Identifiable {
    var label: String
    var value: String
    var help = ""
    var tone: Color = Theme.ink
    var id: String { label }
}

/// The headline of a board: the number the chart below it plots, then the
/// figures that qualify it.
struct NativeHero<Label: View, Trailing: View>: View {
    var value: String
    var numeric: Double? = nil
    var unit = ""
    var facts: [NativeHeroFact] = []
    var maxFacts = 4
    @ViewBuilder var label: () -> Label
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 28) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) { label() }.font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value).font(Theme.num(32)).tracking(Theme.tracking(32)).lineLimit(1).fixedSize()
                        .nativeStatsNumberTransition(numeric)
                    if !unit.isEmpty { Text(unit).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(Theme.muted) }
                }
            }
            ForEach(Array(facts.prefix(maxFacts))) { fact in
                VStack(alignment: .leading, spacing: 5) {
                    Text(fact.label).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    Text(fact.value).font(Theme.num(15, weight: .medium)).foregroundStyle(fact.tone).lineLimit(1).fixedSize()
                }.help(fact.help).accessibilityElement(children: .ignore).accessibilityLabel(fact.label).accessibilityValue(fact.value)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

/// A ruled block of the side pane.
struct NativePaneSection<Content: View>: View {
    var title: String
    var inset: CGFloat = 16
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !title.isEmpty { Text(title).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).accessibilityAddTraits(.isHeader) }
            content()
        }
        .padding(.horizontal, inset).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
    }
}

struct NativePaneFact: View {
    var label: String
    var value: String
    var mono = false
    var tone: Color = Theme.ink
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(mono ? Theme.mono(11) : Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(tone).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// A row of a board table. Selecting it re-scopes the pane.
struct NativeBoardRow<Content: View>: View {
    var selected: Bool
    var margin: CGFloat
    var height: CGFloat = 36
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) { content() }
                .frame(minHeight: height).padding(.horizontal, margin).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.raised : hovering ? Theme.subtle : .clear)
        .overlay(alignment: .top) { Theme.rule.frame(height: 1).padding(.horizontal, margin) }
        .overlay(alignment: .leading) { Theme.accent.frame(width: 2).opacity(selected ? 1 : 0) }
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct NativeSplitPart: Identifiable {
    var id: String
    var label: String
    var amount: Double
    var color: Color
}

/// One quantity divided into its parts, drawn in the tick motif: each tick
/// takes the colour of the part it falls in.
struct NativeSplitTicks: View {
    var parts: [NativeSplitPart]
    var total: Double? = nil
    var height: CGFloat = 14
    var body: some View {
        let sum = max(total ?? 0, parts.reduce(0) { $0 + max(0, $1.amount) })
        Canvas { context, size in
            let tick: CGFloat = 2, gap: CGFloat = 3
            let count = max(1, Int((size.width + gap) / (tick + gap)))
            var bounds: [(Double, Color)] = [], running = 0.0
            for part in parts { running += max(0, part.amount); bounds.append((sum > 0 ? running / sum : 0, part.color)) }
            for index in 0..<count {
                let position = (Double(index) + 0.5) / Double(count)
                let color = bounds.first { position <= $0.0 }?.1 ?? Theme.track
                context.fill(Path(roundedRect: CGRect(x: CGFloat(index) * (tick + gap), y: 0, width: tick, height: size.height), cornerRadius: 1), with: .color(color))
            }
        }
        .frame(height: height).frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.map(\.label).joined(separator: ", "))
    }
}
