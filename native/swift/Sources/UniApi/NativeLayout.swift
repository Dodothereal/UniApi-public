import SwiftUI
import UniApiCore

// ======================================================================
// MARK: - Page
// ======================================================================
//
// A page is one fixed bar and one column. The bar names the page, switches
// its views and holds its actions, so none of them scroll away. The column
// has the same width and the same left edge on every page.

struct NativePage<Content: View>: View {
    var title: String
    var maxWidth: CGFloat
    var readiness: NativePageReadiness
    var scrolls: Bool
    var backTitle: String
    var backAction: (() -> Void)?
    @Environment(\.nativePageVisit) private var visit
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeHostTabs) private var host
    private let content: Content
    private let actions: AnyView
    private let tabs: AnyView?
    /// One strip: the sibling views of the destination around this page's own.
    private var barTabs: AnyView? {
        guard let host else { return tabs }
        return AnyView(HStack(spacing: 2) {
            if !host.before.isEmpty || host.current != nil {
                NativeTabs(options: host.before + (host.current.map { [$0] } ?? []), selection: host.current?.value ?? "", onSelect: host.select)
            }
            if let tabs { tabs }
            if !host.after.isEmpty { NativeTabs(options: host.after, selection: "", onSelect: host.select) }
        })
    }

    /// `subtitle` and `showsHeader` are accepted for source compatibility and
    /// have no effect: pages do not carry a description under their name.
    init(title: String, subtitle: String = "", maxWidth: CGFloat = Theme.contentWidth, readiness: NativePageReadiness = .pending, showsHeader: Bool = true, scrolls: Bool = true, backTitle: String = "Back", back: (() -> Void)? = nil,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.maxWidth = maxWidth; self.readiness = readiness; self.scrolls = scrolls
        self.backTitle = backTitle; self.backAction = back
        self.content = content(); self.actions = AnyView(EmptyView()); self.tabs = nil
    }

    init<Actions: View>(title: String, subtitle: String = "", maxWidth: CGFloat = Theme.contentWidth,
         readiness: NativePageReadiness = .pending, showsHeader: Bool = true, scrolls: Bool = true, backTitle: String = "Back", back: (() -> Void)? = nil, @ViewBuilder actions: () -> Actions,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.maxWidth = maxWidth; self.readiness = readiness; self.scrolls = scrolls
        self.backTitle = backTitle; self.backAction = back
        self.content = content(); self.actions = AnyView(actions()); self.tabs = nil
    }

    init<Tabs: View, Actions: View>(title: String, maxWidth: CGFloat = Theme.contentWidth,
         readiness: NativePageReadiness = .pending, scrolls: Bool = true, backTitle: String = "Back", back: (() -> Void)? = nil,
         @ViewBuilder tabs: () -> Tabs, @ViewBuilder actions: () -> Actions,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.maxWidth = maxWidth; self.readiness = readiness; self.scrolls = scrolls
        self.backTitle = backTitle; self.backAction = back
        self.content = content(); self.actions = AnyView(actions()); self.tabs = AnyView(tabs())
    }

    var body: some View {
        GeometryReader { viewport in
            let column = max(0, min(max(maxWidth, Theme.contentWidth), viewport.size.width))
            VStack(spacing: 0) {
                NativePageBar(title: host?.title ?? title, backTitle: backTitle, backAction: backAction, tabs: barTabs, actions: actions,
                              column: scrolls ? column : viewport.size.width)
                if scrolls {
                    ScrollView {
                        VStack(alignment: .leading, spacing: density.pageGap) { content }
                            .padding(.horizontal, density.pageMargin).padding(.top, density.pageGap).padding(.bottom, 48)
                            .frame(width: column, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .nativeEntrance(.page)
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .nativeEntrance(.page)
                }
            }
        }
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .font(Theme.ui(Theme.textSm))
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

/// A destination made of several pages shows them as views of one page: its
/// name in the bar, and every view in one tab strip.
struct NativeHostTabs {
    var title: String
    /// The view the destination shows, by tab value.
    var view: String
    var before: [(value: String, label: String)] = []
    /// Set for a page that has no tabs of its own.
    var current: (value: String, label: String)? = nil
    var after: [(value: String, label: String)] = []
    var select: (String) -> Void
}
private struct NativeHostTabsKey: EnvironmentKey { static let defaultValue: NativeHostTabs? = nil }
extension EnvironmentValues {
    var nativeHostTabs: NativeHostTabs? {
        get { self[NativeHostTabsKey.self] }
        set { self[NativeHostTabsKey.self] = newValue }
    }
}
private struct NativeHostedView: ViewModifier {
    @Environment(\.nativeHostTabs) private var host
    let own: [String]
    let open: (String) -> Void
    func body(content: Content) -> some View {
        content
            .onAppear { if let host, own.contains(host.view) { open(host.view) } }
            .onChange(of: host?.view ?? "") { _, view in if own.contains(view) { open(view) } }
    }
}
extension View {
    /// Opens the view the destination last showed, when it is one of `own`.
    func nativeHostedView(_ own: [String], open: @escaping (String) -> Void) -> some View { modifier(NativeHostedView(own: own, open: open)) }
}

/// A scrolling pane inside a page that owns its frame (`scrolls: false`).
/// It carries the same margins and column as a scrolling page.
struct NativePane<Content: View>: View {
    var maxWidth: CGFloat = Theme.contentWidth
    var centered = true
    @Environment(\.nativeInterfaceDensity) private var density
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.pageGap) { content() }
                .padding(.horizontal, density.pageMargin).padding(.top, density.pageGap).padding(.bottom, 48)
                .frame(maxWidth: maxWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: centered ? .top : .topLeading)
        }.scrollContentBackground(.hidden)
    }
}

/// The fixed bar of a page. Workbenches that own their whole frame use it
/// directly above their panes.
struct NativePageBar: View {
    var title: String
    var backTitle: String = "Back"
    var backAction: (() -> Void)? = nil
    var tabs: AnyView? = nil
    var actions: AnyView = AnyView(EmptyView())
    var column: CGFloat = .infinity
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeShellInset) private var inset

    private var name: some View {
        HStack(spacing: 8) {
            if let backAction {
                Button(action: backAction) { Text(backTitle).font(Theme.ui(Theme.textBase, weight: .medium)) }
                    .buttonStyle(NativeCrumbStyle())
                    .accessibilityLabel("Back to " + backTitle)
                Text("/").font(Theme.ui(Theme.textBase)).foregroundStyle(Theme.faint).accessibilityHidden(true)
            }
            Text(title).font(Theme.ui(Theme.textBase, weight: .semibold)).tracking(Theme.tracking(Theme.textBase))
                .foregroundStyle(Theme.ink).lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                name.fixedSize()
                if let tabs { tabs.padding(.leading, 14).fixedSize() }
                Spacer(minLength: 16)
                HStack(spacing: 8) { actions }.fixedSize()
            }
            .frame(height: Theme.barHeight)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    name.layoutPriority(-1)
                    Spacer(minLength: 16)
                    HStack(spacing: 8) { actions }.fixedSize()
                }
                .frame(height: Theme.barHeight)
                if let tabs {
                    ScrollView(.horizontal) { tabs.padding(.leading, -10).environment(\.nativeTabHeight, 38) }.scrollIndicators(.hidden)
                        .frame(height: 38)
                }
            }
        }
        .padding(.leading, density.pageMargin + inset).padding(.trailing, density.pageMargin)
        .frame(width: column.isFinite ? column : nil, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
        .background(Theme.bg)
    }
}

private struct NativeCrumbStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { NativeCrumbBody(configuration: configuration) }
}

private struct NativeCrumbBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    var body: some View {
        configuration.label.foregroundStyle(hovering ? Theme.ink : Theme.muted)
            .contentShape(Rectangle()).onHover { hovering = $0 }.pointingHand()
    }
}

private struct NativeShellInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
private struct NativeTabHeightKey: EnvironmentKey { static let defaultValue: CGFloat = Theme.barHeight }
extension EnvironmentValues {
    /// Extra leading room the shell asks page bars to keep clear.
    var nativeShellInset: CGFloat {
        get { self[NativeShellInsetKey.self] }
        set { self[NativeShellInsetKey.self] = newValue }
    }
    var nativeTabHeight: CGFloat {
        get { self[NativeTabHeightKey.self] }
        set { self[NativeTabHeightKey.self] = newValue }
    }
}

/// Compatibility title block for a detail view that has not moved its title
/// into the page bar yet.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var centerTrailing: Bool = false
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: centerTrailing ? .center : .firstTextBaseline, spacing: 16) {
            Text(title).font(Theme.ui(Theme.text2Xl, weight: .semibold)).tracking(Theme.tracking(Theme.text2Xl))
                .foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            HStack(spacing: 8) { trailing() }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, centerTrailing: false, trailing: { EmptyView() })
    }
}

// ======================================================================
// MARK: - Stacks and sections
// ======================================================================

/// Children separated by one hairline each. Use it instead of drawing a rule
/// by hand between rows.
struct NativeStack<Content: View>: View {
    var inset: CGFloat = 0
    var padding: CGFloat = 0
    @ViewBuilder var content: () -> Content
    var body: some View {
        _VariadicView.Tree(NativeDividedRoot(inset: inset, padding: padding)) { content() }
    }
}

private struct NativeDividedRoot: _VariadicView_UnaryViewRoot {
    var inset: CGFloat
    var padding: CGFloat
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(alignment: .leading, spacing: 0) {
            ForEach(children) { child in
                child.padding(.vertical, padding)
                if child.id != last { Theme.rule.frame(height: 1).padding(.leading, inset) }
            }
        }
    }
}

/// `bare` drops the section name: the surrounding view already names it.
enum NativeSectionStyle { case stacked, margin, bare }
private struct NativeSectionStyleKey: EnvironmentKey { static let defaultValue = NativeSectionStyle.stacked }
extension EnvironmentValues {
    var nativeSectionStyle: NativeSectionStyle {
        get { self[NativeSectionStyleKey.self] }
        set { self[NativeSectionStyleKey.self] = newValue }
    }
}

/// The form grammar: sections ruled apart, each named in the left margin with
/// its controls in the column beside it.
struct NativeSheet<Content: View>: View {
    @Environment(\.nativeInterfaceDensity) private var density
    @ViewBuilder var content: () -> Content
    var body: some View {
        NativeStack(padding: density.sectionGap) { content() }
            .environment(\.nativeSectionStyle, .margin)
            .padding(.top, -density.pageGap + 4)
    }
}

/// A named group. Inside `NativeSheet` the name moves to the left margin;
/// elsewhere it is one line above the group. `detail` is a fact about the
/// group (a count, a state), never a description of what the group is.
struct NativeSection<Trailing: View, Content: View>: View {
    var title: String
    var detail: String
    @Environment(\.nativeSectionStyle) private var style
    private let trailing: Trailing
    private let content: Content

    init(_ title: String, detail: String = "", @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        if style == .margin {
            NativeMarginLayout {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(Theme.ui(Theme.textSm, weight: .semibold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if !detail.isEmpty {
                        Text(detail).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    trailing.padding(.top, 5)
                }
                VStack(alignment: .leading, spacing: 18) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .environment(\.nativeSectionStyle, .stacked)
            }
        } else if style == .bare {
            VStack(alignment: .leading, spacing: 18) {
                if !detail.isEmpty || Trailing.self != EmptyView.self {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(detail).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        trailing
                    }
                }
                content
            }
            .environment(\.nativeSectionStyle, .stacked)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(Theme.ui(Theme.textSm, weight: .semibold)).foregroundStyle(Theme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if !detail.isEmpty { Text(detail).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1) }
                    Spacer(minLength: 8)
                    trailing
                }
                content
            }
        }
    }
}

extension NativeSection where Trailing == EmptyView {
    init(_ title: String, detail: String = "", @ViewBuilder content: () -> Content) {
        self.init(title, detail: detail, trailing: { EmptyView() }, content: content)
    }
}

/// Label column beside its content; the label moves above when the column
/// would squeeze the content.
private struct NativeMarginLayout: Layout {
    private let gap: CGFloat = 28
    private func stacked(_ width: CGFloat) -> Bool { width < 620 }
    private func measure(_ width: CGFloat?, _ subviews: Subviews) -> (CGFloat, CGSize, CGSize, Bool) {
        let available = max(0, width.flatMap { $0.isFinite ? $0 : nil } ?? 760)
        let stack = stacked(available)
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: stack ? available : Theme.marginLabelWidth, height: nil))
        let content = subviews[1].sizeThatFits(ProposedViewSize(width: stack ? available : max(0, available - Theme.marginLabelWidth - gap), height: nil))
        return (available, label, content, stack)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let (width, label, content, stack) = measure(proposal.width, subviews)
        return CGSize(width: width, height: stack ? label.height + 14 + content.height : max(label.height, content.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (width, label, content, stack) = measure(bounds.width, subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: stack ? width : Theme.marginLabelWidth, height: label.height))
        subviews[1].place(at: CGPoint(x: bounds.minX + (stack ? 0 : Theme.marginLabelWidth + gap), y: bounds.minY + (stack ? label.height + 14 : 0)),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(width: stack ? width : max(0, width - Theme.marginLabelWidth - gap), height: content.height))
    }
}

/// Compatibility name for a stacked section heading.
struct SectionLabel<Trailing: View>: View {
    var text: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(Theme.ui(Theme.textSm, weight: .semibold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension SectionLabel where Trailing == EmptyView {
    init(_ text: String) { self.init(text: text, trailing: { EmptyView() }) }
}

/// One setting: what it is on the left, its control on the right. `desc`
/// states a consequence the name cannot; leave it out when the name is enough.
struct SettingRow<Control: View>: View {
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var title: String
    var desc: String? = nil
    /// Every other string this row's description can switch to. They are laid
    /// out invisibly underneath the real one, so the row always occupies the
    /// height of its tallest variant and picking a different option cannot
    /// shove the rest of the page up or down.
    var descVariants: [String] = []
    @ViewBuilder var control: () -> Control

    var body: some View {
        NativeSettingRowLayout() {
            labels
            control().fixedSize(horizontal: true, vertical: false)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var labels: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Theme.ui(Theme.textSm, weight: .medium))
                .foregroundStyle(Theme.ink)
            if let d = desc {
                ZStack(alignment: .topLeading) {
                    ForEach(descVariants, id: \.self) { v in
                        descText(v).opacity(0).accessibilityHidden(true)
                    }
                    descText(d).id(d).transition(.opacity)
                }
                .animation(reduceMotion ? nil : NativeMotion.hover, value: d)
            }
        }
    }

    private func descText(_ s: String) -> some View {
        Text(s)
            .font(Theme.ui(Theme.textXs))
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Measure the control rather than the description's unwrapped ideal width.
/// The same child views retain focus when the row changes between two columns
/// and a stack during window resizing.
private struct NativeSettingRowLayout: Layout {
    private func dimensions(_ width: CGFloat?, _ subviews: Subviews) -> (CGFloat, CGSize, CGSize, Bool) {
        let control = subviews[1].sizeThatFits(.unspecified)
        let available = max(0, width.flatMap { $0.isFinite ? $0 : nil } ?? (220 + 20 + control.width))
        let stacked = available < 220 + 20 + control.width
        let labels = subviews[0].sizeThatFits(ProposedViewSize(width: stacked ? available : max(0, available - 20 - control.width), height: nil))
        return (available, labels, control, stacked)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let (width, labels, control, stacked) = dimensions(proposal.width, subviews)
        return CGSize(width: width, height: stacked ? labels.height + 10 + control.height : max(labels.height, control.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let (_, labels, control, stacked) = dimensions(bounds.width, subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: stacked ? bounds.width : max(0, bounds.width - 20 - control.width), height: labels.height))
        subviews[1].place(at: CGPoint(x: bounds.maxX - control.width, y: bounds.minY + (stacked ? labels.height + 10 : 0)),
                          anchor: .topLeading, proposal: ProposedViewSize(control))
    }
}

/// Detail that most visits do not need. The chevron turns, the content
/// arrives below it; nothing above moves.
struct NativeDisclosure<Content: View>: View {
    var title: String
    var detail: String = ""
    var tone: Color = Theme.ink
    private var external: Binding<Bool>?
    @State private var open = false
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private let content: Content

    init(_ title: String, detail: String = "", tone: Color = Theme.ink, @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.tone = tone; self.external = nil; self.content = content()
    }
    init(_ title: String, detail: String = "", tone: Color = Theme.ink, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title; self.detail = detail; self.tone = tone; self.external = isExpanded; self.content = content()
    }
    private var expanded: Bool { external?.wrappedValue ?? open }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : NativeMotion.reveal) {
                    if let external { external.wrappedValue.toggle() } else { open.toggle() }
                }
            } label: {
                HStack(spacing: 7) {
                    NativeIcon("chevron-right", size: 13).rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(hovering ? Theme.ink : Theme.muted)
                    Text(title).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(tone)
                    if !detail.isEmpty { Text(detail).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted) }
                    Spacer(minLength: 0)
                }
                .frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
            .accessibilityLabel(title).accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                content.padding(.top, 12).padding(.leading, 20)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
    }
}

// ======================================================================
// MARK: - Surfaces
// ======================================================================

/// A titled block of a board: a hairline above, the name, then the content
/// on the page ground. It is not a box; neighbouring plates share the rule
/// grid instead of each drawing a border.
struct NativeCard<Content: View>: View {
    var title: String
    private let content: Content

    init(title: String = "", @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !title.isEmpty {
                Text(title).font(Theme.ui(Theme.textSm, weight: .semibold))
                    .foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(.top, 16).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .top) { Theme.border.frame(height: 1) }
    }
}

/// A row that goes somewhere: name, the one number that matters, a qualifying
/// fact. Columns are fixed so a list of these reads as a table. The arrow
/// appears under the pointer; `verb` names the action when it is not "open".
struct NativeLinkRow: View {
    var icon: String
    var title: String
    var value: String = ""
    var detail: String = ""
    var verb: String = ""
    var tone: Color = Theme.muted
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                NativeIcon(icon, size: 15).foregroundStyle(tone).frame(width: 18)
                if value.isEmpty && detail.isEmpty {
                    Text(title).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                } else {
                    Text(title).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).frame(width: 112, alignment: .leading)
                    NativeNumberText(text: value, font: Theme.ui(Theme.textSm), color: Theme.ink).frame(width: 148, alignment: .leading)
                    Text(detail).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 8)
                if !verb.isEmpty { Text(verb).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(hovering ? Theme.ink : Theme.muted) }
                NativeIcon("arrow-right", size: 13).foregroundStyle(hovering ? Theme.ink : Theme.muted)
                    .opacity(hovering || !verb.isEmpty ? 1 : 0).offset(x: hovering ? 0 : -4).frame(width: 16)
            }
            .padding(.horizontal, 16).frame(height: 44)
            .nativeRowHover(hovering).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Row surface inside a list: a tone step under the pointer, nothing else.
    func nativeRowHover(_ hovering: Bool, selected: Bool = false) -> some View {
        background(selected ? Theme.subtle2 : hovering ? Theme.subtle : .clear)
    }
}

// ======================================================================
// MARK: - Meters and bars
// ======================================================================

/// The UniApi meter: a ruler of ticks, filled up to the value. Used for
/// levels, load, progress and share; a chart bar stays a `NativeGrowBar`.
struct NativeTickMeter: View {
    var fraction: Double
    var color: Color = Theme.ink
    var height: CGFloat = 12
    var tick: CGFloat = 2
    var gap: CGFloat = 3
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        NativeTickBody(fraction: NativeMotion.fraction(fraction), color: color, rest: Theme.track, tick: tick, gap: gap)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: fraction)
            .accessibilityHidden(true)
    }
}

private struct NativeTickBody: View, Animatable {
    var fraction: Double
    var color: Color
    var rest: Color
    var tick: CGFloat
    var gap: CGFloat
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }
    var body: some View {
        Canvas { context, size in
            let step = tick + gap
            let count = max(1, Int((size.width + gap) / step))
            let filled = Double(count) * fraction
            for index in 0..<count {
                let on = Double(index) + 0.5 < filled
                let tall = on ? size.height : size.height * 0.58
                let rect = CGRect(x: CGFloat(index) * step, y: size.height - tall, width: tick, height: tall)
                context.fill(Path(roundedRect: rect, cornerRadius: tick / 2), with: .color(on ? color : rest))
            }
        }
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
            let shape = RoundedRectangle(cornerRadius: min(2, height / 2), style: .continuous)
            ZStack(alignment: .leading) {
                shape.fill(Theme.track)
                ZStack(alignment: .leading) {
                    if let spread {
                        let lower = NativeMotion.fraction(spread.lowerBound)
                        let upper = NativeMotion.fraction(spread.upperBound)
                        shape.fill(color.opacity(0.24))
                            .frame(width: geometry.size.width * max(0, upper - lower))
                            .offset(x: geometry.size.width * lower)
                    }
                    shape.fill(color)
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

// ======================================================================
// MARK: - Empty, failed
// ======================================================================

struct NativeError: View {
    var message: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            NativeIcon("circle-alert", size: 14).foregroundStyle(Theme.failFg)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2.5 }
                .accessibilityHidden(true)
            Text(message).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.failFg)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Theme.surfaceFor(Theme.fail), in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .accessibilityElement(children: .combine).accessibilityLabel("Error: " + message)
    }
}

/// Nothing here yet. The group starts where content would start, at the left
/// edge and the top of its container, and holds the one next action.
struct EmptyState: View {
    var icon: String
    var title: String
    var detail: String
    var actionTitle: String? = nil
    var actionIcon: String = "plus"
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeIcon(icon, size: 22, strokeWidth: 1.4)
                .foregroundStyle(Theme.faint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.ui(Theme.textBase, weight: .semibold)).tracking(Theme.tracking(Theme.textBase)).foregroundStyle(Theme.ink)
                if !detail.isEmpty {
                    Text(detail).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.muted)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440, alignment: .leading)
                }
            }.accessibilityElement(children: .combine)
            if let actionTitle, let action {
                Button(actionTitle, nativeIcon: actionIcon, action: action).buttonStyle(T3Button(.primary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 28)
    }
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
        VStack(alignment: .leading, spacing: 14) {
            NativeIcon(icon, size: 22, strokeWidth: 1.4).foregroundStyle(Theme.failFg).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.ui(Theme.textBase, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440, alignment: .leading)
            }.accessibilityElement(children: .combine)
            Button(retryTitle, nativeIcon: "refresh-cw", action: retry).buttonStyle(T3Button(.outline))
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 28)
    }
}
