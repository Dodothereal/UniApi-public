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
    case home, speed, results, prompts, arena, switcher, code, stats, activity, fans, battery, transcribe, jobs, settings
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
        case .activity, .fans, .battery: return "Mac"
        case .transcribe: return "Media"
        }
    }
}

/// Registration is kept explicit so a page is admitted only with its native
/// implementation; the acceptance manifest tracks the remaining destinations.
enum NativeInstalledPages {
    static let destinations: Set<NativeDestination> = [.home, .speed, .results, .switcher, .code, .arena, .prompts, .stats, .transcribe, .activity, .battery, .fans, .jobs, .settings]
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
            if sidebarOpen { Theme.sidebarBorder.frame(width: 1) }
            VStack(alignment: .leading, spacing: 0) {
                if !sidebarOpen {
                    HStack(spacing: 7) {
                        UniApiWordmark(markSize: 18, textSize: 13)
                        Button(action: toggleSidebar) { NativeIcon("panel-left", size: 15) }
                            .buttonStyle(.plain).help("Toggle sidebar (Command-B)")
                        Spacer()
                    }.padding(.horizontal, 16).frame(height: 40)
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
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                UniApiWordmark(markSize: 18, textSize: 13); Spacer()
                Button(action: toggleSidebar) { NativeIcon("panel-left", size: 15) }
                    .buttonStyle(.plain).foregroundStyle(Theme.muted).help("Toggle sidebar (Command-B)")
            }.frame(height: 40).padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    navigationRow(.home)
                    ForEach(NativeSidebarLayout.orderedSections(sidebarOrder), id: \.self) { section in
                        let pages = NativeSidebarLayout.pages(sidebarOrder).filter {
                            $0.section == section
                                && NativeInstalledPages.destinations.contains($0)
                                && NativeShellPolicy.admits($0.rawValue, batterySupported: batterySupported)
                                && NativeNavigationPreferences.isSidebarVisible($0.rawValue, hiddenPages: sidebarHidden)
                        }
                        if !pages.isEmpty {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.uppercased()).font(Theme.ui(10.5, weight: .medium)).tracking(0.84).foregroundStyle(Theme.muted).padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 4)
                                ForEach(pages) { navigationRow($0) }
                            }
                        }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 8)
            }
            VStack(spacing: 1) { navigationRow(.jobs); navigationRow(.settings) }.padding(.horizontal, 8).padding(.vertical, 8)
            Divider().padding(.horizontal, 10)
            footer.padding(.horizontal, 14).padding(.bottom, 14)
        }.background(Theme.sidebarBG)
    }
    private var footer: some View {
        let shim = NativeShellPolicy.shim(routeStatus)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                NativeStatusDot(color: shim.state == .up ? Theme.okFg : shim.state == .down ? Theme.failFg : shim.state == .legacy ? Theme.warnFg : Theme.muted)
                Text(shim.text).font(Theme.ui(11)).foregroundStyle(shim.state == .down ? Theme.failFg : Theme.muted)
            }
            Text("Claude Code: " + NativeShellPolicy.route(routeStatus).name).font(Theme.ui(11)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
            if let error = session.error { Text("Startup failed: " + error).font(Theme.ui(10)).foregroundStyle(Theme.failFg).textSelection(.enabled) }
        }
    }
    private func navigationRow(_ page: NativeDestination) -> some View {
            HStack(spacing: 9) {
                if page == .fans {
                    NativeSpinningFan(rpm: fansSpinning ? 1250 : 0, size: 15).nativeMotionVisibility(initiallyVisible: false).frame(width: 15, height: 15)
                } else { NativeIcon(page.symbol, size: 15, strokeWidth: 1.75) }
                Text(page.title).font(Theme.ui(13, weight: destination == page ? .medium : .regular))
                Spacer()
                if sidebarBadges {
                    if page == .jobs && activeJobs > 0 { Text(String(activeJobs)).font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                    if [.code, .arena].contains(page), badges[page.rawValue].int > 0 { Text(badges[page.rawValue].string).font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                    if page == .battery, !badges["battery"].isNull { Text(badges["battery"].string + "%").font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                }
            }.padding(.horizontal, 8).frame(height: 32)
                .foregroundStyle(destination == page ? Theme.sidebarInk : Theme.sidebarMuted)
            .nativeSidebarRow(selected: destination == page) {
                if page == .results { resultsRun = nil }; navigate(page)
            }
    }
    private func navigate(_ page: NativeDestination) {
        guard NativeShellPolicy.admits(page.rawValue, batterySupported: batterySupported) else { return }
        if page != destination { NativePagePanels.shared.invalidatePresentation(); visit = NativeUIReadiness.shared.begin(page) }
        // Only local selection/entrance effects animate, never the complete new chart tree.
        NativeMotion.withoutAnimation { destination = page }
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
