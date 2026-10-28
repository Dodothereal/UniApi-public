import SwiftUI
import UniApiCore

/// A guided introduction only: finishing records its marker in the session,
/// and the chosen page is opened after the shell has been presented.
struct NativeOnboardingView: View {
    @AppStorage("uniapi-theme") private var appearance = "auto"
    @AppStorage("uniapi-density") private var density = "standard"
    @AppStorage("uniapi-motion") private var motion = "system"
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var step: NativeOnboardingStep
    @State private var startingPoint = "home"
    private let onFinish: (String?) -> Void

    init(initialStep: NativeOnboardingStep = .welcome, onFinish: @escaping (String?) -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
    }

    private var reducedMotion: Bool { systemReduceMotion || motion == "reduced" }
    private var scheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    private var spacing: NativeInterfaceDensity { NativeInterfaceDensity(rawValue: density) ?? .standard }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.border).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content
                        .id(step)
                        .transition(reducedMotion ? .identity : .asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity.combined(with: .offset(y: -8))))
                }
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, spacing.pageMargin)
                .padding(.vertical, spacing.pageGap)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .frame(maxWidth: 820, maxHeight: 660)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(scheme)
        .environment(\.nativeInterfaceDensity, spacing)
        .environment(\.nativeReducedMotion, reducedMotion)
    }

    private var header: some View {
        HStack {
            UniApiWordmark(markSize: 22, textSize: 15)
            Spacer()
            Text("SETUP  /  \(step.rawValue + 1) OF 4")
                .font(Theme.mono(10.5)).tracking(1).foregroundStyle(Theme.muted)
                .accessibilityLabel("Setup step \(step.rawValue + 1) of 4")
        }
        .padding(.horizontal, 28).frame(height: 62)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 20) {
                asciiBrand
                heading("A workspace for your AI tools", "Bring your tools, usage and local workflows together in one native app.")
                Text("Take a short tour, or skip ahead. You can revisit this guide in Settings whenever you like.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
        case .appearance:
            VStack(alignment: .leading, spacing: 20) {
                heading("Make it yours", "These preferences apply immediately and can be changed later in Settings.")
                preference("Color scheme", "Choose how the app follows your system.") {
                    T3Segmented(options: [("auto", "Auto"), ("light", "Light"), ("dark", "Dark")], selection: appearance) { appearance = $0 }
                        .accessibilityLabel("Color scheme")
                }
                preference("Page spacing", "Adjust margins and card spacing.") {
                    T3Segmented(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                        .accessibilityLabel("Page spacing")
                }
                preference("Motion", "Reduced motion keeps transitions and artwork still. The macOS setting is always respected.") {
                    T3Segmented(options: [("system", "System"), ("reduced", "Reduced")], selection: motion) { motion = $0 }
                        .accessibilityLabel("Motion")
                }
            }
        case .connections:
            VStack(alignment: .leading, spacing: 18) {
                heading("Choose your starting point", "Choose where to go after setup. You can always explore the other pages later.")
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    destination("home", title: "Home", icon: "house", detail: "An overview of your workspace.")
                    destination("switcher", title: "Switcher", icon: "route", detail: "Configure providers when you are ready.")
                    destination("stats", title: "Statistics", icon: "chart-line", detail: "Explore available local usage history.")
                    destination("transcribe", title: "Transcribe", icon: "mic", detail: "Work with audio and transcripts.")
                }
                Text("Optional local Whisper transcription uses a 574 MB model. You can choose to download it later; setup does not download it.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 20) {
                asciiBrand
                heading("Ready when you are", "Your workspace is ready to explore.")
                Text("Providers, accounts and optional tools are configured only when you choose to set them up. This guide makes no connections or downloads.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                Text("STARTING AT  /  \(destinationTitle.uppercased())")
                    .font(Theme.mono(11)).tracking(0.8).foregroundStyle(Theme.link)
            }
        }
    }

    private var asciiBrand: some View {
        HStack(spacing: 28) {
            Text(verbatim: "    .  +  .\n  .  /\\  .\n  + /  \\ +\n   /____\\\n . | :: | .\n   |____|")
                .font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.link)
                .lineSpacing(2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text("ONE LOCAL WORKSPACE").font(Theme.mono(10)).tracking(1).foregroundStyle(Theme.muted)
                Text("Your tools,\nyour way.").font(Theme.ui(22, weight: .semibold))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
        .padding(.horizontal, 24)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(Theme.ui(24, weight: .semibold))
            Text(detail).font(Theme.ui(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func preference<Control: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Theme.ui(13, weight: .medium))
            Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            control()
        }
    }

    private func destination(_ id: String, title: String, icon: String, detail: String) -> some View {
        let selected = startingPoint == id
        return Button { startingPoint = id } label: {
            HStack(alignment: .top, spacing: 11) {
                NativeIcon(icon, size: 16).foregroundStyle(selected ? Theme.link : Theme.muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if selected { NativeIcon("check", size: 14).foregroundStyle(Theme.link) }
            }
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + ". " + detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var destinationTitle: String {
        switch startingPoint {
        case "switcher": return "Switcher"
        case "stats": return "Statistics"
        case "transcribe": return "Transcribe"
        default: return "Home"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip setup") { onFinish(nil) }
                .buttonStyle(T3Button(.ghost)).keyboardShortcut(.cancelAction)
            Spacer()
            Button("Back") { move(to: step.previous) }
                .buttonStyle(T3Button(.outline)).disabled(step == .welcome)
                .keyboardShortcut(.leftArrow, modifiers: [.command])
            Button(step == .ready ? "Finish" : "Continue") {
                if step == .ready { onFinish(startingPoint) }
                else { move(to: step.next) }
            }
            .buttonStyle(T3Button(.primary)).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28).frame(height: 66)
    }

    private func move(to next: NativeOnboardingStep) {
        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.22)) { step = next }
    }
}
