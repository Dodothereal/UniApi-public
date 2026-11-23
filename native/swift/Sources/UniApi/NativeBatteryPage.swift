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
    var body: some View {
        NativePage(title: "Battery", readiness: state.error != nil ? .failed : state.status.isNull ? .pending : .ready, actions: {
            T3IconButton(system: "refresh-cw", help: "Refresh") { Task { if let service = session.battery { await state.reload(service, force: true) } } }
        }) {
            if let error = state.error { NativeError(message: error) }
            if !status["error"].isNull { NativeError(message: status["error"].string) }
            if status.isNull {
                if state.error == nil { ShimmerText(text: "Loading…") }
            } else if !status["supported"].bool {
                NativeEmptyState(
                    title: status["installed"] == .bool(false) ? "Helper not built" : "No charge limit on this Mac",
                    detail: status["installed"] == .bool(false) ? "This build does not include the battery helper." : "This version of macOS does not offer one.",
                    icon: "battery")
            } else {
                headline
                if !status["hold"]["installed"].bool {
                    NativeSetup(steps: [NativeSetupStep(id: "helper", title: "Install the charging helper", detail: "Limits below 100% need it. It is installed once.",
                                                        done: false, enabled: !(runtime.paths.readOnly || state.pending || status["busy"].bool),
                                                        actionTitle: "Install", actionIcon: "download", action: { Task { await install() } })])
                }
                limit
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
    private var power: String {
        status["battery"].isNull ? "" : status["battery"]["externalConnected"].bool ? (status["battery"]["charging"].bool ? "Charging" : "Plugged in, not charging") : "On battery"
    }
    private var headline: some View {
        var facts = [NativeHeroFact(label: "Limit", value: !targetKnown ? "—" : target == 100 ? "Off" : "\(target)%", tone: targetKnown && target < 100 ? Theme.accent : Theme.ink)]
        if !status["battery"]["health"].isNull { facts.append(NativeHeroFact(label: "Health", value: "\(status["battery"]["health"].int)%")) }
        if !status["battery"]["cycleCount"].isNull { facts.append(NativeHeroFact(label: "Cycles", value: "\(status["battery"]["cycleCount"].int)")) }
        return NativeHero(value: percent.map { String(format: "%.0f", $0) } ?? "—", numeric: percent, unit: percent == nil ? "" : "%", facts: facts) {
            Text("Charge")
            Text(power).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
        } trailing: { EmptyView() }
    }
    private var limit: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(phase).font(Theme.ui(Theme.textSm)).foregroundStyle(status["phase"].string == "control-error" ? Theme.failFg : Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if state.pending { ProgressView().controlSize(.mini).accessibilityHidden(true) }
                Text(targetHint).font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(interaction.draft != nil ? Theme.accent : Theme.muted)
            }.padding(.bottom, 14)
            control
            targetRange
        }
    }
    private var control: some View {
        GeometryReader { geometry in
            let desired = interaction.draft ?? interaction.pending ?? target
            ZStack(alignment: .leading) {
                NativeTickMeter(fraction: (percent ?? 0) / 100, color: Theme.ink, height: 20)
                ForEach(levels, id: \.self) { level in
                    Theme.faint.frame(width: 1, height: 5)
                        .offset(x: geometry.size.width * Double(level) / 100 - 0.5, y: 16)
                }
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Theme.accent)
                    .frame(width: 3, height: 32)
                    .offset(x: geometry.size.width * Double(desired) / 100 - 1.5)
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
            Text("Off").fixedSize()
        }
        .font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint)
        .accessibilityHidden(true)
    }
    private func levelLabel(_ level: Int) -> String { level == 100 ? "Off" : "\(level)%" }
    private var targetAccessibilityValue: String {
        guard targetKnown else { return "Reading limit" }
        let value = interaction.draft ?? interaction.pending ?? target
        return value == 100 ? "Off" : "\(value) percent"
    }
    private var targetHint: String {
        if state.pending || interaction.pending != nil { return "Setting" }
        if let draft = interaction.draft { return "Release for \(levelLabel(draft))" }
        return ""
    }
    private var phase: String {
        guard targetKnown else { return "" }
        return [
            "unsupported": "This Mac does not offer a charge limit.",
            "control-pending": "Limit requested. Waiting for charging telemetry to confirm it.",
            "control-error": "The helper could not apply charging control. The requested limit is not verified.",
            "off": "Charges to 100%. Drag the marker to stop earlier.",
            "on-battery": "Running on battery. The limit applies again when you plug in.",
            "above-limit": "Above the \(target)% limit and not charging. macOS manages the transition down to the target.",
            "holding-low": "Plugged in and not charging near \(target)%.",
            "holding": "Plugged in and not charging at \(target)%.",
            "charging-to-limit": "Charging below the requested \(target)% limit.",
            "below-limit-idle": "Below the \(target)% limit, plugged in and not charging. macOS controls when charging resumes."
        ][status["phase"].string] ?? ""
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
