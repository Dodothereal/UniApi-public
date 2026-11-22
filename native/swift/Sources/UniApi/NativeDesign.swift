import SwiftUI
import UniApiCore

// The layout vocabulary every page is built from. Content sits on the canvas
// and is organized by alignment, hairlines and type size; nothing here draws
// a bordered box.

/// A one-pixel rule in the border token.
struct NativeRule: View {
    var vertical = false
    var body: some View {
        Theme.border.frame(width: vertical ? 1 : nil, height: vertical ? nil : 1).accessibilityHidden(true)
    }
}

/// A titled region: heading and its controls on one line, a hairline, content.
/// The heading is optional; a region that needs no name gets only its rule.
struct NativeSection<Trailing: View, Content: View>: View {
    var title: String
    var count: String
    var ruled: Bool
    private let trailing: Trailing
    private let content: Content

    init(_ title: String = "", count: String = "", ruled: Bool = true,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder content: () -> Content) {
        self.title = title; self.count = count; self.ruled = ruled
        self.trailing = trailing(); self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !title.isEmpty || Trailing.self != EmptyView.self {
                HStack(alignment: .center, spacing: 8) {
                    if !title.isEmpty {
                        Text(title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.ink)
                            .lineLimit(1).accessibilityAddTraits(.isHeader)
                    }
                    if !count.isEmpty {
                        Text(count).font(Theme.num(12, weight: .regular)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .frame(minHeight: 28).padding(.bottom, 8)
            }
            if ruled { NativeRule().padding(.bottom, 14) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension NativeSection where Trailing == EmptyView {
    init(_ title: String = "", count: String = "", ruled: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title, count: count, ruled: ruled, trailing: { EmptyView() }, content: content)
    }
}

/// A reading: quiet label, large value, optional unit and one supporting fact.
/// `size` separates the reading that leads a page (`.lead`) from its peers.
struct NativeFigure: View {
    enum Size { case lead, regular, small
        var value: CGFloat { self == .lead ? 56 : self == .regular ? 28 : 19 }
        var unit: CGFloat { self == .lead ? 17 : self == .regular ? 13 : 12 }
    }
    var label: String
    var value: String
    var unit: String = ""
    var detail: String = ""
    var size: Size = .regular
    var color: Color = Theme.ink
    var delay: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: size == .lead ? 2 : 4) {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: size == .lead ? 6 : 4) {
                NativeNumberText(text: value, font: Theme.display(size.value), color: color, delay: delay)
                if !unit.isEmpty {
                    Text(unit).font(Theme.ui(size.unit, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            if !detail.isEmpty {
                Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, unit, detail].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

/// Peers on one line, separated by vertical hairlines and sharing a baseline.
/// Wraps to as many columns as the narrowest reading allows.
struct NativeFigureRow<Content: View>: View {
    var minimum: CGFloat = 150
    @ViewBuilder var content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum), spacing: 24, alignment: .topLeading)],
                  alignment: .leading, spacing: 20) { content() }
    }
}

/// A list line on the canvas: leading content, trailing content, a hairline
/// below. With an action the whole line is the target and shows it on hover.
struct NativeLedgerRow<Leading: View, Trailing: View>: View {
    var height: CGFloat = 40
    var last = false
    var action: (() -> Void)? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion

    private var line: some View {
        HStack(alignment: .center, spacing: 12) {
            leading()
            Spacer(minLength: 12)
            trailing()
        }
        .frame(minHeight: height)
        .padding(.horizontal, 8)
        .background(hovering && action != nil ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
    }
    var body: some View {
        VStack(spacing: 0) {
            if let action {
                Button(action: action) { line }.buttonStyle(.plain).pointingHand()
                    .onHover { hovering = $0 }
                    .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
            } else { line }
            if !last { NativeRule() }
        }
    }
}

/// Parts of a whole on one bar, with the legend carrying the numbers. Use it
/// where a row of equal tiles would hide which part dominates.
struct NativeSplitBar: View {
    struct Part: Identifiable { var id: String { label }; var label: String; var value: Double; var text: String; var color: Color }
    var parts: [Part]
    var height: CGFloat = 10
    private var total: Double { parts.reduce(0) { $0 + max(0, $1.value) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    if total > 0 {
                        ForEach(parts.filter { $0.value > 0 }) { part in
                            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(part.color)
                                .frame(width: max(2, (geometry.size.width - CGFloat(parts.count - 1) * 2) * part.value / total))
                        }
                    } else { RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.track) }
                }
            }
            .frame(height: height).clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .nativeEntrance(.grow).accessibilityHidden(true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 20, alignment: .topLeading)], alignment: .leading, spacing: 10) {
                ForEach(parts) { part in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        RoundedRectangle(cornerRadius: 1.5).fill(part.color).frame(width: 8, height: 8)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 0.5 }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(part.text).font(Theme.num(13)).foregroundStyle(Theme.ink)
                            Text(part.label).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }.accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// A status stated in words with its color; the dot only pulses for work that
/// is actually in progress. Never used to announce that data is "live".
struct NativeStatusText: View {
    var text: String
    var color: Color = Theme.muted
    var pulse = false
    var body: some View {
        HStack(spacing: 6) {
            NativeStatusDot(color: color, size: 6, pulse: pulse)
            Text(text).font(Theme.ui(12)).foregroundStyle(color == Theme.muted ? Theme.muted : Theme.dim).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}

/// Keyboard hint, e.g. the jump palette's shortcut.
struct NativeKeyHint: View {
    var text: String
    var body: some View {
        Text(text).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(Theme.subtle2, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}


/// A settings group: its name sits in a fixed left gutter and the rows align
/// on a single column beside it, so the eye scans names and controls as two
/// straight edges. Collapses to a stacked layout when the page is narrow.
struct NativeGutterGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeRule()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) {
                    heading.frame(width: 132, alignment: .leading)
                    rows.frame(minWidth: 380)
                }
                VStack(alignment: .leading, spacing: 14) { heading; rows }
            }.padding(.top, 18).padding(.bottom, 26)
        }
    }
    private var heading: some View {
        Text(title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
    }
    private var rows: some View {
        VStack(alignment: .leading, spacing: 16) { content() }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
