import SwiftUI
import UniApiCore

/// Setup makes presentation choices and one navigation handoff. Connections,
/// permissions and downloads remain explicit actions in their own pages.
struct NativeOnboardingView: View {
    @AppStorage("uniapi-theme") private var appearance = "auto"
    @AppStorage("uniapi-density") private var density = "standard"
    @AppStorage("uniapi-motion") private var motion = "system"
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var step: NativeOnboardingStep
    @State private var startingPoint = "home"
    @AccessibilityFocusState private var focusedStep: NativeOnboardingStep?
    private let onFinish: (String?) -> Void

    init(initialStep: NativeOnboardingStep = .welcome, onFinish: @escaping (String?) -> Void) {
        _step = State(initialValue: initialStep)
        self.onFinish = onFinish
    }

    private var reducedMotion: Bool { systemReduceMotion || motion == "reduced" }
    private var scheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).id("setup-top")
                            content(width: min(600, geometry.size.width - 64), compact: geometry.size.height < 440)
                                .id(step)
                                .transition(reducedMotion ? .identity : .opacity.combined(with: .offset(y: 6)))
                        }
                        .frame(maxWidth: 600, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.vertical, geometry.size.height < 440 ? 16 : 24)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: step) { _, _ in scroll.scrollTo("setup-top", anchor: .top) }
                    .task(id: step) {
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        focusedStep = step
                    }
                }
            }
            footer
        }
        .frame(maxWidth: 820, maxHeight: 660)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .foregroundStyle(Theme.ink)
        .preferredColorScheme(scheme)
        .environment(\.nativeInterfaceDensity, NativeInterfaceDensity(rawValue: density) ?? .standard)
        .environment(\.nativeReducedMotion, reducedMotion)
    }

    private var header: some View {
        VStack(spacing: 20) {
            HStack(spacing: 16) {
                UniApiWordmark(markSize: 25, textSize: 17)
                Spacer(minLength: 12)
                Text("\(step.rawValue + 1) of \(NativeOnboardingStep.allCases.count)")
                    .font(Theme.ui(12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .accessibilityLabel("Step \(step.rawValue + 1) of \(NativeOnboardingStep.allCases.count): \(step.title)")
                Button("Skip setup") { onFinish(nil) }
                    .buttonStyle(OnboardingActionStyle(primary: false))
                    .keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 6) {
                ForEach(NativeOnboardingStep.allCases, id: \.rawValue) { value in
                    Capsule().fill(value.rawValue <= step.rawValue ? Theme.accent : Theme.track)
                        .frame(height: 2)
                }
            }.accessibilityHidden(true)
        }
        .frame(maxWidth: 600)
        .padding(.horizontal, 32).padding(.top, 18)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private func content(width: CGFloat, compact: Bool) -> some View {
        if step == .welcome {
            VStack(alignment: .leading, spacing: compact ? 16 : 24) {
                heading("Welcome to UniApi.", "Your models, usage and local tools, together.\nWhere would you like to begin?", compact: compact)
                VStack(spacing: 0) {
                    destination("switcher", title: "Connect a model", icon: "route", detail: "Bring a provider to Claude Code or Codex.", compact: compact)
                    rowDivider
                    destination("stats", title: "Understand your usage", icon: "chart-line", detail: "Explore token history and available API cost estimates.", compact: compact)
                    rowDivider
                    destination("transcribe", title: "Transcribe locally", icon: "mic", detail: "Turn audio into text with optional local Whisper.", compact: compact)
                    rowDivider
                    destination("home", title: "Just look around", icon: "house", detail: "Start with an overview of your workspace.", compact: compact)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                note("No sign-in, provider connection or download happens during setup.", icon: "shield-check")
            }
        } else {
            VStack(alignment: .leading, spacing: compact ? 16 : 24) {
                heading("Make it feel right.", "Choose a look and a comfortable layout.\nYou can fine-tune colors and more in Settings.", compact: compact)
                HStack(spacing: 10) {
                    appearanceChoice("auto", title: "System", icon: "monitor")
                    appearanceChoice("light", title: "Light", icon: "sun")
                    appearanceChoice("dark", title: "Dark", icon: "moon")
                }
                VStack(spacing: 20) {
                    preference("Page spacing", detail: "Room between content and controls.", stacked: width < 560) {
                        choiceStrip(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                            .frame(width: min(width, 280))
                            .accessibilityLabel("Page spacing")
                    }
                    Rectangle().fill(Theme.border).frame(height: 1)
                    preference("Motion", detail: "macOS Reduce Motion is always respected.", stacked: width < 560) {
                        choiceStrip(options: [("system", "System"), ("reduced", "Reduced")], selection: motion) { motion = $0 }
                            .frame(width: min(width, 280))
                            .accessibilityLabel("Motion")
                    }
                }
                .padding(.vertical, 4)
                note(startingPoint == "transcribe"
                     ? "Next: Transcribe. Install the optional 574 MB model there when you're ready."
                     : "Next: \(destinationTitle). Connections and permissions are yours to choose.", icon: destinationIcon)
            }
        }
    }

    private func heading(_ title: String, _ detail: String, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.ui(compact ? 26 : 30, weight: .semibold)).tracking(-0.7)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                .accessibilityFocused($focusedStep, equals: step)
            Text(detail).font(Theme.ui(13)).foregroundStyle(Theme.dim)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, 70)
            .background(Theme.surface)
    }

    private func note(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            NativeIcon(icon, size: 14).padding(.top, 1)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.ui(12)).foregroundStyle(Theme.muted)
    }

    private func destination(_ id: String, title: String, icon: String, detail: String, compact: Bool) -> some View {
        let selected = startingPoint == id
        return Button { startingPoint = id } label: {
            HStack(spacing: 14) {
                NativeIcon(icon, size: 19).foregroundStyle(selected ? Theme.link : Theme.dim)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.accent.opacity(0.1) : Theme.subtle))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.ui(14, weight: .medium))
                    Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                NativeIcon(selected ? "circle-check" : "circle", size: 18)
                    .foregroundStyle(selected ? Theme.link : Theme.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, compact ? 10 : 14)
            .frame(maxWidth: .infinity, minHeight: compact ? 58 : 68, alignment: .leading)
        }
        .buttonStyle(OnboardingChoiceStyle(selected: selected, row: true))
        .accessibilityLabel(title + ". " + detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func appearanceChoice(_ id: String, title: String, icon: String) -> some View {
        let selected = appearance == id
        return Button { appearance = id } label: {
            VStack(alignment: .leading, spacing: 14) {
                NativeIcon(icon, size: 23).foregroundStyle(selected ? Theme.link : Theme.dim)
                HStack(spacing: 8) {
                    Text(title).font(Theme.ui(13, weight: .medium))
                    Spacer(minLength: 0)
                    NativeIcon(selected ? "circle-check" : "circle", size: 15)
                        .foregroundStyle(selected ? Theme.link : Theme.muted)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(OnboardingChoiceStyle(selected: selected))
        .accessibilityLabel("\(title) color scheme")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
                        .foregroundStyle(selection == option.0 ? Theme.ink : Theme.dim)
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
                }
                Spacer(minLength: 8)
                Button {
                    if step == .appearance { onFinish(startingPoint) }
                    else { move(to: step.next) }
                } label: {
                    HStack(spacing: 9) {
                        Text(step == .appearance ? "Open \(destinationTitle)" : "Continue")
                        NativeIcon("arrow-right", size: 14)
                    }
                    .frame(minWidth: 126)
                }
                .buttonStyle(OnboardingActionStyle()).keyboardShortcut(.defaultAction)
            }
            .frame(maxWidth: 600)
            .padding(.horizontal, 32).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
        }
    }

    private func move(to next: NativeOnboardingStep) {
        focusedStep = nil
        withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.18)) { step = next }
    }
}

private struct OnboardingChoiceStyle: ButtonStyle {
    var selected: Bool
    var row = false
    func makeBody(configuration: Configuration) -> some View {
        OnboardingChoiceBody(configuration: configuration, selected: selected, row: row)
    }
}

private struct OnboardingChoiceBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    let row: Bool
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .background(RoundedRectangle(cornerRadius: row ? 0 : 10).fill(selected ? Theme.accent.opacity(0.1) : hovering ? Theme.subtle2 : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: row ? 0 : 10).strokeBorder(selected && !row ? Theme.accent.opacity(0.45) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
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
