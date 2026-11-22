import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

struct NativeSettingsPage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @Environment(\.nativeBatterySupported) private var batterySupported
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @AppStorage("uniapi-theme") private var appearance = "auto"
    @AppStorage("uniapi-density") private var density = "standard"
    @AppStorage("uniapi-motion") private var motion = "system"
    @AppStorage("uniapi-start-page") private var startPage = NativeNavigationPreferences.defaultStartPage.rawValue
    @AppStorage("uniapi-restore-last-page") private var restoreLastPage = NativeNavigationPreferences.defaultRestoreLastPage
    @State private var diagnostics = ""
    @State private var activeJobs: Int?
    @State private var jobsError: String?
    @State private var health: JSONValue = .null
    @State private var error: String?
    @State private var showColors = false
    @State private var showDiagnostics = false
    @State private var reads = NativePageReadScope()
    @State private var subscription: NativePageReadScope.Ticket?

    private static let sections: [(id: String, title: String)] = [
        ("appearance", "Appearance"), ("sidebar", "Sidebar"), ("launch", "Launch"),
        ("telegram", "Telegram"), ("updates", "Updates"), ("diagnostics", "Diagnostics"),
    ]

    var body: some View {
        ScrollViewReader { scroll in
            NativePage(title: "Settings", eyebrow: "Stored on this Mac", readiness: error != nil || jobsError != nil || session.error != nil ? .failed : diagnostics.isEmpty ? .pending : .ready, actions: {
                Button("Reload", nativeIcon: "rotate-cw") { Task { await reload() } }
                NativeUpdateHeaderButton(model: session.updates)
            }) {
                if let startupError = session.error { failure("Startup failed: " + startupError) }
                if let jobsError { failure("Active jobs unavailable: " + jobsError) }
                if let error { failure(error) }
                readings
                SettingsIndex(sections: Self.sections) { id in
                    if reduceMotion { scroll.scrollTo(id, anchor: .top) }
                    else { withAnimation(.easeOut(duration: 0.28)) { scroll.scrollTo(id, anchor: .top) } }
                }
                appearanceBand.id("appearance")
                NativeSidebarSettingsView().id("sidebar")
                launchBand.id("launch")
                NativeTelegramSettingsView(runtime: runtime).id("telegram")
                Band("Updates", spacing: 0) { NativeUpdateSettings(model: session.updates) }.id("updates")
                diagnosticsBand.id("diagnostics")
            }
        }.nativePageTask {
            guard let listener = reads.begin("events") else { return }
            let events = await runtime.events.stream()
            guard reads.accepts(listener) else { return }
            subscription = listener
            await reload()
            guard reads.accepts(listener) else { return }
            for await event in events {
                guard reads.accepts(listener) else { break }
                if event.topic == "job.updated" || event.topic == "runtime.error" { await reload() }
            }
        }.nativePageTask {
            guard let periodic = reads.begin("periodic") else { return }
            while reads.accepts(periodic) {
                do { try await Task.sleep(nanoseconds: 15_000_000_000); try Task.checkCancellation() }
                catch { return }
                guard reads.accepts(periodic) else { return }
                await reload()
            }
        }.nativePageActivity(reads: reads)
    }

    private func failure(_ message: String) -> some View {
        Notice(text: message, tone: .fail).accessibilityLabel("Error: " + message)
    }

    // ---- the app's own readings ------------------------------------------

    private var readings: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let minutes = Int(runtime.uptime / 60)
        let long = minutes >= 120
        return ReadoutStrip(minimum: 136) {
            SettingsState(name: stateName, detail: stateName == startupStatus ? "Startup confirmed" : startupStatus, tint: stateTint)
            Readout(label: "Version", value: version == "development" ? "dev" : version, detail: session.updates.brief)
            Readout(label: "Uptime", value: long ? String(format: "%.1f", Double(minutes) / 60) : String(minutes),
                    unit: long ? "h" : "min", detail: "Process \(ProcessInfo.processInfo.processIdentifier)")
            Readout(label: "Active jobs", value: activeJobs.map(String.init) ?? "--",
                    unit: activeJobs == nil ? "" : activeJobs == 1 ? "job" : "jobs",
                    detail: activeJobs == nil ? (jobsError == nil ? "Reading the queue" : "Unavailable") : activeJobs == 0 ? "Queue idle" : "Running in the background",
                    tint: (activeJobs ?? 0) > 0 ? Theme.signal : nil, color: activeJobs == nil ? Theme.faint : Theme.ink)
        }
    }
    /// The startup sentence reduced to the state it names.
    private var stateName: String {
        let status = startupStatus
        if status.hasPrefix("Startup failed") { return "Failed" }
        if status.hasPrefix("Read-only") { return "Read-only" }
        if status == "Ready" { return status }
        return status.hasPrefix("Preparing") ? "Preparing" : "Starting"
    }
    private var stateTint: Color? {
        switch stateName { case "Ready": return Theme.ok; case "Failed": return Theme.fail; case "Read-only": return Theme.warn; default: return nil }
    }

    // ---- bands -------------------------------------------------------------

    private var appearanceBand: some View {
        Band("Appearance", spacing: 0) {
            OptionRow(title: "Look", detail: "Auto follows macOS.") {
                Stops(options: [("dark", "Graphite"), ("light", "Paper"), ("auto", "Auto")], selection: appearance,
                      icons: ["dark": "moon", "light": "sun", "auto": "monitor"]) { appearance = $0 }
                    .accessibilityLabel("Color scheme")
            }
            OptionRow(title: "Spacing") {
                Stops(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                    .accessibilityLabel("Page spacing")
            }
            OptionRow(title: "Motion", detail: "System follows macOS Reduce Motion.") {
                Stops(options: [("system", "System"), ("reduced", "Reduced")], selection: motion) { motion = $0 }
                    .accessibilityLabel("Motion")
            }
            SettingsFold(title: "Colors", detail: NativeThemeSettingsView.summary(for: colorScheme), isOpen: $showColors,
                         open: "Customize", close: "Done", label: "Customize colors", closingRule: false) {
                NativeThemeSettingsView()
            }
        }
    }

    private var launchBand: some View {
        Band("Launch", spacing: 0) {
            OptionRow(title: "On launch, open") {
                Stops(options: [(true, "Last visited"), (false, "Launch page")], selection: restoreLastPage) { restoreLastPage = $0 }
                    .accessibilityLabel("Restore last visited page")
            }
            OptionRow(title: "Launch page", detail: launchDetail) {
                Pick(
                    title: "Launch page",
                    selection: Binding(
                        get: {
                            NativeNavigationPreferences.initialPage(
                                startPage: startPage,
                                lastVisited: nil,
                                restoreLastPage: false,
                                installedPages: launchPages.map(\.rawValue)
                            ).rawValue
                        },
                        set: {
                            startPage = $0
                            restoreLastPage = false
                        }
                    ),
                    options: launchPages.map { ($0.rawValue, $0.title) },
                    width: 170
                )
            }
            OptionRow(title: "Welcome guide", detail: "The first-run screen: a starting task, look and spacing.") {
                Button("Show setup") { session.showOnboarding() }
            }
        }
    }
    private var launchDetail: String {
        let fallback = startPage == "battery" && batterySupported == false ? "Battery is unavailable here; Home opens instead. " : ""
        return fallback + (restoreLastPage ? "Used when no last page is stored. Choosing one switches to Launch page." : "")
    }

    private var diagnosticsBand: some View {
        Band("Diagnostics", spacing: 0) {
            NativeUIRecordingControls(runtime: runtime)
            storageRow("Data folder", "Results, transcripts, uploads, the database and job state.", runtime.paths.data)
            storageRow("Logs", "Local diagnostics and transport failure details.", runtime.paths.logs)
            storageRow("Config", "Providers and free API keys, copyable in the provider pages.", runtime.paths.providers)
            SettingsFold(title: "Report", detail: "Version, macOS, process, jobs and installed pages as text.", isOpen: $showDiagnostics,
                         open: "Show", close: "Hide", label: "Diagnostics report", accessory: {
                IconPress(icon: "copy", help: "Copy diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics + "\nStatus: " + startupStatus, forType: .string) }
                IconPress(icon: "save", help: "Save diagnostics") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "UniApi-diagnostics.txt"
                    panel.nativeBegin { response in
                        guard response == .OK, let url = panel.url else { return }
                        do { try (diagnostics + "\nStatus: " + startupStatus).write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
                    }
                }
            }) {
                Text(diagnostics + "\nStatus: " + startupStatus).font(Theme.mono(10.5)).foregroundStyle(Theme.dim).lineSpacing(3)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var launchPages: [NativeDestination] {
        NativeDestination.allCases.filter {
            NativeInstalledPages.destinations.contains($0) && NativeShellPolicy.admits($0.rawValue, batterySupported: batterySupported)
        }
    }
    private var startupStatus: String {
        NativeShellPolicy.startup(readOnly: runtime.paths.readOnly, prepared: session.preferencesPrepared, sessionError: session.error, health: health, pid: Int(ProcessInfo.processInfo.processIdentifier), instance: NativeHealth.instance)
    }
    private func reload() async {
        guard let subscription, reads.accepts(subscription), let ticket = reads.begin("diagnostics") else { return }
        var nextActiveJobs: Int?
        var nextJobsError: String?
        do { nextActiveJobs = try await runtime.jobs.activeCount() }
        catch {
            guard reads.accepts(ticket) else { return }
            nextJobsError = error.localizedDescription
        }
        guard reads.accepts(ticket) else { return }
        let nextHealth = (try? NativeFile.readJSON(runtime.paths.data.appendingPathComponent("native-status.json"))) ?? .null
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        let nextDiagnostics = "UniApi native \(version)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nPID \(ProcessInfo.processInfo.processIdentifier) · up for \(Int(runtime.uptime / 60)) min\n\(nextActiveJobs.map { "\($0) active jobs" } ?? "Active jobs unavailable: " + (nextJobsError ?? "unknown"))\nApps: \(NativeInstalledPages.destinations.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", "))\nRead-only: \(runtime.paths.readOnly ? "yes" : "no")"
        guard reads.accepts(ticket) else { return }
        activeJobs = nextActiveJobs; jobsError = nextJobsError; health = nextHealth; diagnostics = nextDiagnostics
    }
    private func storageRow(_ title: String, _ detail: String, _ url: URL) -> some View {
        SettingsRow(title: title, detail: detail) {
            HStack(spacing: 8) {
                Text(url.path).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .frame(maxWidth: 280, alignment: .trailing).help(url.path)
                IconPress(icon: "folder-open", help: title == "Config" ? "Reveal provider configuration" : title == "Logs" ? "Reveal logs" : "Reveal data folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .padding(.trailing, -7)
            }
        }
    }
}

private struct NativeUIRecordingControls: View {
    let runtime: NativeRuntime
    @ObservedObject private var recorder = NativeUIReadiness.shared
    private var detail: String {
        if recorder.manualRecording { return "Recording current app · stops automatically after 5 minutes" }
        if recorder.automaticRecording { return "Automatic read-only recording is active." }
        if runtime.paths.readOnly { return "Manual recording is unavailable in read-only mode." }
        return "Up to 5 minutes of page changes and Statistics reloads: timing, process CPU and peak memory, kept on this Mac. No prompts, model names or page content."
    }
    var body: some View {
        SettingsRow(title: "Performance recording", detail: detail) {
            HStack(spacing: 8) {
                if recorder.manualRecording { Tag("Recording", tone: Theme.signal, dot: true) }
                if let url = recorder.lastURL {
                    Button("Show recording") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(Press(.quiet))
                }
                if recorder.manualRecording {
                    Button("Stop recording") { recorder.stopRecording() }
                } else {
                    Button("Start recording") { recorder.startRecording(runtime: runtime) }
                        .disabled(runtime.paths.readOnly || recorder.automaticRecording)
                }
            }
        }
        if let error = recorder.recordingError { Notice(text: error, tone: .fail).accessibilityLabel("Error: " + error).padding(.vertical, 8) }
    }
}

// ======================================================================
// MARK: - Settings parts shared by the section views
// ======================================================================

/// A named state where a strip otherwise shows numerals: it hangs from the
/// same ticked rule as `Readout` and is set in the display face.
struct SettingsState: View {
    var label = "State"
    let name: String
    var detail = ""
    var tint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rule()
                (tint ?? Theme.ink).frame(width: 2, height: 7)
            }
            .frame(height: 7, alignment: .top).padding(.bottom, 9)
            MicroLabel(label)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                // An unseen numeral gives the name the line box and baseline of the readings beside it.
                Text("0").font(Theme.readout(34)).hidden().frame(width: 0)
                NativeNumberText(text: name, font: Theme.display(24), color: Theme.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .padding(.top, 5)
            if !detail.isEmpty {
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([name, detail].filter { !$0.isEmpty }.joined(separator: ". "))
    }
}

/// `OptionRow` for a control too wide to always share a line with its name:
/// below the width where both fit, the control drops beneath the text on the
/// left edge instead of squeezing the text into a narrow column.
struct SettingsRow<Control: View>: View {
    var title: String
    var detail: String = ""
    var ruled = true
    var minimumLabel: CGFloat = 220
    @ViewBuilder var control: () -> Control
    var body: some View {
        SettingsRowLayout(minimumLabel: minimumLabel) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                if !detail.isEmpty {
                    Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .overlay(alignment: .bottom) { if ruled { Rule() } }
    }
}

/// Measures the control at its own size, then gives the text what is left.
private struct SettingsRowLayout: Layout {
    var minimumLabel: CGFloat
    private let gap: CGFloat = 20
    private let drop: CGFloat = 10

    private func measure(_ width: CGFloat?, _ subviews: Subviews) -> (width: CGFloat, labels: CGSize, control: CGSize, stacked: Bool) {
        let ideal = subviews[1].sizeThatFits(.unspecified)
        let fallback = minimumLabel + gap + ideal.width
        let available = max(0, width.flatMap { $0.isFinite ? $0 : nil } ?? fallback)
        let stacked = ideal.width > 0 && available < fallback
        let control = stacked ? subviews[1].sizeThatFits(ProposedViewSize(width: available, height: nil)) : ideal
        let room = stacked || ideal.width == 0 ? available : max(0, available - gap - ideal.width)
        let labels = subviews[0].sizeThatFits(ProposedViewSize(width: room, height: nil))
        return (available, CGSize(width: room, height: labels.height), control, stacked)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // A row with no control is its text at the full width.
        if subviews.count == 1 {
            let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumLabel
            return CGSize(width: width, height: subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        }
        guard subviews.count == 2 else { return .zero }
        let m = measure(proposal.width, subviews)
        return CGSize(width: m.width, height: m.stacked ? m.labels.height + drop + m.control.height : max(m.labels.height, m.control.height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if subviews.count == 1 {
            subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            return
        }
        guard subviews.count == 2 else { return }
        let m = measure(bounds.width, subviews)
        let labelY = m.stacked ? bounds.minY : bounds.midY - m.labels.height / 2
        subviews[0].place(at: CGPoint(x: bounds.minX, y: labelY), anchor: .topLeading, proposal: ProposedViewSize(m.labels))
        let point = m.stacked ? CGPoint(x: bounds.minX, y: bounds.minY + m.labels.height + drop)
                              : CGPoint(x: bounds.maxX - m.control.width, y: bounds.midY - m.control.height / 2)
        subviews[1].place(at: point, anchor: .topLeading, proposal: ProposedViewSize(m.control))
    }
}

/// The page's sections on one line; choosing one brings it to the top.
struct SettingsIndex: View {
    let sections: [(id: String, title: String)]
    let jump: (String) -> Void
    private var row: some View {
        HStack(spacing: 20) {
            MicroLabel("Jump to", color: Theme.faint)
            ForEach(sections, id: \.id) { section in
                SettingsIndexLink(title: section.title) { jump(section.id) }
            }
        }
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row.fixedSize()
            ScrollView(.horizontal) { row.fixedSize() }.scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsIndexLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                (hovering ? Theme.signal : Theme.faint).frame(width: hovering ? 2 : 1, height: 9).frame(width: 2)
                Text(title).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(hovering ? Theme.ink : Theme.dim)
            }
            .frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityLabel("Jump to " + title)
    }
}

/// A setting whose detail is too large for a row: the row states the current
/// value and its button grows the editor out beneath it.
struct SettingsFold<Accessory: View, Content: View>: View {
    var title: String
    var detail: String = ""
    @Binding var isOpen: Bool
    var open = "Edit"
    var close = "Done"
    var label: String
    /// Off when the content already ends on a ruled row.
    var closingRule = true
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OptionRow(title: title, detail: detail, ruled: !isOpen) {
                HStack(spacing: 8) {
                    accessory()
                    Button {
                        if reduceMotion { isOpen.toggle() }
                        else { withAnimation(.spring(duration: 0.28, bounce: 0)) { isOpen.toggle() } }
                    } label: {
                        HStack(spacing: 6) {
                            ZStack {
                                Text(open).hidden(); Text(close).hidden()
                                Text(isOpen ? close : open)
                            }
                            NativeIcon("chevron-down", size: 12, strokeWidth: 1.75)
                                .rotationEffect(.degrees(isOpen ? 180 : 0))
                        }
                    }
                    .buttonStyle(Press(.secondary))
                    .accessibilityLabel(label).accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                }
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    content().padding(.top, 6).padding(.bottom, closingRule ? 22 : 0)
                    if closingRule { Rule() }
                }
                .transition(.opacity)
            }
        }
    }
}

extension SettingsFold where Accessory == EmptyView {
    init(title: String, detail: String = "", isOpen: Binding<Bool>, open: String = "Edit", close: String = "Done",
         label: String, closingRule: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, detail: detail, isOpen: isOpen, open: open, close: close, label: label,
                  closingRule: closingRule, accessory: { EmptyView() }, content: content)
    }
}

/// A measured setting on a graduated rule. The filled run is ink; the signal
/// needle marks the chosen value.
struct SettingsRuleSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var divisions: Int = 14
    var width: CGFloat = 168
    var label: String
    @State private var origin: (x: CGFloat, value: Double)?
    @Environment(\.isEnabled) private var enabled

    private var span: Double { range.upperBound - range.lowerBound }
    private var fraction: CGFloat { CGFloat(max(0, min(1, (value - range.lowerBound) / span))) }
    private func clamp(_ next: Double) -> Double { min(range.upperBound, max(range.lowerBound, next.rounded())) }

    var body: some View {
        GeometryReader { geometry in
            let x = (width - 2) * fraction
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.track).frame(width: width, height: 2).offset(y: 9)
                Rectangle().fill(Theme.ink).frame(width: x + 1, height: 2).offset(y: 9)
                TickScale(divisions: divisions, major: 7, minorHeight: 3, majorHeight: 5).fill(Theme.faint)
                    .frame(width: width, height: 5).offset(y: 14)
                Theme.signal.frame(width: 2, height: 14).offset(x: x, y: 3)
            }
            .frame(width: width, height: 24, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    // The pointer is followed in window space: changing this
                    // value can move the page under it.
                    if origin == nil {
                        let local = drag.startLocation.x - geometry.frame(in: .global).minX
                        origin = (drag.startLocation.x, range.lowerBound + span * Double(max(0, min(1, local / width))))
                    }
                    guard let origin else { return }
                    let next = clamp(origin.value + span * Double((drag.location.x - origin.x) / width))
                    if next != value { value = next }
                }
                .onEnded { _ in origin = nil })
        }
        .frame(width: width, height: 24)
        .opacity(enabled ? 1 : 0.4)
        .pointingHand(enabled)
        .accessibilityRepresentation { Slider(value: $value, in: range).accessibilityLabel(label) }
    }
}
