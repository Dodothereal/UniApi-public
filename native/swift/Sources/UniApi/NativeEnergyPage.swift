import SwiftUI
import Charts
import AppKit
import UniApiCore
import UniApiPresentation

struct NativeEnergyPage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var motionVisible
    private static let tabs = ["flow", "history", "sensors", "settings"]
    @State private var contentWidth: CGFloat = 882
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

    private var snapshot: JSONValue { state["snapshot"] }
    private var sessionStats: JSONValue { state["session"] }
    private var allTimeStats: JSONValue { state["allTime"] }
    private var bootStats: JSONValue { snapshot["boot"] }
    private var battery: JSONValue { snapshot["battery"] }
    private var batteryPresent: Bool { battery["present"].bool }
    private var prefs: JSONValue { state["preferences"] }
    private var ratePerKwh: Double { NativeHardwareDisplayPolicies.number(prefs["ratePerKwh"]) ?? 0.30 }
    private var currency: String { prefs["currency"].string.isEmpty ? "$" : prefs["currency"].string }
    private var historyRange: String { range }
    private var historyScope: String { historyRange == "custom" ? "custom:\(from.timeIntervalSince1970):\(through.timeIntervalSince1970)" : historyRange }
    private var history: JSONValue { historySelection.value(for: historyScope) }
    private var historyError: String? { historySelection.error(for: historyScope) }
    private var sensorRows: [JSONValue] {
        NativeHardwareDisplayPolicies.energySensorRows(snapshot["sensors"].array, favorites: favorites, group: group, query: query)
    }

    private static let rangeOptions: [(String, String)] = [
        ("30m", "30m"),
        ("1h", "1h"),
        ("6h", "6h"),
        ("24h", "24h"),
        ("7d", "7d"),
        ("30d", "30d"),
        ("all", "All"),
        ("custom", "Custom")
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
        let needsHistory = ["flow", "history", "settings"].contains(tab)
        if needsHistory && historyError != nil { return .failed }
        if snapshot.isNull || (needsHistory && history.isNull) { return .pending }
        return .ready
    }

    var body: some View {
        GeometryReader { viewport in
            NativePage(title: "Energy", subtitle: "Real-time power flow, subsystem rail telemetry, and historical consumption.", maxWidth: 1500, readiness: pageReadiness, showsHeader: false) {
                energyHeader
                if let statusReadError { statusError(statusReadError) }
                if let error { NativeError(message: error) }
                if !state["error"].string.isEmpty { statusError(state["error"].string) }
                if state.isNull {
                    if error == nil && statusReadError == nil {
                        ShimmerText(text: "Reading live power telemetry and electrical rails…").padding(.vertical, 40)
                    }
                } else if !state["supported"].bool {
                    NativeEmptyState(title: "Energy telemetry is available on macOS", detail: "The other UniApi apps work on this platform.", icon: "zap")
                } else {
                    if contentWidth >= 700 {
                        HStack(spacing: 16) { tabRail; Spacer(minLength: 8); powerSourceBadge }
                    } else {
                        VStack(alignment: .leading, spacing: 12) { tabRail; powerSourceBadge }
                    }
                    switch tab {
                    case "history": historyTab
                    case "sensors": sensorsTab
                    case "settings": preferencesTab
                    default: powerFlowTab
                    }
                }
            }
            .onChange(of: max(0, min(1500, viewport.size.width) - 2 * density.pageMargin), initial: true) { _, width in contentWidth = width }
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
            guard ["flow", "history", "settings"].contains(tab) else { return }
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

    private func statusError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NativeError(message: message)
            Button("Retry") { Task { await reload(force: true) } }
        }
    }

    // MARK: - Header & Navigation

    private var energyHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                energyHeading.fixedSize()
                Spacer(minLength: 0)
                headerActions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                energyHeading
                headerActions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var energyHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Energy")
                .font(Theme.ui(min(42, max(28, (contentWidth + 216 + 2 * density.pageMargin) * 0.038)), weight: .semibold))
                .tracking(-1.6)
                .accessibilityAddTraits(.isHeader)
            Text("Real-time power flow, subsystem rail telemetry, and cumulative consumption.")
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.muted)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                NativeStatusDot(color: snapshot.isNull ? Theme.warnFg : Theme.okFg, pulse: !snapshot.isNull)
                Text(snapshot.isNull ? "Waiting for readings" : "Live · 2s")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Theme.well, in: Capsule())

            Button {
                exportHistory()
            } label: {
                HStack(spacing: 6) {
                    NativeIcon("download", size: 12, strokeWidth: 1.65)
                    Text("Export CSV")
                }
            }
            .buttonStyle(T3Button(.outline))
            .disabled(history["points"].array.isEmpty)

            Button {
                Task {
                    await reload(force: true)
                    if ["flow", "history", "settings"].contains(tab) { await loadHistory() }
                }
            } label: {
                HStack(spacing: 6) {
                    NativeIcon("refresh-cw", size: 12, strokeWidth: 1.65)
                    Text("Refresh")
                }
            }
            .buttonStyle(T3Button(.outline))
        }
    }

    private var tabRail: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.self) { value in
                Button { tab = value } label: {
                    Text([
                        "flow": "Overview & Flow",
                        "history": "History & Export",
                        "sensors": "Rails & Sensors (\(snapshot["sensors"].array.count))",
                        "settings": "Preferences"
                    ][value] ?? value)
                    .font(Theme.ui(12, weight: tab == value ? .medium : .regular))
                    .lineLimit(1).minimumScaleFactor(0.85)
                    .padding(.vertical, 7).frame(maxWidth: .infinity)
                    .foregroundStyle(tab == value ? Theme.ink : Theme.muted)
                }
                .buttonStyle(.plain).pointingHand()
                .accessibilityAddTraits(tab == value ? [.isSelected] : [])
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geometry in
                if let index = Self.tabs.firstIndex(of: tab) {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.surface)
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1) }
                        .frame(width: geometry.size.width / CGFloat(Self.tabs.count))
                        .offset(x: geometry.size.width / CGFloat(Self.tabs.count) * CGFloat(index))
                        .animation(reduceMotion || !motionVisible ? nil : .spring(duration: 0.42), value: tab)
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .padding(4)
        .frame(width: min(520, max(0, contentWidth)))
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Energy sections")
    }

    private var powerSourceBadge: some View {
        let mode = snapshot["powerMode"].string
        let ext = snapshot["externalConnected"].bool
        let battW = snapshot["batteryPowerW"].double
        let voltV = snapshot["voltageInV"].double
        let currA = snapshot["currentInA"].double
        let label: String = {
            if snapshot.isNull { return "Telemetry unavailable" }
            if !batteryPresent || mode == "wall-only" {
                return String(format: "AC Mains Direct · %.2f V @ %.2f A", voltV, currA)
            }
            if ext {
                if mode == "ac-charging" || battW > 0.2 {
                    return String(format: "AC Connected · Charging (%+.1f W)", battW)
                }
                if mode == "ac-assisting" || battW < -0.2 {
                    return String(format: "AC Connected · Battery Assisting (%.1f W)", battW)
                }
                return "AC Connected · Powering Mac Directly"
            }
            return String(format: "Battery Power · %.1f W Draw", abs(battW))
        }()
        return HStack(spacing: 8) {
            NativeStatusDot(color: ext || !batteryPresent ? Theme.okFg : Theme.warnFg)
            Text(label).font(Theme.mono(11)).foregroundStyle(Theme.dim)
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1) }
    }

    // MARK: - Shared Range Bar

    private var rangeControlBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        NativeIcon("clock", size: 13, strokeWidth: 1.65).foregroundStyle(Theme.muted)
                        Text("Time window").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                    }
                    T3Segmented(options: Self.rangeOptions, selection: range) { range = $0 }
                    Spacer(minLength: 8)
                    T3Segmented(options: [("mean", "Avg"), ("max", "Peak"), ("min", "Min")], selection: statistic) { statistic = $0 }
                }
                VStack(alignment: .leading, spacing: 10) {
                    T3Segmented(options: Self.rangeOptions, selection: range) { range = $0 }
                    HStack {
                        T3Segmented(options: [("mean", "Average"), ("max", "Peak"), ("min", "Minimum")], selection: statistic) { statistic = $0 }
                        Spacer()
                    }
                }
            }
            if range == "custom" {
                HStack(spacing: 16) {
                    DatePicker("From", selection: $from, in: ...through, displayedComponents: .date)
                    DatePicker("Through", selection: $through, in: from...Date(), displayedComponents: .date)
                }
                .font(Theme.ui(12))
                .padding(10)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            }
        }
    }

    // MARK: - Tab 1: Overview & Flow

    private var powerFlowTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            powerFlowPipelineCard
            rangeControlBar
            energySummaryStrip
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    subsystemBreakdownCard.frame(minWidth: 420, maxWidth: .infinity)
                    cumulativeEnergyLedgerCard.frame(width: 390)
                }
                VStack(alignment: .leading, spacing: 18) {
                    subsystemBreakdownCard
                    cumulativeEnergyLedgerCard
                }
            }
            if let historyError { NativeError(message: historyError) }
            liveTraceCard
        }
    }

    private var powerFlowPipelineCard: some View {
        let wallW = NativeHardwareDisplayPolicies.number(snapshot["wallPowerW"])
        let sysInW = NativeHardwareDisplayPolicies.number(snapshot["systemPowerInW"])
        let lossW = NativeHardwareDisplayPolicies.number(snapshot["adapterLossW"])
        let sysLoadW = NativeHardwareDisplayPolicies.number(snapshot["systemLoadW"])
        let battW = NativeHardwareDisplayPolicies.number(snapshot["batteryPowerW"])
        let eff = NativeHardwareDisplayPolicies.number(snapshot["efficiencyPercent"])
        let voltV = NativeHardwareDisplayPolicies.number(snapshot["voltageInV"])
        let currA = NativeHardwareDisplayPolicies.number(snapshot["currentInA"])
        let budgetW = NativeHardwareDisplayPolicies.number(snapshot["powerBudgetW"])
        let thermalW = snapshot["subsystems"].array.first(where: { $0["id"].string == "thermal" }).flatMap { NativeHardwareDisplayPolicies.number($0["watts"]) }
        let socW = snapshot["subsystems"].array.first(where: { $0["id"].string == "soc" }).flatMap { NativeHardwareDisplayPolicies.number($0["watts"]) }
        let hourlyCost = ((wallW ?? sysLoadW ?? 0) / 1000.0) * ratePerKwh

        return Card(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Real-Time Power Pipeline")
                                .font(Theme.ui(15, weight: .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(batteryPresent ? "Laptop AC / Battery Architecture" : "Desktop Direct AC Architecture")
                                .font(Theme.mono(10, weight: .medium))
                                .foregroundStyle(Theme.dim)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.well, in: Capsule())
                        }
                        Text(batteryPresent
                             ? "Live wattage from AC wall estimate through the DC-in regulator into Mac system load and battery pack."
                             : "Live wattage from AC wall input through the internal power supply into the 12V DC bus and Apple Silicon rails.")
                            .font(Theme.ui(12))
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 8) {
                        if let eff {
                            metricPill(label: "PSU Efficiency", value: String(format: "%.1f%%", eff), color: eff >= 85 ? Theme.okFg : Theme.warnFg)
                        }
                        if let budgetW, budgetW > 0 {
                            let pct = min(100, max(0, ((sysInW ?? 0) / budgetW) * 100))
                            metricPill(label: "Power Headroom", value: String(format: "%.0f / %.0f W (%.0f%%)", sysInW ?? 0, budgetW, pct), color: Theme.accent)
                        }
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: contentWidth < 760 ? 2 : 4), spacing: 12) {
                    pipelineStageCard(
                        step: "01 · AC INPUT",
                        icon: "plug-zap",
                        title: "Wall Power Draw",
                        watts: NativeHardwareDisplayPolicies.formatWatts(wallW),
                        primaryMeta: lossW.map { String(format: "Conversion heat loss %.2f W", $0) } ?? "Direct input",
                        secondaryMeta: eff.map { String(format: "%.1f%% PSU conversion efficiency", $0) } ?? "Efficiency nominal",
                        accentColor: Theme.pairPalette[0],
                        fraction: budgetW.map { min(1, max(0, (wallW ?? 0) / max(1, $0))) }
                    )
                    pipelineStageCard(
                        step: "02 · DC BUS",
                        icon: "plug",
                        title: "DC-In Supply Rail",
                        watts: NativeHardwareDisplayPolicies.formatWatts(sysInW),
                        primaryMeta: String(format: "%.2f V  ×  %.2f A", voltV ?? 0, currA ?? 0),
                        secondaryMeta: budgetW.map { String(format: "%.0f W ceiling (%.0f W free)", $0, max(0, $0 - (sysInW ?? 0))) } ?? "Regulated main bus",
                        accentColor: Theme.accent,
                        fraction: budgetW.map { min(1, max(0, (sysInW ?? 0) / max(1, $0))) }
                    )
                    pipelineStageCard(
                        step: "03 · COMPUTE & BOARD",
                        icon: "cpu",
                        title: "Mac System Load",
                        watts: NativeHardwareDisplayPolicies.formatWatts(sysLoadW),
                        primaryMeta: String(format: "Burn rate %.1f Wh/h · %@%.3f/h", sysLoadW ?? 0, currency, hourlyCost),
                        secondaryMeta: bootStats["avgSystemLoadW"].isNull
                            ? "Hardware average pending"
                            : String(format: "Since boot avg %.1f W", bootStats["avgSystemLoadW"].double),
                        accentColor: Theme.okFg,
                        fraction: budgetW.map { min(1, max(0, (sysLoadW ?? 0) / max(1, $0))) }
                    )
                    if batteryPresent {
                        pipelineStageCard(
                            step: "04 · BATTERY PACK",
                            icon: "battery-charging",
                            title: (battW ?? 0) > 0.05 ? "Battery Charging" : (battW ?? 0) < -0.05 ? "Battery Discharging" : "Battery Resting",
                            watts: NativeHardwareDisplayPolicies.formatWatts(battW, signed: true),
                            primaryMeta: String(format: "%.0f%% · %.1f / %.1f Wh", battery["percent"].double, battery["remainingWh"].double, battery["maxCapacityWh"].double),
                            secondaryMeta: String(format: "%.2f V · %+.2f A%@", battery["voltageV"].double, battery["currentA"].double, battery["temperatureC"].isNull ? "" : String(format: " · %.1f°C", battery["temperatureC"].double)),
                            accentColor: (battW ?? 0) >= 0 ? Theme.okFg : Theme.warnFg,
                            fraction: max(0, min(1, battery["percent"].double / 100.0))
                        )
                    } else {
                        pipelineStageCard(
                            step: "04 · SILICON THERMAL",
                            icon: "activity",
                            title: "SoC & Thermal Dissipation",
                            watts: NativeHardwareDisplayPolicies.formatWatts(socW ?? thermalW ?? sysLoadW),
                            primaryMeta: String(format: "Thermal zone %.2f W (PHPS)", thermalW ?? 0),
                            secondaryMeta: String(format: "PSU loss %.2f W · Total heat %.1f W", lossW ?? 0, wallW ?? 0),
                            accentColor: Theme.pairPalette[1],
                            fraction: (sysLoadW ?? 0) > 0 ? min(1, max(0, (socW ?? 0) / max(1, sysLoadW ?? 1))) : 0
                        )
                    }
                }
            }
        }
    }

    private func metricPill(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(Theme.ui(11)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.mono(11, weight: .semibold)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
    }

    private func pipelineStageCard(step: String, icon: String, title: String, watts: String, primaryMeta: String, secondaryMeta: String, accentColor: Color, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(step).font(Theme.mono(9.5, weight: .semibold)).foregroundStyle(accentColor)
                Spacer(minLength: 4)
                NativeIcon(icon, size: 13, strokeWidth: 1.7).foregroundStyle(accentColor)
            }
            Text(title).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.dim).lineLimit(1)
            NativeNumberText(text: watts, font: Theme.ui(28, weight: .semibold), color: Theme.ink, isolateLayout: true)
            if let fraction {
                CapsuleBar(fraction: min(1, max(0.03, fraction)), color: accentColor)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(primaryMeta).font(Theme.mono(11, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(secondaryMeta).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1) }
    }

    private var energySummaryStrip: some View {
        let summary = history["summary"]
        let windowSysWh = NativeHardwareDisplayPolicies.number(summary["systemEnergyWh"])
        let windowWallWh = NativeHardwareDisplayPolicies.number(summary["wallEnergyWh"])
        let windowAvgW = NativeHardwareDisplayPolicies.number(summary["avgSystemLoadW"])
        let windowMinW = NativeHardwareDisplayPolicies.number(summary["minSystemLoadW"])
        let windowPeakW = NativeHardwareDisplayPolicies.number(summary["peakSystemLoadW"])
        let windowP95W = NativeHardwareDisplayPolicies.number(summary["p95SystemLoadW"])

        let bootWh = NativeHardwareDisplayPolicies.number(bootStats["systemEnergyWh"])
        let bootWallWh = NativeHardwareDisplayPolicies.number(bootStats["wallEnergyWh"])
        let bootAvgW = NativeHardwareDisplayPolicies.number(bootStats["avgSystemLoadW"])

        let allTimeWh = NativeHardwareDisplayPolicies.number(allTimeStats["systemEnergyWh"])
        let allTimeWallWh = NativeHardwareDisplayPolicies.number(allTimeStats["wallEnergyWh"])

        let basisW = bootAvgW ?? windowAvgW ?? NativeHardwareDisplayPolicies.number(snapshot["systemLoadW"]) ?? 0
        let wallBasisW = NativeHardwareDisplayPolicies.number(bootStats["avgSystemPowerInW"]) ?? NativeHardwareDisplayPolicies.number(snapshot["wallPowerW"]) ?? basisW
        let dailyWh = wallBasisW * 24.0
        let monthlyWh = dailyWh * 30.0
        let yearlyWh = dailyWh * 365.0

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: contentWidth < 760 ? 2 : 4), spacing: 12) {
            kpiCard(
                eyebrow: rangeDisplayName.uppercased(),
                title: "Window Energy Used",
                value: NativeHardwareDisplayPolicies.formatEnergyWh(windowSysWh),
                subtitle: String(format: "Wall %@ · Cost %@", NativeHardwareDisplayPolicies.formatEnergyWh(windowWallWh), NativeHardwareDisplayPolicies.formatCost(wh: windowWallWh, ratePerKwh: ratePerKwh, currency: currency)),
                badge: windowAvgW.map { String(format: "Avg %.1f W", $0) } ?? "\(summary["sampleCount"].int) pts"
            )
            kpiCard(
                eyebrow: "HARDWARE ACCUMULATOR",
                title: "Energy Since Boot",
                value: NativeHardwareDisplayPolicies.formatEnergyWh(bootWh),
                subtitle: String(format: "Wall %@ · Cost %@", NativeHardwareDisplayPolicies.formatEnergyWh(bootWallWh), NativeHardwareDisplayPolicies.formatCost(wh: bootWallWh, ratePerKwh: ratePerKwh, currency: currency)),
                badge: bootAvgW.map { String(format: "Avg %.1f W", $0) } ?? "Since boot"
            )
            kpiCard(
                eyebrow: rangeDisplayName.uppercased(),
                title: "Load Envelope (Min / Peak)",
                value: String(format: "%@ – %@", NativeHardwareDisplayPolicies.formatWatts(windowMinW), NativeHardwareDisplayPolicies.formatWatts(windowPeakW)),
                subtitle: String(format: "Window average %@ · All-time %@", NativeHardwareDisplayPolicies.formatWatts(windowAvgW), NativeHardwareDisplayPolicies.formatEnergyWh(allTimeWh)),
                badge: windowP95W.map { String(format: "P95 %.1f W", $0) } ?? "SQLite"
            )
            kpiCard(
                eyebrow: "RUN-RATE ESTIMATE",
                title: "Projected Consumption",
                value: String(format: "%.2f kWh/mo", monthlyWh / 1000.0),
                subtitle: String(format: "Day %@ · Year %.0f kWh · All-time cost %@", NativeHardwareDisplayPolicies.formatEnergyWh(dailyWh), yearlyWh / 1000.0, NativeHardwareDisplayPolicies.formatCost(wh: allTimeWallWh, ratePerKwh: ratePerKwh, currency: currency)),
                badge: String(format: "%@/mo", NativeHardwareDisplayPolicies.formatCost(wh: monthlyWh, ratePerKwh: ratePerKwh, currency: currency))
            )
        }
    }

    private func kpiCard(eyebrow: String, title: String, value: String, subtitle: String, badge: String) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(eyebrow)
                        .font(Theme.mono(9.5, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(badge)
                        .font(Theme.mono(10, weight: .medium))
                        .foregroundStyle(Theme.dim)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                }
                Text(title).font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim).lineLimit(1)
                NativeNumberText(text: value, font: Theme.ui(22, weight: .semibold), isolateLayout: true)
                Text(subtitle).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }

    private var subsystemBreakdownCard: some View {
        let subsystems = snapshot["subsystems"].array
        let sysLoad = max(0.1, snapshot["systemLoadW"].double)
        let maxRail = max(sysLoad, subsystems.map { $0["watts"].double }.max() ?? sysLoad)
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AppleSMC Subsystem & Regulator Telemetry")
                            .font(Theme.ui(14, weight: .semibold))
                        Text("Live power draw across SoC voltage regulators, memory PMIC, core clusters, and I/O rails")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button { tab = "sensors" } label: {
                        HStack(spacing: 4) {
                            Text("All \(snapshot["sensors"].array.count) sensors")
                            NativeIcon("arrow-up-right", size: 11, strokeWidth: 1.65)
                        }
                    }.buttonStyle(T3Button(.ghost))
                }
                VStack(spacing: 11) {
                    ForEach(Array(subsystems.enumerated()), id: \.offset) { idx, item in
                        let watts = max(0, item["watts"].double)
                        let shareOfLoad = min(1.0, max(0, watts / sysLoad))
                        let barFraction = min(1.0, max(0, watts / maxRail))
                        let groupName = item["group"].string
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(item["label"].string)
                                    .font(Theme.ui(12, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Text(groupName)
                                    .font(Theme.mono(9.5))
                                    .foregroundStyle(Theme.muted)
                                    .padding(.horizontal, 5).padding(.vertical, 1.5)
                                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 4))
                                Spacer(minLength: 8)
                                Text(String(format: "%.0f%% of load", shareOfLoad * 100))
                                    .font(Theme.mono(10.5))
                                    .foregroundStyle(Theme.muted)
                                Text(String(format: "%.2f W", watts))
                                    .font(Theme.mono(12, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .frame(width: 68, alignment: .trailing)
                            }
                            CapsuleBar(fraction: barFraction, color: Theme.pairPalette[idx % Theme.pairPalette.count])
                        }
                    }
                }
            }
        }
    }

    private var cumulativeEnergyLedgerCard: some View {
        let summary = history["summary"]
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cumulative Energy Ledger")
                            .font(Theme.ui(14, weight: .semibold))
                        Text("Integrated Wh and cost across \(rangeDisplayName.lowercased()), hardware boot, and SQLite rollups")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                VStack(spacing: 9) {
                    ledgerSectionHeader(rangeDisplayName)
                    ledgerRow("System energy consumed", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(summary["systemEnergyWh"])))
                    ledgerRow("Wall energy drawn", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(summary["wallEnergyWh"])))
                    ledgerRow("Adapter / PSU conversion loss", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(summary["adapterLossWh"])))
                    ledgerRow("Window electricity cost", NativeHardwareDisplayPolicies.formatCost(wh: NativeHardwareDisplayPolicies.number(summary["wallEnergyWh"]), ratePerKwh: ratePerKwh, currency: currency))

                    Divider().padding(.vertical, 2)
                    ledgerSectionHeader("Since Hardware Boot")
                    ledgerRow("Boot system energy", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(bootStats["systemEnergyWh"])))
                    ledgerRow("Boot wall energy", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(bootStats["wallEnergyWh"])))
                    ledgerRow("Boot PSU heat loss", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(bootStats["adapterLossWh"])))
                    ledgerRow("Boot average efficiency", bootStats["efficiencyPercent"].isNull ? "—" : String(format: "%.1f%%", bootStats["efficiencyPercent"].double))
                    ledgerRow("Boot electricity cost", NativeHardwareDisplayPolicies.formatCost(wh: NativeHardwareDisplayPolicies.number(bootStats["wallEnergyWh"]), ratePerKwh: ratePerKwh, currency: currency))

                    Divider().padding(.vertical, 2)
                    ledgerSectionHeader("All-Time SQLite Rollups")
                    ledgerRow("Total system energy", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(allTimeStats["systemEnergyWh"])))
                    ledgerRow("Total wall energy", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(allTimeStats["wallEnergyWh"])))
                    ledgerRow("Total recorded cost", NativeHardwareDisplayPolicies.formatCost(wh: NativeHardwareDisplayPolicies.number(allTimeStats["wallEnergyWh"]), ratePerKwh: ratePerKwh, currency: currency))
                }
            }
        }
    }

    private func ledgerSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(Theme.mono(10, weight: .semibold))
                .foregroundStyle(Theme.dim)
            Spacer()
        }
    }

    private func ledgerRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(value).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.ink)
        }
    }

    private var liveTraceCard: some View {
        Card(padding: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Power Draw Timeline (\(rangeDisplayName))")
                            .font(Theme.ui(14, weight: .semibold))
                        Text("System load, wall power and DC-in telemetry · \(history["points"].array.count) buckets")
                            .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    Button { tab = "history" } label: {
                        HStack(spacing: 6) {
                            Text("Inspect bucket table & Wh chart")
                            NativeIcon("arrow-up-right", size: 12, strokeWidth: 1.65)
                        }
                    }.buttonStyle(T3Button(.ghost))
                }
                NativeLineChart(
                    series: powerSeries(kind: statistic),
                    height: 205,
                    showPoints: false,
                    includeZero: true,
                    xFormat: { formatAxisDate($0) },
                    yFormat: { String(format: "%.1f W", $0) }
                )
            }
        }
    }

    // MARK: - Tab 2: History & Export

    private var historyTab: some View {
        let points = history["points"].array
        return VStack(alignment: .leading, spacing: 18) {
            rangeControlBar
            if let historyError { NativeError(message: historyError) }
            energySummaryStrip
            NativeCard(title: "Power draw (\(statistic == "max" ? "Peak" : statistic == "min" ? "Minimum" : "Average") Watts) · \(rangeDisplayName)") {
                NativeLineChart(
                    series: powerSeries(kind: statistic),
                    height: 220,
                    showPoints: points.count <= 48,
                    includeZero: true,
                    xFormat: { formatAxisDate($0) },
                    yFormat: { String(format: "%.1f W", $0) }
                )
            }
            NativeCard(title: "Integrated energy per bucket (Wh)") {
                NativeLineChart(
                    series: energyBucketSeries,
                    height: 195,
                    showPoints: points.count <= 48,
                    includeZero: true,
                    xFormat: { formatAxisDate($0) },
                    yFormat: { String(format: "%.2f Wh", $0) }
                )
            }
            historyBucketTableCard(points: points)
            Text("Missing observations remain gaps. \(points.count) buckets in view · ~\(ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file)) stored in SQLite.")
                .font(Theme.ui(11)).foregroundStyle(Theme.muted)
        }
    }

    private func historyBucketTableCard(points: [JSONValue]) -> some View {
        let recentPoints = Array(points.suffix(60).reversed())
        return Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recorded History Buckets")
                            .font(Theme.ui(14, weight: .semibold))
                        Text("Showing \(recentPoints.count) most recent time buckets in \(rangeDisplayName.lowercased()). Export CSV for full raw & sensor series.")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button {
                        exportHistory()
                    } label: {
                        HStack(spacing: 6) {
                            NativeIcon("download", size: 12, strokeWidth: 1.65)
                            Text("Export \(points.count) Buckets (CSV)")
                        }
                    }
                    .buttonStyle(T3Button(.outline))
                    .disabled(points.isEmpty)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)

                Rectangle().fill(Theme.border).frame(height: 1)

                HStack(spacing: 10) {
                    Text("Bucket Time").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Avg Load").frame(width: 82, alignment: .trailing)
                    Text("Peak Load").frame(width: 82, alignment: .trailing)
                    Text("Avg Wall").frame(width: 82, alignment: .trailing)
                    Text("Energy Used").frame(width: 92, alignment: .trailing)
                    Text("Est. Cost").frame(width: 76, alignment: .trailing)
                }
                .font(Theme.mono(10.5, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(Theme.well)

                if recentPoints.isEmpty {
                    NativeEmptyState(title: "No buckets recorded in this range yet", detail: "Live power samples are persisted every 10 seconds and rolled up automatically.")
                        .padding(.vertical, 20)
                } else {
                    ForEach(Array(recentPoints.enumerated()), id: \.offset) { _, pt in
                        let ts = pt["mean"]["date"].double
                        let avgLoad = NativeHardwareDisplayPolicies.number(pt["mean"]["systemLoadW"])
                        let peakLoad = NativeHardwareDisplayPolicies.number(pt["max"]["systemLoadW"])
                        let avgWall = NativeHardwareDisplayPolicies.number(pt["mean"]["wallPowerW"])
                        let sysWh = NativeHardwareDisplayPolicies.number(pt["systemEnergyWh"])
                        let wallWh = NativeHardwareDisplayPolicies.number(pt["wallEnergyWh"])
                        Rectangle().fill(Theme.border).frame(height: 1)
                        HStack(spacing: 10) {
                            Text(Date(timeIntervalSince1970: ts / 1000).formatted(date: .abbreviated, time: .standard))
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(NativeHardwareDisplayPolicies.formatWatts(avgLoad))
                                .font(Theme.mono(11.5, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 82, alignment: .trailing)
                            Text(NativeHardwareDisplayPolicies.formatWatts(peakLoad))
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.dim)
                                .frame(width: 82, alignment: .trailing)
                            Text(NativeHardwareDisplayPolicies.formatWatts(avgWall))
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.dim)
                                .frame(width: 82, alignment: .trailing)
                            Text(NativeHardwareDisplayPolicies.formatEnergyWh(sysWh))
                                .font(Theme.mono(11.5, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .frame(width: 92, alignment: .trailing)
                            Text(NativeHardwareDisplayPolicies.formatCost(wh: wallWh, ratePerKwh: ratePerKwh, currency: currency))
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 76, alignment: .trailing)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 10)
                    }
                }
            }
        }
    }

    private func formatAxisDate(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        if ["30m", "1h", "6h"].contains(historyRange) {
            return d.formatted(date: .omitted, time: .shortened)
        }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private func powerSeries(kind: String) -> [NativeChartSeries] {
        let samples = NativeEnergyHistory.discontinuousSamples(history["points"].array, kind: kind)
        var defs: [(id: String, label: String, key: String)] = [
            ("systemLoad", "System Load (W)", "systemLoadW"),
            ("wallPower", "Wall Power (W)", "wallPowerW")
        ]
        if batteryPresent {
            defs.append(("batteryPower", "Battery Flow (W)", "batteryPowerW"))
        } else {
            defs.append(("adapterLoss", "PSU Conversion Loss (W)", "adapterLossW"))
        }
        return defs.map { def in
            NativeChartSeries(
                id: def.id,
                label: def.label,
                points: samples.map { s in
                    NativeChartPoint(x: s["date"].double, y: NativeHardwareDisplayPolicies.number(s[def.key]))
                }
            )
        }
    }

    private var energyBucketSeries: [NativeChartSeries] {
        let points = history["points"].array
        return [
            NativeChartSeries(
                id: "systemWh",
                label: "System Energy (Wh)",
                points: points.map { pt in
                    NativeChartPoint(x: pt["mean"]["date"].double, y: NativeHardwareDisplayPolicies.number(pt["systemEnergyWh"]))
                }
            ),
            NativeChartSeries(
                id: "wallWh",
                label: "Wall Energy (Wh)",
                points: points.map { pt in
                    NativeChartPoint(x: pt["mean"]["date"].double, y: NativeHardwareDisplayPolicies.number(pt["wallEnergyWh"]))
                }
            )
        ]
    }

    // MARK: - Tab 3: Electrical Rails & Sensors

    private var sensorsTab: some View {
        let peaks = sessionStats["sensorPeaks"]
        let avgs = sessionStats["sensorAverages"]
        let allSensors = snapshot["sensors"].array
        let powerCount = allSensors.filter { $0["unit"].string == "W" }.count
        let voltCount = allSensors.filter { $0["unit"].string == "V" }.count
        let currCount = allSensors.filter { $0["unit"].string == "A" }.count

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Electrical Rails & AppleSMC Channels")
                        .font(Theme.ui(18, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(allSensors.count) live hardware channels (\(powerCount) Power W · \(voltCount) Voltage V · \(currCount) Current A)")
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                T3Field(placeholder: "Filter by SMC key (PMVR, PSTR, VD0R) or rail description…", text: $query, mono: true, leadingIcon: "search")
                NativeMenuSelect(
                    title: "Sensor category",
                    selection: $group,
                    options: ["All", "Favorites", "Telemetry", "System Power", "Processor & SoC", "Rails & Ports", "Power (W)", "Voltage (V)", "Current (A)"].map { ($0, $0) },
                    width: 175
                )
            }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 22, height: 1)
                        Text("Channel / Description").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Category").frame(width: 130, alignment: .leading)
                        Text("Live Reading").frame(width: 96, alignment: .trailing)
                        Text("Mean").frame(width: 90, alignment: .trailing)
                        Text("Peak").frame(width: 90, alignment: .trailing)
                    }
                    .font(Theme.mono(10.5, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Theme.well)

                    ForEach(sensorRows, id: \.self["id"]) { sensor in
                        let id = sensor["id"].string
                        let unit = sensor["unit"].string
                        let cat = NativeHardwareDisplayPolicies.energySensorGroup(id, unit: unit)
                        Rectangle().fill(Theme.border).frame(height: 1)
                        HStack(spacing: 12) {
                            Button {
                                if !favorites.insert(id).inserted { favorites.remove(id) }
                                if !runtime.paths.readOnly {
                                    UserDefaults.standard.set(Array(favorites).sorted(), forKey: "uniapi.energy.favorites")
                                }
                            } label: {
                                NativeIcon("star", size: 13, strokeWidth: 1.65)
                                    .foregroundStyle(favorites.contains(id) ? Theme.warnFg : Theme.muted)
                            }
                            .buttonStyle(.plain).frame(width: 22)

                            HStack(spacing: 8) {
                                Text(id)
                                    .font(Theme.mono(11, weight: .semibold))
                                    .foregroundStyle(Theme.ink)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.well, in: RoundedRectangle(cornerRadius: 4))
                                Text(NativeHardwareDisplayPolicies.energySensorName(id))
                                    .font(Theme.ui(12.5, weight: .medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(cat)
                                .font(Theme.ui(11.5))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .frame(width: 130, alignment: .leading)

                            NativeNumberText(
                                text: formatSensorValue(NativeHardwareDisplayPolicies.number(sensor["value"]), unit: unit),
                                font: Theme.mono(13, weight: .semibold)
                            )
                            .frame(width: 96, alignment: .trailing)

                            Text(formatSensorValue(NativeHardwareDisplayPolicies.number(avgs[id]), unit: unit))
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.dim)
                                .frame(width: 90, alignment: .trailing)

                            Text(formatSensorValue(NativeHardwareDisplayPolicies.number(peaks[id]), unit: unit))
                                .font(Theme.mono(11.5))
                                .foregroundStyle(Theme.muted)
                                .frame(width: 90, alignment: .trailing)
                        }
                        .padding(.horizontal, 18).padding(.vertical, 11)
                    }
                    if sensorRows.isEmpty {
                        NativeEmptyState(title: "No matching electrical sensors", detail: "Try another category or search term.")
                            .padding(.vertical, 20)
                    }
                }
            }
        }
    }

    private func formatSensorValue(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f %@", value, unit)
    }

    // MARK: - Tab 4: Preferences

    private var preferencesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Energy Preferences")
                    .font(Theme.ui(20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Configure sidebar live watt badge, electricity tariff for cost calculations, and SQLite retention.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
            .padding(.bottom, 12)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 50, alignment: .topLeading), count: contentWidth >= 700 ? 2 : 1), alignment: .leading, spacing: 0) {
                settingRow("Sidebar badge metric", "Choose which live watt reading is shown next to Energy in the sidebar.") {
                    NativeMenuSelect(
                        title: "Sidebar badge metric",
                        selection: Binding(
                            get: { prefs["badgeMetric"].string.isEmpty ? "systemLoad" : prefs["badgeMetric"].string },
                            set: { value in Task { await operation("preferences", ["badgeMetric": .string(value)]) } }
                        ),
                        options: [
                            ("systemLoad", "System load (W)"),
                            ("wallPower", "Wall power (W)"),
                            ("batteryNet", "Battery net flow (W)"),
                            ("none", "Hidden")
                        ],
                        width: 185
                    )
                }
                settingRow("Electricity tariff", "Used to calculate window, since-boot, all-time, and projected monthly electricity costs.") {
                    HStack(spacing: 8) {
                        T3Field(placeholder: "$", text: $currencyText, mono: true).frame(width: 64)
                        T3Field(placeholder: "0.30", text: $rateText, mono: true).frame(width: 96)
                        Text("per kWh").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                        Button("Save") {
                            if let rate = Double(rateText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) {
                                Task { await operation("preferences", ["ratePerKwh": .number(rate), "currency": .string(currencyText)]) }
                            } else {
                                error = "Enter a valid number for electricity rate per kWh"
                            }
                        }.disabled(pending || runtime.paths.readOnly)
                    }
                }
                settingRow("History retention & storage", "Detailed 10-second samples for up to \(history["storage"]["rawDays"].isNull ? 7 : history["storage"]["rawDays"].int) days, minute summaries for \(history["storage"]["minuteDays"].isNull ? 90 : history["storage"]["minuteDays"].int) days, and hourly summaries for \(history["storage"]["hourlyDays"].isNull ? 365 : history["storage"]["hourlyDays"].int) days. Daily Wh totals and peaks stay indefinitely.") {
                    HStack(spacing: 12) {
                        Text(history.isNull ? "Reading…" : "~" + ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file))
                            .font(Theme.mono(13, weight: .medium))
                        Button("Export CSV") { exportHistory() }
                            .disabled(history["points"].array.isEmpty)
                    }
                }
            }
        }
    }

    private func settingRow<Control: View>(_ title: String, _ description: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.ui(14, weight: .medium))
            Text(description).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            control()
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
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
