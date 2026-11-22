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
    @Namespace private var marker
    private let onFinish: (String?) -> Void

    init(onFinish: @escaping (String?) -> Void) { self.onFinish = onFinish }

    private var reducedMotion: Bool { systemReduceMotion || motion == "reduced" }
    private var scheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    private var spacing: NativeInterfaceDensity { NativeInterfaceDensity(rawValue: density) ?? .standard }

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geometry in
                // The ledger and the selector share whatever height is left, so
                // every supported window shows all four tasks without scrolling.
                let gap: CGFloat = spacing.pageGap
                let room: CGFloat = geometry.size.height - 77 - gap
                let wanted: CGFloat = spacing == .compact ? 56 : spacing == .spacious ? 72 : 64
                let line: CGFloat = max(44, min(wanted, (room / 4).rounded(.down)))
                let wide = geometry.size.width >= 720 && line >= 52
                ScrollView {
                    VStack(alignment: .leading, spacing: gap) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("What would you like to do?")
                                .font(Theme.display(24)).tracking(-0.4)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityFocused($focusedHeading)
                            OnboardingRuler().padding(.top, 14)
                        }
                        if wide {
                            HStack(alignment: .center, spacing: 28) {
                                tasks(height: line)
                                OnboardingSelector(destination: destination, size: max(168, min(236, room - 44))) { destination = $0 }
                            }
                        } else {
                            tasks(height: line)
                        }
                    }
                    .frame(maxWidth: 704, alignment: .leading)
                    .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 10)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                }
            }
            customization
            footer
        }
        .frame(maxWidth: 820, maxHeight: 660)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas).foregroundStyle(Theme.ink)
        .preferredColorScheme(scheme)
        .environment(\.nativeInterfaceDensity, spacing)
        .environment(\.nativeReducedMotion, reducedMotion)
        .task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            focusedHeading = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            UniApiWordmark(markSize: 30, textSize: 16)
            Spacer(minLength: 12)
            Button("Skip for now") { onFinish(nil) }
                .buttonStyle(Press(.quiet))
                .keyboardShortcut(.cancelAction)
            KeyCap("esc")
        }
        .frame(maxWidth: 704)
        .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    /// The four tasks as one ledger. The signal tick is the only selection
    /// mark and slides to the chosen line.
    private func tasks(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Rule()
            ForEach(OnboardingDestination.allCases) { value in
                let selected = destination == value
                Button { destination = value } label: {
                    OnboardingTaskLine(value: value, selected: selected, showsDetail: height >= 52, height: height, marker: marker)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(value.spokenChoice)
                .accessibilityHint(value.spokenHint)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
        .animation(reducedMotion ? nil : NativeMotion.marker, value: destination)
        .animation(reducedMotion ? nil : .easeInOut(duration: 0.16), value: density)
    }

    /// Pinned above the footer, so trying a look or a spacing never moves the
    /// control under the pointer.
    private var customization: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel("Look")
                Stops(options: [("dark", "Graphite"), ("light", "Paper"), ("auto", "Auto")], selection: appearance,
                      icons: ["dark": "moon", "light": "sun", "auto": "monitor"]) { appearance = $0 }
                    .accessibilityLabel("Appearance")
            }
            VStack(alignment: .leading, spacing: 4) {
                MicroLabel("Spacing")
                Stops(options: [("compact", "Compact"), ("standard", "Default"), ("spacious", "Spacious")], selection: density) { density = $0 }
                    .accessibilityLabel("Page spacing")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 704, alignment: .leading)
        .padding(.horizontal, 32).padding(.top, 10).padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rule()
            HStack(spacing: 16) {
                Text("Nothing connects or downloads here. All of it can change in Settings.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                KeyCap("return")
                Button { onFinish(destination.rawValue) } label: {
                    HStack(spacing: 10) {
                        ZStack(alignment: .leading) {
                            // The widest name reserves the width, so the button does not resize under the pointer.
                            ForEach(OnboardingDestination.allCases) { Text("Open \($0.title)").hidden() }
                            Text("Open \(destination.title)")
                        }
                        .font(Theme.ui(13, weight: .semibold))
                        NativeIcon("arrow-right", size: 14, strokeWidth: 1.75).accessibilityHidden(true)
                    }
                    .padding(.horizontal, 6)
                }
                .buttonStyle(Press(.primary, height: 40)).keyboardShortcut(.defaultAction)
                .accessibilityLabel("Open \(destination.title)")
            }
            .padding(.top, 16).padding(.bottom, 20)
        }
        .frame(maxWidth: 704)
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }
}

private enum OnboardingDestination: String, CaseIterable, Identifiable {
    case home, switcher, stats, transcribe
    var id: String { rawValue }
    var title: String {
        switch self { case .home: return "Home"; case .switcher: return "Switcher"; case .stats: return "Statistics"; case .transcribe: return "Transcribe" }
    }
    var actionTitle: String {
        switch self {
        case .home: return "Look around"
        case .switcher: return "Connect a model"
        case .stats: return "Explore usage"
        case .transcribe: return "Transcribe audio"
        }
    }
    var spokenChoice: String { "\(actionTitle). Select \(title) as starting page. \(detail)" }
    var spokenHint: String { "Use Open \(title) to continue." }
    var icon: String {
        switch self { case .home: return "house"; case .switcher: return "route"; case .stats: return "chart-line"; case .transcribe: return "mic" }
    }
    var detail: String {
        switch self {
        case .home: return "Your apps at a glance."
        case .switcher: return "Choose a provider and model."
        case .stats: return "Review tokens and cost estimates."
        case .transcribe: return "Install Whisper when you need it."
        }
    }
}

/// The heading's rule, graduated across its whole length.
private struct OnboardingRuler: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rule(strong: true)
            TickScale().fill(Theme.faint).frame(height: 6).frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).frame(height: 6, alignment: .top)
        .accessibilityHidden(true)
    }
}

/// One task: what to do, where it opens. The row keeps its height whatever is
/// selected; only the tick and the ink change.
private struct OnboardingTaskLine: View {
    let value: OnboardingDestination
    let selected: Bool
    let showsDetail: Bool
    let height: CGFloat
    let marker: Namespace.ID
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reducedMotion

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            NativeIcon(value.icon, size: 18, strokeWidth: 1.6)
                .foregroundStyle(selected ? Theme.ink : Theme.muted)
                .frame(width: 22, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(value.actionTitle).font(Theme.display(17, weight: .medium))
                    .foregroundStyle(selected || hovering ? Theme.ink : Theme.dim).lineLimit(1)
                if showsDetail {
                    Text(value.detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            MicroLabel(value.title, color: selected ? Theme.ink : Theme.muted)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(selected ? Theme.pressed : hovering ? Theme.hover : .clear)
                .padding(.horizontal, -10)
        }
        .overlay(alignment: .leading) {
            if selected {
                Theme.signal.frame(width: 2, height: 18).offset(x: -10)
                    .matchedGeometryEffect(id: "selected", in: marker)
            }
        }
        .overlay(alignment: .bottom) { Rule() }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .animation(reducedMotion ? nil : NativeMotion.hover, value: hovering)
        .pointingHand()
    }
}

/// The choice drawn as an instrument: a four-position selector whose needle
/// swings to the chosen page. It restates the ledger: its stops select the
/// same tasks, it holds no data, opens nothing and is hidden from assistive
/// technology, which already has the ledger.
private struct OnboardingSelector: View {
    let destination: OnboardingDestination
    var size: CGFloat = 236
    let choose: (OnboardingDestination) -> Void

    private func fraction(_ value: OnboardingDestination) -> Double {
        let index = OnboardingDestination.allCases.firstIndex(of: value) ?? 0
        return (Double(index) * 2 + 1) / 8
    }

    var body: some View {
        ZStack {
            Dial(fraction: fraction(destination), color: .clear, size: size) {
                VStack(spacing: 6) {
                    MicroLabel("Opens")
                    NativeNumberText(text: destination.title, font: Theme.display(24), color: Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: size - 64)
                }
            }
            ForEach(OnboardingDestination.allCases) { value in
                let angle = (-120 + 240 * fraction(value)) * Double.pi / 180
                let radius = Double(size) / 2 + 20
                OnboardingSelectorStop(icon: value.icon, selected: value == destination) { choose(value) }
                    .offset(x: CGFloat(sin(angle) * radius), y: CGFloat(-cos(angle) * radius))
            }
        }
        .frame(width: size + 76, height: size + 44)
        .accessibilityHidden(true)
    }
}

private struct OnboardingSelectorStop: View {
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reducedMotion
    var body: some View {
        Button(action: action) {
            NativeIcon(icon, size: 16, strokeWidth: 1.6)
                .foregroundStyle(selected ? Theme.ink : hovering ? Theme.dim : Theme.faint)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
        .animation(reducedMotion ? nil : NativeMotion.hover, value: hovering)
        .animation(reducedMotion ? nil : NativeMotion.hover, value: selected)
    }
}
