import SwiftUI
import UniApiCore

/// Setup changes presentation preferences only. Connections and downloads stay
/// explicit actions on their own pages; finishing opens the chosen destination.
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
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if geometry.size.width >= 740 { journey }
                VStack(alignment: .leading, spacing: 0) {
                    if geometry.size.width < 740 {
                        HStack {
                            UniApiWordmark(markSize: 22, textSize: 15)
                            Spacer()
                            progress
                        }
                        .padding(.bottom, 26)
                    }
                    ScrollViewReader { scroll in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Color.clear.frame(height: 0).id("setup-top")
                                content(compact: geometry.size.height < 620)
                                    .id(step)
                                    .transition(reducedMotion ? .identity : .asymmetric(
                                        insertion: .opacity.combined(with: .offset(y: 10)),
                                        removal: .opacity.combined(with: .offset(y: -6))))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.bottom, 16)
                            }
                        }
                        .onChange(of: step) { _, _ in scroll.scrollTo("setup-top", anchor: .top) }
                    }
                    footer.padding(.top, 20)
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: 880, maxHeight: 660)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(scheme)
        .environment(\.nativeInterfaceDensity, spacing)
        .environment(\.nativeReducedMotion, reducedMotion)
    }

    private var journey: some View {
        VStack(alignment: .leading, spacing: 0) {
            UniApiWordmark(markSize: 28, textSize: 18).padding(.bottom, 48)
            VStack(alignment: .leading, spacing: 26) {
                journeyStep(.welcome, title: "Welcome", detail: "Meet your workspace")
                journeyStep(.appearance, title: "Appearance", detail: "Make it feel like you")
                journeyStep(.connections, title: "Starting point", detail: "Choose your first page")
                journeyStep(.ready, title: "Ready", detail: "Make yourself at home")
            }
            Spacer(minLength: 28)
            VStack(alignment: .leading, spacing: 8) {
                NativeIcon("shield-check", size: 18).foregroundStyle(Theme.muted)
                Text("You're in control.").font(Theme.ui(12, weight: .medium))
                Text("Connect providers and install optional tools only when you choose.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(26)
        .frame(width: 208, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Theme.surface)
    }

    private func journeyStep(_ value: NativeOnboardingStep, title: String, detail: String) -> some View {
        let current = value == step
        let complete = value.rawValue < step.rawValue
        return HStack(alignment: .top, spacing: 11) {
            ZStack {
                Circle().fill(current ? Theme.accent : Theme.subtle2)
                if complete {
                    NativeIcon("check", size: 12).foregroundStyle(Theme.link)
                } else {
                    Text("\(value.rawValue + 1)").font(Theme.ui(11, weight: .semibold))
                        .foregroundStyle(current ? Theme.onAccent : Theme.muted)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(Theme.ui(12.5, weight: current ? .semibold : .medium))
                    .foregroundStyle(current ? Theme.ink : Theme.dim)
                Text(detail).font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(value.rawValue + 1): \(title)\(current ? ", current" : complete ? ", complete" : "")")
    }

    private var progress: some View {
        HStack(spacing: 5) {
            ForEach(0..<4) { index in
                Capsule().fill(index <= step.rawValue ? Theme.accent : Theme.track)
                    .frame(width: 20, height: 3)
            }
        }
        .accessibilityLabel("Setup step \(step.rawValue + 1) of 4")
    }

    @ViewBuilder private func content(compact: Bool) -> some View {
        switch step {
        case .welcome:
            VStack(alignment: .leading, spacing: 26) {
                heading("Your AI tools,\nin one place.", "Models, usage and local workflows, brought together. Revisit this guide anytime in Settings.", eyebrow: "WELCOME TO UNIAPI")
                if !compact { workspacePreview }
                VStack(alignment: .leading, spacing: 19) {
                    feature("route", title: "The right model for the job", detail: "Bring your providers and switch between them.")
                    feature("chart-line", title: "Know what you're using", detail: "See local usage history and available cost estimates.")
                    feature("mic", title: "Tools that work on your terms", detail: "Add local transcription and other tools when you need them.")
                }
            }
        case .appearance:
            VStack(alignment: .leading, spacing: 25) {
                heading("Make it yours.", "Choose a comfortable starting point. Every option stays editable in Settings.", eyebrow: "APPEARANCE")
                HStack(spacing: 10) {
                    appearanceChoice("auto", title: "System", light: false, automatic: true)
                    appearanceChoice("light", title: "Light", light: true)
                    appearanceChoice("dark", title: "Dark", light: false)
                }
                HStack(alignment: .top, spacing: 20) {
                    preference("Page spacing", detail: "A little tighter, or room to breathe.") {
                        T3Segmented(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                            .accessibilityLabel("Page spacing")
                    }
                    preference("Motion", detail: "The macOS Reduce Motion setting is always respected.") {
                        T3Segmented(options: [("system", "System"), ("reduced", "Reduced")], selection: motion) { motion = $0 }
                            .accessibilityLabel("Motion")
                    }
                }
            }
        case .connections:
            VStack(alignment: .leading, spacing: 24) {
                heading("Pick your starting page.", "Choose what opens after setup. Explore the rest anytime.", eyebrow: "YOUR STARTING POINT")
                VStack(spacing: 9) {
                    destination("home", title: "Home", icon: "house", detail: "Your workspace at a glance.")
                    destination("switcher", title: "Switcher", icon: "route", detail: "Bring a provider and choose your models.")
                    destination("stats", title: "Statistics", icon: "chart-line", detail: "Explore available local usage history.")
                    destination("transcribe", title: "Transcribe", icon: "mic", detail: "Turn audio into text with local Whisper.")
                }
                Text("Transcription's optional 574 MB model is downloaded only when you ask. Nothing is installed during setup.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Theme.accent.opacity(0.12))
                    NativeIcon("check", size: 28).foregroundStyle(Theme.link)
                }
                .frame(width: 48, height: 48).accessibilityHidden(true)
                heading("Ready to begin.", "Your workspace starts with \(destinationTitle). You can revisit this guide in Settings.", eyebrow: "ALL SET")
                VStack(spacing: 0) {
                    summaryRow("Color scheme", value: appearance == "light" ? "Light" : appearance == "dark" ? "Dark" : "Follow system", icon: "sun")
                    Rectangle().fill(Theme.border).frame(height: 1)
                    summaryRow("Page spacing", value: density == "compact" ? "Compact" : density == "spacious" ? "Spacious" : "Default", icon: "sliders-horizontal")
                    Rectangle().fill(Theme.border).frame(height: 1)
                    summaryRow("Motion", value: motion == "reduced" ? "Reduced" : systemReduceMotion ? "System (reduced)" : "Follow system", icon: "sparkles")
                }
                Text("This guide makes no connections or downloads.\nAdd what you need, when you need it.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func heading(_ title: String, _ detail: String, eyebrow: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(eyebrow).font(Theme.ui(10, weight: .semibold)).tracking(1.3).foregroundStyle(Theme.link)
            Text(title).font(Theme.ui(30, weight: .semibold)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(Theme.ui(13)).foregroundStyle(Theme.dim)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workspacePreview: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                UniApiMark(size: 18)
                ForEach(["house", "route", "chart-line"], id: \.self) { name in
                    NativeIcon(name, size: 12).foregroundStyle(name == "house" ? Theme.link : Theme.muted)
                }
            }
            .padding(14).frame(width: 52).frame(maxHeight: .infinity).background(Theme.subtle)
            VStack(alignment: .leading, spacing: 12) {
                Text("Your workspace").font(Theme.ui(12, weight: .semibold))
                HStack(spacing: 8) {
                    previewTile("Models", icon: "route")
                    previewTile("Usage", icon: "chart-line")
                    previewTile("Local tools", icon: "mic")
                }
            }
            .padding(16)
        }
        .frame(height: 116)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func previewTile(_ title: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NativeIcon(icon, size: 15).foregroundStyle(Theme.link)
            Text(title).font(Theme.ui(10.5)).foregroundStyle(Theme.dim).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(11)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.subtle))
    }

    private func feature(_ icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            NativeIcon(icon, size: 17).foregroundStyle(Theme.link).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.ui(13, weight: .medium))
                Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func appearanceChoice(_ id: String, title: String, light: Bool, automatic: Bool = false) -> some View {
        let selected = appearance == id
        return Button { appearance = id } label: {
            VStack(alignment: .leading, spacing: 11) {
                // Fixed swatches intentionally show both schemes, independent of
                // the active theme. The surrounding control uses the live tokens.
                GeometryReader { geometry in
                    ZStack {
                        appearancePreview(light: light)
                        if automatic {
                            appearancePreview(light: true)
                                .mask(alignment: .trailing) {
                                    Rectangle().frame(width: geometry.size.width / 2)
                                }
                        }
                    }
                }
                .frame(height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text(title).font(Theme.ui(12, weight: .medium))
                    Spacer(minLength: 0)
                    NativeIcon(selected ? "circle-check" : "circle", size: 14)
                        .foregroundStyle(selected ? Theme.link : Theme.muted)
                }
            }
            .padding(10)
        }
        .buttonStyle(OnboardingChoiceStyle(selected: selected))
        .accessibilityLabel("\(title) color scheme")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func appearancePreview(light: Bool) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(light ? Color.black.opacity(0.09) : Color.white.opacity(0.13)).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(light ? Color.black.opacity(0.26) : Color.white.opacity(0.38)).frame(width: 35, height: 4)
                RoundedRectangle(cornerRadius: 3).fill(light ? Color.black.opacity(0.07) : Color.white.opacity(0.1))
                RoundedRectangle(cornerRadius: 3).fill(light ? Color.black.opacity(0.07) : Color.white.opacity(0.1))
            }
        }
        .padding(9)
        .background(light ? Color.white : Color(white: 0.075))
        .accessibilityHidden(true)
    }

    private func preference<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.ui(13, weight: .medium))
            Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 32, alignment: .topLeading)
            control()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func destination(_ id: String, title: String, icon: String, detail: String) -> some View {
        let selected = startingPoint == id
        return Button { startingPoint = id } label: {
            HStack(spacing: 13) {
                NativeIcon(icon, size: 18).foregroundStyle(selected ? Theme.link : Theme.muted)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Theme.accent.opacity(0.1) : Theme.subtle))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.ui(13, weight: .medium))
                    Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                NativeIcon(selected ? "circle-check" : "circle", size: 16)
                    .foregroundStyle(selected ? Theme.link : Theme.muted.opacity(0.55))
            }
            .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(OnboardingChoiceStyle(selected: selected))
        .accessibilityLabel(title + ". " + detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func summaryRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 10) {
            NativeIcon(icon, size: 15).foregroundStyle(Theme.muted).frame(width: 18)
            Text(title).foregroundStyle(Theme.dim)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium)
        }
        .font(Theme.ui(12)).padding(.vertical, 13)
        .accessibilityElement(children: .combine)
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
        VStack(spacing: 18) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 12) {
                if step == .welcome {
                    Button("Skip setup") { onFinish(nil) }
                        .buttonStyle(OnboardingActionStyle(primary: false)).keyboardShortcut(.cancelAction)
                } else {
                    Button { move(to: step.previous) } label: {
                        HStack(spacing: 6) { NativeIcon("arrow-left", size: 13); Text("Back") }
                    }
                    .buttonStyle(OnboardingActionStyle(primary: false))
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                    Button("Skip") { onFinish(nil) }
                        .buttonStyle(OnboardingActionStyle(primary: false)).keyboardShortcut(.cancelAction)
                }
                Spacer(minLength: 8)
                Button {
                    if step == .ready { onFinish(startingPoint) }
                    else { move(to: step.next) }
                } label: {
                    HStack(spacing: 8) {
                        Text(step == .welcome ? "Get started" : step == .ready ? "Open \(destinationTitle)" : "Continue")
                        NativeIcon("arrow-right", size: 14)
                    }
                }
                .buttonStyle(OnboardingActionStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(to next: NativeOnboardingStep) {
        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.22)) { step = next }
    }
}

private struct OnboardingChoiceStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        OnboardingChoiceBody(configuration: configuration, selected: selected)
    }
}

private struct OnboardingChoiceBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.07) : hovering ? Theme.subtle2 : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.accent.opacity(0.65) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.99 : 1)
            .animation(reducedMotion ? nil : NativeMotion.hover, value: hovering)
            .animation(reducedMotion ? nil : NativeMotion.press, value: configuration.isPressed)
            .onHover { hovering = $0 && enabled }
            .onChange(of: enabled) { _, value in if !value { hovering = false } }
            .onDisappear { hovering = false }
            .pointingHand(enabled)
    }
}

private struct OnboardingActionStyle: ButtonStyle {
    var primary = true
    func makeBody(configuration: Configuration) -> some View {
        OnboardingActionBody(configuration: configuration, primary: primary)
    }
}

private struct OnboardingActionBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label.font(Theme.ui(13, weight: .semibold))
            .foregroundStyle(primary ? Theme.onAccent : Theme.dim).padding(.horizontal, primary ? 17 : 10).frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 9).fill(primary ? Theme.accent : hovering ? Theme.subtle2 : .clear))
            .overlay(RoundedRectangle(cornerRadius: 9).fill(Theme.onAccent.opacity(primary && hovering ? 0.08 : 0)))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.98 : 1)
            .animation(reducedMotion ? nil : NativeMotion.hover, value: hovering)
            .animation(reducedMotion ? nil : NativeMotion.press, value: configuration.isPressed)
            .onHover { hovering = $0 && enabled }
            .onChange(of: enabled) { _, value in if !value { hovering = false } }
            .onDisappear { hovering = false }
            .pointingHand(enabled)
    }
}
