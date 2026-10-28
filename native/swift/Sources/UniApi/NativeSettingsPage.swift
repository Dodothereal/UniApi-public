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
    @State private var showDiagnostics = false
    @State private var reads = NativePageReadScope()
    @State private var subscription: NativePageReadScope.Ticket?
    var body: some View {
        NativePage(title: "Settings", subtitle: "Appearance, navigation and optional Telegram delivery. Providers are configured in the provider pages.", readiness: error != nil || jobsError != nil || session.error != nil ? .failed : diagnostics.isEmpty ? .pending : .ready, actions: {
            Button { Task { await reload() } } label: { HStack(spacing: 6) { NativeIcon("rotate-cw", size: 12); Text("Reload") } }
        }) {
            VStack(alignment: .leading, spacing: 20) {
                SectionLabel("Setup")
                SettingRow(title: "Guided setup", desc: "Review application basics, provider setup and where optional configuration lives.") {
                    Button("Show setup") { session.showOnboarding() }
                }
            }
            navigationSettings
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 16) {
                SectionLabel("Appearance")
                SettingRow(title: "Color scheme", desc: "Choose a theme or follow macOS.") {
                    T3Segmented(options: [("dark", "Dark"), ("light", "Light"), ("auto", "Auto")], selection: appearance) { appearance = $0 }
                        .accessibilityLabel("Color scheme")
                }
                SettingRow(title: "Page spacing", desc: "Adjust margins and card padding.") {
                    T3Segmented(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                        .accessibilityLabel("Page spacing")
                }
                SettingRow(title: "Motion", desc: "System follows macOS Reduce Motion.") {
                    T3Segmented(options: [("system", "System"), ("reduced", "Reduced")], selection: motion) { motion = $0 }
                        .accessibilityLabel("Motion")
                }
                DisclosureGroup("Customize colors") {
                    NativeThemeSettingsView().padding(.top, 12)
                }.font(Theme.ui(12))
            }
            Rectangle().fill(Theme.border).frame(height: 1)
            NativeSidebarSettingsView()
            Rectangle().fill(Theme.border).frame(height: 1)
            NativeTelegramSettingsView(runtime: runtime)
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 20) {
                SectionLabel("Application")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Status").font(Theme.ui(14, weight: .medium))
                    Text(statusSummary).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
                DisclosureGroup("Diagnostics and storage", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(diagnostics + "\nStatus: " + startupStatus).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        HStack {
                            Button("Copy diagnostics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics + "\nStatus: " + startupStatus, forType: .string) }
                            Button("Save diagnostics") {
                                let panel = NSSavePanel(); panel.nameFieldStringValue = "UniApi-diagnostics.txt"
                                panel.nativeBegin { response in
                                    guard response == .OK, let url = panel.url else { return }
                                    do { try (diagnostics + "\nStatus: " + startupStatus).write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
                                }
                            }
                        }
                        storageRow("Data folder", "Results, transcripts, uploads, the database and job state.", runtime.paths.data)
                        storageRow("Logs", "Local diagnostics and transport failure details.", runtime.paths.logs)
                        storageRow("Config", "Providers and free API keys, copyable in the provider pages.", runtime.paths.providers)
                    }.padding(.top, 12)
                }.font(Theme.ui(12))
                if let jobsError { NativeError(message: "Active jobs unavailable: " + jobsError) }
                if let startupError = session.error { NativeError(message: "Startup failed: " + startupError) }
            }
            if let error { NativeError(message: error) }
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
    private var navigationSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Navigation")
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
            SettingRow(title: "Restore last visited page", desc: "On by default. The launch page is used when this is off or no valid previous page is stored.") {
                T3Switch(isOn: $restoreLastPage).accessibilityLabel("Restore last visited page")
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
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.ui(14, weight: .medium))
                Text(detail).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                Text(url.path).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                HStack(spacing: 6) { NativeIcon("folder-open", size: 12); Text("Reveal") }
            }.accessibilityLabel(title == "Config" ? "Reveal provider configuration" : title == "Logs" ? "Reveal logs" : "Reveal data folder")
        }
    }
}
