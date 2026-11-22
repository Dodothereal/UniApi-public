import SwiftUI
import AppKit

/// Command-K: type a few letters, press Return. Lists every visible page and
/// the handful of shell commands, in the order the index shows them.
struct NativeCommandPalette: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        let group: String
        let icon: String
        let key: String
        let run: () -> Void
    }

    var items: [Item]
    var close: () -> Void
    @State private var query = ""
    @State private var cursor = 0
    @FocusState private var focused: Bool

    /// Prefix matches lead, then word starts, then any ordered subsequence.
    static func rank(_ title: String, _ query: String) -> Int? {
        let needle = query.lowercased().filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return 0 }
        let hay = title.lowercased()
        if hay.hasPrefix(needle) { return 0 }
        if hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if hay.contains(needle) { return 2 }
        var index = hay.startIndex
        for character in needle {
            guard let found = hay[index...].firstIndex(of: character) else { return nil }
            index = hay.index(after: found)
        }
        return 3
    }
    private var matches: [Item] {
        var ranked: [(rank: Int, offset: Int, item: Item)] = []
        for (offset, item) in items.enumerated() {
            if let rank = Self.rank(item.title, query) { ranked.append((rank, offset, item)) }
        }
        ranked.sort { left, right in
            left.rank == right.rank ? left.offset < right.offset : left.rank < right.rank
        }
        return ranked.map { $0.item }
    }
    private func run(_ item: Item) { close(); item.run() }
    private func move(_ delta: Int) {
        let count = matches.count
        guard count > 0 else { return }
        cursor = (cursor + delta + count) % count
    }

    var body: some View {
        let rows = matches
        ZStack(alignment: .top) {
            Theme.overlay.ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    NativeIcon("search", size: 15, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                    TextField("Jump to a page or command", text: $query)
                        .textFieldStyle(.plain).font(Theme.ui(15)).foregroundStyle(Theme.ink)
                        .focused($focused)
                        .onSubmit { if rows.indices.contains(cursor) { run(rows[cursor]) } }
                    KeyCap("esc")
                }
                .padding(.horizontal, 16).frame(height: 48)
                TickRule(span: 60)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            if rows.isEmpty {
                                Text("Nothing matches \u{201C}" + query + "\u{201D}.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 10).frame(height: 40)
                            }
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, item in
                                if query.isEmpty, index == 0 || rows[index - 1].group != item.group {
                                    MicroLabel(item.group).padding(.horizontal, 10).padding(.top, index == 0 ? 4 : 12).padding(.bottom, 5)
                                }
                                PaletteRow(item: item, active: index == cursor, showGroup: !query.isEmpty) { run(item) }
                                    .onHover { if $0 { cursor = index } }
                                    .id(item.id)
                            }
                        }.padding(8)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: cursor) { _, next in
                        if rows.indices.contains(next) { proxy.scrollTo(rows[next].id) }
                    }
                }
                Rule()
                HStack(spacing: 14) {
                    HStack(spacing: 5) { KeyCap("\u{2191}"); KeyCap("\u{2193}"); Text("move") }
                    HStack(spacing: 5) { KeyCap("\u{21B5}"); Text("open") }
                    Spacer()
                    Text(String(rows.count) + (rows.count == 1 ? " match" : " matches")).font(Theme.mono(10.5))
                }
                .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                .padding(.horizontal, 16).frame(height: 34)
            }
            .frame(width: 520)
            .background(Theme.popover, in: RoundedRectangle(cornerRadius: Theme.radiusSheet, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSheet, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1))
            .shadow(color: Theme.shadow, radius: 30, y: 14)
            .padding(.top, 96)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Jump to")
        }
        // Cancel is a key equivalent, so Escape closes the palette wherever focus sits.
        .background {
            Button("Close", action: close).keyboardShortcut(.cancelAction)
                .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        // The field is not in the window yet when the overlay first appears;
        // claiming focus one turn later is what makes typing land at once.
        .onAppear { focused = true; DispatchQueue.main.async { focused = true } }
        .onChange(of: query) { _, _ in cursor = 0 }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
    }
}

private struct PaletteRow: View {
    var item: NativeCommandPalette.Item
    var active: Bool
    var showGroup: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                NativeIcon(item.icon, size: 15, strokeWidth: 1.6).foregroundStyle(active ? Theme.ink : Theme.muted)
                    .frame(width: 16)
                Text(item.title).font(Theme.ui(13, weight: active ? .medium : .regular)).foregroundStyle(active ? Theme.ink : Theme.dim)
                if showGroup { Text(item.group).font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
                Spacer(minLength: 8)
                if !item.key.isEmpty { KeyCap(item.key) }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).fill(Theme.pressed)
                        .overlay(alignment: .leading) { Theme.signal.frame(width: 2, height: 14) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand()
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
