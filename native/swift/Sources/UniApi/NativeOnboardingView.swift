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
                        Text("Where to start")
                            .font(Theme.ui(compact ? 22 : 26, weight: .semibold)).tracking(Theme.tracking(26))
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityFocused($focusedHeading)
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
            Button("Skip") { onFinish(nil) }
                .buttonStyle(T3Button(.ghost))
                .keyboardShortcut(.cancelAction)
        }
        .frame(maxWidth: 704)
        .padding(.horizontal, 32).padding(.top, 16).padding(.bottom, 6)
        .frame(maxWidth: .infinity)
    }

    private func destinations(grid: Bool) -> some View {
        Group {
            if grid {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                    ForEach(OnboardingDestination.allCases) { destinationChoice($0, compact: true) }
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(OnboardingDestination.allCases) { destinationChoice($0, compact: false) }
                }
            }
        }
    }

    private func destinationChoice(_ value: OnboardingDestination, compact: Bool) -> some View {
        let selected = destination == value
        return Button { destination = value } label: {
            HStack(alignment: .center, spacing: 12) {
                NativeIcon(value.icon, size: 16).foregroundStyle(selected ? Theme.ink : Theme.muted)
                    .frame(width: 20, height: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(value.title).font(Theme.ui(Theme.textSm, weight: .medium))
                    Text(value.detail).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: compact ? 60 : 64, alignment: .leading)
        }
        .buttonStyle(OnboardingChoiceStyle(selected: selected))
        .accessibilityLabel(value.title + ". " + value.detail)
        .accessibilityHint("Use Open " + value.title + " to continue.")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func customization(showPreview: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if showPreview {
                OnboardingWorkspacePreview(destination: destination)
                    .frame(height: 188)
                    .accessibilityHidden(true).allowsHitTesting(false)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { appearanceControl; spacingControl; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 12) { appearanceControl; spacingControl }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appearanceControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Appearance").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
            T3Segmented(options: [("auto", "System"), ("light", "Light"), ("dark", "Dark")], selection: appearance) { appearance = $0 }
                .accessibilityLabel("Appearance")
        }
    }

    private var spacingControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spacing").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
            T3Segmented(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Roomy")], selection: density) { density = $0 }
                .accessibilityLabel("Page spacing")
        }
    }

    private var footer: some View {
        HStack(spacing: 20) {
            Spacer(minLength: 0)
            Button { onFinish(destination.rawValue) } label: {
                HStack(spacing: 8) {
                    Text("Open \(destination.title)")
                    NativeIcon("arrow-right", size: 14).accessibilityHidden(true)
                }
            }
            .buttonStyle(T3Button(.primary, size: Theme.textSm)).keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: 704)
        .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
    }
}

private enum OnboardingDestination: String, CaseIterable, Identifiable {
    case home, switcher, stats, transcribe
    var id: String { rawValue }
    var title: String {
        switch self { case .home: return "Home"; case .switcher: return "Switcher"; case .stats: return "Statistics"; case .transcribe: return "Transcribe" }
    }
    var previewRows: [String] {
        switch self {
        case .home: return ["Recent work", "Usage overview"]
        case .switcher: return ["Choose a coding tool", "Add a provider and model"]
        case .stats: return ["Tokens and cost estimates", "Models and usage history"]
        case .transcribe: return ["Optional local model", "Your audio, on your Mac"]
        }
    }
    var icon: String {
        switch self { case .home: return "house"; case .switcher: return "route"; case .stats: return "chart-line"; case .transcribe: return "mic" }
    }
    var detail: String {
        switch self {
        case .home: return "Routes, runs and what is waiting."
        case .switcher: return "Pick the provider and model Claude Code uses."
        case .stats: return "Tokens and cost by model."
        case .transcribe: return "Audio to text on this Mac."
        }
    }
}

/// An inert illustration of the app's navigation, never a second app session.
/// Real theme tokens and density values make the presentation choices visible.
private struct OnboardingWorkspacePreview: View {
    let destination: OnboardingDestination
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeReducedMotion) private var reducedMotion
    private var gap: CGFloat { density == .compact ? 6 : density == .spacious ? 12 : 9 }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: gap / 2) {
                UniApiMark(size: 23).padding(.bottom, 4)
                ForEach(OnboardingDestination.allCases) { value in
                    NativeIcon(value.icon, size: 15)
                        .foregroundStyle(destination == value ? Theme.ink : Theme.muted)
                        .frame(width: 32, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(destination == value ? Theme.raised : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(destination == value ? Theme.border : .clear, lineWidth: 1))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 12).frame(width: 54)
            .background(Theme.sidebarBG)
            Rectangle().fill(Theme.border).frame(width: 1)
            VStack(alignment: .leading, spacing: gap) {
                Text(destination.title).font(Theme.ui(Theme.textSm, weight: .semibold))
                Theme.rule.frame(height: 1)
                ForEach(Array(destination.previewRows.enumerated()), id: \.offset) { index, title in
                    VStack(alignment: .leading, spacing: density == .compact ? 4 : density == .spacious ? 8 : 6) {
                        Text(title).font(Theme.ui(10.5)).foregroundStyle(Theme.dim)
                        NativeTickMeter(fraction: index == 0 ? 0.62 : 0.34, color: index == 0 ? Theme.accent : Theme.ink, height: 7)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
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
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(selected ? Theme.raised : hovering ? Theme.subtle : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(selected ? Theme.border : .clear, lineWidth: 1))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3, height: selected ? 22 : 0).opacity(selected ? 1 : 0)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .scaleEffect(configuration.isPressed && !reducedMotion ? 0.99 : 1)
            .animation(reducedMotion ? nil : NativeMotion.hover, value: hovering)
            .animation(reducedMotion ? nil : NativeMotion.hover, value: selected)
            .animation(reducedMotion ? nil : NativeMotion.press, value: configuration.isPressed)
            .onHover { hovering = $0 }
            .onDisappear { hovering = false }
            .pointingHand()
    }
}
