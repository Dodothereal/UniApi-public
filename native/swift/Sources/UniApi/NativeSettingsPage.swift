import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

struct NativeSettingsPage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @AppStorage("uniapi-theme") private var appearance = "auto"
    @AppStorage("uniapi-density") private var density = "standard"
    @AppStorage("uniapi-motion") private var motion = "system"
    @AppStorage("uniapi-sidebar") private var sidebarOpen = true
    @AppStorage("uniapi-sidebar-width") private var sidebarWidth = NativeSidebarLayout.defaultWidth
    @AppStorage("uniapi-sidebar-order") private var sidebarOrder = ""
    @State private var notificationConfig = NativeNotifications.Configuration()
    @State private var notificationStatus = "External delivery is off until explicitly configured and saved."
    @State private var notificationLoaded = false
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
                SectionLabel("Appearance")
                SettingRow(title: "Color scheme", desc: appearanceDescription, descVariants: ["Follows the system appearance, and switches with it.", "T3 Code's light tokens; the window and the mark follow.", "The app was designed dark."]) {
                    T3Segmented(options: [("dark", "Dark"), ("light", "Light"), ("auto", "Auto")], selection: appearance) { appearance = $0 }
                        .accessibilityLabel("Color scheme")
                }
                SettingRow(title: "Page spacing", desc: "Adjust page margins and card padding. Buttons keep the same consistent size.") {
                    T3Segmented(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                        .accessibilityLabel("Page spacing")
                }
                SettingRow(title: "Motion", desc: "System respects macOS Reduce Motion. Reduced keeps animated readings and artwork still.") {
                    T3Segmented(options: [("system", "System"), ("reduced", "Reduced")], selection: motion) { motion = $0 }
                        .accessibilityLabel("Motion")
                }
                SettingRow(title: "Sidebar", desc: "Keep navigation visible. Command-B toggles it from any page.") {
                    T3Switch(isOn: $sidebarOpen).accessibilityLabel("Show sidebar")
                }
            }
            sidebarSettings
            Rectangle().fill(Theme.border).frame(height: 1)
            notificationSettings
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 20) {
                SectionLabel("Application")
                SettingRow(title: "Status", desc: statusSummary) {
                    VStack(alignment: .trailing, spacing: 8) {
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics + "\nStatus: " + startupStatus, forType: .string) } label: {
                            HStack(spacing: 6) { NativeIcon("copy", size: 12); Text("Copy diagnostics") }
                        }
                        Button {
                            let panel = NSSavePanel(); panel.nameFieldStringValue = "UniApi-diagnostics.txt"
                            panel.nativeBegin { response in
                                guard response == .OK, let url = panel.url else { return }
                                do { try (diagnostics + "\nStatus: " + startupStatus).write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
                            }
                        } label: { HStack(spacing: 6) { NativeIcon("download", size: 12); Text("Save diagnostics") } }
                    }
                }.textSelection(.enabled)
                DisclosureGroup("Diagnostic details", isExpanded: $showDiagnostics) {
                    Text(diagnostics + "\nStatus: " + startupStatus).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(Theme.ui(12)).foregroundStyle(Theme.muted)
                if let jobsError { NativeError(message: "Active jobs unavailable: " + jobsError) }
                if let startupError = session.error { NativeError(message: "Startup failed: " + startupError) }
                storageRow("Data folder", "Results, transcripts, uploads, the database and job state.", runtime.paths.data)
                storageRow("Logs", "Local diagnostics and transport failure details.", runtime.paths.logs)
                storageRow("Config", "Providers and free API keys, copyable in the provider pages.", runtime.paths.providers)
            }
            if let error { NativeError(message: error) }
        }.onAppear { loadNotifications() }.nativePageTask {
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
    private var sidebarSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Sidebar layout")
            SettingRow(title: "Width", desc: "Choose a width between 180 and 320 points.") {
                HStack {
                    Slider(value: $sidebarWidth, in: 180...320).tint(Theme.accent).frame(width: 160).accessibilityLabel("Sidebar width")
                    Text("\(Int(NativeSidebarLayout.width(sidebarWidth))) pt").font(Theme.mono(11))
                }
            }
            Text("Reorder sections and their pages. Home, Jobs and Settings stay anchored.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            ForEach(NativeSidebarLayout.orderedSections(sidebarOrder), id: \.self) { section in
                let sections = NativeSidebarLayout.orderedSections(sidebarOrder)
                let pages = NativeSidebarLayout.pages(sidebarOrder).filter { $0.section == section }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(section).font(Theme.ui(13, weight: .medium)); Spacer()
                        Button("Up") { moveSection(section, by: -1) }.disabled(sections.first == section).accessibilityLabel("Move " + section + " section up")
                        Button("Down") { moveSection(section, by: 1) }.disabled(sections.last == section).accessibilityLabel("Move " + section + " section down")
                    }
                    ForEach(pages) { page in
                        HStack {
                            Text(page.title).font(Theme.ui(12)); Spacer()
                            Button("Up") { movePage(page, by: -1) }.disabled(pages.first == page).accessibilityLabel("Move " + page.title + " up")
                            Button("Down") { movePage(page, by: 1) }.disabled(pages.last == page).accessibilityLabel("Move " + page.title + " down")
                        }.padding(.leading, 12)
                    }
                }
            }
            Button("Restore sidebar layout defaults") { sidebarWidth = NativeSidebarLayout.defaultWidth; sidebarOrder = "" }
        }
    }
    private func movePage(_ page: NativeDestination, by offset: Int) {
        var pages = NativeSidebarLayout.pages(sidebarOrder)
        let siblings = pages.indices.filter { pages[$0].section == page.section }
        guard let index = pages.firstIndex(of: page), let rank = siblings.firstIndex(of: index), siblings.indices.contains(rank + offset) else { return }
        pages.swapAt(index, siblings[rank + offset]); sidebarOrder = pages.map(\.rawValue).joined(separator: ",")
    }
    private func moveSection(_ section: String, by offset: Int) {
        var sections = NativeSidebarLayout.orderedSections(sidebarOrder)
        guard let index = sections.firstIndex(of: section), sections.indices.contains(index + offset) else { return }
        sections.swapAt(index, index + offset)
        let pages = NativeSidebarLayout.pages(sidebarOrder)
        sidebarOrder = sections.flatMap { section in pages.filter { $0.section == section } }.map(\.rawValue).joined(separator: ",")
    }
    private var notificationSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Telegram notifications")
            Text("Optional external delivery uses only this app's saved configuration. Saving does not send a test message.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            SettingRow(title: "Enable external delivery", desc: "Off by default. Enabling requires a bot token and chat ID, then Save.") {
                T3Switch(isOn: $notificationConfig.enabled).accessibilityLabel("Enable Telegram delivery")
            }
            SecureField("Bot token", text: $notificationConfig.token).textFieldStyle(.roundedBorder).accessibilityLabel("Telegram bot token")
            TextField("Chat ID", text: $notificationConfig.chat).textFieldStyle(.roundedBorder).accessibilityLabel("Telegram chat ID")
            Text("Stored privately in Library/Application Support/UniApi/notifications.json under this app's home.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            HStack {
                Button("Save notification settings") { saveNotifications() }
                Button("Reload saved settings") { notificationLoaded = false; loadNotifications() }
            }
            Text(notificationStatus).font(Theme.ui(12)).foregroundStyle(Theme.muted).accessibilityLabel("Notification status: " + notificationStatus)
        }.disabled(runtime.paths.readOnly)
    }
    private func loadNotifications() {
        guard !notificationLoaded else { return }
        notificationLoaded = true
        do {
            notificationConfig = try NativeNotifications.configuration(home: runtime.paths.home)
            notificationStatus = notificationConfig.enabled ? "Saved configuration enables Telegram delivery. Delivery has not been tested." : "Saved configuration has external delivery off."
        } catch {
            notificationConfig = .init()
            notificationStatus = "Notification configuration could not be loaded. Delivery requires valid saved configuration."
        }
    }
    private func saveNotifications() {
        do {
            try runtime.paths.assertWritable()
            try NativeNotifications.save(notificationConfig, home: runtime.paths.home)
            notificationStatus = notificationConfig.enabled ? "Saved: Telegram delivery enabled. Delivery has not been tested." : "Saved: external delivery off."
        } catch { notificationStatus = "Could not save notification settings. Check the fields and private storage access." }
    }
    private var appearanceDescription: String {
        appearance == "auto" ? "Follows the system appearance, and switches with it." : appearance == "light" ? "T3 Code's light tokens; the window and the mark follow." : "The app was designed dark."
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
