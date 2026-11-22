import SwiftUI

/// One thing the palette can do: open a page or run a window action.
struct NativeCommand: Identifiable {
    let id: String
    let title: String
    let group: String
    let symbol: String
    var hint: String = ""
    var current: Bool = false
    let action: () -> Void
}

/// Command-K. Type a few letters, press Return. Arrow keys move, Escape closes.
struct NativeCommandPalette: View {
    let commands: [NativeCommand]
    let dismiss: () -> Void
    @State private var query = ""
    @State private var index = 0
    @State private var shown = false
    @FocusState private var focused: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion

    private var matches: [NativeCommand] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return commands }
        return commands.compactMap { command -> (Int, NativeCommand)? in
            guard let score = Self.score(needle, command.title.lowercased()) ?? Self.score(needle, command.group.lowercased()).map({ $0 + 4 }) else { return nil }
            return (score, command)
        }.sorted { $0.0 < $1.0 }.map(\.1)
    }
    /// Lower is better: prefix, word prefix, substring, then letters in order.
    private static func score(_ needle: String, _ text: String) -> Int? {
        if text.hasPrefix(needle) { return 0 }
        if text.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 1 }
        if text.contains(needle) { return 2 }
        var cursor = text.startIndex
        for character in needle {
            guard let found = text[cursor...].firstIndex(of: character) else { return nil }
            cursor = text.index(after: found)
        }
        return 3
    }

    var body: some View {
        let rows = matches
        ZStack(alignment: .top) {
            Theme.overlay.ignoresSafeArea().contentShape(Rectangle()).onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    NativeIcon("search", size: 16).foregroundStyle(Theme.muted)
                    TextField("Page or command", text: $query)
                        .textFieldStyle(.plain).font(Theme.ui(Theme.textBase)).foregroundStyle(Theme.ink)
                        .focused($focused)
                        .onSubmit { run(rows) }
                        .onKeyPress(.downArrow) { move(1, rows.count); return .handled }
                        .onKeyPress(.upArrow) { move(-1, rows.count); return .handled }
                        .onKeyPress(.escape) { dismiss(); return .handled }
                    NativeKbd("esc")
                }
                .padding(.horizontal, 16).frame(height: 50)
                Theme.rule.frame(height: 1)
                if rows.isEmpty {
                    Text("Nothing matches \u{201C}" + query + "\u{201D}").font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(rows.enumerated()), id: \.element.id) { offset, command in
                                    if query.isEmpty, offset == 0 || rows[offset - 1].group != command.group {
                                        Text(command.group.uppercased()).font(Theme.ui(10.5, weight: .semibold)).tracking(0.9)
                                            .foregroundStyle(Theme.faint).padding(.horizontal, 10).padding(.top, offset == 0 ? 4 : 12).padding(.bottom, 4)
                                    }
                                    NativeCommandRow(command: command, selected: offset == index, showsGroup: !query.isEmpty,
                                                     hover: { index = offset }, action: { index = offset; run(rows) })
                                        .id(command.id)
                                }
                            }.padding(6)
                        }
                        .frame(height: min(372, listHeight(rows)))
                        .onChange(of: index) { _, next in
                            if rows.indices.contains(next) { proxy.scrollTo(rows[next].id) }
                        }
                    }
                }
            }
            .frame(width: 540)
            .background(Theme.popover, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: Theme.shadow, radius: 32, y: 18)
            .scaleEffect(shown || reduceMotion ? 1 : 0.98, anchor: .top)
            .offset(y: shown || reduceMotion ? 0 : -6)
            .padding(.top, 92).padding(.horizontal, 24)
            .accessibilityElement(children: .contain).accessibilityLabel("Jump to")
            .accessibilityAddTraits(.isModal)
        }
        .onAppear {
            focused = true
            withAnimation(reduceMotion ? nil : NativeMotion.outExpo(0.24)) { shown = true }
        }
        .onChange(of: query) { _, _ in index = 0 }
    }
    private func listHeight(_ rows: [NativeCommand]) -> CGFloat {
        let groups = query.isEmpty ? Set(rows.map(\.group)).count : 0
        return CGFloat(rows.count) * 35 + CGFloat(groups) * 30 + 8
    }
    private func move(_ step: Int, _ count: Int) {
        guard count > 0 else { return }
        index = (index + step + count) % count
    }
    private func run(_ rows: [NativeCommand]) {
        guard rows.indices.contains(index) else { return }
        let command = rows[index]
        dismiss()
        command.action()
    }
}

private struct NativeCommandRow: View {
    let command: NativeCommand
    let selected: Bool
    let showsGroup: Bool
    let hover: () -> Void
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                NativeIcon(command.symbol, size: 15).foregroundStyle(selected ? Theme.ink : Theme.muted)
                Text(command.title).font(Theme.ui(Theme.textSm, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.dim)
                Spacer(minLength: 8)
                if command.current { Text("Open").font(Theme.ui(11)).foregroundStyle(Theme.faint) }
                else if showsGroup { Text(command.group).font(Theme.ui(11)).foregroundStyle(Theme.faint) }
                if !command.hint.isEmpty { NativeKbd(command.hint) }
                if selected { NativeIcon("arrow-right", size: 13).foregroundStyle(Theme.muted) }
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(selected ? Theme.subtle2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { hover() } }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
