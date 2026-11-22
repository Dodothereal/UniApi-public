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
        NativePage(title: "Settings", readiness: error != nil || jobsError != nil || session.error != nil ? .failed : diagnostics.isEmpty ? .pending : .ready, actions: {
            T3IconButton(system: "refresh-cw", help: "Reload") { Task { await reload() } }
        }) {
            if let error { NativeError(message: error) }
            NativeSheet {
                NativeSection("Appearance") {
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
                    NativeDisclosure("Customize colors") {
                        NativeThemeSettingsView()
                    }
                }
                navigationSettings
                NativeSidebarSettingsView()
                NativeTelegramSettingsView(runtime: runtime)
                NativeSection("Application", detail: statusSummary) {
                    NativeUpdateSettings(model: session.updates)
                    SettingRow(title: "Guided setup", desc: "Choose a starting task again.") {
                        Button("Show setup") { session.showOnboarding() }
                    }
                    if let jobsError { NativeError(message: "Active jobs unavailable: " + jobsError) }
                    if let startupError = session.error { NativeError(message: "Startup failed: " + startupError) }
                    NativeDisclosure("Diagnostics and storage", isExpanded: $showDiagnostics) {
                        VStack(alignment: .leading, spacing: 18) {
                            NativeUIRecordingControls(runtime: runtime)
                            VStack(alignment: .leading, spacing: 10) {
                                Text(diagnostics + "\nStatus: " + startupStatus).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineSpacing(2)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(12).background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                                HStack(spacing: 8) {
                                    Button("Copy diagnostics", nativeIcon: "copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics + "\nStatus: " + startupStatus, forType: .string) }
                                    Button("Save diagnostics", nativeIcon: "download") {
                                        let panel = NSSavePanel(); panel.nameFieldStringValue = "UniApi-diagnostics.txt"
                                        panel.nativeBegin { response in
                                            guard response == .OK, let url = panel.url else { return }
                                            do { try (diagnostics + "\nStatus: " + startupStatus).write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
                                        }
                                    }
                                }
                            }
                            Card(padding: 0) {
                                NativeStack {
                                    storageRow("Data", "Results, transcripts, uploads, the database and job state", runtime.paths.data)
                                    storageRow("Logs", "Local diagnostics and transport failure details", runtime.paths.logs)
                                    storageRow("Config", "Providers and free API keys", runtime.paths.providers)
                                }
                            }
                        }
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
    private var navigationSettings: some View {
        NativeSection("Launch") {
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
        }.padding(.horizontal, 14).padding(.vertical, 10)
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
