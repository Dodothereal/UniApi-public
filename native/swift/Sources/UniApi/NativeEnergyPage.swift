import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

/// Series hues shared by the readings and the plots they belong to. System
/// load is drawn in ink: it is the reading the page leads with.
private enum EnergySeries {
    static var load: Color { Theme.ink }
    static let wall = Theme.pairPalette[3]
    static let flow = Theme.pairPalette[6]
}

struct NativeEnergyPage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @Environment(\.nativeReducedMotion) private var reduceMotion
    /// Preferences moved behind the header control; an earlier stored
    /// "settings" value opens the live view.
    private static let views = ["flow", "history", "sensors"]
    @State private var reads = NativePageReadScope()
    @State private var preferencesRestored = false
    @State private var state: JSONValue = .null
    @State private var historySelection = NativeFanHistorySelection()
    @AppStorage("uniapi.energy.tab") private var tab = "flow"
    @AppStorage("uniapi.energy.range") private var range = "24h"
    @AppStorage("uniapi.energy.statistic") private var statistic = "mean"
    @State private var query = ""
    @State private var group = "All"
    @State private var favorites = Set<String>()
    @State private var from = Date().addingTimeInterval(-86400)
    @State private var through = Date()
    @State private var error: String?
    @State private var statusReadError: String?
    @State private var pending = false
    @State private var rateText = "0.30"
    @State private var currencyText = "$"
    @State private var showsPreferences = false
    @State private var showsBreakdown = false

    private var snapshot: JSONValue { state["snapshot"] }
    private var sessionStats: JSONValue { state["session"] }
    private var allTimeStats: JSONValue { state["allTime"] }
    private var bootStats: JSONValue { snapshot["boot"] }
    private var battery: JSONValue { snapshot["battery"] }
    private var batteryPresent: Bool { battery["present"].bool }
    private var prefs: JSONValue { state["preferences"] }
    private var ratePerKwh: Double { NativeHardwareDisplayPolicies.number(prefs["ratePerKwh"]) ?? 0.30 }
    private var currency: String { prefs["currency"].string.isEmpty ? "$" : prefs["currency"].string }
    private var view: String { Self.views.contains(tab) ? tab : "flow" }
    private var needsHistory: Bool { ["flow", "history", "settings"].contains(tab) }
    private var historyRange: String { range }
    private var historyScope: String { historyRange == "custom" ? "custom:\(from.timeIntervalSince1970):\(through.timeIntervalSince1970)" : historyRange }
    private var history: JSONValue { historySelection.value(for: historyScope) }
    private var historyError: String? { historySelection.error(for: historyScope) }
    private var sensorRows: [JSONValue] {
        NativeHardwareDisplayPolicies.energySensorRows(snapshot["sensors"].array, favorites: favorites, group: group, query: query)
    }

    private static let rangeOptions: [(String, String)] = [
        ("30m", "30m"), ("1h", "1h"), ("6h", "6h"), ("24h", "24h"),
        ("7d", "7d"), ("30d", "30d"), ("all", "All"), ("custom", "Custom")
    ]

    private var rangeDisplayName: String {
        switch historyRange {
        case "30m": return "Last 30 minutes"
        case "1h": return "Last hour"
        case "6h": return "Last 6 hours"
        case "24h": return "Last 24 hours"
        case "7d": return "Last 7 days"
        case "30d": return "Last 30 days"
        case "90d": return "Last 90 days"
        case "1y": return "Last year"
        case "all": return "All recorded time"
        case "custom": return "Custom date range"
        default: return historyRange
        }
    }

    private var pageReadiness: NativePageReadiness {
        if error != nil || statusReadError != nil || !state["error"].string.isEmpty { return .failed }
        if state.isNull { return .pending }
        if !state["supported"].bool { return .ready }
        if needsHistory && historyError != nil { return .failed }
        if snapshot.isNull || (needsHistory && history.isNull) { return .pending }
        return .ready
    }

    private var eyebrow: String {
        if !snapshot.isNull { return "Live · every 2 s" }
        if state.isNull { return "Reading power telemetry" }
        return state["supported"].bool ? "Waiting for readings" : "Unavailable on this Mac"
    }

    var body: some View {
        NativePage(title: "Energy", eyebrow: eyebrow, readiness: pageReadiness) {
            headerActions
        } content: {
            if let statusReadError {
                if state.isNull {
                    NativeReadFailureState(icon: "zap", title: "Power telemetry could not be read", detail: statusReadError, retryTitle: "Retry") {
                        Task { await reload(force: true) }
                    }
                } else { failure(statusReadError) }
            }
            if let error { Notice(text: error, tone: .fail).accessibilityLabel("Error: " + error) }
            if !state["error"].string.isEmpty { failure(state["error"].string) }
            if !state.isNull && !state["supported"].bool {
                Blank(icon: "zap", title: "This Mac reports no power telemetry",
                      detail: "Neither battery telemetry nor power sensors are exposed here, which is usual for a virtual machine.")
            } else if !(state.isNull && statusReadError != nil) {
                switch view {
                case "history": historyView
                case "sensors": sensorsView
                default: nowView
                }
            }
        }
        .nativePageTask {
            if !preferencesRestored {
                if let saved = UserDefaults.standard.array(forKey: "uniapi.energy.favorites") as? [String] { favorites = Set(saved) }
                preferencesRestored = true
            }
            let events = await runtime.events.stream()
            await reload(force: true)
            for await event in events {
                if Task.isCancelled { break }
                if event.topic == "energy.state" {
                    reads.invalidate("status")
                    state = event.data
                    statusReadError = nil
                    syncPreferenceInputs()
                }
            }
        }
        .nativePageTask(id: "\(tab):\(historyScope)") {
            guard needsHistory else { return }
            while !Task.isCancelled {
                await loadHistory()
                do { try await Task.sleep(nanoseconds: tab == "flow" ? 10_000_000_000 : 20_000_000_000) } catch { return }
            }
        }
        .nativePageTask {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                await reload()
            }
        }
        .nativePageActivity(reads: reads)
    }

    private func failure(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Notice(text: message, tone: .fail).accessibilityLabel("Error: " + message)
            Button("Retry") { Task { await reload(force: true) } }
        }
    }

    // MARK: - Header

    @ViewBuilder private var headerActions: some View {
        Stops(options: [("flow", "Now"), ("history", "History"), ("sensors", "Rails")], selection: view) { tab = $0 }
            .accessibilityLabel("Energy sections")
            .padding(.trailing, 6)
        IconPress(icon: "refresh-cw", help: "Refresh") {
            Task {
                await reload(force: true)
                if needsHistory { await loadHistory() }
            }
        }
        IconPress(icon: "sliders-horizontal", help: "Energy preferences", active: showsPreferences) { showsPreferences.toggle() }
            .popover(isPresented: $showsPreferences, arrowEdge: .bottom) { preferencesPanel }
        Button("Export CSV", nativeIcon: "download") { exportHistory() }
            .buttonStyle(Press(.primary))
            .disabled(history["points"].array.isEmpty)
    }

    private var rangeStops: some View {
        Stops(options: Self.rangeOptions, selection: range, spacing: 14) { range = $0 }
            .accessibilityLabel("Time window")
    }

    private var statisticStops: some View {
        Stops(options: [("mean", "Average"), ("max", "Peak"), ("min", "Minimum")], selection: statistic) { statistic = $0 }
            .accessibilityLabel("Statistic")
    }

    @ViewBuilder private var customRange: some View {
        if range == "custom" {
            HStack(spacing: 20) {
                DatePicker("From", selection: $from, in: ...through, displayedComponents: .date)
                DatePicker("Through", selection: $through, in: from...Date(), displayedComponents: .date)
            }
            .datePickerStyle(.compact).font(Theme.ui(12.5)).foregroundStyle(Theme.dim).fixedSize()
        }
    }

    // MARK: - Now

    @ViewBuilder private var nowView: some View {
        hero
        powerPath
        Band(title: "Energy used", spacing: 16) { rangeStops } content: {
            customRange
            if let historyError { Notice(text: historyError, tone: .fail).accessibilityLabel("Error: " + historyError) }
            energyStrip
            breakdown
        }
        Band(title: "Timeline") { statisticStops } content: {
            Well {
                NativeLineChart(series: powerSeries(kind: statistic), height: 205, showPoints: false, includeZero: true,
                                xFormat: { formatAxisDate($0) }, yFormat: { String(format: "%.1f W", $0) })
            }
        }
        consumers
    }

    /// The meter's full scale: the supply's limit when the Mac reports one,
    /// otherwise the next round figure above anything seen so far.
    private var gaugeMaximum: (value: Double, limit: Bool) {
        if let budget = NativeHardwareDisplayPolicies.number(snapshot["powerBudgetW"]), budget > 0 { return (budget, true) }
        let seen = [snapshot["systemLoadW"], history["summary"]["peakSystemLoadW"], sessionStats["peakSystemLoadW"]]
            .compactMap(NativeHardwareDisplayPolicies.number).max() ?? 0
        let steps: [Double] = [4, 8, 12, 20, 40, 60, 80, 100, 120, 160, 200, 300, 400, 600, 800]
        return (steps.first { $0 >= seen * 1.1 } ?? 800, false)
    }

    private var sourceTag: Tag? {
        guard !snapshot.isNull else { return nil }
        let mode = snapshot["powerMode"].string
        let external = snapshot["externalConnected"].bool
        let flow = snapshot["batteryPowerW"].double
        let text: String
        if !batteryPresent || mode == "wall-only" {
            text = String(format: "AC direct · %.2f V × %.2f A", snapshot["voltageInV"].double, snapshot["currentInA"].double)
        } else if external {
            if mode == "ac-charging" || flow > 0.2 { text = String(format: "On AC · charging %+.1f W", flow) }
            else if mode == "ac-assisting" || flow < -0.2 { text = String(format: "On AC · battery assisting %.1f W", abs(flow)) }
            else { text = "On AC · powering the Mac directly" }
        } else {
            text = String(format: "On battery · %.1f W draw", abs(flow))
        }
        return Tag(text, tone: external || !batteryPresent ? Theme.okFg : Theme.warnFg, dot: true)
    }

    private var hero: some View {
        let load = NativeHardwareDisplayPolicies.number(snapshot["systemLoadW"])
        let wall = NativeHardwareDisplayPolicies.number(snapshot["wallPowerW"])
        let gauge = gaugeMaximum
        let summary = history["summary"]
        let low = NativeHardwareDisplayPolicies.number(summary["minSystemLoadW"])
        let high = NativeHardwareDisplayPolicies.number(summary["peakSystemLoadW"])
        let spread: ClosedRange<Double>? = low.flatMap { low in high.flatMap { $0 >= low ? low...$0 : nil } }
        let hourly = ((wall ?? load ?? 0) / 1000.0) * ratePerKwh
        var facts: [String] = []
        if load != nil { facts.append(String(format: "%@%.3f an hour", currency, hourly)) }
        if !bootStats["avgSystemLoadW"].isNull { facts.append(String(format: "%.1f W average since boot", bootStats["avgSystemLoadW"].double)) }
        var envelope = ""
        if let spread {
            envelope = String(format: "Shaded: %@, %.1f to %.1f W", rangeDisplayName.lowercased(), spread.lowerBound, spread.upperBound)
            if let mean = NativeHardwareDisplayPolicies.number(summary["avgSystemLoadW"]) { envelope += String(format: " · average %.1f W", mean) }
            if let p95 = NativeHardwareDisplayPolicies.number(summary["p95SystemLoadW"]) { envelope += String(format: " · 95th percentile %.1f W", p95) }
        }
        let endLabel = String(format: gauge.limit ? "%.0f W supply limit" : "%.0f W", gauge.value)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                if load != nil { NativeStatusDot(color: Theme.signal, size: 5, pulse: true) }
                MicroLabel("System load")
                Spacer(minLength: 12)
                if let sourceTag { sourceTag }
            }
            .frame(minHeight: 18)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    NativeNumberText(text: figure(load), font: Theme.readout(54), color: load == nil ? Theme.faint : Theme.ink, isolateLayout: true)
                    MicroLabel("watts", size: 11)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("System load")
                .accessibilityValue(load == nil ? "Unavailable" : figure(load) + " watts")
                Spacer(minLength: 16)
                Text(facts.joined(separator: " · ")).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            EnergyGauge(value: load, maximum: gauge.value, spread: spread, endLabel: endLabel).padding(.top, 8)
            if !envelope.isEmpty {
                Text(envelope).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 10)
            }
        }
    }

    /// Wall to supply rail to battery: the stages around the load above.
    private var powerPath: some View {
        let wall = NativeHardwareDisplayPolicies.number(snapshot["wallPowerW"])
        let supply = NativeHardwareDisplayPolicies.number(snapshot["systemPowerInW"])
        let loss = NativeHardwareDisplayPolicies.number(snapshot["adapterLossW"])
        let load = NativeHardwareDisplayPolicies.number(snapshot["systemLoadW"])
        let flow = NativeHardwareDisplayPolicies.number(snapshot["batteryPowerW"])
        let efficiency = NativeHardwareDisplayPolicies.number(snapshot["efficiencyPercent"])
        let budget = NativeHardwareDisplayPolicies.number(snapshot["powerBudgetW"])
        let thermal = subsystemWatts("thermal"), soc = subsystemWatts("soc")
        var rail = snapshot.isNull ? "" : String(format: "%.2f V × %.2f A", snapshot["voltageInV"].double, snapshot["currentInA"].double)
        if let budget, budget > 0 { rail += String(format: " · %.0f W free", max(0, budget - (supply ?? 0))) }
        return ReadoutStrip(minimum: 200) {
            Readout(label: "Wall", value: figure(wall), unit: "W",
                    detail: loss.map { String(format: "%.2f W lost in conversion", $0) } ?? "",
                    size: .medium, tint: EnergySeries.wall, color: wall == nil ? Theme.faint : Theme.ink, isolateLayout: true)
            Readout(label: "Supply rail", value: figure(supply), unit: "W", detail: rail,
                    size: .medium, color: supply == nil ? Theme.faint : Theme.ink, isolateLayout: true)
            if batteryPresent {
                Readout(label: (flow ?? 0) > 0.05 ? "Battery charging" : (flow ?? 0) < -0.05 ? "Battery discharging" : "Battery resting",
                        value: figure(flow, "%+.1f"), unit: "W", detail: batteryDetail,
                        size: .medium, tint: EnergySeries.flow, color: (flow ?? 0) < -0.05 ? Theme.warnFg : Theme.ink, isolateLayout: true)
            } else {
                Readout(label: "SoC and thermal", value: figure(soc ?? thermal ?? load), unit: "W",
                        detail: snapshot.isNull ? "" : String(format: "Thermal zone %.2f W · total heat %.1f W", thermal ?? 0, wall ?? 0),
                        size: .medium, tint: EnergySeries.flow, color: snapshot.isNull ? Theme.faint : Theme.ink, isolateLayout: true)
            }
            Readout(label: "Conversion efficiency", value: figure(efficiency), unit: "%",
                    detail: bootStats["efficiencyPercent"].isNull ? "" : String(format: "%.1f%% since boot", bootStats["efficiencyPercent"].double),
                    size: .medium, color: efficiency == nil ? Theme.faint : efficiency! < 85 ? Theme.warnFg : Theme.ink, isolateLayout: true)
        }
    }

    private var batteryDetail: String {
        var text = String(format: "%.0f%% · %.1f of %.1f Wh", battery["percent"].double, battery["remainingWh"].double, battery["maxCapacityWh"].double)
        if !battery["temperatureC"].isNull { text += String(format: " · %.1f °C", battery["temperatureC"].double) }
        return text
    }

    private func subsystemWatts(_ id: String) -> Double? {
        snapshot["subsystems"].array.first { $0["id"].string == id }.flatMap { NativeHardwareDisplayPolicies.number($0["watts"]) }
    }

    private func cost(_ wh: Double?) -> String {
        NativeHardwareDisplayPolicies.formatCost(wh: wh, ratePerKwh: ratePerKwh, currency: currency)
    }

    private var energyStrip: some View {
        let summary = history["summary"]
        let windowWh = NativeHardwareDisplayPolicies.number(summary["systemEnergyWh"])
        let windowWallWh = NativeHardwareDisplayPolicies.number(summary["wallEnergyWh"])
        let windowMean = NativeHardwareDisplayPolicies.number(summary["avgSystemLoadW"])
        let bootWh = NativeHardwareDisplayPolicies.number(bootStats["systemEnergyWh"])
        let bootWallWh = NativeHardwareDisplayPolicies.number(bootStats["wallEnergyWh"])
        let bootMean = NativeHardwareDisplayPolicies.number(bootStats["avgSystemLoadW"])
        let allWh = NativeHardwareDisplayPolicies.number(allTimeStats["systemEnergyWh"])
        let allWallWh = NativeHardwareDisplayPolicies.number(allTimeStats["wallEnergyWh"])
        let basis = bootMean ?? windowMean ?? NativeHardwareDisplayPolicies.number(snapshot["systemLoadW"]) ?? 0
        let wallBasis = NativeHardwareDisplayPolicies.number(bootStats["avgSystemPowerInW"]) ?? NativeHardwareDisplayPolicies.number(snapshot["wallPowerW"]) ?? basis
        let monthlyWh = wallBasis * 24.0 * 30.0, yearlyWh = wallBasis * 24.0 * 365.0
        let window = energyParts(history.isNull ? nil : windowWh), boot = energyParts(bootWh), all = energyParts(state.isNull ? nil : allWh)
        return ReadoutStrip(minimum: 200) {
            Readout(label: rangeDisplayName, value: window.value, unit: window.unit,
                    detail: history.isNull ? "" : cost(windowWallWh) + (windowMean.map { String(format: " · %.1f W average", $0) } ?? ""),
                    size: .large, color: history.isNull ? Theme.faint : Theme.ink)
            Readout(label: "Since boot", value: boot.value, unit: boot.unit,
                    detail: bootWh == nil ? "" : cost(bootWallWh) + (bootMean.map { String(format: " · %.1f W average", $0) } ?? ""),
                    size: .large, color: bootWh == nil ? Theme.faint : Theme.ink)
            Readout(label: "All recorded", value: all.value, unit: all.unit,
                    detail: state.isNull ? "" : cost(allWallWh),
                    size: .large, color: state.isNull ? Theme.faint : Theme.ink)
            Readout(label: "At this rate", value: snapshot.isNull ? "--" : String(format: "%.2f", monthlyWh / 1000.0), unit: "kWh a month",
                    detail: snapshot.isNull ? "" : cost(monthlyWh) + String(format: " · %.0f kWh a year", yearlyWh / 1000.0),
                    size: .large, color: snapshot.isNull ? Theme.faint : Theme.ink)
        }
    }

    /// Wall energy, conversion loss and efficiency: detail most visits do not
    /// need, so it grows from its own control.
    @ViewBuilder private var breakdown: some View {
        let summary = history["summary"]
        let columns: [JSONValue] = [summary, bootStats, allTimeStats]
        Button {
            withAnimation(reduceMotion ? nil : NativeMotion.toggle) { showsBreakdown.toggle() }
        } label: {
            HStack(spacing: 6) {
                NativeIcon(showsBreakdown ? "chevron-down" : "chevron-right", size: 12, strokeWidth: 1.75)
                Text("Wall energy, loss and efficiency")
            }
        }
        .buttonStyle(Press(.quiet)).padding(.leading, -8).padding(.top, -4)
        .accessibilityValue(showsBreakdown ? "Expanded" : "Collapsed")
        if showsBreakdown {
            VStack(spacing: 0) {
                LedgerHead {
                    MicroLabel("Measure").frame(maxWidth: .infinity, alignment: .leading)
                    MicroLabel(historyRange == "all" ? "All time" : historyRange == "custom" ? "Custom range" : rangeDisplayName).frame(width: 124, alignment: .trailing)
                    MicroLabel("Since boot").frame(width: 124, alignment: .trailing)
                    MicroLabel("All recorded").frame(width: 124, alignment: .trailing)
                }
                breakdownRow("System energy", columns.map { NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number($0["systemEnergyWh"])) })
                breakdownRow("Wall energy", columns.map { NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number($0["wallEnergyWh"])) })
                breakdownRow("Conversion loss", columns.map { NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number($0["adapterLossWh"])) })
                breakdownRow("Efficiency", [percent(summary["avgEfficiencyPercent"]), percent(bootStats["efficiencyPercent"]), "—"])
                breakdownRow("Cost", columns.map { cost(NativeHardwareDisplayPolicies.number($0["wallEnergyWh"])) })
            }
            .padding(.top, -6)
        }
    }

    private func breakdownRow(_ label: String, _ values: [String]) -> some View {
        LedgerRow(minHeight: 28) {
            HStack(spacing: 12) {
                Text(label).font(Theme.ui(12.5)).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    EnergyFigure(value, color: index == 0 ? Theme.ink : Theme.dim).frame(width: 124, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func percent(_ value: JSONValue) -> String {
        NativeHardwareDisplayPolicies.number(value).map { String(format: "%.1f %%", $0) } ?? "—"
    }

    private var consumers: some View {
        let subsystems = snapshot["subsystems"].array
        let load = max(0.1, snapshot["systemLoadW"].double)
        let widest = max(load, subsystems.map { $0["watts"].double }.max() ?? load)
        return Band(title: "Consumers", spacing: 0) {
            Button("All \(snapshot["sensors"].array.count) sensors") { tab = "sensors" }.buttonStyle(Press(.quiet))
        } content: {
            LedgerHead {
                MicroLabel("Rail").frame(maxWidth: .infinity, alignment: .leading)
                MicroLabel("Share of load").frame(minWidth: 60, idealWidth: 220, maxWidth: 220, alignment: .leading)
                Color.clear.frame(width: 40, height: 1)
                MicroLabel("Watts").frame(width: 64, alignment: .trailing)
            }
            if subsystems.isEmpty {
                Text(state.isNull ? "Reading subsystem rails" : "No subsystem rails reported").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    .padding(.vertical, 20)
            }
            ForEach(Array(subsystems.enumerated()), id: \.offset) { _, item in
                let watts = max(0, item["watts"].double)
                LedgerRow(minHeight: 28) {
                    HStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Text(item["label"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(item["group"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Scale(fraction: min(1, watts / widest), height: 3)
                            .frame(minWidth: 60, idealWidth: 220, maxWidth: 220)
                        Text(String(format: "%.0f%%", min(1, watts / load) * 100)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            .frame(width: 40, alignment: .trailing)
                        Text(String(format: "%.2f", watts)).font(Theme.readout(17)).foregroundStyle(Theme.ink)
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(item["label"].string)
                .accessibilityValue(String(format: "%.2f watts, %.0f percent of load", watts, min(1, watts / load) * 100))
            }
        }
    }

    // MARK: - History

    @ViewBuilder private var historyView: some View {
        let points = history["points"].array
        let summary = history["summary"]
        let used = energyParts(history.isNull ? nil : NativeHardwareDisplayPolicies.number(summary["systemEnergyWh"]))
        let wallWh = NativeHardwareDisplayPolicies.number(summary["wallEnergyWh"])
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { MicroLabel(rangeDisplayName); Spacer(minLength: 12); rangeStops }
                VStack(alignment: .leading, spacing: 8) { rangeStops; MicroLabel(rangeDisplayName) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    NativeNumberText(text: used.value, font: Theme.readout(54), color: history.isNull ? Theme.faint : Theme.ink)
                    MicroLabel(used.unit + " used", size: 11)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Energy used, " + rangeDisplayName.lowercased())
                .accessibilityValue(used.value + " " + used.unit)
                Spacer(minLength: 16)
                if !history.isNull {
                    Text(cost(wallWh) + " · " + NativeHardwareDisplayPolicies.formatEnergyWh(wallWh) + " at the wall")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .padding(.top, 2)
            customRange.padding(.top, 10)
        }
        if let historyError { Notice(text: historyError, tone: .fail).accessibilityLabel("Error: " + historyError) }
        ReadoutStrip(minimum: 130) {
            loadReadout("Average load", summary["avgSystemLoadW"])
            loadReadout("Minimum", summary["minSystemLoadW"])
            loadReadout("95th percentile", summary["p95SystemLoadW"])
            loadReadout("Peak", summary["peakSystemLoadW"])
        }
        Band(title: "Power") { statisticStops } content: {
            Well {
                NativeLineChart(series: powerSeries(kind: statistic), height: 220, showPoints: points.count <= 48, includeZero: true,
                                xFormat: { formatAxisDate($0) }, yFormat: { String(format: "%.1f W", $0) })
            }
        }
        Band("Energy per bucket") {
            Well {
                NativeLineChart(series: energyBucketSeries, height: 195, showPoints: points.count <= 48, includeZero: true,
                                xFormat: { formatAxisDate($0) }, yFormat: { String(format: "%.2f Wh", $0) })
            }
        }
        bucketLedger(points)
    }

    private func loadReadout(_ label: String, _ value: JSONValue) -> some View {
        let watts = NativeHardwareDisplayPolicies.number(value)
        return Readout(label: label, value: figure(watts), unit: "W", size: .medium, color: watts == nil ? Theme.faint : Theme.ink)
    }

    private func bucketLedger(_ points: [JSONValue]) -> some View {
        let recent = Array(points.suffix(60).reversed())
        let stored = ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file)
        return Band(title: "Buckets", spacing: 0) {
            if !recent.isEmpty { Text("\(recent.count) most recent of \(points.count)").font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
        } content: {
            LedgerHead {
                MicroLabel("Bucket").frame(maxWidth: .infinity, alignment: .leading)
                MicroLabel("Avg W").frame(width: 64, alignment: .trailing)
                MicroLabel("Peak W").frame(width: 64, alignment: .trailing)
                MicroLabel("Wall W").frame(width: 64, alignment: .trailing)
                MicroLabel("Energy").frame(width: 88, alignment: .trailing)
                MicroLabel("Cost").frame(width: 72, alignment: .trailing)
            }
            if recent.isEmpty {
                if history.isNull && historyError == nil {
                    Text("Reading recorded history").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20)
                } else {
                    Blank(icon: "clock", title: "No buckets recorded in this range yet",
                          detail: "Live power samples are persisted every 10 seconds and rolled up automatically.")
                }
            }
            ForEach(Array(recent.enumerated()), id: \.offset) { _, point in
                LedgerRow(minHeight: 28) {
                    HStack(spacing: 12) {
                        Text(bucketStamp(point["mean"]["date"].double)).font(Theme.mono(11.5)).foregroundStyle(Theme.ink).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        bucketFigure(point["mean"]["systemLoadW"], Theme.ink)
                        bucketFigure(point["max"]["systemLoadW"], Theme.dim)
                        bucketFigure(point["mean"]["wallPowerW"], Theme.dim)
                        EnergyFigure(NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(point["systemEnergyWh"])))
                            .frame(width: 88, alignment: .trailing)
                        Text(cost(NativeHardwareDisplayPolicies.number(point["wallEnergyWh"]))).font(Theme.readout(17)).foregroundStyle(Theme.muted)
                            .frame(width: 72, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if !history.isNull {
                Text("Missing observations remain gaps. \(points.count) buckets in view · about \(stored) stored.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).padding(.top, 12)
            }
        }
    }

    private func bucketFigure(_ value: JSONValue, _ color: Color) -> some View {
        Text(figure(NativeHardwareDisplayPolicies.number(value), missing: "—")).font(Theme.readout(17)).foregroundStyle(color)
            .frame(width: 64, alignment: .trailing)
    }

    private func bucketStamp(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        if ["30m", "1h", "6h"].contains(historyRange) { return date.formatted(date: .omitted, time: .standard) }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func formatAxisDate(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        if ["30m", "1h", "6h"].contains(historyRange) {
            return d.formatted(date: .omitted, time: .shortened)
        }
        return d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func powerSeries(kind: String) -> [NativeChartSeries] {
        let samples = NativeEnergyHistory.discontinuousSamples(history["points"].array, kind: kind)
        var defs: [(id: String, label: String, key: String, color: Color)] = [
            ("systemLoad", "System load", "systemLoadW", EnergySeries.load),
            ("wallPower", "Wall power", "wallPowerW", EnergySeries.wall)
        ]
        if batteryPresent {
            defs.append(("batteryPower", "Battery flow", "batteryPowerW", EnergySeries.flow))
        } else {
            defs.append(("adapterLoss", "Conversion loss", "adapterLossW", EnergySeries.flow))
        }
        return defs.map { def in
            NativeChartSeries(
                id: def.id,
                label: def.label,
                points: samples.map { s in
                    NativeChartPoint(x: s["date"].double, y: NativeHardwareDisplayPolicies.number(s[def.key]))
                },
                color: def.color
            )
        }
    }

    private var energyBucketSeries: [NativeChartSeries] {
        let points = history["points"].array
        return [
            NativeChartSeries(
                id: "systemWh",
                label: "System energy",
                points: points.map { pt in
                    NativeChartPoint(x: pt["mean"]["date"].double, y: NativeHardwareDisplayPolicies.number(pt["systemEnergyWh"]))
                },
                color: EnergySeries.load
            ),
            NativeChartSeries(
                id: "wallWh",
                label: "Wall energy",
                points: points.map { pt in
                    NativeChartPoint(x: pt["mean"]["date"].double, y: NativeHardwareDisplayPolicies.number(pt["wallEnergyWh"]))
                },
                color: EnergySeries.wall
            )
        ]
    }

    // MARK: - Rails and sensors

    private var sensorsView: some View {
        let all = snapshot["sensors"].array
        let power = all.filter { $0["unit"].string == "W" }.count
        let volts = all.filter { $0["unit"].string == "V" }.count
        let amps = all.filter { $0["unit"].string == "A" }.count
        let categories = ["All", "Favorites", "Telemetry", "System Power", "Processor & SoC", "Rails & Ports", "Power (W)", "Voltage (V)", "Current (A)"]
        return Band(title: "Channels", spacing: 12) {
            if !all.isEmpty {
                Text("\(all.count) live · \(power) power · \(volts) voltage · \(amps) current").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
            }
        } content: {
            HStack(spacing: 10) {
                Entry(placeholder: "Filter by key (PMVR, PSTR, VD0R) or rail", text: $query, mono: true, icon: "search")
                    .accessibilityLabel("Filter sensors")
                Pick(title: "Sensor category", selection: $group, options: categories.map { ($0, $0) }, width: 175)
            }
            ViewThatFits(in: .horizontal) {
                sensorLedger(category: true).frame(minWidth: 680, idealWidth: 680, maxWidth: .infinity)
                sensorLedger(category: false)
            }
        }
    }

    private func sensorLedger(category: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LedgerHead {
                Color.clear.frame(width: 22, height: 1)
                MicroLabel("Channel").frame(maxWidth: .infinity, alignment: .leading)
                if category { MicroLabel("Category").frame(width: 130, alignment: .leading) }
                MicroLabel("Live").frame(width: 92, alignment: .trailing)
                MicroLabel("Mean").frame(width: 64, alignment: .trailing)
                MicroLabel("Peak").frame(width: 64, alignment: .trailing)
            }
            ForEach(sensorRows, id: \.self["id"]) { sensor in sensorRow(sensor, category: category) }
            if sensorRows.isEmpty {
                if snapshot.isNull {
                    Text("Reading electrical sensors").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20)
                } else {
                    Blank(icon: "search", title: "No matching electrical sensors", detail: "Try another category or search term.")
                }
            }
        }
    }

    private func sensorRow(_ sensor: JSONValue, category: Bool) -> some View {
        let id = sensor["id"].string, unit = sensor["unit"].string
        let favorite = favorites.contains(id)
        return LedgerRow(minHeight: 28) {
            HStack(spacing: 12) {
                Button {
                    if !favorites.insert(id).inserted { favorites.remove(id) }
                    if !runtime.paths.readOnly {
                        UserDefaults.standard.set(Array(favorites).sorted(), forKey: "uniapi.energy.favorites")
                    }
                } label: {
                    NativeIcon(favorite ? "star.fill" : "star", size: 13, strokeWidth: 1.65)
                        .foregroundStyle(favorite ? Theme.ink : Theme.faint)
                        .frame(width: 22, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointingHand()
                .accessibilityLabel(favorite ? "Remove \(id) from favorites" : "Add \(id) to favorites")
                .help(favorite ? "Remove from favorites" : "Add to favorites")
                HStack(spacing: 8) {
                    Tag(id).frame(width: 74, alignment: .leading)
                    Text(NativeHardwareDisplayPolicies.energySensorName(id)).font(Theme.ui(12.5)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if category {
                    Text(NativeHardwareDisplayPolicies.energySensorGroup(id, unit: unit)).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                        .lineLimit(1).frame(width: 130, alignment: .leading)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    NativeNumberText(text: figure(NativeHardwareDisplayPolicies.number(sensor["value"]), "%.2f", missing: "—"), font: Theme.readout(17))
                    MicroLabel(unit).frame(width: 12, alignment: .leading)
                }
                .frame(width: 92, alignment: .trailing)
                Text(figure(NativeHardwareDisplayPolicies.number(sessionStats["sensorAverages"][id]), "%.2f", missing: "—"))
                    .font(Theme.readout(17)).foregroundStyle(Theme.dim).frame(width: 64, alignment: .trailing)
                Text(figure(NativeHardwareDisplayPolicies.number(sessionStats["sensorPeaks"][id]), "%.2f", missing: "—"))
                    .font(Theme.readout(17)).foregroundStyle(Theme.muted).frame(width: 64, alignment: .trailing)
            }
        }
    }

    // MARK: - Preferences

    private var preferencesPanel: some View {
        let storage = history["storage"]
        let retention = "10-second samples for \(storage["rawDays"].isNull ? 7 : storage["rawDays"].int) days, minutes for \(storage["minuteDays"].isNull ? 90 : storage["minuteDays"].int) days, hours for \(storage["hourlyDays"].isNull ? 365 : storage["hourlyDays"].int) days. Daily totals stay."
        return VStack(alignment: .leading, spacing: 0) {
            Text("Energy preferences").font(Theme.display(17)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader).padding(.bottom, 8)
            if let error { Notice(text: error, tone: .fail).padding(.bottom, 4) }
            OptionRow(title: "Sidebar reading", detail: "The live figure beside Energy in the sidebar.") {
                Pick(
                    title: "Sidebar badge metric",
                    selection: Binding(
                        get: { prefs["badgeMetric"].string.isEmpty ? "systemLoad" : prefs["badgeMetric"].string },
                        set: { value in Task { await operation("preferences", ["badgeMetric": .string(value)]) } }
                    ),
                    options: [
                        ("systemLoad", "System load"),
                        ("wallPower", "Wall power"),
                        ("batteryNet", "Battery net flow"),
                        ("none", "Hidden")
                    ],
                    width: 170
                )
            }
            OptionRow(title: "Electricity tariff", detail: "Prices every cost on this page.") {
                HStack(spacing: 8) {
                    Entry(placeholder: "$", text: $currencyText, mono: true, width: 52).accessibilityLabel("Currency")
                    Entry(placeholder: "0.30", text: $rateText, mono: true, width: 78, onSubmit: saveTariff).accessibilityLabel("Rate per kilowatt hour")
                    Text("per kWh").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                }
            }
            OptionRow(title: "History on disk", detail: retention, ruled: false) {
                Text(history.isNull ? "Reading" : "about " + ByteCountFormatter.string(fromByteCount: Int64(storage["bytes"].double), countStyle: .file))
                    .font(Theme.mono(12)).foregroundStyle(history.isNull ? Theme.muted : Theme.ink)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Close") { showsPreferences = false }.buttonStyle(Press(.secondary)).keyboardShortcut(.cancelAction)
                Button("Save tariff", action: saveTariff).buttonStyle(Press(.primary)).disabled(pending || runtime.paths.readOnly)
            }
            .padding(.top, 14)
        }
        .padding(20).frame(width: 460)
        .background(Theme.popover).foregroundStyle(Theme.ink).font(Theme.ui(13)).tint(Theme.signal)
    }

    private func saveTariff() {
        guard !pending, !runtime.paths.readOnly else { return }
        if let rate = Double(rateText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) {
            Task { await operation("preferences", ["ratePerKwh": .number(rate), "currency": .string(currencyText)]) }
        } else {
            error = "Enter a valid number for electricity rate per kWh"
        }
    }

    // MARK: - Formatting

    private func figure(_ value: Double?, _ format: String = "%.1f", missing: String = "--") -> String {
        guard let value, value.isFinite else { return missing }
        return String(format: format, value)
    }

    /// The same thresholds as `formatEnergyWh`, with the unit kept apart so
    /// it can be set as an engraved label.
    private func energyParts(_ wh: Double?) -> (value: String, unit: String) {
        guard let wh, wh.isFinite else { return ("--", "Wh") }
        if abs(wh) >= 1000 { return (String(format: "%.2f", wh / 1000.0), "kWh") }
        return (String(format: abs(wh) >= 10 ? "%.1f" : "%.2f", wh), "Wh")
    }

    // MARK: - Data Operations

    private func syncPreferenceInputs() {
        if let r = NativeHardwareDisplayPolicies.number(prefs["ratePerKwh"]) {
            rateText = String(format: "%.2f", r)
        }
        if !prefs["currency"].string.isEmpty {
            currencyText = prefs["currency"].string
        }
    }

    private func reload(force: Bool = false) async {
        guard let service = session.energy, let ticket = reads.begin("status") else { return }
        do {
            let next = try await service.handle("status", input: ["force": .bool(force)])
            guard reads.accepts(ticket) else { return }
            state = next
            statusReadError = nil
            syncPreferenceInputs()
        } catch {
            if reads.accepts(ticket) { statusReadError = error.localizedDescription }
        }
    }

    private func operation(_ name: String, _ input: JSONObject = [:]) async {
        guard let service = session.energy, !pending else { return }
        pending = true
        defer { pending = false }
        do {
            let next = try await service.handle(name, input: input)
            state = next
            syncPreferenceInputs()
            error = nil
        } catch {
            self.error = error.localizedDescription
            await reload()
        }
    }

    private func loadHistory() async {
        guard let service = session.energy, let ticket = reads.begin("history") else { return }
        let scope = historyScope, selectedRange = historyRange
        let request = historySelection.begin(scope: scope)
        do {
            var input: JSONObject = ["range": .string(selectedRange)]
            if selectedRange == "custom" {
                input.merge(try NativeHardwareDisplayPolicies.fanHistoryDays(from: from, through: through)) { _, new in new }
            }
            let next = try await service.handle("history", input: input)
            guard reads.accepts(ticket) else { return }
            historySelection.resolve(request, value: next)
        } catch {
            if reads.accepts(ticket) { historySelection.reject(request, message: error.localizedDescription) }
        }
    }

    private func exportHistory() {
        let csv = NativeHardwareDisplayPolicies.energyHistoryCSV(history["points"].array)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "UniApi-energy-history-\(range).csv"
        panel.nativeBegin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(csv.utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
        }
    }
}

/// The hero meter: the kit `Scale` with the chosen window's range shaded, a
/// signal needle on the live value and its graduations labelled in watts.
private struct EnergyGauge: View {
    var value: Double?
    var maximum: Double
    var spread: ClosedRange<Double>?
    var endLabel: String
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    private var fraction: Double { NativeMotion.fraction((value ?? 0) / max(maximum, 0.001)) }
    private var shaded: ClosedRange<Double>? {
        guard let spread, maximum > 0 else { return nil }
        return NativeMotion.fraction(spread.lowerBound / maximum)...NativeMotion.fraction(spread.upperBound / maximum)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Scale(fraction: fraction, height: 6, ticks: true, spread: shaded)
                .overlay(alignment: .topLeading) {
                    GeometryReader { geometry in
                        if value != nil {
                            Theme.signal.frame(width: 2, height: 13)
                                .offset(x: min(max(0, geometry.size.width - 2), max(0, geometry.size.width * fraction - 1)), y: -3)
                                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: fraction)
                        }
                    }
                }
            HStack(spacing: 0) {
                ForEach(0..<4, id: \.self) { index in
                    Text(String(format: "%.0f", maximum * Double(index) / 4)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .overlay(alignment: .trailing) { Text(endLabel) }
            .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
        }
        .accessibilityHidden(true)
    }
}

/// A formatted quantity such as "312.4 Wh": condensed numerals with the unit
/// following as an engraved label. Values without a unit stay whole.
private struct EnergyFigure: View {
    var text: String
    var color: Color = Theme.ink
    init(_ text: String, color: Color = Theme.ink) { self.text = text; self.color = color }
    var body: some View {
        let parts = text.split(separator: " ", maxSplits: 1).map(String.init)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.first ?? text).font(Theme.readout(17)).foregroundStyle(parts.first == "—" ? Theme.faint : color)
            if parts.count == 2 { MicroLabel(parts[1]) }
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}
