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
        let pricing = ["pricing-empty": "empty", "pricing-unknown": "unknown", "pricing-partial": "partial", "pricing-priced": "priced"][page]
        let viewportAllowed = pricing == nil
            ? (640...1200).contains(width) && (500...1000).contains(height)
            : (320...1200).contains(width) && (100...1000).contains(height)
        guard paths.readOnly, ["stats", "transcribe", "settings"].contains(page) || onboarding || section != nil || pricing != nil,
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
        defaults.setVolatileDomain(["uniapi-theme": appearance, "uniapi-density": "standard",
                                    "uniapi-motion": "reduced", "uniapi.transcribe.notify": false,
                                    "uniapi.stats.source": "all", "uniapi.stats.range": 0],
                                   forName: suiteName)
        NativeUIReadiness.shared.launched()
        let destination: NativeDestination = page == "stats" ? .stats : page == "transcribe" ? .transcribe : .settings
        guard let visit = NativeUIReadiness.shared.begin(destination) else {
            throw NativeFailure("Production readiness instrumentation must be enabled")
        }
        let content: AnyView
        if let pricing {
            content = AnyView(VStack { NativeStatsPricing(cost: pricingFixture(pricing)); Spacer(minLength: 0) }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Theme.bg))
        } else if onboarding {
            content = AnyView(NativeOnboardingView { _ in })
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
        let report: [String: Any] = ["kind": pricing == nil ? "offscreen-native-page-empty-fixture" : "offscreen-native-pricing-component-synthetic", "page": page,
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
        if args[0] == "--prepare-fixture", args.count == 3 {
            // A separate process exits after creating only fresh schemas. No
            // default session, ownership lease, recovery, services or UI starts.
            Task {
                do {
                    let runtime = try NativeRuntime(paths: NativePaths(root: root, home: home))
                    try await NativeTranscriptionService(runtime: runtime).start()
                    try await NativeStatisticsService(runtime: runtime).start()
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
