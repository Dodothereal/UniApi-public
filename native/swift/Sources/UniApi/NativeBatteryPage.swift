import SwiftUI
import UniApiCore
import UniApiPresentation

@MainActor
private final class NativeBatteryModel: ObservableObject {
    @Published var status: JSONValue = .null
    @Published var pending = false
    @Published var error: String?
    private var generation = 0
    private var recovery = false
    private let reads = NativePageReadScope()
    func resume() { reads.resume() }
    func stop() { reads.suspend() }
    func reload(_ service: NativeBatteryService, force: Bool = false) async {
        guard let ticket = reads.begin("status") else { return }
        let own = generation
        do {
            let next = try await service.handle("status", input: ["force": .bool(force)])
            if reads.accepts(ticket), own == generation && (!pending || recovery) {
                status = next
                if recovery && next["error"].isNull && !next["battery"].isNull { pending = false; recovery = false }
            }
        }
        catch { if reads.accepts(ticket), own == generation { self.error = error.localizedDescription } }
    }
    func select(_ target: Int, service: NativeBatteryService) async {
        guard !pending else { return }
        generation += 1; pending = true; recovery = false; error = nil
        do {
            let lowest = status["levels"].array.map(\.int).min() ?? 80
            let next = try await service.handle(target == 100 ? "off" : target < lowest ? "hold" : "limit", input: target == 100 ? [:] : [target < lowest ? "target" : "limit": .number(Double(target))])
            status = next; pending = false
        } catch {
            self.error = error.localizedDescription
            let fresh = try? await service.handle("status", input: ["force": true])
            recovery = true
            if let fresh { status = fresh; if fresh["error"].isNull && !fresh["battery"].isNull { pending = false; recovery = false } }
        }
    }
    func update(_ value: JSONValue) { guard reads.active else { return }; reads.invalidate("status"); if !pending || recovery { status = value; if recovery && value["error"].isNull && !value["battery"].isNull { pending = false; recovery = false } } }
}

struct NativeBatteryPage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var state = NativeBatteryModel()
    @State private var interaction = NativeBatteryTargetInteraction()
    @GestureState private var pointerDown = false
    @FocusState private var controlFocused: Bool
    private var status: JSONValue { state.status }
    private var target: Int { NativeHardwareDisplayPolicies.batteryTarget(status) }
    private var levels: [Int] { NativeHardwareDisplayPolicies.batteryLevels(status) }
    private var targetKnown: Bool {
        let raw = status["hold"]["active"].bool ? status["hold"]["target"] : status["limit"]
        return NativeBatteryTargetInteraction.confirmedTarget(NativeHardwareDisplayPolicies.number(raw)) != nil
    }
    private var disabled: Bool { runtime.paths.readOnly || state.pending || status["busy"].bool || !status["supported"].bool || !targetKnown }
    private var percent: Double? { NativeHardwareDisplayPolicies.number(status["battery"]["percent"]) }
    private var limitLabel: String { !targetKnown ? "Reading limit…" : target == 100 ? "No limit" : "Limit \(target)%" }
    private var statusColor: Color {
        switch status["phase"].string {
        case "holding", "holding-low": return Theme.okFg
        case "above-limit": return Theme.warnFg
        case "off": return Theme.muted.opacity(0.5)
        default: return Theme.accent
        }
    }
    var body: some View {
        NativePage(title: "Battery", subtitle: "Stop charging at a level instead of always filling to 100%, so the charger powers the Mac directly.", readiness: state.error != nil ? .failed : state.status.isNull ? .pending : .ready) {
            if let error = state.error { NativeError(message: error) }
            if !status["error"].isNull { NativeError(message: status["error"].string) }
            if status.isNull {
                if state.error == nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading battery state…").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 48)
                } else {
                    NativeEmptyState(title: "Battery unavailable", detail: "Refresh to try reading the battery again.", icon: "battery.0percent")
                    refreshButton
                }
            } else if !status["supported"].bool {
                NativeEmptyState(
                    title: status["installed"] == .bool(false) ? "Helper not built" : "Not available on this Mac",
                    detail: status["installed"] == .bool(false)
                        ? "The battery helper is not included in this build."
                        : "This version of macOS does not offer a battery charge limit.",
                    icon: "battery.0percent")
            } else {
                controlCard
            }
        }
        .onChange(of: disabled) { _, value in if value { interaction.cancel() } }
        .onChange(of: scenePhase) { _, value in if value != .active { interaction.blur() } }
        .onAppear { interaction.endPointerSequence() }
        .nativePageTask {
            state.resume()
            guard let service = session.battery else { return }
            let events = await runtime.events.stream()
            await state.reload(service, force: true)
            for await event in events {
                if Task.isCancelled { break }
                if event.topic == "battery.state" { state.update(event.data) }
            }
        }
        .nativePageActivity(suspended: { state.stop(); interaction.blur(); controlFocused = false })
    }
    private var controlCard: some View {
        Card(padding: 20) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            NativeNumberText(text: percent.map { String(format: "%.0f%%", $0) } ?? "—", font: Theme.ui(34, weight: .medium), color: percent == nil ? Theme.muted : Theme.ink)
                            if status["battery"]["externalConnected"].bool {
                                NativeIcon("plug", size: 14)
                                    .foregroundStyle(Theme.muted)
                                    .accessibilityLabel("Power connected")
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 8) {
                            StatusDot(color: statusColor, pulse: status["phase"].string == "charging-to-limit")
                                .accessibilityHidden(true)
                            Text(limitLabel).font(Theme.ui(12)).foregroundStyle(Theme.dim)
                        }
                        .fixedSize()
                        .accessibilityElement(children: .combine)
                    }

                    control.padding(.top, 12)
                    targetRange

                    Text(phase)
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.dim)
                        .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            readouts
                            Spacer(minLength: 0)
                            refreshButton
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            readouts
                            refreshButton
                        }
                    }
                    .padding(.top, 16)

                    if !status["hold"]["installed"].bool {
                        helperInstallation.padding(.top, 16)
                    }
                }
            }
    }
    private var control: some View {
        GeometryReader { geometry in
            let desired = interaction.draft ?? interaction.pending ?? target
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.subtle2).frame(height: 8)
                if let percent {
                    Capsule().fill(Theme.accent.opacity(0.4))
                        .frame(width: geometry.size.width * max(0, min(1, percent / 100)), height: 8)
                }
                Capsule().fill(Theme.accent)
                    .overlay(Capsule().strokeBorder(Theme.surface, lineWidth: 2))
                    .frame(width: 12, height: 20)
                    .shadow(color: Theme.shadow.opacity(0.25), radius: 1, y: 1)
                    .offset(x: geometry.size.width * Double(desired) / 100 - 6)
            }.frame(height: 48).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($pointerDown) { _, down, _ in down = true }
                    .onChanged { value in
                        if !interaction.hasPointerSequence && !disabled && interaction.pending == nil { controlFocused = true }
                        interaction.pointerChanged(to: Double(value.location.x / max(1, geometry.size.width)) * 100,
                                                   current: target, levels: levels, enabled: !disabled)
                    }
                    .onEnded { value in
                        commit(interaction.pointerReleased(at: Double(value.location.x / max(1, geometry.size.width)) * 100,
                                                           current: target, levels: levels, enabled: !disabled))
                    })
        }.frame(height: 48).opacity(disabled ? 0.6 : 1)
            .focusable().focused($controlFocused)
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(controlFocused ? Theme.accent : .clear, lineWidth: 1))
            .onChange(of: pointerDown) { _, down in
                guard !down, let sequence = interaction.pointerSequenceID else { return }
                // Gesture-state reset and onEnded have no assumed callback order.
                // Defer abandonment cleanup and reject callbacks from older drags.
                DispatchQueue.main.async {
                    guard !pointerDown else { return }
                    interaction.endPointerSequence(ifMatching: sequence)
                }
            }
            .onChange(of: controlFocused) { _, focused in if !focused { interaction.blur() } }
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow, .home, .end, .escape], phases: [.down, .repeat, .up]) { key in
                if key.key == .escape {
                    if key.phase != .up { interaction.cancel() }
                    return .handled
                }
                guard let direction = interactionKey(key.key) else { return .ignored }
                if key.phase == .up {
                    commit(interaction.keyUp(direction, current: target, levels: levels, enabled: !disabled))
                } else {
                    interaction.keyDown(direction, repeating: key.phase == .repeat, current: target, levels: levels, enabled: !disabled)
                }
                return disabled ? .ignored : .handled
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Charge-limit target")
            .accessibilityValue(targetAccessibilityValue)
            .accessibilityAdjustableAction { direction in
                commit(interaction.adjust(direction == .increment ? .up : .down, current: target, levels: levels, enabled: !disabled))
            }
    }
    private var targetRange: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(levelLabel(levels.first ?? 100)).fixedSize()
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if state.pending { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                Text(targetHint)
            }
            .foregroundStyle(Theme.dim)
            .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Text("100% · Off").fixedSize()
        }
        .font(Theme.ui(11)).foregroundStyle(Theme.muted).monospacedDigit()
        .accessibilityElement(children: .combine)
    }
    private func levelLabel(_ level: Int) -> String { level == 100 ? "Off" : "\(level)%" }
    private var targetAccessibilityValue: String {
        guard targetKnown else { return "Reading limit" }
        let value = interaction.draft ?? interaction.pending ?? target
        return value == 100 ? "Off" : "\(value) percent"
    }
    private var targetHint: String {
        if state.pending || interaction.pending != nil { return "Setting limit…" }
        if let draft = interaction.draft { return "Release to set \(levelLabel(draft))" }
        if !targetKnown { return "Reading limit…" }
        return "Drag to set limit · \(levelLabel(target))"
    }
    private var readouts: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { batteryReadouts }
            VStack(alignment: .leading, spacing: 4) { batteryReadouts }
        }
        .font(Theme.ui(11)).foregroundStyle(Theme.muted).monospacedDigit()
    }
    @ViewBuilder private var batteryReadouts: some View {
        if !status["battery"]["health"].isNull { Text("Health \(status["battery"]["health"].int)%").fixedSize() }
        if !status["battery"]["cycleCount"].isNull { Text("\(status["battery"]["cycleCount"].int) cycles").fixedSize() }
        Text(status["battery"].isNull ? "Reading battery…" : status["battery"]["externalConnected"].bool ? (status["battery"]["charging"].bool ? "Charging" : "Plugged in, not charging") : "On battery")
            .fixedSize()
    }
    private var refreshButton: some View {
        Button {
            Task { if let service = session.battery { await state.reload(service, force: true) } }
        } label: {
            HStack(spacing: 6) { NativeIcon("refresh-cw", size: 12); Text("Refresh") }
        }
        .buttonStyle(T3Button(.ghost, size: 11))
        .fixedSize()
    }
    private var helperInstallation: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                helperExplanation
                Spacer(minLength: 0)
                installButton
            }
            VStack(alignment: .leading, spacing: 10) {
                helperExplanation
                installButton
            }
        }
    }
    private var helperExplanation: some View {
        Text("Lower targets require one charging-helper installation.")
            .font(Theme.ui(11)).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
    private var installButton: some View {
        Button("Install helper") { Task { await install() } }
            .buttonStyle(T3Button(.outline, size: 11))
            .fixedSize()
            .disabled(runtime.paths.readOnly || state.pending || status["busy"].bool)
    }
    private var phase: String {
        guard targetKnown else { return "Reading charge-limit policy…" }
        return [
            "unsupported": "This Mac does not offer a charge limit.",
            "control-pending": "Limit requested. Waiting for charging telemetry to confirm it.",
            "control-error": "The helper could not apply charging control. The requested limit is not verified.",
            "off": "No charge limit is set.",
            "on-battery": "Running on battery. The limit applies again when you plug in.",
            "above-limit": "Above the \(target)% limit and not charging. macOS manages the transition down to the target.",
            "holding-low": "Plugged in and not charging near \(target)%.",
            "holding": "Plugged in and not charging at \(target)%.",
            "charging-to-limit": "Charging below the requested \(target)% limit.",
            "below-limit-idle": "Below the \(target)% limit, plugged in and not charging. macOS controls when charging resumes."
        ][status["phase"].string] ?? "Reading battery state"
    }
    private func interactionKey(_ key: KeyEquivalent) -> NativeBatteryTargetInteraction.Key? {
        switch key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        case .home: return .home
        case .end: return .end
        default: return nil
        }
    }
    private func commit(_ value: Int?) {
        guard let value else { return }
        Task { await apply(value); interaction.commitFinished() }
    }
    private func apply(_ target: Int) async { if let service = session.battery { await state.select(target, service: service) } }
    private func install() async { guard let service = session.battery else { return }; do { _ = try await service.handle("install"); await state.reload(service, force: true) } catch { state.error = error.localizedDescription } }
}
