import SwiftUI
import UniApiCore

/// The updater's last published state, shared by Settings and the sidebar.
@MainActor final class NativeUpdateModel: ObservableObject {
    @Published private(set) var state: JSONValue = .null
    var restore: (() -> Void)?

    var phase: String { state["phase"].string }
    var latest: String { state["staged"].string.isEmpty ? state["latest"].string : state["staged"].string }
    /// A release is downloaded and verified, or is being installed.
    var actionable: Bool { ["ready", "waiting", "installing"].contains(phase) }

    func apply(_ next: JSONValue) {
        // A refused or rolled-back installation leaves this process running
        // with its window put away; bring it back so the reason is visible.
        if phase == "installing", next["phase"].string == "failed" { restore?() }
        if state != next { state = next }
    }

    var summary: String {
        let current = state["current"].string
        let running = current.isEmpty ? "This build has no release version." : "UniApi \(current) is installed."
        switch phase {
        case "checking": return running + " Checking GitHub for a newer release."
        case "current": return running + " This is the newest release."
        case "downloading": return "Downloading UniApi \(latest), \(Int((state["progress"].double * 100).rounded())) percent."
        case "ready": return "UniApi \(latest) is downloaded and verified. Installing takes under a minute; the window closes and reopens, and providers, data and settings are kept."
        case "waiting", "installing", "failed", "unavailable": return state["message"].string
        default: return running
        }
    }
}

/// Settings > Application: release check, one-click install and the automatic check preference.
struct NativeUpdateSettings: View {
    @ObservedObject var model: NativeUpdateModel
    @EnvironmentObject private var session: NativeAppSession
    @AppStorage(NativeAppSession.automaticUpdateKey) private var automatic = true

    var body: some View {
        let phase = model.phase
        SettingRow(title: "Software update", desc: model.summary) {
            HStack(spacing: 8) {
                switch phase {
                case "ready":
                    Button { session.installUpdate() } label: {
                        HStack(spacing: 6) { NativeIcon("download", size: 12); Text("Update to " + model.latest) }
                    }.buttonStyle(T3Button(.primary))
                case "waiting":
                    Button("Cancel") { Task { await session.updater?.cancelInstall() } }.buttonStyle(T3Button(.outline))
                case "installing":
                    ShimmerText(text: "Installing…")
                case "checking":
                    ShimmerText(text: "Checking…")
                case "downloading":
                    NativeGrowBar(fraction: model.state["progress"].double, height: 6, entrance: false).frame(width: 120)
                        .accessibilityLabel("Download progress").accessibilityValue("\(Int(model.state["progress"].double * 100)) percent")
                case "unavailable":
                    EmptyView()
                default:
                    if phase == "failed", !model.state["staged"].string.isEmpty {
                        Button("Try again") { session.installUpdate() }.buttonStyle(T3Button(.primary))
                    }
                    Button("Check for updates") { Task { await session.updater?.check() } }.buttonStyle(T3Button(.outline))
                }
            }
        }
        if phase != "unavailable" {
            SettingRow(title: "Check for updates automatically", desc: "Downloads a newer GitHub release in the background. Nothing installs until you choose to update.") {
                T3Switch(isOn: $automatic).accessibilityLabel("Check for updates automatically")
            }
        }
    }
}

/// Sidebar footer: appears only once a newer release is ready to install.
struct NativeUpdateSidebarButton: View {
    @ObservedObject var model: NativeUpdateModel
    @EnvironmentObject private var session: NativeAppSession

    var body: some View {
        if model.actionable {
            let phase = model.phase
            Button { if phase == "ready" { session.installUpdate() } } label: {
                HStack(spacing: 7) {
                    NativeIcon("download", size: 13)
                    Text(phase == "ready" ? "Update to " + model.latest : phase == "waiting" ? "Updating when idle" : "Installing update")
                        .font(Theme.ui(11.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9).frame(height: 28).frame(maxWidth: .infinity)
                .foregroundStyle(Theme.onInk)
                .background(Theme.ink.opacity(phase == "ready" ? 1 : 0.55), in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(phase != "ready")
            .help(phase == "ready" ? "Installs UniApi \(model.latest) now. Providers, data and settings are kept." : model.state["message"].string)
            .accessibilityLabel(phase == "ready" ? "Update to UniApi " + model.latest : "Update in progress")
        }
    }
}
