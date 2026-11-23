import AppKit
import SwiftUI
import UniApiCore
import UniApiPresentation

// Page illustrations only: the runner supplies exact copied production UI and
// one capture-only session initializer. Never call NativeEntry.main(), the
// default NativeAppSession initializer, or NativeAppDelegate here.
private final class PublicCapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ rect: NSRect, to screen: NSScreen?) -> NSRect { rect }
}

// Inserted only into the temporary copies used by the Settings detail matrix.
// The marker is transparent and participates only in locating a real section
// in the production page's existing scroll view.
struct PublicCaptureAnchor: NSViewRepresentable {
    let name: String
    init(_ name: String) { self.name = name }
    func makeNSView(context: Context) -> PublicCaptureAnchorView {
        let view = PublicCaptureAnchorView()
        view.anchorName = name
        return view
    }
    func updateNSView(_ view: PublicCaptureAnchorView, context: Context) { view.anchorName = name }
}

private enum PublicArenaCapture {
    static let screens = ["arena-home": "Home", "arena-empty": "Home", "arena-live": "Watch",
                          "arena-duel": "Match", "arena-revealed": "Match", "arena-history": "History",
                          "arena-ranking": "Ranking", "arena-presets": "Presets"]
    static let matches = ["arena-duel": "fixture-match-0", "arena-live": "fixture-match-1", "arena-revealed": "fixture-match-4"]
    static let task = "Design a keyboard-first reading list. Explain how users add a first book and resume where they left off."
    static let homePreset = "fixture-home-task"

    static func prepare(page: String, runtime: NativeRuntime) async throws {
        try await NativeArenaService.shared(runtime: runtime).start()
        guard page != "arena-empty" else { return }
        let now = Date().timeIntervalSince1970 * 1000
        if page == "arena-home" {
            try runtime.db.execute("INSERT INTO arena_prompts(id,title,category,prompt,builtin,created_at,updated_at) VALUES(?,?,?,?,0,?,?)",
                                   [.string(homePreset), "Keyboard-first reading list", "design", .string(task), .number(now), .number(now)])
        }
        let cedar = "reading-assistant-enterprise-cedar-regional-preview-2026"
        let models = [(cedar, "sample-source"), ("reading-assistant-enterprise-maple-regional-preview-2026", "sample-source"),
                      (cedar, "sample-alternate"), ("sample-pine", "sample-source")]
        let answers = [
            "Make Add a book the first focused action. It opens a search field and a short list of matches. Enter adds the highlighted book; Escape returns to the library without losing the query.\n\nWhen a book is in progress, put Resume reading first. Show a short excerpt and the last saved page beside it.",
            "Use one command palette for Add, Find, and Resume. A keyboard shortcut opens it from anywhere, and the default action changes when the library is empty.\n\nKeep a recent books section and show the last completed chapter inline.",
            "Start with a focused search field. Offer title search, a recent books list, and a simple detail pane with notes and progress.",
            "Show a small reading queue sorted by last opened. Keep Resume and Add available without opening settings."
        ]
        let folder = runtime.paths.root.appendingPathComponent("arena/results")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<6 {
            let id = "fixture-match-\(index)", mode: JSONValue = index.isMultiple(of: 2) ? "random" : "chosen"
            let ranked = (2...4).contains(index), status: JSONValue = index == 1 ? "running" : index == 5 ? "queued" : "done"
            let prompt = index == 0 || index == 4 ? task : ["", "Compare two ways to organize a local library.", "Draft an accessible command palette.", "Sketch a desktop notes workspace.", "", "Plan a small offline search index."][index]
            let created = now - (ranked ? Double(index - 1) * 86_400_000 : Double(index + 2) * 120_000)
            let count = index == 0 || index == 1 || index == 4 ? 4 : 2
            let order = index == 3 ? [0, 1] : Array(0..<count).map { ($0 + index) % count }
            try runtime.db.execute("INSERT INTO arena_matches(id,mode,prompt,category,status,ranking,verdict,timeout_s,max_turns,created_at,started_at,finished_at,voted_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                .string(id), mode, .string(prompt), "design", status,
                ranked ? .string("[" + order.map(String.init).joined(separator: ",") + "]") : .null,
                ranked ? "ranked" : .null, 1200, 80, .number(created), .number(created + 1000),
                status == "done" ? .number(created + 40_000) : .null, ranked ? .number(created + 50_000) : .null
            ])
            var contestants: [JSONValue] = []
            for slot in 0..<count {
                let (name, route) = models[(slot + (count == 4 ? 0 : index)) % models.count]
                let duration = Double([18_500, 29_000, 24_000, 38_000][slot])
                let workdir = runtime.paths.data.appendingPathComponent("arena/matches/\(id)/slot-\(slot)").path
                let slotID = JSONValue.string("\(id)-slot-\(slot)")
                let slotStatus: JSONValue = index == 1 && slot == 0 ? "done" : status
                try runtime.db.execute("INSERT INTO arena_slots(id,match_id,idx,route,model,status,workdir,final_text,duration_ms,turns,output_tokens,cost_usd,started_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", [
                    slotID, .string(id), .number(Double(slot)), .string(route), .string(name), slotStatus,
                    .string(workdir), slotStatus == "done" ? .string(answers[slot]) : "",
                    slotStatus == "done" ? .number(duration) : .null, slotStatus == "done" ? .number(Double(slot + 3)) : 0,
                    .number(Double(640 + slot * 146)), slot == 1 ? 0 : .number(0.014 + Double(slot) * 0.009), .number(created + 1000)
                ])
                if index == 1 {
                    for step in 0..<(slot + 3) {
                        let tools = ["Read", "Glob", "Edit", "Write"]
                        let payload: JSONValue = ["message_id": .string("fixture-message-\(step)"), "content": [
                            ["type": "tool_use", "name": .string(tools[(step + slot) % tools.count])],
                            ["type": "text", "text": .string(answers[slot])]
                        ]]
                        let body = String(decoding: try payload.encoded(), as: UTF8.self)
                        try runtime.db.execute("INSERT INTO arena_slot_events(slot_id,seq,type,payload,ts) VALUES(?,?,?,?,?)",
                                               [slotID, .number(Double(step + 1)), "assistant", .string(body), .number(created + Double(step * 1000))])
                    }
                }
                contestants.append(["route": .string(route), "model": .string(name), "status": "done",
                                     "rank": .number(Double((order.firstIndex(of: slot) ?? 0) + 1)), "duration_ms": .number(duration), "turns": .number(Double(slot + 3))])
            }
            if ranked {
                let value: JSONValue = ["v": 1, "id": .string(id), "ts": .number(created + 50_000), "mode": mode, "category": "design",
                                        "voter": "sample", "prompt": .string(prompt), "verdict": "ranked", "contestants": .array(contestants)]
                try NativeFile.writeAtomic(try value.encoded(pretty: true), to: folder.appendingPathComponent(id + ".json"))
            }
        }
    }
}

final class PublicCaptureAnchorView: NSView {
    var anchorName = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class PublicPageCapture {
    private var panel: PublicCapturePanel?
    private var host: NSHostingView<AnyView>?
    private var activated = false
    private var observer: NSObjectProtocol?
    private var samples: [[String: Any]] = []
    private var preferences: UserDefaults?
    private var suite: String?

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private func scrollToSettingsSection(_ name: String, host: NSHostingView<AnyView>) throws -> [String: Any] {
        let matches = descendants(host).compactMap { $0 as? PublicCaptureAnchorView }.filter { $0.anchorName == name }
        guard matches.count == 1, let anchor = matches.first, !anchor.bounds.isEmpty else {
            throw NativeFailure("Expected exactly one laid-out Settings section anchor: \(name)")
        }
        var parent = anchor.superview
        while parent != nil && !(parent is NSScrollView) { parent = parent?.superview }
        guard let scroll = parent as? NSScrollView, let document = scroll.documentView else {
            throw NativeFailure("Settings section anchor is not in the production scroll view")
        }
        let rect = anchor.convert(anchor.bounds, to: document)
        let clip = scroll.contentView
        let top = document.isFlipped ? rect.minY : rect.maxY
        let y = document.isFlipped ? top - 16 : top - clip.bounds.height + 16
        let proposed = NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)
        let bounded = clip.constrainBoundsRect(proposed)
        clip.scroll(to: bounded.origin)
        scroll.reflectScrolledClipView(clip)
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard rect.intersects(scroll.documentVisibleRect) else {
            throw NativeFailure("Scrolled Settings section is not visible")
        }
        return ["section": name, "documentY": top, "scrollY": clip.bounds.minY,
                "visibleHeight": clip.bounds.height, "anchorIntersectsViewport": true]
    }

    private func sample(_ phase: String) throws {
        guard let panel else { throw NativeFailure("Capture panel missing") }
        let intersects = NSScreen.screens.contains { $0.frame.intersects(panel.frame) }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
        let quiet = !intersects && !panel.isVisible && !panel.isKeyWindow && !panel.isMainWindow
            && !NSApp.isActive && !frontmost && !activated
        samples.append(["phase": phase, "intersectsScreen": intersects, "visible": panel.isVisible,
                        "key": panel.isKeyWindow, "main": panel.isMainWindow,
                        "active": NSApp.isActive, "frontmostIsOwn": frontmost, "quiet": quiet])
        guard quiet else { throw NativeFailure("Offscreen capture lost its quiet state") }
    }

    private func pricingFixture(_ state: String) -> JSONValue {
        switch state {
        case "empty": return ["pricedTokens": 0, "unpricedTokens": 0, "unpriced": [], "rows": []]
        case "unknown": return ["pricedTokens": 0, "unpricedTokens": 1_000_000, "unpriced": .array((0..<19).map { .string("fixture-model-\($0)") }), "rows": []]
        case "partial": return ["pricedTokens": 750_000, "unpricedTokens": 250_000, "unpriced": ["fixture-model"], "rows": []]
        default: return ["pricedTokens": 1_000_000, "unpricedTokens": 0, "unpriced": [], "rows": []]
        }
    }

    private func readiness(_ metrics: URL, visit: Int) throws -> Bool {
        guard FileManager.default.fileExists(atPath: metrics.path) else { return false }
        let rows = try String(contentsOf: metrics, encoding: .utf8).split(separator: "\n")
        var ready = false
        for row in rows {
            let value = try JSONValue.decode(Data(row.utf8))
            guard value["visit"].int == visit else { continue }
            if value["phase"].string == "failureViewCommit" {
                throw NativeFailure("The production page reported failed readiness")
            }
            ready = ready || value["phase"].string == "dataViewCommit"
        }
        return ready
    }

    func capture(paths: NativePaths, output: URL, page: String, appearance: String, width: Int, height: Int) async throws {
        let detailSections = ["settings-sidebar": "sidebar", "settings-telegram": "telegram",
                              "settings-theme-common": "theme-common", "settings-theme-advanced": "theme-advanced"]
        let section = detailSections[page]
        let onboarding = page == "onboarding-welcome"
        let arenaScreen = PublicArenaCapture.screens[page]
        let pricing = ["pricing-empty": "empty", "pricing-unknown": "unknown", "pricing-partial": "partial", "pricing-priced": "priced"][page]
        let viewportAllowed = pricing == nil
            ? (640...1200).contains(width) && (500...1000).contains(height)
            : (320...1200).contains(width) && (100...1000).contains(height)
        guard paths.readOnly, ["stats", "transcribe", "settings"].contains(page) || onboarding || section != nil || pricing != nil || arenaScreen != nil,
              viewportAllowed,
              ["light", "dark"].contains(appearance),
              ProcessInfo.processInfo.environment["UNIAPI_CAPTURE_SETTINGS_SECTION"] == section,
              let metricsPath = ProcessInfo.processInfo.environment["UNIAPI_NATIVE_UI_METRICS"] else {
            throw NativeFailure("Expected isolated read-only page capture arguments")
        }
        // Theme uses UserDefaults.standard, not the injected AppStorage suite.
        // An argument-domain override is process-local and precedes persistent
        // domains. Admit capture only if the singleton sees the empty palette.
        let standard = UserDefaults.standard
        var arguments = standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let emptyTheme = NativeThemePreferences().serialized()
        arguments[NativeThemePreferences.storageKey] = emptyTheme
        standard.removeVolatileDomain(forName: UserDefaults.argumentDomain)
        standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        guard standard.string(forKey: NativeThemePreferences.storageKey) == emptyTheme,
              NativeThemeStore.shared.preferences == NativeThemePreferences() else {
            throw NativeFailure("Capture theme isolation failed")
        }
        let metrics = URL(fileURLWithPath: metricsPath)
        let runtime = try NativeRuntime(paths: paths)
        // Injected into the copied class, not an extension or product change.
        let session = NativeAppSession(captureRuntime: runtime)
        guard session.activity == nil, session.battery == nil, session.fans == nil,
              session.summaries == nil, session.preferencesPrepared, session.pageActive else {
            throw NativeFailure("Unexpected background domains in capture session")
        }
        let suiteName = "org.uniapi.public-page-capture." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NativeFailure("Cannot create isolated preferences")
        }
        suite = suiteName; preferences = defaults
        // setVolatileDomain does not create persistent operator preferences.
        let capturePreferences: [String: Any] = ["uniapi-theme": appearance, "uniapi-density": "standard",
                                    "uniapi-motion": "reduced", "uniapi.transcribe.notify": false,
                                    "uniapi.stats.source": "all", "uniapi.stats.range": 0]
        defaults.setVolatileDomain(capturePreferences, forName: suiteName)
        NativeUIReadiness.shared.launched()
        let destination: NativeDestination = arenaScreen != nil ? .arena : page == "stats" ? .stats : page == "transcribe" ? .transcribe : .settings
        guard let visit = NativeUIReadiness.shared.begin(destination) else {
            throw NativeFailure("Production readiness instrumentation must be enabled")
        }
        let content: AnyView
        if let pricing {
            content = AnyView(VStack { NativeStatsPricing(cost: pricingFixture(pricing)); Spacer(minLength: 0) }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Theme.bg))
        } else if onboarding {
            content = AnyView(NativeOnboardingView { _ in })
        } else if let arenaScreen {
            content = AnyView(NativeArenaPage(runtime: runtime, opens: arenaScreen, matchID: PublicArenaCapture.matches[page],
                                              initialPreset: page == "arena-home" ? PublicArenaCapture.homePreset : "").background(Theme.bg))
        } else { switch page {
        case "stats": content = AnyView(NativeStatsPage(runtime: runtime))
        case "transcribe": content = AnyView(NativeTranscribePage(runtime: runtime))
        default: content = AnyView(NativeSettingsPage(runtime: runtime))
        } }
        let scheme: ColorScheme = appearance == "dark" ? .dark : .light
        let view = AnyView(content.environmentObject(session).defaultAppStorage(defaults)
            .environment(\.nativePageVisit, visit)
            .environment(\.nativePageActivation, session.pageActivation)
            .environment(\.nativeInterfaceDensity, .standard)
            .environment(\.nativeReducedMotion, true)
            .environment(\.nativeMotionVisible, false)
            .environment(\.colorScheme, scheme).preferredColorScheme(scheme))
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: NSApp, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.activated = true }
            }
        let x = (NSScreen.screens.map { $0.frame.minX }.min() ?? 0) - 10_000
        let y = (NSScreen.screens.map { $0.frame.minY }.min() ?? 0) - 10_000
        let panel = PublicCapturePanel(contentRect: NSRect(x: x, y: y, width: CGFloat(width), height: CGFloat(height)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.isReleasedWhenClosed = false; panel.animationBehavior = .none
        panel.isExcludedFromWindowsMenu = true
        panel.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view); self.host = host
        // AppKit must not enlarge an allegedly finite viewport to fit content.
        host.sizingOptions = []
        panel.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        // The production page owns its NativePage/ScrollView. No extra scroll
        // container, artificial minimum height, sidebar, or ordering call.
        try sample("created-unordered")
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while true {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            try sample("waiting-for-production-readiness")
            // An unordered host may commit its readiness probe only while
            // caching display. Drive that path without accepting this bitmap.
            guard let discarded = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw NativeFailure("Cannot allocate readiness bitmap")
            }
            host.cacheDisplay(in: host.bounds, to: discarded)
            try sample("after-readiness-bitmap")
            if onboarding || pricing != nil { break }
            if try readiness(metrics, visit: visit.id) { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw NativeFailure("Page never reached ready; no screenshot accepted")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        var scrollReport: [String: Any] = [:]
        if let section {
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            scrollReport = try scrollToSettingsSection(section, host: host)
            try sample("after-programmatic-scroll")
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        if let section {
            scrollReport = try scrollToSettingsSection(section, host: host)
            try sample("before-scrolled-bitmap")
        }
        try sample("before-bitmap")
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard host.bounds.size == NSSize(width: CGFloat(width), height: CGFloat(height)),
              panel.contentView?.bounds.size == host.bounds.size else {
            throw NativeFailure("Capture viewport resized; no screenshot accepted")
        }
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NativeFailure("Cannot allocate native page bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NativeFailure("Cannot encode native page bitmap")
        }
        try sample("after-bitmap")
        let fixtureKind = pricing != nil ? "offscreen-native-pricing-component-synthetic" : arenaScreen != nil && page != "arena-empty" ? "offscreen-native-arena-synthetic" : "offscreen-native-page-empty-fixture"
        let report: [String: Any] = ["kind": fixtureKind, "page": page,
            "appearance": appearance, "viewportWidth": width, "viewportHeight": height,
            "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh,
            "quiet": true, "samples": samples, "inputActions": 0,
            "programmaticScroll": scrollReport,
            "themePreferences": "isolated volatile standard-defaults override; original palette verified",
            "sessionInitializer": "captureRuntime", "readOnly": true,
            "limits": "Page illustration only. Settings details use recorded capture-only expanded state and programmatic scrolling. No complete shell, compositor, layout parity, runtime feature or fresh-installed acceptance claim."]
        // Core's writer creates its temporary file beside the destination;
        // Foundation atomic writes can request an external replacement folder.
        let reportData = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        try NativeFile.writeAtomic(reportData, to: output.appendingPathComponent("capture.json"))
        try NativeFile.writeAtomic(png, to: output.appendingPathComponent("page.png"))
        // Dropping the actual page cancels its SwiftUI reads/listeners. This
        // special session never started the normal session background domains.
        host.rootView = AnyView(EmptyView())
        if let observer { NotificationCenter.default.removeObserver(observer) }
        defaults.removeVolatileDomain(forName: suiteName)
        panel.close()
    }
}

@main private enum PublicScreenshotMain {
    @MainActor static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else { fputs("Use the capture-public-screenshots.py runner\n", stderr); exit(64) }
        let root = URL(fileURLWithPath: args[1], isDirectory: true)
        let home = URL(fileURLWithPath: args[2], isDirectory: true)
        let env = ProcessInfo.processInfo.environment
        guard root.path == home.appendingPathComponent("UniApi").path,
              env["UNIAPI_ROOT"] == root.path, env["UNIAPI_NATIVE_HOME"] == home.path,
              env["UNIAPI_NATIVE_READ_ONLY"] == "1", env["HOME"] == home.path,
              env["CFFIXED_USER_HOME"] == home.path else {
            fputs("Isolated capture environment required\n", stderr); exit(64)
        }
        if args[0] == "--prepare-fixture", args.count == 3 || (args.count == 4 && PublicArenaCapture.screens[args[3]] != nil) {
            // A separate process exits after creating only fresh schemas. No
            // default session, ownership lease, recovery, services or UI starts.
            Task {
                do {
                    let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home))
                    try await NativeTranscriptionService(runtime: runtime).start()
                    try await NativeStatisticsService(runtime: runtime).start()
                    if args.count == 4 { try await PublicArenaCapture.prepare(page: args[3], runtime: runtime) }
                    guard try runtime.db.query("SELECT id FROM jobs").isEmpty,
                          try runtime.db.query("SELECT id FROM transcripts").isEmpty,
                          try runtime.providers.list().isEmpty else {
                        throw NativeFailure("Fixture must remain empty")
                    }
                    exit(0)
                } catch { fputs("Fixture preparation failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        guard args[0] == "--capture", args.count == 8,
              let width = Int(args[6]), let height = Int(args[7]) else { exit(64) }
        let app = NSApplication.shared
        guard app.setActivationPolicy(.prohibited) else { exit(65) }
        let capture = PublicPageCapture()
        Task { @MainActor in
            do {
                try await capture.capture(paths: NativePaths(root: root, home: home, readOnly: true),
                    output: URL(fileURLWithPath: args[3], isDirectory: true), page: args[4], appearance: args[5], width: width, height: height)
                exit(0)
            } catch { fputs("Page capture failed: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        // Run AppKit's loop without the production delegate or entry point.
        withExtendedLifetime(capture) { app.run() }
    }
}
