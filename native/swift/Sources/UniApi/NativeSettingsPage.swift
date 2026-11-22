import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

struct NativeSettingsPage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @Environment(\.nativeBatterySupported) private var batterySupported
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
    @AppStorage("uniapi-settings-category") private var category = "appearance"
    @State private var query = ""
    @State private var reads = NativePageReadScope()
    @State private var subscription: NativePageReadScope.Ticket?
    private static let categories: [(id: String, title: String, icon: String, terms: String)] = [
        ("appearance", "Appearance", "sun", "color scheme light dark auto theme page spacing compact spacious density motion reduced animation"),
        ("colors", "Colors", "layers", "customize colors accent palette theme background text border"),
        ("launch", "Launch", "rocket", "launch page start restore last visited"),
        ("sidebar", "Sidebar", "panel-left", "sidebar expanded width badges pages order hide reorder"),
        ("telegram", "Telegram", "messages-square", "telegram bot token chat notifications"),
        ("updates", "Updates", "download", "update version check install guided setup onboarding"),
        ("diagnostics", "Diagnostics", "circuit-board", "diagnostics storage logs data config performance recording copy save reveal status")
    ]
    private var matches: [(id: String, title: String, icon: String, terms: String)] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return Self.categories }
        return Self.categories.filter { item in words.allSatisfy { (item.title.lowercased() + " " + item.terms).contains($0) } }
    }
    /// The category on show: the chosen one, or the first that matches the search.
    private var shown: String? { matches.contains { $0.id == category } ? category : matches.first?.id }
    var body: some View {
        NativePage(title: "Settings", maxWidth: .infinity, readiness: error != nil || jobsError != nil || session.error != nil ? .failed : diagnostics.isEmpty ? .pending : .ready, scrolls: false) {
            GeometryReader { geometry in
                if geometry.size.width >= 620 {
                    HStack(spacing: 0) {
                        rail.frame(width: 212)
                        Theme.border.frame(width: 1)
                        pane
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        NativeMenuSelect(title: "Category", selection: $category, options: Self.categories.map { ($0.id, $0.title) }, width: 180)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                        Theme.border.frame(height: 1)
                        pane
                    }
                }
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
    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            T3Field(placeholder: "Search settings", text: $query, leadingIcon: "search").accessibilityLabel("Search settings")
                .padding(.bottom, 10)
            ForEach(matches, id: \.id) { item in
                NativeSettingsCategoryRow(title: item.title, icon: item.icon, selected: shown == item.id) { category = item.id }
            }
            if matches.isEmpty { Text("No setting matches").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).padding(.horizontal, 8).padding(.top, 4) }
            Spacer(minLength: 0)
        }
        .padding(.leading, 16).padding(.trailing, 12).padding(.top, 16)
        .focusable().focusEffectDisabled()
        .onMoveCommand { direction in
            guard let index = matches.firstIndex(where: { $0.id == shown }) else { return }
            let next = direction == .down ? index + 1 : direction == .up ? index - 1 : index
            if next != index, matches.indices.contains(next) { category = matches[next].id }
        }
    }
    private var pane: some View {
        NativePane(maxWidth: 720, centered: false) {
            if let error { NativeError(message: error) }
            Group {
                switch shown {
                case "appearance":
                    SettingRow(title: "Color scheme") {
                        T3Segmented(options: [("light", "Light"), ("dark", "Dark"), ("auto", "Auto")], selection: appearance,
                                    icons: ["light": "sun", "dark": "moon", "auto": "monitor"]) { appearance = $0 }
                            .accessibilityLabel("Color scheme")
                    }
                    SettingRow(title: "Page spacing") {
                        T3Segmented(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                            .accessibilityLabel("Page spacing")
                    }
                    SettingRow(title: "Motion", desc: "System follows macOS Reduce Motion.") {
                        T3Segmented(options: [("system", "System"), ("reduced", "Reduced")], selection: motion) { motion = $0 }
                            .accessibilityLabel("Motion")
                    }
                case "colors": NativeThemeSettingsView()
                case "launch": navigationSettings
                case "sidebar": NativeSidebarSettingsView()
                case "telegram": NativeTelegramSettingsView(runtime: runtime)
                case "updates":
                    NativeUpdateSettings(model: session.updates)
                    SettingRow(title: "Guided setup", desc: "Choose a starting task again.") {
                        Button("Show setup") { session.showOnboarding() }
                    }
                case "diagnostics": diagnosticsSettings
                default: EmptyView()
                }
            }
            .environment(\.nativeSectionStyle, .bare)
            .id(shown)
        }
    }
    @ViewBuilder private var diagnosticsSettings: some View {
        Text(statusSummary).font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted).textSelection(.enabled)
        if let jobsError { NativeError(message: "Active jobs unavailable: " + jobsError) }
        if let startupError = session.error { NativeError(message: "Startup failed: " + startupError) }
        VStack(alignment: .leading, spacing: 10) {
            Text(diagnostics + "\nStatus: " + startupStatus).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineSpacing(2)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12).background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            HStack(spacing: 8) {
                Button("Copy", nativeIcon: "copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics + "\nStatus: " + startupStatus, forType: .string) }
                    .accessibilityLabel("Copy diagnostics")
                Button("Save", nativeIcon: "download") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "UniApi-diagnostics.txt"
                    panel.nativeBegin { response in
                        guard response == .OK, let url = panel.url else { return }
                        do { try (diagnostics + "\nStatus: " + startupStatus).write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
                    }
                }.accessibilityLabel("Save diagnostics")
                Spacer(minLength: 0)
                T3IconButton(system: "refresh-cw", help: "Reload") { Task { await reload() } }
            }
        }
        NativeStack {
            storageRow("Data", "Results, transcripts, uploads, the database and job state", runtime.paths.data)
            storageRow("Logs", "Local diagnostics and transport failure details", runtime.paths.logs)
            storageRow("Config", "Providers and free API keys", runtime.paths.providers)
        }
        NativeUIRecordingControls(runtime: runtime)
    }
    @ViewBuilder private var navigationSettings: some View {
            SettingRow(
                title: "Launch page",
                desc: startPage == "battery" && batterySupported == false ? "Battery is unavailable; fallback is Home. Choosing a page turns off Restore last visited page." : "Choosing a page turns off Restore last visited page.",
                descVariants: ["Choosing a page turns off Restore last visited page.", "Battery is unavailable; fallback is Home. Choosing a page turns off Restore last visited page."]
            ) {
                NativeMenuSelect(
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
            SettingRow(title: "Restore last visited page", desc: "Off opens the launch page instead.") {
                T3Switch(isOn: $restoreLastPage).accessibilityLabel("Restore last visited page")
            }
    }
    private var launchPages: [NativeDestination] {
        NativeDestination.allCases.filter {
            $0.host == $0 && NativeInstalledPages.destinations.contains($0) && NativeShellPolicy.admits($0.rawValue, batterySupported: batterySupported)
        }
    }
    private var startupStatus: String {
        NativeShellPolicy.startup(readOnly: runtime.paths.readOnly, prepared: session.preferencesPrepared, sessionError: session.error, health: health, pid: Int(ProcessInfo.processInfo.processIdentifier), instance: NativeHealth.instance)
    }
    private var statusSummary: String {
        let jobs = activeJobs.map { "\($0) active " + ($0 == 1 ? "job" : "jobs") } ?? "Active jobs unavailable"
        return startupStatus + " · Up for \(Int(runtime.uptime / 60)) min · " + jobs
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
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(Theme.ui(Theme.textSm, weight: .medium))
                    Text(detail).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Text(url.path).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Reveal", nativeIcon: "folder-open") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .buttonStyle(T3Button(.ghost))
                .accessibilityLabel(title == "Config" ? "Reveal provider configuration" : title == "Logs" ? "Reveal logs" : "Reveal data folder")
        }.padding(.vertical, 10)
    }
}

private struct NativeSettingsCategoryRow: View {
    let title: String, icon: String, selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                NativeIcon(icon, size: 15).foregroundStyle(selected ? Theme.ink : Theme.muted).frame(width: 18).accessibilityHidden(true)
                Text(title).font(Theme.ui(Theme.textSm, weight: selected ? .medium : .regular)).foregroundStyle(selected ? Theme.ink : Theme.dim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).frame(height: 30)
            .background(selected ? Theme.raised : hovering ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay { if selected { RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(Theme.border, lineWidth: 1) } }
            .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(Theme.accent).frame(width: 2, height: 14).offset(x: -5).opacity(selected ? 1 : 0) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct NativeUIRecordingControls: View {
    let runtime: NativeRuntime
    @ObservedObject private var recorder = NativeUIReadiness.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance recording").font(Theme.ui(Theme.textSm, weight: .medium))
            Text("Records page changes and Statistics reloads for up to 5 minutes: timing, process CPU and peak memory. No prompts, model names or page content; nothing leaves this Mac.")
                .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if recorder.manualRecording {
                    Button("Stop recording") { recorder.stopRecording() }
                } else {
                    Button("Start recording") { recorder.startRecording(runtime: runtime) }
                        .disabled(runtime.paths.readOnly || recorder.automaticRecording)
                }
                if let url = recorder.lastURL {
                    Button("Show recording") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            if recorder.manualRecording {
                Text("Recording. Stops by itself after 5 minutes.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.link)
            } else if recorder.automaticRecording {
                Text("Automatic read-only recording is active.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
            } else if runtime.paths.readOnly {
                Text("Manual recording is unavailable in read-only mode.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
            }
            if let error = recorder.recordingError { NativeError(message: error) }
        }
    }
}
