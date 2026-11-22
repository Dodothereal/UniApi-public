import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

private struct NativeBatterySupportKey: EnvironmentKey {
    static let defaultValue: JSONValue = .null
}
extension EnvironmentValues {
    var nativeBatterySupported: JSONValue {
        get { self[NativeBatterySupportKey.self] }
        set { self[NativeBatterySupportKey.self] = newValue }
    }
}

enum NativeDestination: String, CaseIterable, Identifiable {
    case home, speed, results, prompts, arena, switcher, code, stats, activity, fans, battery, energy, keyboard, transcribe, jobs, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: return "Home"
        case .speed: return "Speed"
        case .results: return "Results"
        case .prompts: return "Prompts"
        case .arena: return "Arena"
        case .switcher: return "Switcher"
        case .code: return "Code"
        case .stats: return "Statistics"
        case .activity: return "Activity"
        case .fans: return "Fan Control"
        case .battery: return "Battery"
        case .energy: return "Energy"
        case .keyboard: return "Keyboard Stats"
        case .transcribe: return "Transcribe"
        case .jobs: return "Jobs"
        case .settings: return "Settings"
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .speed: return "gauge"
        case .results: return "chart-bar"
        case .prompts: return "file-text"
        case .arena: return "swords"
        case .switcher: return "route"
        case .code: return "bot"
        case .stats: return "chart-line"
        case .activity: return "activity"
        case .fans: return "fan"
        case .battery: return "battery-charging"
        case .energy: return "zap"
        case .keyboard: return "keyboard"
        case .transcribe: return "mic"
        case .jobs: return "list-checks"
        case .settings: return "settings"
        }
    }
    var section: String {
        switch self {
        case .home, .jobs, .settings: return ""
        case .speed, .results, .prompts, .arena: return "Benchmark"
        case .switcher, .code, .stats: return "Coding"
        case .activity, .fans, .battery, .energy, .keyboard: return "Mac"
        case .transcribe: return "Media"
        }
    }
}

/// Registration is kept explicit so a page is admitted only with its native
/// implementation; the acceptance manifest tracks the remaining destinations.
enum NativeInstalledPages {
    static let destinations: Set<NativeDestination> = [.home, .speed, .results, .switcher, .code, .arena, .prompts, .stats, .transcribe, .activity, .battery, .fans, .energy, .keyboard, .jobs, .settings]
    @MainActor @ViewBuilder static func page(_ destination: NativeDestination, runtime: NativeRuntime, models: NativePageModels? = nil, resultsRun: String? = nil, navigate: @escaping (NativeDestination) -> Void) -> some View {
        switch destination {
        case .home: NativeHomePage(runtime: runtime, navigate: navigate)
        case .jobs: NativeJobsPage(runtime: runtime)
        case .settings: NativeSettingsPage(runtime: runtime)
        case .prompts: NativePromptsPage(runtime: runtime)
        case .stats: NativeStatsPage(runtime: runtime, model: models?.statistics)
        case .transcribe: NativeTranscribePage(runtime: runtime)
        case .activity: NativeActivityPage(runtime: runtime)
        case .battery: NativeBatteryPage(runtime: runtime)
        case .fans: NativeFansPage(runtime: runtime)
        case .energy: NativeEnergyPage(runtime: runtime)
        case .keyboard: NativeKeyboardPage(runtime: runtime)
        case .speed: NativeSpeedPage(runtime: runtime, model: models?.speed)
        case .results: NativeResultsPage(runtime: runtime, initialRun: resultsRun)
        case .code: NativeCodePage(runtime: runtime)
        case .arena: NativeArenaPage(runtime: runtime)
        case .switcher: NativeSwitcherPage(runtime: runtime)
        }
    }
}

/// Sidebar layout resets do not change appearance, sidebar open state, density or motion.
enum NativeSidebarLayout {
    static let defaultWidth = 216.0
    static func width(_ value: Double) -> Double { value.isFinite ? min(320, max(180, value)) : defaultWidth }
    static func pages(_ stored: String) -> [NativeDestination] {
        var result: [NativeDestination] = []
        for key in stored.split(separator: ",") {
            if let page = NativeDestination(rawValue: String(key)), !page.section.isEmpty, !result.contains(page) { result.append(page) }
        }
        return result + NativeDestination.allCases.filter { !$0.section.isEmpty && !result.contains($0) }
    }
    static func orderedSections(_ stored: String) -> [String] {
        var result: [String] = []
        for page in pages(stored) where !result.contains(page.section) { result.append(page.section) }
        return result
    }
}

struct NativeShell: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var destination = NativeShell.initialDestination
    @AppStorage("uniapi-sidebar") private var sidebarOpen = true
    @AppStorage("uniapi-sidebar-width") private var sidebarWidth = NativeSidebarLayout.defaultWidth
    @AppStorage("uniapi-sidebar-order") private var sidebarOrder = ""
    @AppStorage("uniapi-sidebar-hidden") private var sidebarHidden = ""
    @AppStorage("uniapi-sidebar-badges") private var sidebarBadges = NativeNavigationPreferences.defaultSidebarBadges
    @AppStorage("uniapi-theme") private var appearance = "auto"
    @AppStorage("uniapi-density") private var density = "standard"
    @AppStorage("uniapi-motion") private var motion = "system"
    @State private var activeJobs = 0
    @State private var fansSpinning = false
    @State private var badges: JSONValue = [:]
    @State private var routeStatus: JSONValue = .null
    @State private var batterySupported: JSONValue = .null
    @State private var resultsRun: String?
    @State private var visit: NativePageVisit?
    @State private var pageReload: UInt64 = 0
    @State private var reads = NativePageReadScope()
    @State private var workOwner = NativePageWorkOwner()
    @State private var subscribed = false
    @State private var marker = NativeShell.initialDestination
    @State private var paletteOpen = false
    @Namespace private var selectionSpace
    @StateObject private var notices = NativeNoticeCenter()
    @StateObject private var pageModels: NativePageModels
    init(runtime: NativeRuntime) { self.runtime = runtime; _pageModels = StateObject(wrappedValue: NativePageModels(runtime: runtime)) }
    private static var initialDestination: NativeDestination {
        let env = ProcessInfo.processInfo.environment
        let readOnly = env["UNIAPI_NATIVE_READ_ONLY"] == "1" || CommandLine.arguments.contains("--read-only") || Bundle.main.object(forInfoDictionaryKey: "UniApiReadOnlyPreview") as? Bool == true
        let defaults = UserDefaults.standard
        let preview = readOnly ? env["UNIAPI_NATIVE_UI_PAGE"] ?? Bundle.main.object(forInfoDictionaryKey: "UniApiUIProfilePage") as? String : nil
        let restore = defaults.object(forKey: NativeNavigationPreferences.restoreLastPageKey) as? Bool ?? NativeNavigationPreferences.defaultRestoreLastPage
        let installed = NativeInstalledPages.destinations.map(\.rawValue)
        let page = NativeNavigationPreferences.initialPage(
            startPage: defaults.string(forKey: NativeNavigationPreferences.startPageKey),
            lastVisited: defaults.string(forKey: "uniapi-native-page"),
            restoreLastPage: restore,
            previewPage: preview,
            installedPages: installed
        )
        return NativeDestination(rawValue: page.rawValue) ?? .home
    }
    private var scheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    private var reduceMotion: Bool { systemReduceMotion || motion == "reduced" }
    private var pageActive: Bool { session.presented && session.pageActive }
    private struct ShellWork: Equatable { var activation: NativePageActivation; var subscribed: Bool }
    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: NativeSidebarLayout.width(sidebarWidth))
                .frame(width: sidebarOpen ? NativeSidebarLayout.width(sidebarWidth) : 0, alignment: .leading)
                .clipped().opacity(sidebarOpen ? 1 : 0)
            VStack(alignment: .leading, spacing: 0) {
                if !sidebarOpen {
                    HStack(spacing: 4) {
                        NativeChromeButton(icon: "panel-left", help: "Show sidebar (Command-B)", action: toggleSidebar)
                        NativeChromeButton(icon: "search", help: "Jump to (Command-K)") { paletteOpen = true }
                        Spacer()
                    }.padding(.leading, 78).frame(height: 30)
                }
                if session.presentation.retainsPage { NativeInstalledPages.page(destination, runtime: runtime, models: pageModels, resultsRun: resultsRun, navigate: navigate)
                    .id(destination.rawValue + ":" + String(pageReload) + ":" + String(session.presentation.generation))
                    .environment(\.nativePageVisit, visit)
                    .environment(\.nativePageActivation, session.pageActivation)
                    .environment(\.nativeMotionVisible, session.presented && session.pageActive)
                    .allowsHitTesting(session.presented && session.pageActive)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { Color.clear }
            }
        }
        .background(Theme.bg).foregroundStyle(Theme.ink)
        .overlay(alignment: .topTrailing) { NativeNoticeHost(center: notices) }
        .overlay {
            if paletteOpen {
                NativeJumpPalette(pages: reachablePages, current: destination, reduceMotion: reduceMotion,
                                  choose: { page in paletteOpen = false; if page == .results { resultsRun = nil }; navigate(page) },
                                  dismiss: { paletteOpen = false })
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: paletteOpen)
        .preferredColorScheme(scheme)
        .environment(\.nativeInterfaceDensity, NativeInterfaceDensity(rawValue: density) ?? .standard)
        .environment(\.nativeReducedMotion, reduceMotion)
        .environment(\.nativeBatterySupported, batterySupported)
        .environment(\.nativeMotionVisible, session.presented && session.pageActive)
        .onAppear { visit = NativeUIReadiness.shared.begin(destination) }
        .onChange(of: session.presentation.generation) { _, _ in pageModels.discard() }
        .task(id: pageActive, priority: .utility) {
            guard pageActive, destination != .stats else { return }
            await pageModels.prefetchStatistics()
        }
        .onChange(of: session.pageActivation, initial: true) { _, next in
            _ = workOwner.synchronize(next, reads: reads, suspended: {})
        }
        .onChange(of: session.error, initial: true) { _, message in
            if let message { notices.push(message, kind: .error) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeNotice)) { event in
            guard let text = event.object as? String else { return }
            notices.push(text, kind: NativeNoticeKind(rawValue: event.userInfo?["kind"] as? String ?? "info") ?? .info)
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeNavigation)) { event in
            if let page = event.object as? NativeDestination { navigate(page) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativePageReload)) { _ in
            // A deliberate page reload starts a fresh view lifetime, while
            // shared services and their background jobs keep their ownership.
            NativePagePanels.shared.invalidatePresentation()
            visit = NativeUIReadiness.shared.begin(destination)
            pageModels.statistics.invalidateSnapshots()
            pageReload &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeSidebarToggle)) { _ in toggleSidebar() }
        .onReceive(NotificationCenter.default.publisher(for: .nativeResultsScope)) { event in
            if let id = event.object as? String { resultsRun = id; navigate(.results) }
        }
        // AppKit owns the normal window minimum. System tiling can supply a
        // narrower viewport; a second SwiftUI minimum would crop both edges.
        .frame(minWidth: 0, idealWidth: 1150, maxWidth: .infinity, minHeight: 0, idealHeight: 840, maxHeight: .infinity, alignment: .topLeading)
        .background {
            Button("Toggle sidebar", action: toggleSidebar).keyboardShortcut("b", modifiers: .command).hidden().accessibilityHidden(true)
            Button("Jump to") { paletteOpen.toggle() }.keyboardShortcut("k", modifiers: .command).hidden().accessibilityHidden(true)
        }
        .task {
            // Register before initial reads so a badge edge cannot land in the gap.
            let events = await runtime.events.stream()
            guard !Task.isCancelled else { return }
            subscribed = true
            if !NativeInstalledPages.destinations.contains(destination) { destination = .home }
            for await event in events {
                if Task.isCancelled { break }
                if event.topic == "runtime.error" { notices.push(event.data.string, kind: .error) }
                if event.topic == "notify.error" { notices.push("Telegram notification delivery failed. Check the local notification configuration.", kind: .error) }
                if event.topic == "stats.scanned" { pageModels.statistics.invalidateSnapshots() }
                guard pageActive else { continue }
                if event.topic == "job.updated" { await refreshBadges() }
                if event.topic.hasPrefix("code.permission") || ["code.thread", "code.thread.deleted", "code.projects", "arena.match", "arena.match.deleted"].contains(event.topic) { await refreshBadges() }
                if event.topic == "switcher.changed" { await refreshFooter() }
                if event.topic == "battery.state" {
                    updateBatteryCapability(event.data)
                    badges["battery"] = event.data["supported"].bool ? event.data["hold"]["active"].bool ? event.data["hold"]["target"] : event.data["phase"].string == "off" ? .null : event.data["limit"] : .null
                }
                if event.topic == "fans.spin" { fansSpinning = event.data["spinning"].bool }
                if event.topic == "fans.state" { fansSpinning = event.data["snapshot"]["fans"].array.contains { $0["actual"].double > 0 } }
                if event.topic == "energy.state" {
                    let badge = NativeHardwareDisplayPolicies.energyBadgeText(event.data)
                    badges["energy"] = badge.isEmpty ? .null : .string(badge)
                }
            }
        }.task(id: ShellWork(activation: session.pageActivation, subscribed: subscribed)) {
            guard pageActive, subscribed else { return }
            guard workOwner.synchronize(session.pageActivation, reads: reads, suspended: {}) else { return }
            await refreshFooter()
            await refreshBadges()
            if let fans = session.fans, let ticket = reads.begin("fan-summary"),
               let value = try? await fans.handle("summary"), reads.accepts(ticket) { fansSpinning = value["spinning"].bool }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000); try Task.checkCancellation() }
                catch { return }
                await refreshFooter()
                await refreshBadges()
            }
        }
    }
    private func admitted(_ page: NativeDestination) -> Bool {
        NativeInstalledPages.destinations.contains(page) && NativeShellPolicy.admits(page.rawValue, batterySupported: batterySupported)
    }
    /// Every page that can be opened, in sidebar order. Pages hidden from the
    /// sidebar stay reachable from the jump palette.
    private var reachablePages: [NativeDestination] {
        [.home] + NativeSidebarLayout.pages(sidebarOrder).filter(admitted) + [.jobs, .settings]
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                Spacer()
                NativeChromeButton(icon: "search", help: "Jump to (Command-K)") { paletteOpen = true }
                NativeChromeButton(icon: "panel-left", help: "Hide sidebar (Command-B)", action: toggleSidebar)
            }.frame(height: 30).padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    navigationRow(.home)
                    ForEach(NativeSidebarLayout.orderedSections(sidebarOrder), id: \.self) { section in
                        let pages = NativeSidebarLayout.pages(sidebarOrder).filter {
                            $0.section == section && admitted($0)
                                && NativeNavigationPreferences.isSidebarVisible($0.rawValue, hiddenPages: sidebarHidden)
                        }
                        if !pages.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.sidebarMuted.opacity(0.75))
                                    .padding(.horizontal, 10).padding(.bottom, 5).accessibilityAddTraits(.isHeader)
                                ForEach(pages) { navigationRow($0) }
                            }
                        }
                    }
                }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 10)
            }
            VStack(spacing: 1) { navigationRow(.jobs); navigationRow(.settings) }.padding(.horizontal, 8).padding(.bottom, 8)
            footer.padding(.horizontal, 18).padding(.bottom, 14)
        }.background(Theme.sidebarBG)
    }
    private var footer: some View {
        let shim = NativeShellPolicy.shim(routeStatus)
        let healthy = shim.state == .up
        let dot: Color = switch shim.state {
        case .up: Theme.okFg
        case .down: Theme.failFg
        case .legacy: Theme.warnFg
        default: Theme.muted
        }
        let routeName: String = NativeShellPolicy.route(routeStatus).name
        let label: String = healthy ? routeName : shim.text
        let labelColor: Color = shim.state == .down ? Theme.failFg : Theme.sidebarMuted
        return VStack(alignment: .leading, spacing: 6) {
            NativeUpdateSidebarButton(model: session.updates)
            Button { navigate(.switcher) } label: {
                HStack(spacing: 7) {
                    NativeStatusDot(color: dot)
                    Text(label).font(Theme.ui(11.5)).foregroundStyle(labelColor)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHand()
                .help("Claude Code route: \(routeName). \(shim.text)")
                .accessibilityLabel("Claude Code route \(routeName), \(shim.text)")
            if let error = session.error { Text("Startup failed: " + error).font(Theme.ui(10.5)).foregroundStyle(Theme.failFg).textSelection(.enabled) }
        }
    }
    private func badge(_ page: NativeDestination) -> String {
        guard sidebarBadges else { return "" }
        if page == .jobs { return activeJobs > 0 ? String(activeJobs) : "" }
        if [.code, .arena].contains(page) { return badges[page.rawValue].int > 0 ? badges[page.rawValue].string : "" }
        if page == .battery { return badges["battery"].isNull ? "" : badges["battery"].string + "%" }
        if page == .energy { return badges["energy"].isNull ? "" : badges["energy"].string }
        return ""
    }
    private func navigationRow(_ page: NativeDestination) -> some View {
        let selected = marker == page
        return NativeSidebarRow(selected: selected, space: selectionSpace) {
            if page == .results { resultsRun = nil }; navigate(page)
        } label: {
            HStack(spacing: 10) {
                if page == .fans {
                    NativeSpinningFan(rpm: fansSpinning ? 1250 : 0, size: 15).nativeMotionVisibility(initiallyVisible: false).frame(width: 15, height: 15)
                } else { NativeIcon(page.symbol, size: 15, strokeWidth: 1.6) }
                Text(page.title).font(Theme.ui(13, weight: selected ? .medium : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                Text(badge(page)).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.sidebarMuted).lineLimit(1)
            }
            .padding(.horizontal, 10).frame(height: 30)
            .foregroundStyle(selected ? Theme.sidebarInk : Theme.sidebarMuted)
        }
    }
    private func navigate(_ page: NativeDestination) {
        guard NativeShellPolicy.admits(page.rawValue, batterySupported: batterySupported) else { return }
        if page != destination { NativePagePanels.shared.invalidatePresentation(); visit = NativeUIReadiness.shared.begin(page) }
        // Only local selection/entrance effects animate, never the complete new chart tree.
        NativeMotion.withoutAnimation { destination = page }
        withAnimation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.12)) { marker = page }
        UserDefaults.standard.set(page.rawValue, forKey: "uniapi-native-page")
    }
    private func toggleSidebar() {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.34, bounce: 0.08)) { sidebarOpen.toggle() }
        UserDefaults.standard.set(sidebarOpen, forKey: "uniapi-sidebar")
    }
    private func refreshBadges() async {
        guard let ticket = reads.begin("badges") else { return }
        if let summaries = session.summaries {
            let value = await summaries.badges()
            guard reads.accepts(ticket) else { return }
            for (key, data) in value.object { badges[key] = data }; activeJobs = value["jobs"].int
        }
        if let battery = session.battery, let value = try? await battery.handle("status") {
            guard reads.accepts(ticket) else { return }
            updateBatteryCapability(value)
            badges["battery"] = value["supported"].bool ? value["hold"]["active"].bool ? value["hold"]["target"] : value["phase"].string == "off" ? .null : value["limit"] : .null
        }
        if let energy = session.energy, let value = try? await energy.handle("summary") {
            guard reads.accepts(ticket) else { return }
            let badge = value["badge"].string
            badges["energy"] = badge.isEmpty ? .null : .string(badge)
        }
    }
    private func updateBatteryCapability(_ value: JSONValue) {
        guard value["error"].isNull, case .bool = value["supported"] else { return }
        batterySupported = value["supported"]
        if !NativeShellPolicy.admits(destination.rawValue, batterySupported: batterySupported) { navigate(.home) }
    }
    private func refreshFooter() async {
        guard let ticket = reads.begin("footer") else { return }
        do {
            let value = try await NativeSwitcherService.shared(runtime: runtime).handle("status")
            guard reads.accepts(ticket) else { return }
            routeStatus = value
        } catch {
            if reads.accepts(ticket) { routeStatus = ["error": .string(error.localizedDescription)] }
        }
    }
}

extension Notification.Name {
    static let nativePageReload = Notification.Name("UniApi.NativePageReload")
    static let nativeSidebarToggle = Notification.Name("UniApi.NativeSidebarToggle")
}

/// Window-chrome icon button: sidebar toggle and jump.
struct NativeChromeButton: View {
    var icon: String
    var help: String
    var action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            NativeIcon(icon, size: 15, strokeWidth: 1.6)
                .foregroundStyle(hovering ? Theme.ink : Theme.muted)
                .frame(width: 26, height: 24)
                .background(hovering ? Theme.subtle2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }.help(help).accessibilityLabel(help)
    }
}

/// The selection is one surface that travels between rows, so the eye is led
/// to the new page instead of two rows blinking.
private struct NativeSidebarRow<Label: View>: View {
    let selected: Bool
    let space: Namespace.ID
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            label()
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(Theme.sidebarAccent)
                            .matchedGeometryEffect(id: "sidebar-selection", in: space)
                    } else if hovering {
                        RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(Theme.subtle)
                    }
                }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand()
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Command-K: type a few letters, press Return. Reaches every page, including
/// ones hidden from the sidebar.
private struct NativeJumpPalette: View {
    let pages: [NativeDestination]
    let current: NativeDestination
    let reduceMotion: Bool
    let choose: (NativeDestination) -> Void
    let dismiss: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool
    private var matches: [NativeDestination] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return pages }
        let scored = pages.compactMap { page -> (NativeDestination, Int)? in
            let title = page.title.lowercased(), group = page.section.lowercased()
            if title.hasPrefix(needle) { return (page, 0) }
            if title.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return (page, 1) }
            if title.contains(needle) { return (page, 2) }
            if group.hasPrefix(needle) { return (page, 3) }
            var cursor = title.startIndex
            for character in needle {
                guard let found = title[cursor...].firstIndex(of: character) else { return nil }
                cursor = title.index(after: found)
            }
            return (page, 4)
        }
        return scored.enumerated().sorted { $0.element.1 == $1.element.1 ? $0.offset < $1.offset : $0.element.1 < $1.element.1 }.map(\.element.0)
    }
    var body: some View {
        let results = matches
        ZStack(alignment: .top) {
            Theme.overlay.ignoresSafeArea().onTapGesture(perform: dismiss).accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    NativeIcon("search", size: 15, strokeWidth: 1.6).foregroundStyle(Theme.muted)
                    TextField("Jump to", text: $query).textFieldStyle(.plain).font(Theme.ui(15)).focused($focused)
                        .onSubmit { if results.indices.contains(index) { choose(results[index]) } }
                    NativeKeyHint(text: "esc")
                }.padding(.horizontal, 16).frame(height: 48)
                NativeRule()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element) { offset, page in
                                Button { choose(page) } label: {
                                    HStack(spacing: 11) {
                                        NativeIcon(page.symbol, size: 15, strokeWidth: 1.6).foregroundStyle(offset == index ? Theme.ink : Theme.muted)
                                        Text(page.title).font(Theme.ui(13, weight: offset == index ? .medium : .regular))
                                        Spacer()
                                        if page == current { Text("Open").font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
                                        else if !page.section.isEmpty { Text(page.section).font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
                                    }
                                    .padding(.horizontal, 10).frame(height: 34)
                                    .background(offset == index ? Theme.subtle2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).id(page).onHover { if $0 { index = offset } }
                            }
                            if results.isEmpty {
                                Text("No page matches").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 34)
                            }
                        }.padding(6)
                    }
                    .frame(maxHeight: 340).fixedSize(horizontal: false, vertical: true)
                    .onChange(of: index) { _, next in if results.indices.contains(next) { proxy.scrollTo(results[next]) } }
                }
            }
            .frame(width: 460)
            .background(Theme.popover, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: Theme.shadow, radius: 30, y: 14)
            .padding(.top, 110)
            .transition(reduceMotion ? .identity : .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
        }
        .foregroundStyle(Theme.ink)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
        .onKeyPress(.downArrow) { index = min(max(0, results.count - 1), index + 1); return .handled }
        .onKeyPress(.upArrow) { index = max(0, index - 1); return .handled }
        .onExitCommand(perform: dismiss)
        .accessibilityAddTraits(.isModal)
    }
}
