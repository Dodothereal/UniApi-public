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
            T3IconButton(icon: "rotate-cw", help: "Reload") { Task { await reload() } }
        }) {
            VStack(alignment: .leading, spacing: 0) {
            NativeGutterGroup(title: "Appearance") {
                SettingRow(title: "Color scheme") {
                    T3Segmented(options: [("dark", "Dark"), ("light", "Light"), ("auto", "Auto")], selection: appearance) { appearance = $0 }
                        .accessibilityLabel("Color scheme")
                }
                SettingRow(title: "Spacing") {
                    T3Segmented(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                        .accessibilityLabel("Page spacing")
                }
                SettingRow(title: "Motion") {
                    T3Segmented(options: [("system", "System"), ("reduced", "Reduced")], selection: motion) { motion = $0 }
                        .accessibilityLabel("Motion")
                }
                DisclosureGroup("Customize colors") {
                    NativeThemeSettingsView().padding(.top, 12)
                }.font(Theme.ui(12))
            }
            navigationSettings
            NativeGutterGroup(title: "Sidebar") { NativeSidebarSettingsView() }
            NativeGutterGroup(title: "Telegram") { NativeTelegramSettingsView(runtime: runtime) }
            NativeGutterGroup(title: "UniApi") {
                SettingRow(title: "Setup guide") { Button("Open") { session.showOnboarding() } }
                Text(statusSummary).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                NativeUpdateSettings(model: session.updates)
                DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 16) {
                        NativeUIRecordingControls(runtime: runtime)
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
                        storageRow("Data folder", "", runtime.paths.data)
                        storageRow("Logs", "", runtime.paths.logs)
                        storageRow("Config", "", runtime.paths.providers)
                    }.padding(.top, 12)
                }.font(Theme.ui(12))
                if let jobsError { NativeError(message: "Active jobs unavailable: " + jobsError) }
                if let startupError = session.error { NativeError(message: "Startup failed: " + startupError) }
            }
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
        NativeGutterGroup(title: "Launch") {
            SettingRow(title: "Reopen the last page") {
                T3Switch(isOn: $restoreLastPage).accessibilityLabel("Restore last visited page")
            }
            SettingRow(
                title: "Open on",
                desc: startPage == "battery" && batterySupported == false ? "Battery is unavailable here; Home opens instead." : nil
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
                Text(url.path).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                HStack(spacing: 6) { NativeIcon("folder-open", size: 12); Text("Reveal") }
            }.accessibilityLabel(title == "Config" ? "Reveal provider configuration" : title == "Logs" ? "Reveal logs" : "Reveal data folder")
        }
    }
}

private struct NativeUIRecordingControls: View {
    let runtime: NativeRuntime
    @ObservedObject private var recorder = NativeUIReadiness.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance recording").font(Theme.ui(14, weight: .medium))
            Text("Timing, CPU and peak memory for up to 5 minutes. No prompts, model names or page content.")
                .font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
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
                Text("Recording current app · stops automatically after 5 minutes").font(Theme.ui(12)).foregroundStyle(Theme.accent)
            } else if recorder.automaticRecording {
                Text("Automatic read-only recording is active.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            } else if runtime.paths.readOnly {
                Text("Manual recording is unavailable in read-only mode.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
            if let error = recorder.recordingError { NativeError(message: error) }
        }
    }
}
