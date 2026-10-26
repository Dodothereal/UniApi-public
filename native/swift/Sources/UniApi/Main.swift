import Foundation
import SwiftUI
import AppKit
import Carbon
import Darwin
import UniApiCore
import UniApiPresentation

@main
@MainActor enum NativeEntry {
    static func main() {
        NativeUIReadiness.shared.launched()
        if CommandLine.arguments.contains("--version") { print("UniApi " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")); return }
        if ["--local-model", "--transcribe-file"].contains(CommandLine.arguments.dropFirst().first ?? "") {
            let task = Task {
                do { exit(try await NativeLocalTranscriptionCLI.run(Array(CommandLine.arguments.dropFirst()))) }
                catch is CancellationError { fputs("Local transcription cancelled\n", stderr); exit(130) }
                catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
                source.setEventHandler { task.cancel() }; source.resume(); return source
            }
            withExtendedLifetime(signals) { dispatchMain() }
        }
        let installationOperations: Set<String> = ["--prepare-install", "--retire-native-update", "--prepare-transfer", "--retire-legacy", "--retire-native-install"]
        guard CommandLine.arguments.filter({ installationOperations.contains($0) }).count <= 1 else { fputs("Select one installation operation\n", stderr); exit(64) }
        if let index = CommandLine.arguments.firstIndex(where: { $0 == "--prepare-install" || $0 == "--retire-native-update" }) {
            let retire = CommandLine.arguments[index] == "--retire-native-update"
            let appIndex = index + (retire ? 2 : 1)
            guard index == 1, CommandLine.arguments.count == (retire ? 5 : 3),
                  appIndex < CommandLine.arguments.count, CommandLine.arguments[appIndex].hasPrefix("/") else { fputs("Expected one installation operation and an absolute installed app path\n", stderr); exit(64) }
            let application = URL(fileURLWithPath: CommandLine.arguments[appIndex])
            var instance = "", hashes: [String: String] = [:]
            if retire {
                do {
                    guard index + 3 < CommandLine.arguments.count, let nonce = UUID(uuidString: CommandLine.arguments[index + 1]),
                          CommandLine.arguments[index + 3].utf8.count <= 65536 else { throw NativeFailure("Expected a native update identity and prepared plan") }
                    let plan = try JSONValue.decode(Data(CommandLine.arguments[index + 3].utf8))
                    let values = plan["definitionHashes"].object
                    guard plan["kind"] == "native", plan["status"] == "prepared", plan["canPrepare"].bool,
                          plan["oldInstance"].string == nonce.uuidString, !values.isEmpty, values.count <= 2,
                          values.values.allSatisfy({ $0.string.utf8.count == 64 && $0.string.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }) else { throw NativeFailure("The native update plan is invalid") }
                    instance = nonce.uuidString; hashes = values.mapValues(\.string)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(64) }
            }
            let task = Task {
                do {
                    let paths = NativePaths.discover()
                    let result: JSONValue
                    if retire { result = await NativeServiceUpdate.retire(paths: paths, application: application, instance: instance, expectedDefinitionHashes: hashes) }
                    else if try NativeServiceUpdate.isNativeInstallation(paths: paths) { result = await NativeServiceUpdate.prepare(paths: paths, application: application) }
                    else {
                        var value = await NativeLegacyRetirement.prepare(paths: paths, io: try .production(paths: paths))
                        value["kind"] = "legacy"; result = value
                    }
                    print(String(decoding: try result.encoded(), as: UTF8.self))
                    exit((retire ? result["safeToInstall"].bool : result["canPrepare"].bool) ? 0 : 2)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
                source.setEventHandler { task.cancel() }; source.resume(); return source
            }
            // A cancelled update must finish its shielded recovery before this
            // command can release the installer to replace or restore files.
            withExtendedLifetime(signals) { dispatchMain() }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--retire-native-install") {
            guard index + 2 < CommandLine.arguments.count,
                  UUID(uuidString: CommandLine.arguments[index + 1]) != nil,
                  CommandLine.arguments[index + 2].hasPrefix("/"),
                  !CommandLine.arguments.contains("--retire-legacy"), !CommandLine.arguments.contains("--prepare-transfer") else { fputs("Expected one startup identity and absolute app path\n", stderr); exit(64) }
            let task = Task {
                do {
                    let result = await NativeInstallServiceRetirement.retire(paths: NativePaths.discover(), application: URL(fileURLWithPath: CommandLine.arguments[index + 2]), instance: CommandLine.arguments[index + 1])
                    print(String(decoding: try result.encoded(), as: UTF8.self)); exit(result["safeToRestore"].bool ? 0 : 2)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
                source.setEventHandler { task.cancel() }; source.resume(); return source
            }
            withExtendedLifetime(signals) { dispatchMain() }
        }
        if CommandLine.arguments.contains("--prepare-transfer") || CommandLine.arguments.contains("--retire-legacy") {
            let retire = CommandLine.arguments.contains("--retire-legacy")
            guard !(retire && CommandLine.arguments.contains("--prepare-transfer")) else { fputs("Select one transfer operation\n", stderr); exit(64) }
            let task = Task {
                do {
                    let paths = NativePaths.discover()
                    let io = try NativeLegacyRetirementIO.production(paths: paths)
                    let result = retire ? await NativeLegacyRetirement.retire(paths: paths, io: io) : await NativeLegacyRetirement.prepare(paths: paths, io: io)
                    print(String(decoding: try result.encoded(), as: UTF8.self))
                    exit((retire ? result["safeToInstall"].bool : result["canPrepare"].bool) ? 0 : 2)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            // Cancellation must unwind owned admission pauses and await the
            // coordinator's shielded recovery before the CLI exits.
            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
                source.setEventHandler { task.cancel() }; source.resume(); return source
            }
            withExtendedLifetime(signals) { dispatchMain() }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--native-health") {
            do {
                guard index + 2 < CommandLine.arguments.count, let pid = Int32(CommandLine.arguments[index + 1]), pid > 1 else { throw NativeFailure("Expected native background PID and startup identity") }
                print(String(decoding: try NativeHealth.read(paths: NativePaths.discover(), expectedPID: pid, expectedInstance: CommandLine.arguments[index + 2]).encoded(), as: UTF8.self)); return
            } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--native-shim-health") {
            Task {
                do {
                    guard index + 2 < CommandLine.arguments.count, let pid = Int32(CommandLine.arguments[index + 1]), pid > 1 else { throw NativeFailure("Expected native shim PID and startup identity") }
                    _ = try await NativeHealth.shim(expectedPID: pid, expectedInstance: CommandLine.arguments[index + 2]); exit(0)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--legacy-health") {
            Task {
                do {
                    guard index + 1 < CommandLine.arguments.count else { throw NativeFailure("Expected restored service label") }
                    try await NativeTransferCheck.legacyHealth(service: CommandLine.arguments[index + 1]); exit(0)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--check-transfer") {
            Task {
                do { let check = try await NativeTransferCheck.inspect(); print(String(decoding: try check.json.encoded(), as: UTF8.self)); exit(check.canTransfer ? 0 : 2) }
                catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--profile-results") {
            Task {
                do {
                    let paths = NativePaths.discover()
                    guard paths.readOnly else { throw NativeFailure("Results profiling requires UNIAPI_NATIVE_READ_ONLY=1") }
                    let runtime = try NativeRuntime(paths: paths), service = NativeBenchmarkService.shared(runtime: runtime)
                    var measurements: [NativeMeasurement] = []
                    let (summary, first) = try await NativePerformance.measure("results-summary") { try await service.handle("summary", input: ["scope": "latest"]) }
                    measurements.append(first)
                    let (rows, raw) = try await NativePerformance.measure("results-raw") { try await service.handle("rows", input: ["scope": summary["scope"], "limit": 2000]) }
                    measurements.append(raw)
                    let (curves, arrival) = try await NativePerformance.measure("results-curves") { try await service.handle("curves", input: ["scope": summary["scope"]]) }
                    measurements.append(arrival)
                    let (_, warm) = try await NativePerformance.measure("results-warm-summary") { try await service.handle("summary", input: ["scope": "latest"]) }
                    measurements.append(warm)
                    let encoder = JSONEncoder(), values = try measurements.map { try JSONValue.decode(encoder.encode($0)) }
                    let report: JSONValue = ["kind": "native-results-read-only-profile", "recordedAt": .string(ISO8601DateFormatter().string(from: Date())), "measurements": .array(values), "cells": .number(Double(summary["cells"].object.count)), "runs": .number(Double(summary["runs"].array.count)), "rawRows": .number(Double(rows.array.count)), "curves": .number(Double(curves.array.count)), "note": "Core operation times only; no UI, inference, hardware operation or persistent write."]
                    print(String(decoding: try report.encoded(pretty: true), as: UTF8.self)); exit(0)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--profile-statistics") || CommandLine.arguments.contains("--statistics-metadata") {
            Task {
                do {
                    let paths = NativePaths.discover()
                    guard paths.readOnly else { throw NativeFailure("Statistics profiling requires UNIAPI_NATIVE_READ_ONLY=1") }
                    let runtime = try NativeRuntime(paths: paths), service = NativeStatisticsService.shared(runtime: runtime)
                    if CommandLine.arguments.contains("--statistics-metadata") { print(String(decoding: try await service.metadataDiagnostics().encoded(pretty: true), as: UTF8.self)); exit(0) }
                    let (overview, first) = try await NativePerformance.measure("statistics-first-load") { try await service.handle("overview") }
                    let (_, warm) = try await NativePerformance.measure("statistics-warm-load") { try await service.handle("overview") }
                    let (bench, spend) = try await NativePerformance.measure("statistics-benchmark-spend") { try await service.handle("bench") }
                    let encoder = JSONEncoder()
                    let measurements = try [first, warm, spend].map { try JSONValue.decode(encoder.encode($0)) }
                    let totals = overview["derived"]["summary"]["totals"]
                    let grand = ["input", "output", "cacheRead", "cacheWrite"].reduce(0.0) { $0 + totals[$1].double }
                    let report: JSONValue = ["kind": "native-statistics-read-only-profile", "recordedAt": .string(ISO8601DateFormatter().string(from: Date())), "measurements": .array(measurements), "scan": overview["scan"], "grand": .number(grand), "responses": overview["derived"]["events"], "benchmarkCalls": bench["spend"]["calls"], "note": "Core operation times and process peak RSS; no UI, inference, hardware operation or persistent write."]
                    print(String(decoding: try report.encoded(pretty: true), as: UTF8.self)); exit(0)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--web-baseline") {
            Task {
                do {
                    let result = try await NativeWebBaseline.collect(root: NativePaths.discover().root)
                    print(String(decoding: try result.encoded(pretty: true), as: UTF8.self))
                    exit(0)
                } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        let application = NSApplication.shared
        let delegate = NativeAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(CommandLine.arguments.contains("--background") ? .accessory : .regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

struct NativeRoot: View {
    @ObservedObject var session: NativeAppSession
    var body: some View {
        Group {
            if !session.preferencesPrepared {
                if let error = session.error { NativeError(message: error).padding(30) }
                else { ProgressView("Opening local storage…").padding(30) }
            }
            else if let runtime = session.runtime { NativeShell(runtime: runtime).environmentObject(session) }
            else { NativeError(message: session.error ?? "Unable to open local storage").padding(30).frame(minWidth: 900, minHeight: 600) }
        }
    }
}

@MainActor
final class NativeAppSession: ObservableObject {
    static weak var current: NativeAppSession?
    @Published var runtime: NativeRuntime?
    @Published var error: String?
    @Published var presentation = NativePresentationState(visible: !CommandLine.arguments.contains("--background"))
    @Published var pageActivation = NativePageActivation(active: false)
    var pageActive: Bool {
        get { pageActivation.active }
        set { pageActivation.setActive(newValue) }
    }
    var presented: Bool {
        get { presentation.visible }
        set { if newValue { presentation.show() } else { presentation.close() } }
    }
    @Published var preferencesPrepared = false
    private var prompts: NativePromptsService?
    var transcription: NativeTranscriptionService?
    var activity: NativeActivityService?
    var battery: NativeBatteryService?
    var fans: NativeFanService?
    var summaries: NativeHubSummaries?
    private var statistics: NativeStatisticsService?
    private var statisticsStartup: Task<Void, Never>?
    private var statisticsStopping = false
    private var benchmark: NativeBenchmarkService?
    private var code: NativeCodeService?
    private var arena: NativeArenaService?
    private var switcher: NativeSwitcherService?
    private var ownership: NativeOwnershipLease?
    init() {
        do {
            let paths = NativePaths.discover()
            if !paths.readOnly { ownership = try NativeOwnership.claim() }
            let runtime = try NativeRuntime(paths: paths)
            self.runtime = runtime
            let prompts = NativePromptsService(runtime: runtime)
            self.prompts = prompts
            let transcription = NativeTranscriptionService(runtime: runtime)
            self.transcription = transcription
            activity = NativeActivityService(readOnly: paths.readOnly)
            let battery = NativeBatteryService(runtime: runtime)
            self.battery = battery
            let fans = NativeFanService(runtime: runtime)
            self.fans = fans
            statistics = NativeStatisticsService.shared(runtime: runtime)
            let benchmark = NativeBenchmarkService.shared(runtime: runtime)
            self.benchmark = benchmark
            let code = NativeCodeService.shared(runtime: runtime)
            self.code = code
            let arena = NativeArenaService.shared(runtime: runtime)
            self.arena = arena
            let switcher = NativeSwitcherService.shared(runtime: runtime)
            self.switcher = switcher
            summaries = NativeHubSummaries(runtime: runtime, transcription: transcription)
            Task {
                do {
                    if !paths.readOnly { _ = try await NativePreferencesBridge.migrate(runtime: runtime) }
                    guard !self.statisticsStopping else { return }
                    if let statistics = self.statistics {
                        // Claim before Home can queue its independent cache
                        // reader. Keep shell prefetch: it joins this same scan.
                        let initial = statistics.reserveInitialGeneration(), delayed = !self.presented
                        self.statisticsStartup = Task(priority: .utility) {
                            do {
                                if delayed { try await Task.sleep(nanoseconds: 2_000_000_000); try Task.checkCancellation() }
                                if let initial { try await statistics.startInitialGeneration(initial) }
                                else { try await statistics.start() }
                            }
                            catch is CancellationError { }
                            catch {
                                guard !Task.isCancelled else { return }
                                await runtime.events.publish("stats.failed", .string(error.localizedDescription))
                                await runtime.events.publish("runtime.error", .string("Usage refresh failed: " + error.localizedDescription))
                            }
                        }
                    }
                    self.preferencesPrepared = true
                    NotificationCenter.default.post(name: .nativeSessionPrepared, object: self)
                    try await prompts.start()
                    try await transcription.start()
                    try await benchmark.start()
                    try await code.start()
                    try await arena.start()
                    try await switcher.start()
                    try await battery.start()
                    try await fans.start()
                    if !paths.readOnly {
                        try await runtime.jobs.recover()
                        try await arena.reconcileAfterRecovery()
                        try await code.reconcileAfterRecovery()
                        try NativeHealth.write(paths: paths, ready: true)
                    }
                } catch {
                    self.error = error.localizedDescription
                    if !paths.readOnly { try? NativeHealth.write(paths: paths, ready: false, error: error.localizedDescription) }
                    if !self.preferencesPrepared { NotificationCenter.default.post(name: .nativeSessionPrepared, object: self) }
                    else { await runtime.events.publish("runtime.error", .string(error.localizedDescription)) }
                }
            }
        }
        catch { self.error = error.localizedDescription }
        Self.current = self
        if runtime == nil { Task { NotificationCenter.default.post(name: .nativeSessionPrepared, object: self) } }
    }
    func shutdown() async {
        statisticsStopping = true
        let startup = statisticsStartup; startup?.cancel()
        if let runtime, !runtime.paths.readOnly {
            try? NativeHealth.write(paths: runtime.paths, ready: false)
        }
        await statistics?.shutdownInitialGeneration()
        await startup?.value; statisticsStartup = nil
        guard let runtime else { return }
        if !runtime.paths.readOnly {
            await runtime.jobs.suspendForShutdown()
            await code?.shutdown()
        }
        await fans?.stopMonitoring()
        await switcher?.shutdown()
    }
}

@MainActor final class NativeAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var session: NativeAppSession?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var fanMenu: NativeFanMenu?
    private var powerObserver: NSObjectProtocol?
    private var preparationObserver: NSObjectProtocol?
    private var pageActivity: NativeWindowActivityObserver?
    private var terminationSignals: [DispatchSourceSignal] = []
    private var shuttingDown = false, terminationPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        let session = NativeAppSession(); self.session = session
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1150, height: 840), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "UniApi Native"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none; window.backgroundColor = .windowBackgroundColor
        window.contentMinSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false; window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier("UniApiMain")
        window.contentView = NSTextField(labelWithString: "Opening local storage…")
        window.center()
        self.window = window
        pageActivity = NativeWindowActivityObserver(window: window,
            presented: { [weak session] in session?.presented == true },
            changed: { [weak session] active in
                if session?.pageActive != active { session?.pageActive = active }
            })
        preparationObserver = NotificationCenter.default.addObserver(forName: .nativeSessionPrepared, object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, let session = self.session else { return }
                let host = NSHostingView(rootView: NativeRoot(session: session))
                // Scrolling content must not redefine the window's minimum or
                // grow it beyond the screen when a longer page is selected.
                host.sizingOptions = []
                window.contentView = host
                NativePreferencesBridge.restoreWindowGeometry(window)
                window.setFrameAutosaveName("UniApiMain")
                if session.presented { self.installMenu() }
            }
        }
        powerObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.shuttingDown = true } }
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.shuttingDown = true
                // terminateLater pumps an AppKit loop while awaiting shutdown.
                // A main-dispatch callback holds the queue and prevents its
                // MainActor cleanup task from starting inside that nested loop.
                RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) }
            }
            source.resume(); terminationSignals.append(source)
        }
        if !session.presented { hidePresentation() } else { showWindow() }
    }
    private func installApplicationMenu() {
        let menu = NSMenu(), app = NSMenu(), edit = NSMenu(title: "Edit"), view = NSMenu(title: "View"), window = NSMenu(title: "Window")
        func submenu(_ title: String, _ child: NSMenu) { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.submenu = child; menu.addItem(item) }
        app.addItem(withTitle: "About UniApi", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator()); app.addItem(withTitle: "Hide UniApi", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let others = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"); others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator()); app.addItem(withTitle: "Quit UniApi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        submenu("UniApi", app)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key) }
        submenu("Edit", edit)
        let reload = view.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r"); reload.target = self
        let sidebar = view.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b"); sidebar.target = self
        view.addItem(.separator())
        let logs = view.addItem(withTitle: "Show Logs", action: #selector(showLogs), keyEquivalent: ""); logs.target = self
        view.addItem(.separator())
        let fullscreen = view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"); fullscreen.keyEquivalentModifierMask = [.command, .control]
        submenu("View", view)
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator()); window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        submenu("Window", window); NSApp.mainMenu = menu; NSApp.windowsMenu = window
    }
    private func installMenu() {
        guard fanMenu == nil, statusItem == nil else { return }
        if let session = NativeAppSession.current, let fans = session.fans, let runtime = session.runtime {
            fanMenu = NativeFanMenu(service: fans, readOnly: runtime.paths.readOnly) { [weak self] fans in
                self?.showWindow()
                if fans { NotificationCenter.default.post(name: .nativeNavigation, object: NativeDestination.fans) }
            }
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "UniApi")
        let menu = NSMenu()
        let show = NSMenuItem(title: "Show UniApi", action: #selector(showWindow), keyEquivalent: "")
        show.target = self; menu.addItem(show); menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit UniApi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu; statusItem = item
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    @objc private func showWindow() {
        NativeAppSession.current?.presented = true
        NSApp.setActivationPolicy(.regular)
        if NativeAppSession.current?.preferencesPrepared == true { installMenu() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        pageActivity?.scheduleCheck()
    }
    @objc private func reloadPage() {
        showWindow()
        NotificationCenter.default.post(name: .nativePageReload, object: nil)
    }
    @objc private func toggleSidebar() {
        showWindow()
        NotificationCenter.default.post(name: .nativeSidebarToggle, object: nil)
    }
    @objc private func showLogs() {
        let paths = NativeAppSession.current?.runtime?.paths ?? NativePaths.discover()
        NSWorkspace.shared.activateFileViewerSelecting([paths.logs])
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Keep only the selected page's state, while its UI work is suspended.
        // Normal Quit below deliberately discards that retained page instead.
        session?.pageActive = false; session?.presentation.close()
        NativePagePanels.shared.cancelOwnedPanels(for: sender)
        sender.orderOut(nil); return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        let systemExit = shuttingDown || [OSType(kAEQuitAll), OSType(kAEShutDown), OSType(kAERestart), OSType(kAEReallyLogOut)].contains(reason ?? 0)
        guard systemExit || NativeAppSession.current?.runtime == nil || NativeAppSession.current?.preferencesPrepared == false || NativeAppSession.current?.runtime?.paths.readOnly == true else {
            // The old shell's Quit removed only its UI; its independent hub
            // kept jobs and kept fan intent alive. Preserve that contract in
            // Swift without retaining hidden page pollers or a client lease.
            hidePresentation(); return .terminateCancel
        }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task { await NativeAppSession.current?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    private func hidePresentation() {
        NativeAppSession.current?.pageActive = false
        NativeAppSession.current?.presentation.discard()
        if let window { NativePagePanels.shared.cancelOwnedPanels(for: window) }
        fanMenu?.stop(); fanMenu = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem); self.statusItem = nil }
        for window in NSApp.windows where window.canBecomeMain { window.orderOut(nil) }
        NSApp.setActivationPolicy(.accessory)
    }
    func applicationWillTerminate(_ notification: Notification) {
        terminationSignals.forEach { $0.cancel() }; terminationSignals = []
        if let powerObserver { NSWorkspace.shared.notificationCenter.removeObserver(powerObserver) }
        if let preparationObserver { NotificationCenter.default.removeObserver(preparationObserver) }
        pageActivity?.stop(); pageActivity = nil
        fanMenu?.stop(); fanMenu = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
    }
}

extension Notification.Name { static let nativeSessionPrepared = Notification.Name("UniApi.NativeSessionPrepared") }
