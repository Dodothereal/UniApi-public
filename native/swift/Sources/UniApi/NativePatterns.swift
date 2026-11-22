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
                if !(stacked && open) { main().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
                if open {
                    inspector()
                        .frame(width: stacked ? geometry.size.width : width)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(Theme.surface)
                        .overlay(alignment: .leading) { Theme.border.frame(width: 1) }
                        .transition(reduced ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                        .onExitCommand(perform: onClose)
                }
            }
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
