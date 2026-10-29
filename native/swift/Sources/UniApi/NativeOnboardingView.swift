import SwiftUI
import UniApiCore

/// A presentation-only welcome screen. Connections, permissions and downloads
/// remain explicit actions in their destination pages.
struct NativeOnboardingView: View {
    @AppStorage("uniapi-theme") private var appearance = "auto"
    @AppStorage("uniapi-density") private var density = "standard"
    @AppStorage("uniapi-motion") private var motion = "system"
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var destination = OnboardingDestination.home
    @AccessibilityFocusState private var focusedHeading: Bool
    private let onFinish: (String?) -> Void

    init(onFinish: @escaping (String?) -> Void) { self.onFinish = onFinish }

    private var reducedMotion: Bool { systemReduceMotion || motion == "reduced" }
    private var scheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                let compact = geometry.size.height < 460
                let wide = geometry.size.width >= 720 && !compact
                ScrollView {
                    VStack(alignment: .leading, spacing: compact ? 18 : 28) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Your UniApi workspace")
                                .font(Theme.ui(compact ? 24 : 26, weight: .semibold)).tracking(-0.6)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityFocused($focusedHeading)
                            Text("Choose a starting page and a look that feels like you.")
                                .font(Theme.ui(13)).foregroundStyle(Theme.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if wide {
                            HStack(alignment: .top, spacing: 32) {
                                destinations(grid: false).frame(width: 278)
                                customization(showPreview: true)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                destinations(grid: true)
                                customization(showPreview: false)
                            }
                        }
                    }
                    .frame(maxWidth: 704, alignment: .leading)
                    .padding(.horizontal, 32).padding(.vertical, compact ? 12 : 20)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            footer
        }
        .frame(maxWidth: 820, maxHeight: 660)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg).foregroundStyle(Theme.ink)
        .preferredColorScheme(scheme)
        .environment(\.nativeInterfaceDensity, NativeInterfaceDensity(rawValue: density) ?? .standard)
        .environment(\.nativeReducedMotion, reducedMotion)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedHeading = true
        }
    }

    private var header: some View {
        HStack {
            UniApiWordmark(markSize: 24, textSize: 16)
            Spacer(minLength: 12)
            Button("Skip for now") { onFinish(nil) }
                .buttonStyle(OnboardingActionStyle(primary: false))
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: 704)
        .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private func destinations(grid: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start in").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
            if grid {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(OnboardingDestination.allCases) { destinationChoice($0, compact: true) }
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(OnboardingDestination.allCases) { destinationChoice($0, compact: false) }
                }
            }
        }
    }

    private func destinationChoice(_ value: OnboardingDestination, compact: Bool) -> some View {
        let selected = destination == value
        return Button { destination = value } label: {
            HStack(alignment: .center, spacing: 12) {
                NativeIcon(value.icon, size: 19).foregroundStyle(selected ? Theme.link : Theme.dim)
                    .frame(width: 24, height: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(value.title).font(Theme.ui(13, weight: .medium))
                    Text(value.detail).font(Theme.ui(11.5)).foregroundStyle(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                NativeIcon("check", size: 14).foregroundStyle(Theme.link)
                    .opacity(selected ? 1 : 0).accessibilityHidden(true)
            }
            .padding(.horizontal, 12).padding(.vertical, density == "compact" ? 8 : density == "spacious" ? 14 : compact ? 10 : 12)
            .frame(maxWidth: .infinity, minHeight: density == "compact" ? 58 : density == "spacious" ? 76 : 64, alignment: .leading)
        }
        .buttonStyle(OnboardingChoiceStyle(selected: selected))
        .accessibilityLabel(value.title + ". " + value.detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func customization(showPreview: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showPreview {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Layout preview").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                    OnboardingWorkspacePreview(destination: destination)
                        .frame(height: 240)
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Appearance").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                choiceStrip(options: [("auto", "System", "monitor"), ("light", "Light", "sun"), ("dark", "Dark", "moon")], selection: appearance) { appearance = $0 }
                    .accessibilityLabel("Appearance")
            }
            HStack(spacing: 12) {
                Text("Spacing").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
                choiceStrip(options: [("compact", "Compact", nil), ("standard", "Default", nil), ("spacious", "Roomy", nil)], selection: density) { density = $0 }
                    .frame(maxWidth: 250)
                    .accessibilityLabel("Page spacing")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choiceStrip(options: [(String, String, String?)], selection: String, change: @escaping (String) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                Button { change(option.0) } label: {
                    HStack(spacing: 6) {
                        if let icon = option.2 { NativeIcon(icon, size: 13).accessibilityHidden(true) }
                        Text(option.1).font(Theme.ui(11.5, weight: selection == option.0 ? .medium : .regular))
                    }
                    .foregroundStyle(selection == option.0 ? Theme.ink : Theme.dim)
                    .frame(maxWidth: .infinity).frame(height: 30)
                }
                .buttonStyle(OnboardingSegmentStyle(selected: selection == option.0))
                .accessibilityAddTraits(selection == option.0 ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.subtle))
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Change any of this in Settings.").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                Text("No connections or downloads during setup.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { onFinish(destination.rawValue) } label: {
                HStack(spacing: 10) {
                    Text("Open \(destination.title)")
                    NativeIcon("arrow-right", size: 14).accessibilityHidden(true)
                }
                .frame(minWidth: 125)
            }
            .buttonStyle(OnboardingActionStyle()).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 704)
        .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 20)
        .frame(maxWidth: .infinity)
    }
}

private enum OnboardingDestination: String, CaseIterable, Identifiable {
    case home, switcher, stats, transcribe
    var id: String { rawValue }
    var title: String {
        switch self { case .home: return "Home"; case .switcher: return "Switcher"; case .stats: return "Statistics"; case .transcribe: return "Transcribe" }
    }
    var icon: String {
        switch self { case .home: return "house"; case .switcher: return "route"; case .stats: return "chart-line"; case .transcribe: return "mic" }
    }
    var detail: String {
        switch self {
        case .home: return "All your apps at a glance."
        case .switcher: return "Bring your models to coding tools."
        case .stats: return "Usage history and cost estimates."
        case .transcribe: return "Audio to text, on your Mac."
        }
    }
}

/// An inert illustration of the app's navigation, never a second app session.
/// Real theme tokens and density values make the presentation choices visible.
private struct OnboardingWorkspacePreview: View {
    let destination: OnboardingDestination
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeReducedMotion) private var reducedMotion
    private var gap: CGFloat { density == .compact ? 8 : density == .spacious ? 18 : 12 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: gap / 2) {
                UniApiMark(size: 23).padding(.bottom, 8)
                ForEach(OnboardingDestination.allCases) { value in
                    NativeIcon(value.icon, size: 15)
                        .foregroundStyle(destination == value ? Theme.link : Theme.muted)
                        .frame(width: 32, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(destination == value ? Theme.sidebarAccent : .clear))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 18).frame(width: 54)
            .background(Theme.sidebarBG)
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(alignment: .leading, spacing: gap) {
                Text(destination.title).font(Theme.ui(14, weight: .semibold))
                Text(destination.detail).font(Theme.ui(10.5)).foregroundStyle(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(["Your providers", "Your usage", "Local tools"], id: \.self) { title in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.65)).frame(width: 3, height: 14)
                        Text(title).font(Theme.ui(10.5)).foregroundStyle(Theme.dim)
                        Spacer(minLength: 0)
                        NativeIcon("chevron-right", size: 10).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, density == .compact ? 5 : density == .spacious ? 9 : 7)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.subtle))
                }
                Spacer(minLength: 0)
            }
            .padding(18).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
        .animation(reducedMotion ? nil : .easeInOut(duration: 0.16), value: density)
    }
}

private struct OnboardingChoiceStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        OnboardingChoiceBody(configuration: configuration, selected: selected)
    }
}
private struct OnboardingChoiceBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @State private var hovering = false
    var body: some View {
        configuration.label
            .foregroundStyle(Theme.ink)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Theme.accent.opacity(0.08) : hovering ? Theme.subtle2 : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.99 : 1)
            .animation(reducedMotion ? nil : NativeMotion.hover, value: hovering)
            .animation(reducedMotion ? nil : NativeMotion.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .pointingHand()
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
    @State private var hovering = false
    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.surface : configuration.isPressed || hovering ? Theme.subtle2 : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .animation(reducedMotion ? nil : NativeMotion.hover, value: hovering)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .pointingHand()
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
    @State private var hovering = false
    var body: some View {
        configuration.label.font(Theme.ui(13, weight: .medium))
            .foregroundStyle(primary ? Theme.onAccent : hovering ? Theme.ink : Theme.dim)
            .padding(.horizontal, primary ? 16 : 8).frame(height: primary ? 40 : 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Theme.accent : hovering ? Theme.subtle2 : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).fill(Theme.onAccent.opacity(primary && hovering ? 0.08 : 0)))
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.98 : 1)
            .animation(reducedMotion ? nil : NativeMotion.hover, value: hovering)
            .animation(reducedMotion ? nil : NativeMotion.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .pointingHand()
    }
}
