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
    private var stateTone: Color? {
        switch status["phase"].string {
        case "holding", "holding-low": return Theme.ok
        case "above-limit", "control-pending": return Theme.warn
        case "control-error": return Theme.fail
        case "charging-to-limit": return Theme.signal
        default: return nil
        }
    }
    /// The limit most people want next: the usual 80 percent cap, or a full charge.
    private var quickTarget: Int { target == 100 ? (levels.first { $0 >= 80 && $0 < 100 } ?? levels.first ?? 100) : 100 }
    var body: some View {
        NativePage(title: "Battery", readiness: state.error != nil ? .failed : state.status.isNull ? .pending : .ready) {
            IconPress(icon: "refresh-cw", help: "Refresh") { refresh() }
            if status["supported"].bool {
                Button(target == 100 ? "Limit to \(quickTarget)%" : "Charge to full", nativeIcon: target == 100 ? "shield-check" : "battery-charging") {
                    guard !disabled, interaction.pending == nil, quickTarget != target else { return }
                    interaction.cancel()
                    Task { await apply(quickTarget) }
                }
                .buttonStyle(Press(.primary)).disabled(disabled || quickTarget == target)
            }
        } content: {
            if let error = state.error { failure(error) }
            if !status["error"].isNull { failure(status["error"].string) }
            if status.isNull {
                if state.error == nil {
                    Text("Reading battery state").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20)
                } else {
                    Blank(icon: "battery", title: "Battery unavailable", detail: "Refresh to try reading the battery again.",
                          actionTitle: "Refresh", actionIcon: "refresh-cw", primary: false) { refresh() }
                }
            } else if !status["supported"].bool {
                Blank(icon: "battery",
                      title: status["installed"] == .bool(false) ? "Helper not built" : "Not available on this Mac",
                      detail: status["installed"] == .bool(false)
                        ? "The battery helper is not included in this build."
                        : "This version of macOS does not offer a battery charge limit.")
            } else {
                reading
                limitScale
                ReadoutStrip(minimum: 140) {
                    Readout(label: "Health", value: status["battery"]["health"].isNull ? "--" : String(status["battery"]["health"].int),
                            unit: status["battery"]["health"].isNull ? "" : "%", size: .medium,
                            color: status["battery"]["health"].isNull ? Theme.faint : Theme.ink)
                    Readout(label: "Cycles", value: status["battery"]["cycleCount"].isNull ? "--" : String(status["battery"]["cycleCount"].int), size: .medium,
                            color: status["battery"]["cycleCount"].isNull ? Theme.faint : Theme.ink)
                    Readout(label: "Limit range", value: levels.first.map { $0 < 100 ? "\($0)–100" : "100" } ?? "--", unit: "%",
                            detail: status["hold"]["installed"].bool ? "With the charging helper" : "The levels macOS accepts", size: .medium)
                }
                if !status["hold"]["installed"].bool {
                    Band("Lower limits", spacing: 0) {
                        OptionRow(title: "Charging helper", detail: "Lower targets require one charging-helper installation.", ruled: false) {
                            Button("Install helper", nativeIcon: "download") { Task { await install() } }
                                .disabled(runtime.paths.readOnly || state.pending || status["busy"].bool)
                        }
                    }
                }
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
    private func refresh() { Task { if let service = session.battery { await state.reload(service, force: true) } } }
    private func failure(_ message: String) -> some View {
        Notice(text: message, tone: .fail).accessibilityLabel("Error: " + message)
    }
    /// Charge, large, beside the state the charger is in.
    private var reading: some View {
        ColumnFlow(minimum: 240, spacing: 32, rowSpacing: 24, maxColumns: 2) {
            VStack(alignment: .leading, spacing: 0) {
                BatteryHang()
                MicroLabel("Charge")
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    NativeNumberText(text: percent.map { String(format: "%.0f", $0) } ?? "--", font: Theme.readout(54), color: percent == nil ? Theme.faint : Theme.ink)
                    MicroLabel("%", size: 11)
                    if status["battery"]["externalConnected"].bool {
                        NativeIcon(status["battery"]["charging"].bool ? "plug-zap" : "plug", size: 15, strokeWidth: 1.75)
                            .foregroundStyle(Theme.muted).padding(.leading, 6)
                            .accessibilityLabel("Power connected")
                    }
                }
                .padding(.top, 4)
                Text(status["battery"].isNull ? "Reading battery" : status["battery"]["externalConnected"].bool ? (status["battery"]["charging"].bool ? "Charging" : "Plugged in, not charging") : "Unplugged")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 0) {
                BatteryHang(tint: stateTone ?? Theme.ink)
                MicroLabel("State")
                Text(stateName).font(Theme.display()).tracking(-0.4).foregroundStyle(targetKnown ? Theme.ink : Theme.muted)
                    .lineLimit(1).minimumScaleFactor(0.7).padding(.top, 12)
                if let phaseNote {
                    Text(phaseNote).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
    /// The whole range as a ruler. The fill is the charge; the cursor is the
    /// limit, dragged or stepped between the levels macOS accepts.
    private var limitScale: some View {
        VStack(alignment: .leading, spacing: 8) {
            control
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(targetHint).font(Theme.ui(11.5)).foregroundStyle(Theme.dim)
                Spacer(minLength: 0)
                MicroLabel("100% is off", color: Theme.faint)
            }
            .accessibilityElement(children: .combine)
        }
    }
    private var control: some View {
        GeometryReader { geometry in
            let desired = interaction.draft ?? interaction.pending ?? target
            BatteryLimitRuler(percent: percent, limit: desired, known: targetKnown, levels: levels,
                              active: controlFocused || interaction.draft != nil, width: geometry.size.width)
                .frame(height: 56).contentShape(Rectangle())
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
        }.frame(height: 56).opacity(disabled ? 0.6 : 1)
            .focusable().focused($controlFocused).focusEffectDisabled()
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
    private func levelLabel(_ level: Int) -> String { level == 100 ? "Off" : "\(level)%" }
    private var targetAccessibilityValue: String {
        guard targetKnown else { return "Reading limit" }
        let value = interaction.draft ?? interaction.pending ?? target
        return value == 100 ? "Off" : "\(value) percent"
    }
    private var targetHint: String {
        if state.pending || interaction.pending != nil { return "Setting limit" }
        if let draft = interaction.draft { return "Release to set \(levelLabel(draft))" }
        if !targetKnown { return "Reading limit" }
        return "Drag the cursor or use the arrow keys to set the limit"
    }
    private var stateName: String {
        guard targetKnown else { return "Reading limit" }
        return [
            "unsupported": "Unavailable",
            "control-pending": "Confirming limit",
            "control-error": "Limit not verified",
            "off": "No charge limit",
            "on-battery": "On battery",
            "above-limit": "Above \(target)%",
            "holding-low": "Holding near \(target)%",
            "holding": "Holding at \(target)%",
            "charging-to-limit": "Charging to \(target)%",
            "below-limit-idle": "Idle below \(target)%"
        ][status["phase"].string] ?? "Reading"
    }
    /// The sentence under the state, only where it says more than the name does.
    private var phaseNote: String? {
        guard targetKnown else { return nil }
        return ["off", "holding", "holding-low", "charging-to-limit"].contains(status["phase"].string) ? nil : phase
    }
    private var phase: String {
        guard targetKnown else { return "Reading charge-limit policy" }
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

private struct BatteryHang: View {
    var tint: Color = Theme.ink
    var body: some View {
        ZStack(alignment: .topLeading) {
            Rule()
            tint.frame(width: 2, height: 7)
        }
        .frame(height: 7, alignment: .top).padding(.bottom, 9).accessibilityHidden(true)
    }
}

/// Zero to one hundred percent, a tick per percent. Ink fills to the charge,
/// the hatched run past the cursor is the part the limit keeps empty, and the
/// notches above the bar are the levels the cursor can rest on.
private struct BatteryLimitRuler: View {
    var percent: Double?
    var limit: Int
    var known: Bool
    var levels: [Int]
    var active: Bool
    var width: CGFloat
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    private func x(_ value: Double) -> CGFloat { (width - 1) * CGFloat(max(0, min(100, value)) / 100) }

    var body: some View {
        let cursor = x(Double(limit))
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.track).frame(width: width, height: 8).offset(y: 20)
            if known && limit < 100 {
                BatteryHatch().stroke(Theme.faint, lineWidth: 1)
                    .frame(width: max(0, width - cursor), height: 8).clipped().offset(x: cursor, y: 20)
            }
            if let percent {
                Rectangle().fill(Theme.ink).frame(width: x(percent) + 1, height: 8).offset(y: 20)
                    .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: percent)
            }
            if levels.count <= 16 {
                ForEach(levels, id: \.self) { level in
                    Theme.muted.frame(width: 1, height: 4).offset(x: x(Double(level)), y: 14)
                }
            }
            TickScale(divisions: width >= 420 ? 100 : 50, major: 5, minorHeight: 3, majorHeight: 6)
                .fill(Theme.faint).frame(width: width, height: 6).offset(y: 30)
            ForEach([0, 25, 50, 75, 100], id: \.self) { mark in
                Text(String(mark)).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).fixedSize()
                    .frame(width: 40, alignment: mark == 0 ? .leading : mark == 100 ? .trailing : .center)
                    .offset(x: x(Double(mark)) - (mark == 0 ? 0 : mark == 100 ? 39 : 20), y: 41)
            }
            if known {
                Group {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(Theme.canvas)
                        .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(active ? Theme.signal : Theme.ruleStrong, lineWidth: 1))
                        .frame(width: 10, height: 24)
                        .offset(x: min(width - 10, max(0, cursor - 4.5)), y: 12)
                    Theme.signal.frame(width: 2, height: 18).offset(x: min(width - 2, max(0, cursor - 0.5)), y: 15)
                    MicroLabel(limit == 100 ? "Off" : "Limit \(limit)%", color: Theme.ink)
                        .fixedSize().frame(width: 120, alignment: cursor < 60 ? .leading : cursor > width - 60 ? .trailing : .center)
                        .offset(x: cursor < 60 ? 0 : cursor > width - 60 ? width - 120 : cursor - 60, y: 0)
                }
                .animation(reduceMotion || !visible ? nil : NativeMotion.marker, value: limit)
            }
        }
        .frame(width: width, height: 56, alignment: .topLeading)
    }
}

private struct BatteryHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY)); path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 5
        }
        return path
    }
}
