import SwiftUI
import UniApiCore

/// Presentation choices only. Connections, permissions and downloads remain
/// explicit actions in their pages; finishing performs one navigation handoff.
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
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(spacing: 0) {
                            Color.clear.frame(height: 0).id("setup-top")
                            content(width: geometry.size.width - 64, compact: geometry.size.height < 440)
                                .id(step)
                                .transition(reducedMotion ? .identity : .asymmetric(
                                    insertion: .opacity.combined(with: .offset(y: 8)),
                                    removal: .opacity.combined(with: .offset(y: -4))))
                                .frame(maxWidth: 636, alignment: .leading)
                                .padding(.horizontal, 32)
                                .padding(.vertical, geometry.size.height < 440 ? 20 : 28)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height, alignment: step == .welcome ? .center : .top)
                    }
                    .onChange(of: step) { _, _ in scroll.scrollTo("setup-top", anchor: .top) }
                }
            }
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
        VStack(spacing: 14) {
            HStack {
                UniApiWordmark(markSize: 24, textSize: 16)
                Spacer()
                Button("Skip setup") { onFinish(nil) }
                    .buttonStyle(OnboardingActionStyle(primary: false))
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 12) {
                ForEach(NativeOnboardingStep.allCases, id: \.rawValue) { value in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            if value.rawValue < step.rawValue {
                                NativeIcon("check", size: 11).foregroundStyle(Theme.link)
                            }
                            Text(stepTitle(value))
                                .font(Theme.ui(11.5, weight: value == step ? .semibold : .regular))
                                .foregroundStyle(value == step ? Theme.ink : Theme.muted)
                                .lineLimit(1)
                        }
                        Capsule().fill(value.rawValue <= step.rawValue ? Theme.accent : Theme.track)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(value.rawValue + 1) of 4: \(stepTitle(value))\(value == step ? ", current" : value.rawValue < step.rawValue ? ", complete" : "")")
                }
            }
        }
        .frame(maxWidth: 636)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder private func content(width: CGFloat, compact: Bool) -> some View {
        switch step {
        case .welcome:
            welcome(compact: compact)
        case .appearance:
            VStack(alignment: .leading, spacing: compact ? 18 : 24) {
                heading("Make yourself at home.", "Choose a color scheme and a comfortable layout.")
                HStack(spacing: 12) {
                    appearanceChoice("auto", title: "System", light: false, automatic: true)
                    appearanceChoice("light", title: "Light", light: true)
                    appearanceChoice("dark", title: "Dark", light: false)
                }
                VStack(spacing: 18) {
                    preference("Page spacing", detail: "How much room your pages use.", stacked: width < 560) {
                        choiceStrip(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                            .frame(width: min(max(width - 10, 220), 292))
                            .accessibilityLabel("Page spacing")
                    }
                    Rectangle().fill(Theme.border).frame(height: 1)
                    preference("Motion", detail: "Always respects macOS Reduce Motion.", stacked: width < 560) {
                        choiceStrip(options: [("system", "System"), ("reduced", "Reduced")], selection: motion) { motion = $0 }
                            .frame(width: min(max(width - 10, 220), 292))
                            .accessibilityLabel("Motion")
                    }
                }
            }
        case .connections:
            VStack(alignment: .leading, spacing: compact ? 18 : 24) {
                heading("Where would you like to start?", "Pick the first page you'll see. The whole workspace is available from the sidebar.")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    destination("home", title: "Home", icon: "house", detail: "An overview of your workspace.", compact: compact)
                    destination("switcher", title: "Switcher", icon: "route", detail: "Connect providers and choose models.", compact: compact)
                    destination("stats", title: "Statistics", icon: "chart-line", detail: "Explore your local usage and costs.", compact: compact)
                    destination("transcribe", title: "Transcribe", icon: "mic", detail: "Turn audio into text with local Whisper.", compact: compact)
                }
                HStack(alignment: .top, spacing: 9) {
                    NativeIcon(startingPoint == "transcribe" ? "download" : "settings", size: 14)
                        .foregroundStyle(Theme.muted).padding(.top, 1)
                    Text(startingPoint == "transcribe"
                         ? "Whisper's optional 574 MB model is downloaded from Transcribe when you choose to install it."
                         : "This choice opens a page once. Your usual launch behavior stays in Settings.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .ready:
            VStack(alignment: .leading, spacing: compact ? 18 : 24) {
                heading("You're ready.", "Your workspace is set. Everything here stays editable in Settings.")
                HStack(spacing: 14) {
                    NativeIcon(destinationIcon, size: 24).foregroundStyle(Theme.link)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.accent.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("FIRST STOP").font(Theme.ui(10, weight: .semibold)).tracking(1).foregroundStyle(Theme.muted)
                        Text(destinationTitle).font(Theme.ui(19, weight: .semibold))
                    }
                    Spacer()
                    NativeIcon("check", size: 18).foregroundStyle(Theme.link)
                }
                .padding(compact ? 16 : 20)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                .accessibilityElement(children: .combine)
                VStack(spacing: 0) {
                    summaryRow("Appearance", value: appearance == "light" ? "Light" : appearance == "dark" ? "Dark" : "Follow system", icon: "sun")
                    Rectangle().fill(Theme.border).frame(height: 1)
                    summaryRow("Page spacing", value: density == "compact" ? "Compact" : density == "spacious" ? "Spacious" : "Default", icon: "sliders-horizontal")
                    Rectangle().fill(Theme.border).frame(height: 1)
                    summaryRow("Motion", value: motion == "reduced" ? "Reduced" : systemReduceMotion ? "System (reduced)" : "Follow system", icon: "sparkles")
                }
                HStack(spacing: 8) {
                    NativeIcon("shield-check", size: 14)
                    Text("Providers and optional tools connect only when you choose.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func welcome(compact: Bool) -> some View {
        VStack(spacing: compact ? 18 : 24) {
            VStack(spacing: compact ? 12 : 16) {
                UniApiMark(size: compact ? 44 : 60).accessibilityHidden(true)
                Text("Your models. One workspace.")
                    .font(Theme.ui(compact ? 28 : 30, weight: .semibold)).tracking(-0.7)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Switch between providers, understand your usage,\nand keep your AI tools together.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.dim).lineSpacing(3)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                feature("route", title: "Your models, one place", detail: "Bring the providers you already use.", compact: compact)
                Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 52)
                feature("chart-line", title: "A clearer picture of usage", detail: "Explore token history and available cost estimates.", compact: compact)
                Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 52)
                feature("mic", title: "Local tools, when you need them", detail: "Add optional transcription without a cloud account.", compact: compact)
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
            .frame(maxWidth: 500)
        }
        .frame(maxWidth: .infinity)
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.ui(27, weight: .semibold)).tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail).font(Theme.ui(13)).foregroundStyle(Theme.dim)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feature(_ icon: String, title: String, detail: String, compact: Bool) -> some View {
        HStack(alignment: .center, spacing: 14) {
            NativeIcon(icon, size: 20).foregroundStyle(Theme.link).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.ui(13, weight: .medium))
                Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 11 : 15)
        .accessibilityElement(children: .combine)
    }

    private func appearanceChoice(_ id: String, title: String, light: Bool, automatic: Bool = false) -> some View {
        let selected = appearance == id
        return Button { appearance = id } label: {
            VStack(spacing: 12) {
                GeometryReader { geometry in
                    ZStack {
                        appearancePreview(light: light)
                        if automatic {
                            appearancePreview(light: true)
                                .mask(alignment: .trailing) { Rectangle().frame(width: geometry.size.width / 2) }
                        }
                    }
                }
                .frame(height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                HStack(spacing: 8) {
                    Text(title).font(Theme.ui(12.5, weight: .medium))
                    Spacer(minLength: 0)
                    NativeIcon(selected ? "circle-check" : "circle", size: 15)
                        .foregroundStyle(selected ? Theme.link : Theme.muted)
                }
            }
            .padding(12)
        }
        .buttonStyle(OnboardingChoiceStyle(selected: selected))
        .accessibilityLabel("\(title) color scheme")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func appearancePreview(light: Bool) -> some View {
        // These fixed swatches depict the alternatives rather than the active
        // theme. All surrounding controls continue to use the shared tokens.
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(light ? Color.black.opacity(0.08) : Color.white.opacity(0.08)).frame(width: 24)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Theme.accent.opacity(0.75)).frame(width: 34, height: 4)
                RoundedRectangle(cornerRadius: 3).fill(light ? Color.black.opacity(0.06) : Color.white.opacity(0.07))
                RoundedRectangle(cornerRadius: 3).fill(light ? Color.black.opacity(0.06) : Color.white.opacity(0.07))
            }
        }
        .padding(9)
        .background(light ? Color.white : Color(white: 0.075))
        .accessibilityHidden(true)
    }

    @ViewBuilder private func preference<Control: View>(_ title: String, detail: String, stacked: Bool, @ViewBuilder control: () -> Control) -> some View {
        if stacked {
            VStack(alignment: .leading, spacing: 10) {
                preferenceLabel(title, detail: detail)
                control()
            }.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 20) {
                preferenceLabel(title, detail: detail)
                Spacer(minLength: 0)
                control()
            }
        }
    }

    private func preferenceLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.ui(13, weight: .medium))
            Text(detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choiceStrip(options: [(String, String)], selection: String, change: @escaping (String) -> Void) -> some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.0) { option in
                Button { change(option.0) } label: {
                    Text(option.1).font(Theme.ui(12, weight: selection == option.0 ? .medium : .regular))
                        .foregroundStyle(selection == option.0 ? Theme.ink : Theme.muted)
                        .frame(maxWidth: .infinity).frame(height: 32)
                }
                .buttonStyle(OnboardingSegmentStyle(selected: selection == option.0))
                .accessibilityAddTraits(selection == option.0 ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.subtle))
        .accessibilityElement(children: .contain)
    }

    private func destination(_ id: String, title: String, icon: String, detail: String, compact: Bool) -> some View {
        let selected = startingPoint == id
        return Button { startingPoint = id } label: {
            VStack(alignment: .leading, spacing: compact ? 9 : 13) {
                HStack {
                    NativeIcon(icon, size: compact ? 18 : 21).foregroundStyle(selected ? Theme.link : Theme.dim)
                    Spacer(minLength: 8)
                    NativeIcon(selected ? "circle-check" : "circle", size: 16)
                        .foregroundStyle(selected ? Theme.link : Theme.muted.opacity(0.65))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(Theme.ui(14, weight: .medium))
                    Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: compact ? 28 : 32, alignment: .topLeading)
                }
            }
            .padding(compact ? 14 : 18).frame(maxWidth: .infinity, minHeight: compact ? 106 : 124, alignment: .topLeading)
        }
        .buttonStyle(OnboardingChoiceStyle(selected: selected))
        .accessibilityLabel(title + ". " + detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func summaryRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 11) {
            NativeIcon(icon, size: 15).foregroundStyle(Theme.muted).frame(width: 20)
            Text(title).foregroundStyle(Theme.dim)
            Spacer(minLength: 12)
            Text(value).fontWeight(.medium)
        }
        .font(Theme.ui(12.5)).padding(.vertical, 13)
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

    private var destinationIcon: String {
        switch startingPoint {
        case "switcher": return "route"
        case "stats": return "chart-line"
        case "transcribe": return "mic"
        default: return "house"
        }
    }

    private func stepTitle(_ value: NativeOnboardingStep) -> String {
        switch value {
        case .welcome: return "Welcome"
        case .appearance: return "Appearance"
        case .connections: return "Start page"
        case .ready: return "Ready"
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 12) {
                if step != .welcome {
                    Button { move(to: step.previous) } label: {
                        HStack(spacing: 7) { NativeIcon("arrow-left", size: 14); Text("Back") }
                    }
                    .buttonStyle(OnboardingActionStyle(primary: false))
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                } else {
                    Text("About a minute to make it yours.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    if step == .ready { onFinish(startingPoint) }
                    else { move(to: step.next) }
                } label: {
                    HStack(spacing: 9) {
                        Text(step == .welcome ? "Get started" : step == .ready ? "Open \(destinationTitle)" : "Continue")
                        NativeIcon("arrow-right", size: 14)
                    }
                    .frame(minWidth: 128)
                }
                .buttonStyle(OnboardingActionStyle()).keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 636)
            .padding(.horizontal, 32).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
    }

    private func move(to next: NativeOnboardingStep) {
        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.2)) { step = next }
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
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.accent.opacity(0.07) : hovering ? Theme.subtle2 : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Theme.accent.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 12))
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

private struct OnboardingSegmentStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        OnboardingSegmentBody(configuration: configuration, selected: selected)
    }
}

private struct OnboardingSegmentBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.surface : configuration.isPressed || hovering ? Theme.subtle2 : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .animation(reducedMotion ? nil : NativeMotion.hover, value: hovering)
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
        configuration.label.font(Theme.ui(13, weight: .medium))
            .foregroundStyle(primary ? Theme.onAccent : hovering ? Theme.ink : Theme.muted)
            .padding(.horizontal, primary ? 16 : 9).frame(height: 40)
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
