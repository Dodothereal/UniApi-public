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
    /// A verified release is waiting, either fresh or after a refused attempt.
    var installable: Bool { phase == "ready" || phase == "failed" && !state["staged"].string.isEmpty }

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

    /// The state in two or three words, for a reading rather than a sentence.
    var brief: String {
        switch phase {
        case "checking": return "Checking for a release"
        case "current": return "Newest release"
        case "downloading": return "Downloading " + latest
        case "ready": return latest + " ready to install"
        case "waiting": return latest + " installs when idle"
        case "installing": return "Installing " + latest
        case "failed": return "Update did not finish"
        case "unavailable": return "Updates unavailable"
        default: return "Not checked yet"
        }
    }
}

/// Settings > Updates: release check, one-click install and the automatic check preference.
struct NativeUpdateSettings: View {
    @ObservedObject var model: NativeUpdateModel
    @EnvironmentObject private var session: NativeAppSession
    @AppStorage(NativeAppSession.automaticUpdateKey) private var automatic = true

    var body: some View {
        let phase = model.phase
        OptionRow(title: "Software update", detail: model.summary) {
            HStack(spacing: 8) {
                switch phase {
                case "ready":
                    // The page's primary sits in the header; this is the same action beside its explanation.
                    Button("Update to " + model.latest, nativeIcon: "download") { session.installUpdate() }
                case "waiting":
                    Button("Cancel") { Task { await session.updater?.cancelInstall() } }
                case "installing":
                    NativeUpdateProgressWord("Installing")
                case "checking":
                    NativeUpdateProgressWord("Checking")
                case "downloading":
                    NativeUpdateDownloadMeter(fraction: model.state["progress"].double)
                case "unavailable":
                    EmptyView()
                default:
                    if phase == "failed", !model.state["staged"].string.isEmpty {
                        Button("Try again") { session.installUpdate() }
                    }
                    Button("Check for updates") { Task { await session.updater?.check() } }
                }
            }
            .buttonStyle(Press(.secondary))
        }
        if phase != "unavailable" {
            OptionRow(title: "Check for updates automatically",
                      detail: "Finds and downloads a newer release every few hours. Nothing installs until you choose to update.") {
                Flip(isOn: $automatic).accessibilityLabel("Check for updates automatically")
            }
        }
    }
}

/// The one primary on Settings: present only while a verified release waits.
struct NativeUpdateHeaderButton: View {
    @ObservedObject var model: NativeUpdateModel
    @EnvironmentObject private var session: NativeAppSession
    var body: some View {
        if model.installable {
            Button(model.phase == "ready" ? "Update to " + model.latest : "Try update again", nativeIcon: "download") { session.installUpdate() }
                .buttonStyle(Press(.primary))
                .help("Installs UniApi \(model.latest) now. Providers, data and settings are kept.")
                .accessibilityLabel(model.phase == "ready" ? "Update to UniApi " + model.latest : "Try the update again")
        }
    }
}

/// Work with no measurable progress: a still word, never an indeterminate indicator.
private struct NativeUpdateProgressWord: View {
    let word: String
    init(_ word: String) { self.word = word }
    var body: some View {
        HStack(spacing: 6) {
            NativeStatusDot(color: Theme.signal, size: 5, pulse: true)
            Text(word).font(Theme.ui(12.5)).foregroundStyle(Theme.dim)
        }
        .frame(height: 28).accessibilityElement(children: .combine)
    }
}

/// Download progress as a graduated meter with its percentage as a reading.
private struct NativeUpdateDownloadMeter: View {
    let fraction: Double
    private var percent: Int { Int((NativeMotion.fraction(fraction) * 100).rounded()) }
    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Scale(fraction: fraction, ticks: true).frame(width: 132)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                NativeNumberText(text: String(percent), font: Theme.readout(17), color: Theme.ink)
                MicroLabel("%")
            }
            .frame(width: 42, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download progress").accessibilityValue("\(percent) percent")
    }
}

/// Index footer: appears only once a newer release is ready to install.
struct NativeUpdateSidebarButton: View {
    @ObservedObject var model: NativeUpdateModel
    @EnvironmentObject private var session: NativeAppSession
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        if model.actionable {
            let phase = model.phase
            let ready = phase == "ready"
            Button { if ready { session.installUpdate() } } label: {
                HStack(spacing: 7) {
                    NativeIcon(ready ? "download" : "clock", size: 12, strokeWidth: 1.75)
                    Text(ready ? "Update to " + model.latest : phase == "waiting" ? "Updating when idle" : "Installing update")
                        .font(Theme.ui(11.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9).frame(height: 28).frame(maxWidth: .infinity)
                .foregroundStyle(ready ? Theme.onInk : Theme.dim)
                .background(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(ready ? Theme.ink.opacity(hovering ? 0.86 : 1) : Theme.hover))
                .overlay {
                    if !ready {
                        RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.rule, lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(!ready).pointingHand(ready)
            .onHover { hovering = $0 && ready }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
            .padding(.bottom, 6)
            .help(ready ? "Installs UniApi \(model.latest) now. Providers, data and settings are kept." : model.state["message"].string)
            .accessibilityLabel(ready ? "Update to UniApi " + model.latest : "Update in progress")
        }
    }
}
