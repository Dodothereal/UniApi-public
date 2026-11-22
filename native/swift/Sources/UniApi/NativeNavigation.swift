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
    static let railWidth = 72.0
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
    @State private var paletteOpen = false
    /// The selection plate follows the destination with its own animation;
    /// the page swap itself is never animated.
    @State private var plate = NativeShell.initialDestination
    @Namespace private var navigation
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
            ZStack(alignment: .topLeading) {
                if sidebarOpen { sidebar.frame(width: NativeSidebarLayout.width(sidebarWidth)).transition(.opacity) }
                else { rail.frame(width: NativeSidebarLayout.railWidth).transition(.opacity) }
            }
            .frame(width: sidebarOpen ? NativeSidebarLayout.width(sidebarWidth) : NativeSidebarLayout.railWidth, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Theme.sidebarBG)
            .clipped()
            Theme.sidebarBorder.frame(width: 1)
            Group {
                if session.presentation.retainsPage { NativeInstalledPages.page(destination, runtime: runtime, models: pageModels, resultsRun: resultsRun, navigate: navigate)
                    .id(destination.rawValue + ":" + String(pageReload) + ":" + String(session.presentation.generation))
                    .environment(\.nativePageVisit, visit)
                    .environment(\.nativePageActivation, session.pageActivation)
                    .environment(\.nativeMotionVisible, session.presented && session.pageActive)
                    .allowsHitTesting(session.presented && session.pageActive)
                } else { Color.clear }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The page bar and the sidebar run to the top edge of the window; the
        // window buttons sit over the sidebar's title strip.
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if paletteOpen {
                NativeCommandPalette(commands: paletteCommands) { paletteOpen = false }
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : (paletteOpen ? NativeMotion.reveal : NativeMotion.dismiss), value: paletteOpen)
        .onChange(of: destination) { _, next in
            withAnimation(reduceMotion ? nil : NativeMotion.selection) { plate = next }
        }
        .background(Theme.bg).foregroundStyle(Theme.ink)
        .overlay(alignment: .topTrailing) { NativeNoticeHost(center: notices) }
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
    private var visibleSections: [(name: String, pages: [NativeDestination])] {
        let ordered = NativeSidebarLayout.pages(sidebarOrder)
        return NativeSidebarLayout.orderedSections(sidebarOrder).compactMap { section in
            let pages = ordered.filter {
                $0.section == section
                    && NativeInstalledPages.destinations.contains($0)
                    && NativeShellPolicy.admits($0.rawValue, batterySupported: batterySupported)
                    && NativeNavigationPreferences.isSidebarVisible($0.rawValue, hiddenPages: sidebarHidden)
            }
            return pages.isEmpty ? nil : (section, pages)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The window buttons own the left of this strip.
            HStack {
                Spacer()
                T3IconButton(system: "panel-left", help: "Collapse sidebar (Command-B)", action: toggleSidebar)
            }.padding(.trailing, 8).frame(height: NativeShellMetrics.titleStrip)
            NativeJumpButton { paletteOpen = true }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    navigationRow(.home)
                    ForEach(visibleSections, id: \.name) { section in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.name.uppercased()).font(Theme.ui(10.5, weight: .semibold)).tracking(0.9)
                                .foregroundStyle(Theme.faint).padding(.horizontal, 9).padding(.bottom, 5)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(section.pages) { navigationRow($0) }
                        }
                    }
                }.padding(.horizontal, 10).padding(.bottom, 10)
            }
            VStack(spacing: 1) { navigationRow(.jobs); navigationRow(.settings) }.padding(.horizontal, 10).padding(.bottom, 10)
            Theme.sidebarBorder.frame(height: 1)
            footer
        }
    }
    private var rail: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: NativeShellMetrics.titleStrip)
            VStack(spacing: 2) {
                railButton("panel-left", help: "Expand sidebar (Command-B)", action: toggleSidebar)
                railButton("search", help: "Jump to (Command-K)") { paletteOpen = true }
            }.padding(.top, 6).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 10) {
                    railRow(.home)
                    ForEach(visibleSections, id: \.name) { section in
                        VStack(spacing: 2) { ForEach(section.pages) { railRow($0) } }
                            .padding(.top, 10)
                            .overlay(alignment: .top) { Theme.sidebarBorder.frame(width: 20, height: 1) }
                    }
                }.frame(maxWidth: .infinity).padding(.bottom, 10)
            }.scrollIndicators(.hidden)
            VStack(spacing: 2) {
                railRow(.jobs); railRow(.settings)
                let shim = NativeShellPolicy.shim(routeStatus)
                if shim.state == .down || session.error != nil {
                    NativeIcon("triangle-alert", size: 15).foregroundStyle(Theme.failFg).frame(width: 36, height: 30)
                        .help(session.error.map { "Startup failed: " + $0 } ?? shim.text)
                }
            }.padding(.bottom, 12)
        }
    }
    private func railButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        NativeIcon(symbol, size: 16).frame(width: 36, height: 32)
            .foregroundStyle(Theme.sidebarMuted)
            .nativeSidebarRow(selected: false, namespace: navigation, action: action)
            .help(help).accessibilityLabel(help)
    }
    private func railRow(_ page: NativeDestination) -> some View {
        Group {
            if page == .fans {
                NativeSpinningFan(rpm: fansSpinning ? 1250 : 0, size: 16).nativeMotionVisibility(initiallyVisible: false).frame(width: 16, height: 16)
            } else { NativeIcon(page.symbol, size: 16) }
        }
        .frame(width: 36, height: 32)
        .foregroundStyle(plate == page ? Theme.sidebarInk : Theme.sidebarMuted)
        .overlay(alignment: .topTrailing) {
            if sidebarBadges, !badge(page).isEmpty { Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(x: -5, y: 5) }
        }
        .nativeSidebarRow(selected: plate == page, namespace: navigation) {
            if page == .results { resultsRun = nil }; navigate(page)
        }
        .help(badge(page).isEmpty ? page.title : page.title + " · " + badge(page))
        .accessibilityLabel(page.title)
    }
    /// The route new Claude Code sessions take: the one fact every page depends on.
    private var footer: some View {
        let shim = NativeShellPolicy.shim(routeStatus)
        let route = NativeShellPolicy.route(routeStatus)
        return VStack(alignment: .leading, spacing: 8) {
            NativeUpdateSidebarButton(model: session.updates)
            NativeRouteButton(name: route.name, model: route.model,
                              warning: shim.state == .down ? shim.text : shim.state == .legacy ? shim.text : "",
                              failing: shim.state == .down) { navigate(.switcher) }
            if let error = session.error {
                Text("Startup failed: " + error).font(Theme.ui(11)).foregroundStyle(Theme.failFg).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 9)
            }
        }.padding(10)
    }
    private func badge(_ page: NativeDestination) -> String {
        if page == .jobs { return activeJobs > 0 ? String(activeJobs) : "" }
        if [.code, .arena].contains(page) { return badges[page.rawValue].int > 0 ? badges[page.rawValue].string : "" }
        if page == .battery { return badges["battery"].isNull ? "" : badges["battery"].string + "%" }
        if page == .energy { return badges["energy"].isNull ? "" : badges["energy"].string }
        return ""
    }
    private func navigationRow(_ page: NativeDestination) -> some View {
        HStack(spacing: 9) {
            if page == .fans {
                NativeSpinningFan(rpm: fansSpinning ? 1250 : 0, size: 15).nativeMotionVisibility(initiallyVisible: false).frame(width: 15, height: 15)
            } else { NativeIcon(page.symbol, size: 15) }
            Text(page.title).font(Theme.ui(Theme.textSm, weight: plate == page ? .medium : .regular)).lineLimit(1)
            Spacer(minLength: 4)
            if sidebarBadges, !badge(page).isEmpty {
                Text(badge(page)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }.padding(.horizontal, 9).frame(height: 30)
            .foregroundStyle(plate == page ? Theme.sidebarInk : Theme.sidebarMuted)
            .nativeSidebarRow(selected: plate == page, namespace: navigation) {
                if page == .results { resultsRun = nil }; navigate(page)
            }
    }
    private var paletteCommands: [NativeCommand] {
        let pages = [NativeDestination.home] + visibleSections.flatMap(\.pages) + [.jobs, .settings]
        var commands = pages.map { page in
            NativeCommand(id: "page." + page.rawValue, title: page.title, group: page.section.isEmpty ? "Go to" : page.section, symbol: page.symbol,
                          current: page == destination) { if page == .results { resultsRun = nil }; navigate(page) }
        }
        commands.append(NativeCommand(id: "reload", title: "Reload this page", group: "Window", symbol: "refresh-cw", hint: "\u{2318}R") {
            NotificationCenter.default.post(name: .nativePageReload, object: nil)
        })
        commands.append(NativeCommand(id: "sidebar", title: sidebarOpen ? "Collapse sidebar" : "Expand sidebar", group: "Window", symbol: "panel-left", hint: "\u{2318}B", action: toggleSidebar))
        for (value, title, symbol) in [("light", "Light appearance", "sun"), ("dark", "Dark appearance", "moon"), ("auto", "Match macOS appearance", "monitor")] where value != appearance {
            commands.append(NativeCommand(id: "appearance." + value, title: title, group: "Window", symbol: symbol) { appearance = value })
        }
        return commands
    }
    private func navigate(_ page: NativeDestination) {
        guard NativeShellPolicy.admits(page.rawValue, batterySupported: batterySupported) else { return }
        if page != destination { NativePagePanels.shared.invalidatePresentation(); visit = NativeUIReadiness.shared.begin(page) }
        // Only local selection/entrance effects animate, never the complete new chart tree.
        NativeMotion.withoutAnimation { destination = page }
        UserDefaults.standard.set(page.rawValue, forKey: "uniapi-native-page")
    }
    private func toggleSidebar() {
        withAnimation(reduceMotion ? nil : NativeMotion.sidebar) { sidebarOpen.toggle() }
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

enum NativeShellMetrics {
    /// Height of the strip the window buttons sit in.
    static let titleStrip: CGFloat = 30
}

/// Opens the command palette. Reads as a field because typing is what follows.
private struct NativeJumpButton: View {
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                NativeIcon("search", size: 13).foregroundStyle(Theme.faint)
                Text("Jump to").font(Theme.ui(Theme.textXs + 0.5)).foregroundStyle(hovering ? Theme.dim : Theme.muted)
                Spacer(minLength: 4)
                NativeKbd("\u{2318}K")
            }
            .padding(.leading, 9).padding(.trailing, 6).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(hovering ? Theme.sidebarAccent : Theme.subtle))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(hovering ? Theme.input : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(NativePressStyle(scale: 0.985)).pointingHand().onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityLabel("Jump to a page or command").help("Jump to a page or command (Command-K)")
    }
}

/// Sidebar footer: where new Claude Code sessions go, and the way to change it.
private struct NativeRouteButton: View {
    let name: String
    let model: String
    let warning: String
    let failing: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                NativeIcon(warning.isEmpty ? "route" : "triangle-alert", size: 15)
                    .foregroundStyle(warning.isEmpty ? Theme.sidebarMuted : failing ? Theme.failFg : Theme.warnFg)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.sidebarInk)
                        .lineLimit(1).truncationMode(.middle)
                    Text(warning.isEmpty ? model : warning).font(warning.isEmpty ? Theme.mono(10.5) : Theme.ui(11))
                        .foregroundStyle(warning.isEmpty ? Theme.sidebarMuted : failing ? Theme.failFg : Theme.warnFg)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                NativeIcon("arrow-up-right", size: 12).foregroundStyle(Theme.sidebarMuted)
                    .opacity(hovering ? 1 : 0).offset(x: hovering ? 0 : -3, y: hovering ? 0 : 3)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(hovering ? Theme.subtle : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(NativePressStyle(scale: 0.985)).pointingHand().onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityLabel("Claude Code route: " + name + (warning.isEmpty ? "" : ". " + warning))
        .help("Claude Code route. Opens Switcher.")
    }
}

extension Notification.Name {
    static let nativePageReload = Notification.Name("UniApi.NativePageReload")
    static let nativeSidebarToggle = Notification.Name("UniApi.NativeSidebarToggle")
}
