import SwiftUI
import UniformTypeIdentifiers
import UniApiCore

/// Edits the same preferences consumed by the shell. Dragging only changes the
/// order after a valid drop; the arrows provide the same moves without a pointer.
struct NativeSidebarSettingsView: View {
    @Environment(\.nativeBatterySupported) private var batterySupported
    @AppStorage("uniapi-sidebar") private var sidebarOpen = true
    @AppStorage("uniapi-sidebar-width") private var sidebarWidth = NativeSidebarLayout.defaultWidth
    @AppStorage("uniapi-sidebar-order") private var sidebarOrder = ""
    @AppStorage("uniapi-sidebar-hidden") private var sidebarHidden = ""
    @AppStorage("uniapi-sidebar-badges") private var sidebarBadges = NativeNavigationPreferences.defaultSidebarBadges
    @State private var editing = false
    @State private var dragged: SidebarDrag?
    @State private var dragNonce: String?
    @State private var hovered: SidebarDrag?

    var body: some View {
        Band(title: "Sidebar", spacing: 0) {
            Button("Restore defaults", nativeIcon: "rotate-ccw") {
                sidebarWidth = NativeSidebarLayout.defaultWidth
                sidebarOrder = ""
                sidebarHidden = ""
                sidebarBadges = NativeNavigationPreferences.defaultSidebarBadges
            }
            .buttonStyle(Press(.quiet)).padding(.trailing, -8)
            .help("Resets width, order, hidden pages and readings.")
            .accessibilityLabel("Restore sidebar layout defaults")
        } content: {
            OptionRow(title: "Layout", detail: "Command-B switches between the two.") {
                Stops(options: [(true, "Full"), (false, "Icon rail")], selection: sidebarOpen) { sidebarOpen = $0 }
                    .accessibilityLabel("Show sidebar")
            }
            OptionRow(title: "Width", detail: "Of the full sidebar, 180 to 320 points.") {
                HStack(spacing: 12) {
                    SettingsRuleSlider(value: $sidebarWidth, range: 180...320, label: "Sidebar width")
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(String(Int(NativeSidebarLayout.width(sidebarWidth)))).font(Theme.readout(17)).foregroundStyle(Theme.ink)
                        MicroLabel("pt")
                    }
                    .frame(width: 46, alignment: .trailing)
                }
            }
            OptionRow(title: "Readings", detail: "Counts, charge and power beside the page names.") {
                Flip(isOn: $sidebarBadges).accessibilityLabel("Show sidebar badges")
            }
            SettingsFold(title: "Pages", detail: pagesSummary, isOpen: $editing, label: "Edit sidebar") {
                VStack(alignment: .leading, spacing: 10) {
                    ledger
                    // One fixed line, so refusing a drop never moves the rows being dragged over.
                    let refused = dragged.flatMap { source in hovered.map { !validMove(source, $0) } } ?? false
                    Text(refused ? "Cannot move here. Pages stay within their section; sections move onto section headings. Fixed pages cannot move."
                                 : "Drag a handle onto a row: moving up places it before that row, moving down after. Pages stay within their section.")
                        .font(Theme.ui(11.5)).foregroundStyle(refused ? Theme.failFg : Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var pagesSummary: String {
        let pages = NativeSidebarLayout.pages(sidebarOrder)
        let hidden = pages.filter { !NativeNavigationPreferences.isSidebarVisible($0.rawValue, hiddenPages: sidebarHidden) }.count
        let sections = NativeSidebarLayout.orderedSections(sidebarOrder).count
        return "\(pages.count) pages in \(sections) sections" + (hidden == 0 ? ", all shown" : ", \(hidden) hidden")
    }

    // ---- the drag ledger ---------------------------------------------------

    private var ledger: some View {
        VStack(alignment: .leading, spacing: 0) {
            LedgerHead {
                HStack(spacing: 8) {
                    MicroLabel("Page")
                    Spacer(minLength: 8)
                    MicroLabel("Shown").fixedSize().frame(width: 48)
                    MicroLabel("Order").fixedSize().frame(width: 56)
                }
            }
            anchoredRow(.home)
            ForEach(NativeSidebarLayout.orderedSections(sidebarOrder), id: \.self) { section in
                sectionView(section)
            }
            anchoredRow(.jobs)
            anchoredRow(.settings)
        }
    }

    private func anchoredRow(_ page: NativeDestination) -> some View {
        SidebarLedgerLine {
            Color.clear.frame(width: 14)
            NativeIcon(page.symbol, size: 14, strokeWidth: 1.75).foregroundStyle(Theme.muted).frame(width: 18)
            Text(page.title).font(Theme.ui(13)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            MicroLabel("Fixed", color: Theme.faint).frame(width: 116, alignment: .center)
        }
            .overlay(alignment: .top) { dropMarker(.fixed(page)) }
            .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(dragged: $dragged, dragNonce: $dragNonce, hovered: $hovered, target: .fixed(page), move: reorder))
            .accessibilityElement(children: .combine)
    }

    private func sectionView(_ section: String) -> some View {
        let sections = NativeSidebarLayout.orderedSections(sidebarOrder)
        let pages = NativeSidebarLayout.pages(sidebarOrder).filter { $0.section == section }
        return VStack(alignment: .leading, spacing: 0) {
            SidebarLedgerLine(height: 34) {
                dragHandle(.section(section), label: "Drag \(section) section")
                MicroLabel(section, color: Theme.ink)
                Spacer(minLength: 8)
                moveButtons("\(section) section", canMoveUp: sections.first != section, canMoveDown: sections.last != section,
                            up: { moveSection(section, by: -1) }, down: { moveSection(section, by: 1) })
            }
                .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(dragged: $dragged, dragNonce: $dragNonce, hovered: $hovered, target: .section(section), move: reorder))
            ForEach(pages) { page in
                let shown = NativeNavigationPreferences.isSidebarVisible(page.rawValue, hiddenPages: sidebarHidden)
                SidebarLedgerLine {
                    dragHandle(.page(page), label: "Drag \(page.title)")
                    NativeIcon(page.symbol, size: 14, strokeWidth: 1.75).frame(width: 18).foregroundStyle(shown ? Theme.dim : Theme.faint)
                    Text(page.title).font(Theme.ui(13)).foregroundStyle(shown ? Theme.ink : Theme.muted)
                    if page == .battery && batterySupported == false { Tag("Unavailable") }
                    Spacer(minLength: 4)
                    Flip(isOn: visibility(page)).accessibilityLabel("Show \(page.title) in sidebar").frame(width: 48)
                    moveButtons(page.title, canMoveUp: pages.first != page, canMoveDown: pages.last != page,
                                up: { movePage(page, by: -1) }, down: { movePage(page, by: 1) })
                }
                    .overlay(alignment: markerAlignment(.page(page))) { dropMarker(.page(page)) }
                    .onDrop(of: [UTType.text], delegate: SidebarDropDelegate(dragged: $dragged, dragNonce: $dragNonce, hovered: $hovered, target: .page(page), move: reorder))
            }
        }.overlay(alignment: markerAlignment(.section(section))) { dropMarker(.section(section)) }
    }

    private func dragHandle(_ item: SidebarDrag, label: String) -> some View {
        NativeIcon("grip-vertical", size: 13, strokeWidth: 1.75).foregroundStyle(Theme.faint)
            .frame(width: 14, height: 26).contentShape(Rectangle())
            .help(label).accessibilityHidden(true)
            .onDrag {
                let nonce = "uniapi-sidebar-" + UUID().uuidString
                let provider = NSItemProvider(object: "UniApi sidebar" as NSString)
                provider.suggestedName = nonce
                dragged = item; dragNonce = nonce; hovered = nil
                return provider
            }
    }

    /// The pointer-free way to reorder: one press per step.
    private func moveButtons(_ name: String, canMoveUp: Bool, canMoveDown: Bool,
                             up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            IconPress(icon: "arrow-up", help: "Move \(name) up", size: 13, action: up).disabled(!canMoveUp)
            IconPress(icon: "arrow-down", help: "Move \(name) down", size: 13, action: down).disabled(!canMoveDown)
        }
        .frame(width: 56)
    }

    private func dropMarker(_ target: SidebarDrag) -> some View {
        let valid = dragged.map { validMove($0, target) } ?? false
        return Rectangle().fill(valid ? Theme.signal : Theme.failFg)
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

/// One line of the drag ledger: a ruled row whose hover fill bleeds into the
/// margins, so the eye can follow a name across to its controls.
private struct SidebarLedgerLine<Content: View>: View {
    var height: CGFloat = 30
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(hovering ? Theme.hover : .clear).padding(.horizontal, -8)
            }
            .overlay(alignment: .bottom) { Rule() }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
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
