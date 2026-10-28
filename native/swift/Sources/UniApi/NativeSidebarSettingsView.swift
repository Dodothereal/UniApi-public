import SwiftUI
import UniformTypeIdentifiers
import UniApiCore

/// Edits the same preferences consumed by the shell. Dragging only changes the
/// order after a valid drop; the menus provide the same moves without a pointer.
struct NativeSidebarSettingsView: View {
    @Environment(\.nativeBatterySupported) private var batterySupported
    @AppStorage("uniapi-sidebar") private var sidebarOpen = true
    @AppStorage("uniapi-sidebar-width") private var sidebarWidth = NativeSidebarLayout.defaultWidth
    @AppStorage("uniapi-sidebar-order") private var sidebarOrder = ""
    @AppStorage("uniapi-sidebar-hidden") private var sidebarHidden = ""
    @AppStorage("uniapi-sidebar-badges") private var sidebarBadges = NativeNavigationPreferences.defaultSidebarBadges
    @State private var dragged: SidebarDrag?
    @State private var dragNonce: String?
    @State private var hovered: SidebarDrag?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Sidebar")
            SettingRow(title: "Show sidebar", desc: "Command-B also toggles the sidebar.") {
                T3Switch(isOn: $sidebarOpen).accessibilityLabel("Show sidebar")
            }
            SettingRow(title: "Width", desc: "Adjust the sidebar from 180 to 320 points.") {
                HStack(spacing: 8) {
                    Slider(value: $sidebarWidth, in: 180...320).frame(width: 140).accessibilityLabel("Sidebar width")
                    Text("\(Int(NativeSidebarLayout.width(sidebarWidth))) pt").font(Theme.mono(11)).frame(width: 48, alignment: .trailing)
                }
            }
            SettingRow(title: "Show badges", desc: "Show counts and battery percentage beside pages.") {
                T3Switch(isOn: $sidebarBadges).accessibilityLabel("Show sidebar badges")
            }
            DisclosureGroup("Edit sidebar") {
              VStack(alignment: .leading, spacing: 8) {
                Text("Drag onto a row: moving up places it before that row; moving down places it after. Use Move for keyboard access. Pages stay within their section.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                VStack(alignment: .leading, spacing: 7) {
                    anchoredRow(.home)
                    ForEach(NativeSidebarLayout.orderedSections(sidebarOrder), id: \.self) { section in
                        sectionView(section)
                    }
                    Divider().padding(.vertical, 3)
                    anchoredRow(.jobs)
                    anchoredRow(.settings)
                }
                .padding(12).frame(maxWidth: 500, alignment: .leading)
                .background(Theme.sidebarBG, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                Text("Home stays at the top; Jobs and Settings stay at the bottom.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                if let dragged, let hovered, !validMove(dragged, hovered) {
                    Text("Cannot move here. Pages stay within their section; sections move onto section headings. Fixed pages cannot move.")
                        .font(Theme.ui(11)).foregroundStyle(Theme.failFg)
                }
              }.padding(.top, 10)
            }.font(Theme.ui(13, weight: .medium))
            Button("Restore sidebar layout defaults") {
                sidebarWidth = NativeSidebarLayout.defaultWidth
                sidebarOrder = ""
                sidebarHidden = ""
                sidebarBadges = NativeNavigationPreferences.defaultSidebarBadges
            }.buttonStyle(T3Button(.ghost))
        }
    }

    private func anchoredRow(_ page: NativeDestination) -> some View {
        HStack(spacing: 9) {
            NativeIcon(page.symbol, size: 14).frame(width: 18)
            Text(page.title).font(Theme.ui(12, weight: .medium))
            Spacer()
            Text("Fixed").font(Theme.ui(11)).foregroundStyle(Theme.muted)
        }.frame(height: 29).padding(.horizontal, 8)
            .contentShape(Rectangle())
            .overlay(alignment: .top) { dropMarker(.fixed(page)) }
            .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(dragged: $dragged, dragNonce: $dragNonce, hovered: $hovered, target: .fixed(page), move: reorder))
            .accessibilityElement(children: .combine)
    }

    private func sectionView(_ section: String) -> some View {
        let sections = NativeSidebarLayout.orderedSections(sidebarOrder)
        let pages = NativeSidebarLayout.pages(sidebarOrder).filter { $0.section == section }
        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 7) {
                dragHandle(.section(section), label: "Drag \(section) section")
                Text(section.uppercased()).font(Theme.ui(10.5, weight: .medium)).tracking(0.7).foregroundStyle(Theme.muted)
                Spacer()
                moveMenu("Move \(section) section", canMoveUp: sections.first != section, canMoveDown: sections.last != section,
                         up: { moveSection(section, by: -1) }, down: { moveSection(section, by: 1) })
            }.frame(height: 29).padding(.horizontal, 8)
                .contentShape(Rectangle())
                .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(dragged: $dragged, dragNonce: $dragNonce, hovered: $hovered, target: .section(section), move: reorder))
            ForEach(pages) { page in
                HStack(spacing: 7) {
                    dragHandle(.page(page), label: "Drag \(page.title)")
                    NativeIcon(page.symbol, size: 14).frame(width: 18).foregroundStyle(Theme.sidebarMuted)
                    Text(page.title).font(Theme.ui(12)).foregroundStyle(Theme.sidebarInk)
                    if page == .battery && batterySupported == false {
                        Text("Unavailable").font(Theme.ui(10)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 4)
                    T3Switch(isOn: visibility(page)).accessibilityLabel("Show \(page.title) in sidebar")
                    moveMenu("Move \(page.title)", canMoveUp: pages.first != page, canMoveDown: pages.last != page,
                             up: { movePage(page, by: -1) }, down: { movePage(page, by: 1) })
                }.frame(height: 32).padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .overlay(alignment: markerAlignment(.page(page))) { dropMarker(.page(page)) }
                    .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(dragged: $dragged, dragNonce: $dragNonce, hovered: $hovered, target: .page(page), move: reorder))
            }
        }.overlay(alignment: markerAlignment(.section(section))) { dropMarker(.section(section)) }
    }

    private func dragHandle(_ item: SidebarDrag, label: String) -> some View {
        NativeIcon("grip-vertical", size: 13).foregroundStyle(Theme.muted)
            .frame(width: 18, height: 26).contentShape(Rectangle())
            .help(label).accessibilityHidden(true)
            .onDrag {
                let nonce = "uniapi-sidebar-" + UUID().uuidString
                let provider = NSItemProvider(object: "UniApi sidebar" as NSString)
                provider.suggestedName = nonce
                dragged = item; dragNonce = nonce; hovered = nil
                return provider
            }
    }

    private func moveMenu(_ label: String, canMoveUp: Bool, canMoveDown: Bool,
                          up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        Menu {
            Button("Move up", action: up).disabled(!canMoveUp)
            Button("Move down", action: down).disabled(!canMoveDown)
        } label: {
            HStack(spacing: 3) { Text("Move"); NativeIcon("chevron-down", size: 10) }
                .font(Theme.ui(11)).foregroundStyle(Theme.muted).frame(height: 26).contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help(label).accessibilityLabel(label)
    }

    private func dropMarker(_ target: SidebarDrag) -> some View {
        let valid = dragged.map { validMove($0, target) } ?? false
        return Rectangle().fill(valid ? Theme.accent : Theme.failFg)
            .frame(height: 2).opacity(hovered == target ? 1 : 0).allowsHitTesting(false)
    }

    private func markerAlignment(_ target: SidebarDrag) -> Alignment {
        guard let source = dragged else { return .top }
        switch (source, target) {
        case let (.section(from), .section(to)):
            let sections = NativeSidebarLayout.orderedSections(sidebarOrder)
            guard let a = sections.firstIndex(of: from), let b = sections.firstIndex(of: to) else { return .top }
            return a < b ? .bottom : .top
        case let (.page(from), .page(to)) where from.section == to.section:
            let pages = NativeSidebarLayout.pages(sidebarOrder).filter { $0.section == from.section }
            guard let a = pages.firstIndex(of: from), let b = pages.firstIndex(of: to) else { return .top }
            return a < b ? .bottom : .top
        default: return .top
        }
    }

    private func visibility(_ page: NativeDestination) -> Binding<Bool> {
        Binding(get: { NativeNavigationPreferences.isSidebarVisible(page.rawValue, hiddenPages: sidebarHidden) },
                set: { sidebarHidden = NativeNavigationPreferences.settingSidebarVisibility(page.rawValue, visible: $0, in: sidebarHidden) })
    }

    private func movePage(_ page: NativeDestination, by offset: Int) {
        let pages = NativeSidebarLayout.pages(sidebarOrder).filter { $0.section == page.section }
        guard let index = pages.firstIndex(of: page), pages.indices.contains(index + offset) else { return }
        reorder(.page(page), .page(pages[index + offset]))
    }

    private func moveSection(_ section: String, by offset: Int) {
        let sections = NativeSidebarLayout.orderedSections(sidebarOrder)
        guard let index = sections.firstIndex(of: section), sections.indices.contains(index + offset) else { return }
        reorder(.section(section), .section(sections[index + offset]))
    }

    private func reorder(_ source: SidebarDrag, _ target: SidebarDrag) {
        let allPages = NativeSidebarLayout.pages(sidebarOrder)
        var sections = NativeSidebarLayout.orderedSections(sidebarOrder)
        switch (source, target) {
        case let (.section(from), .section(to)):
            guard let old = sections.firstIndex(of: from), let new = sections.firstIndex(of: to), old != new else { return }
            sections.remove(at: old); sections.insert(from, at: new)
            sidebarOrder = sections.flatMap { section in allPages.filter { $0.section == section } }.map(\.rawValue).joined(separator: ",")
        case let (.page(from), .page(to)):
            guard from.section == to.section else { return }
            var siblings = allPages.filter { $0.section == from.section }
            guard let old = siblings.firstIndex(of: from), let new = siblings.firstIndex(of: to), old != new else { return }
            siblings.remove(at: old); siblings.insert(from, at: new)
            sidebarOrder = sections.flatMap { section in section == from.section ? siblings : allPages.filter { $0.section == section } }.map(\.rawValue).joined(separator: ",")
        default: return
        }
    }
}

private enum SidebarDrag: Equatable {
    case section(String)
    case page(NativeDestination)
    case fixed(NativeDestination)
}

private func validMove(_ source: SidebarDrag, _ target: SidebarDrag) -> Bool {
    guard source != target else { return false }
    switch (source, target) {
    case (.section, .section): return true
    case let (.page(from), .page(to)): return from.section == to.section
    default: return false
    }
}

private struct SidebarDropDelegate: DropDelegate {
    @Binding var dragged: SidebarDrag?
    @Binding var dragNonce: String?
    @Binding var hovered: SidebarDrag?
    let target: SidebarDrag
    let move: (SidebarDrag, SidebarDrag) -> Void

    // A cancelled drag can leave view state behind. Match the actual provider
    // for this drag before even displaying a target or changing saved order.
    func validateDrop(info: DropInfo) -> Bool {
        guard dragged != nil, let dragNonce else { return false }
        return info.itemProviders(for: [UTType.text]).contains { $0.suggestedName == dragNonce }
    }
    func dropEntered(info: DropInfo) { if validateDrop(info: info) { hovered = target } }
    func dropExited(info: DropInfo) {
        if validateDrop(info: info), hovered == target { hovered = nil }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info), let dragged, validMove(dragged, target) else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        guard validateDrop(info: info) else { return false }
        defer { dragged = nil; dragNonce = nil; hovered = nil }
        guard let source = dragged, validMove(source, target) else { return false }
        move(source, target)
        return true
    }
}
