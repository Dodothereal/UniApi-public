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
    @AppStorage("uniapi.energy.range") private var range = "30m"
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
    private var prefs: JSONValue { state["preferences"] }
    private var ratePerKwh: Double { NativeHardwareDisplayPolicies.number(prefs["ratePerKwh"]) ?? 0.30 }
    private var currency: String { prefs["currency"].string.isEmpty ? "$" : prefs["currency"].string }
    private var historyRange: String { tab == "history" ? range : "30m" }
    private var historyScope: String { historyRange == "custom" ? "custom:\(from.timeIntervalSince1970):\(through.timeIntervalSince1970)" : historyRange }
    private var history: JSONValue { historySelection.value(for: historyScope) }
    private var historyError: String? { historySelection.error(for: historyScope) }
    private var sensorRows: [JSONValue] {
        NativeHardwareDisplayPolicies.energySensorRows(snapshot["sensors"].array, favorites: favorites, group: group, query: query)
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
            NativePage(title: "Energy", subtitle: "Live watt flow, electrical rails, cumulative consumption and efficiency.", maxWidth: 1500, readiness: pageReadiness, showsHeader: false) {
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
                    if contentWidth >= 650 {
                        HStack(spacing: 20) { tabRail; Spacer(minLength: 8); powerSourcePill }
                    } else {
                        VStack(alignment: .leading, spacing: 12) { tabRail; powerSourcePill }
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
                do { try await Task.sleep(nanoseconds: tab == "flow" ? 10_000_000_000 : 30_000_000_000) } catch { return }
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

    private var energyHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) { energyHeading.fixedSize(); Spacer(minLength: 0); headerActions.fixedSize() }
            VStack(alignment: .leading, spacing: 12) { energyHeading; headerActions.frame(maxWidth: .infinity, alignment: .trailing) }
        }
    }

    private var energyHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Energy").font(Theme.ui(min(44, max(30, (contentWidth + 216 + 2 * density.pageMargin) * 0.04)), weight: .semibold)).tracking(-1.8).accessibilityAddTraits(.isHeader)
            Text("Live power flow, electrical rails, cumulative consumption and efficiency.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
        }
    }

    private var headerActions: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                NativeStatusDot(color: snapshot.isNull ? Theme.warnFg : Theme.okFg, pulse: !snapshot.isNull)
                Text(snapshot.isNull ? "Waiting for readings" : "Live · 2s").font(Theme.ui(11)).foregroundStyle(Theme.muted)
            }
            Button {
                Task { await operation("resetSession") }
            } label: {
                HStack(spacing: 6) { NativeIcon("rotate-ccw", size: 12, strokeWidth: 1.65); Text("Reset session") }
            }.disabled(pending || snapshot.isNull)
            Button {
                Task {
                    await reload(force: true)
                    if ["flow", "history", "settings"].contains(tab) { await loadHistory() }
                }
            } label: {
                HStack(spacing: 6) { NativeIcon("refresh-cw", size: 12, strokeWidth: 1.65); Text("Refresh") }
            }
        }
    }

    private var tabRail: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.self) { value in
                Button { tab = value } label: {
                    Text([
                        "flow": "Power flow",
                        "history": "History & totals",
                        "sensors": "Rails & sensors",
                        "settings": "Preferences"
                    ][value] ?? value)
                    .font(Theme.ui(12)).lineLimit(1).minimumScaleFactor(0.85).padding(.vertical, 7).frame(maxWidth: .infinity)
                    .foregroundStyle(tab == value ? Theme.ink : Theme.muted)
                }.buttonStyle(.plain).pointingHand().accessibilityAddTraits(tab == value ? [.isSelected] : [])
            }
        }
        .background(alignment: .leading) {
            GeometryReader { geometry in
                if let index = Self.tabs.firstIndex(of: tab) {
                    RoundedRectangle(cornerRadius: 8).fill(Theme.surface)
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1) }
                        .frame(width: geometry.size.width / CGFloat(Self.tabs.count))
                        .offset(x: geometry.size.width / CGFloat(Self.tabs.count) * CGFloat(index))
                        .animation(reduceMotion || !motionVisible ? nil : .spring(duration: 0.46), value: tab)
                }
            }.allowsHitTesting(false).accessibilityHidden(true)
        }
        .padding(5).frame(width: min(460, max(0, contentWidth))).background(Theme.well, in: RoundedRectangle(cornerRadius: 10)).accessibilityElement(children: .contain).accessibilityLabel("Energy sections")
    }

    private var powerSourcePill: some View {
        let ext = snapshot["externalConnected"].bool
        let charging = snapshot["charging"].bool
        let battW = snapshot["batteryPowerW"].double
        let label: String = {
            if snapshot.isNull { return "Telemetry unavailable" }
            if ext {
                if charging || battW > 0.2 { return String(format: "AC connected · charging battery (%+.1f W)", battW) }
                if battW < -0.2 { return String(format: "AC connected · battery assisting (%.1f W)", battW) }
                return "AC connected · powering Mac directly"
            }
            return String(format: "On battery power (%.1f W draw)", abs(battW))
        }()
        return HStack(spacing: 8) {
            NativeStatusDot(color: ext ? Theme.okFg : Theme.warnFg)
            Text(label)
        }.font(Theme.ui(11)).foregroundStyle(Theme.muted)
    }

    // MARK: - Tab 1: Power Flow & Overview

    private var powerFlowTab: some View {
        VStack(alignment: .leading, spacing: 22) {
            powerFlowTopologyCard
            kpiGrid
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    subsystemBreakdownCard.frame(minWidth: 420, maxWidth: .infinity)
                    cumulativeEnergyCard.frame(width: 380)
                }
                VStack(alignment: .leading, spacing: 20) {
                    subsystemBreakdownCard
                    cumulativeEnergyCard
                }
            }
            if let historyError { NativeError(message: historyError) }
            Card(padding: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Live power trace").font(Theme.ui(14, weight: .medium))
                            Text("System load, wall draw and battery net power · last 30 minutes").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        Button { tab = "history" } label: {
                            HStack(spacing: 6) { Text("Explore history"); NativeIcon("arrow-up-right", size: 12, strokeWidth: 1.65) }
                        }.buttonStyle(T3Button(.ghost))
                    }
                    NativeLineChart(
                        series: powerSeries(kind: "mean"),
                        height: 195,
                        showPoints: false,
                        includeZero: true,
                        xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .omitted, time: .shortened) },
                        yFormat: { String(format: "%.1f W", $0) }
                    )
                }
            }
        }
    }

    private var powerFlowTopologyCard: some View {
        let ext = snapshot["externalConnected"].bool
        let wallW = NativeHardwareDisplayPolicies.number(snapshot["wallPowerW"])
        let sysInW = NativeHardwareDisplayPolicies.number(snapshot["systemPowerInW"])
        let lossW = NativeHardwareDisplayPolicies.number(snapshot["adapterLossW"])
        let sysLoadW = NativeHardwareDisplayPolicies.number(snapshot["systemLoadW"])
        let battW = NativeHardwareDisplayPolicies.number(snapshot["batteryPowerW"])
        let eff = NativeHardwareDisplayPolicies.number(snapshot["efficiencyPercent"])
        let voltV = NativeHardwareDisplayPolicies.number(snapshot["voltageInV"])
        let currA = NativeHardwareDisplayPolicies.number(snapshot["currentInA"])
        let budgetW = NativeHardwareDisplayPolicies.number(snapshot["powerBudgetW"])

        return Card(padding: 22) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Real-time power flow").font(Theme.ui(14, weight: .medium))
                        Text(ext ? "Wall power through adapter into DC-in bus, split between Mac system load and battery pack." : "Running on internal battery pack; DC-in bus is idle.")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 12)
                    if let budgetW, budgetW > 0 {
                        Text(String(format: "Adapter budget %.0f W", budgetW))
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: contentWidth < 680 ? 2 : 4), spacing: 12) {
                    flowStageNode(
                        icon: "plug-zap",
                        title: "Wall / AC Estimate",
                        watts: NativeHardwareDisplayPolicies.formatWatts(wallW),
                        detail: lossW.map { String(format: "Adapter heat loss %.2f W", $0) } ?? "No adapter loss",
                        subdetail: eff.map { String(format: "%.1f%% conversion efficiency", $0) } ?? (ext ? "Efficiency pending" : "Adapter unplugged"),
                        color: Theme.pairPalette[6]
                    )
                    flowStageNode(
                        icon: "plug",
                        title: "System DC-In Bus",
                        watts: NativeHardwareDisplayPolicies.formatWatts(sysInW),
                        detail: String(format: "%.2f V · %.2f A", voltV ?? 0, currA ?? 0),
                        subdetail: budgetW.map { sysInW != nil ? String(format: "%.0f%% of %.0f W ceiling", min(100, ((sysInW ?? 0) / max(1, $0)) * 100), $0) : "—" } ?? "USB-C / MagSafe input",
                        color: Theme.accent
                    )
                    flowStageNode(
                        icon: "cpu",
                        title: "Mac System Load",
                        watts: NativeHardwareDisplayPolicies.formatWatts(sysLoadW),
                        detail: String(format: "Burn rate %.1f Wh/hr", sysLoadW ?? 0),
                        subdetail: sessionStats["avgSystemLoadW"].isNull ? "Session avg pending" : String(format: "Session avg %.1f W · peak %.1f W", sessionStats["avgSystemLoadW"].double, sessionStats["peakSystemLoadW"].double),
                        color: Theme.ink
                    )
                    flowStageNode(
                        icon: "battery-charging",
                        title: (battW ?? 0) > 0.05 ? "Into Battery (Charging)" : (battW ?? 0) < -0.05 ? "From Battery (Discharging)" : "Battery Flow (Idle)",
                        watts: NativeHardwareDisplayPolicies.formatWatts(battW, signed: true),
                        detail: String(format: "%.0f%% · %.1f / %.1f Wh", battery["percent"].double, battery["remainingWh"].double, battery["maxCapacityWh"].double),
                        subdetail: String(format: "%.2f V · %+.2f A%@", battery["voltageV"].double, battery["currentA"].double, battery["temperatureC"].isNull ? "" : String(format: " · %.1f°C", battery["temperatureC"].double)),
                        color: (battW ?? 0) >= 0 ? Theme.okFg : Theme.warnFg
                    )
                }
            }
        }
    }

    private func flowStageNode(icon: String, title: String, watts: String, detail: String, subdetail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                NativeIcon(icon, size: 14, strokeWidth: 1.65).foregroundStyle(color)
                Text(title).font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            NativeNumberText(text: watts, font: Theme.ui(26, weight: .semibold), color: Theme.ink, isolateLayout: true)
            Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.dim).lineLimit(1)
            Text(subdetail).font(Theme.ui(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1) }
    }

    private var kpiGrid: some View {
        let sessionWh = NativeHardwareDisplayPolicies.number(sessionStats["systemEnergyWh"])
        let bootWh = NativeHardwareDisplayPolicies.number(bootStats["systemEnergyWh"])
        let allTimeWh = NativeHardwareDisplayPolicies.number(allTimeStats["systemEnergyWh"])
        let avgSessionW = NativeHardwareDisplayPolicies.number(sessionStats["avgSystemLoadW"])
        let p95SessionW = NativeHardwareDisplayPolicies.number(sessionStats["p95SystemLoadW"])
        let minSessionW = NativeHardwareDisplayPolicies.number(sessionStats["minSystemLoadW"])
        let peakSessionW = NativeHardwareDisplayPolicies.number(sessionStats["peakSystemLoadW"])
        let bootAvgW = NativeHardwareDisplayPolicies.number(bootStats["avgSystemLoadW"])
        let basisW = bootAvgW ?? avgSessionW ?? NativeHardwareDisplayPolicies.number(snapshot["systemLoadW"]) ?? 0
        let dailyWh = basisW * 24.0
        let monthlyWh = dailyWh * 30.0
        let yearlyWh = dailyWh * 365.0

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: contentWidth < 680 ? 2 : 3), spacing: 14) {
            statTile(
                title: "Session Energy Used",
                value: NativeHardwareDisplayPolicies.formatEnergyWh(sessionWh),
                subtitle: String(format: "Wall %@ · Est. %@", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(sessionStats["wallEnergyWh"])), NativeHardwareDisplayPolicies.formatCost(wh: sessionStats["wallEnergyWh"].double, ratePerKwh: ratePerKwh, currency: currency)),
                badge: "\(sessionStats["sampleCount"].int) samples"
            )
            statTile(
                title: "Energy Since Boot",
                value: NativeHardwareDisplayPolicies.formatEnergyWh(bootWh),
                subtitle: String(format: "Wall %@ · Loss %@", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(bootStats["wallEnergyWh"])), NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(bootStats["adapterLossWh"]))),
                badge: bootAvgW.map { String(format: "Avg %.1f W", $0) } ?? "Hardware counter"
            )
            statTile(
                title: "All-Time Recorded",
                value: NativeHardwareDisplayPolicies.formatEnergyWh(allTimeWh),
                subtitle: String(format: "Wall %@ · Est. %@", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(allTimeStats["wallEnergyWh"])), NativeHardwareDisplayPolicies.formatCost(wh: allTimeStats["wallEnergyWh"].double, ratePerKwh: ratePerKwh, currency: currency)),
                badge: allTimeStats["peakSystemLoadW"].isNull ? "SQLite rollups" : String(format: "Peak %.1f W", allTimeStats["peakSystemLoadW"].double)
            )
            statTile(
                title: "Session Average Draw",
                value: NativeHardwareDisplayPolicies.formatWatts(avgSessionW),
                subtitle: String(format: "Min %@ · Peak %@", NativeHardwareDisplayPolicies.formatWatts(minSessionW), NativeHardwareDisplayPolicies.formatWatts(peakSessionW)),
                badge: p95SessionW.map { String(format: "P95 %.1f W", $0) } ?? "Live"
            )
            statTile(
                title: "Battery Energy Reserve",
                value: String(format: "%.1f Wh", battery["remainingWh"].double),
                subtitle: String(format: "Max %.1f Wh · Design %.1f Wh", battery["maxCapacityWh"].double, battery["designCapacityWh"].double),
                badge: "\(battery["percent"].int)% charged"
            )
            statTile(
                title: "Projected Consumption",
                value: String(format: "%.2f kWh/mo", monthlyWh / 1000.0),
                subtitle: String(format: "Day %@ · Year %.0f kWh", NativeHardwareDisplayPolicies.formatEnergyWh(dailyWh), yearlyWh / 1000.0),
                badge: String(format: "%@/mo", NativeHardwareDisplayPolicies.formatCost(wh: monthlyWh, ratePerKwh: ratePerKwh, currency: currency))
            )
        }
    }

    private func statTile(title: String, value: String, subtitle: String, badge: String) -> some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(title).font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(badge).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                }
                NativeNumberText(text: value, font: Theme.ui(24, weight: .semibold), isolateLayout: true)
                Text(subtitle).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }

    private var subsystemBreakdownCard: some View {
        let subsystems = snapshot["subsystems"].array
        let totalLoad = max(0.1, snapshot["systemLoadW"].double)
        return Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Subsystem & rail power breakdown").font(Theme.ui(14, weight: .medium))
                        Text("Live SMC rail distribution relative to system load").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Text(NativeHardwareDisplayPolicies.formatWatts(snapshot["systemLoadW"].double))
                        .font(Theme.mono(12, weight: .semibold))
                }
                VStack(spacing: 11) {
                    ForEach(subsystems, id: \.self["id"]) { item in
                        let watts = max(0, item["watts"].double)
                        let share = min(1.0, max(0, watts / totalLoad))
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item["label"].string).font(Theme.ui(12)).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(String(format: "%.0f%%", share * 100)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                                Text(String(format: "%.2f W", watts)).font(Theme.mono(11.5, weight: .medium)).frame(width: 66, alignment: .trailing)
                            }
                            CapsuleBar(fraction: share, color: Theme.accent)
                        }
                    }
                }
            }
        }
    }

    private var cumulativeEnergyCard: some View {
        Card(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Energy ledger").font(Theme.ui(14, weight: .medium))
                    Text("Breakdown of watt-hours across session, boot and history").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                }
                VStack(spacing: 10) {
                    ledgerRow("Session system energy", NativeHardwareDisplayPolicies.formatEnergyWh(sessionStats["systemEnergyWh"].double))
                    ledgerRow("Session wall energy", NativeHardwareDisplayPolicies.formatEnergyWh(sessionStats["wallEnergyWh"].double))
                    ledgerRow("Session adapter heat loss", NativeHardwareDisplayPolicies.formatEnergyWh(sessionStats["adapterLossWh"].double))
                    ledgerRow("Session battery charged", NativeHardwareDisplayPolicies.formatEnergyWh(sessionStats["batteryChargedWh"].double))
                    ledgerRow("Session battery discharged", NativeHardwareDisplayPolicies.formatEnergyWh(sessionStats["batteryDischargedWh"].double))
                    Divider()
                    ledgerRow("Boot system energy", NativeHardwareDisplayPolicies.formatEnergyWh(bootStats["systemEnergyWh"].double))
                    ledgerRow("Boot wall energy", NativeHardwareDisplayPolicies.formatEnergyWh(bootStats["wallEnergyWh"].double))
                    ledgerRow("Boot adapter loss", NativeHardwareDisplayPolicies.formatEnergyWh(bootStats["adapterLossWh"].double))
                    ledgerRow("Boot average efficiency", bootStats["efficiencyPercent"].isNull ? "—" : String(format: "%.1f%%", bootStats["efficiencyPercent"].double))
                }
            }
        }
    }

    private func ledgerRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            Text(value).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.ink)
        }
    }

    // MARK: - Tab 2: History & Totals

    private var historyTab: some View {
        let summary = history["summary"]
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Power & energy over time").font(Theme.ui(18, weight: .medium)).accessibilityAddTraits(.isHeader)
                Text("Multi-tier history with average, peak and minimum watts plus integrated Wh per bucket.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            }
            HStack {
                NativeMenuSelect(
                    title: "History range",
                    selection: $range,
                    options: [
                        ("30m", "30 minutes"), ("1h", "1 hour"), ("6h", "6 hours"), ("24h", "24 hours"),
                        ("7d", "7 days"), ("30d", "30 days"), ("90d", "90 days"), ("1y", "1 year"),
                        ("all", "All time"), ("custom", "Custom")
                    ],
                    width: 125
                )
                T3Segmented(options: [("mean", "Average"), ("max", "Peak"), ("min", "Minimum")], selection: statistic) { statistic = $0 }
                Spacer()
                Button("Refresh") { Task { await loadHistory() } }
                Button("Export CSV") { exportHistory() }.disabled(history["points"].array.isEmpty)
            }
            if range == "custom" {
                HStack {
                    DatePicker("From", selection: $from, in: ...through, displayedComponents: .date)
                    DatePicker("Through", selection: $through, in: from...Date(), displayedComponents: .date)
                }
            }
            if let historyError { NativeError(message: historyError) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: contentWidth < 680 ? 2 : 4), spacing: 12) {
                statTile(
                    title: "Range System Energy",
                    value: NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(summary["systemEnergyWh"])),
                    subtitle: String(format: "Wall %@ · Loss %@", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(summary["wallEnergyWh"])), NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(summary["adapterLossWh"]))),
                    badge: NativeHardwareDisplayPolicies.formatCost(wh: NativeHardwareDisplayPolicies.number(summary["wallEnergyWh"]), ratePerKwh: ratePerKwh, currency: currency)
                )
                statTile(
                    title: "Range Average Draw",
                    value: NativeHardwareDisplayPolicies.formatWatts(NativeHardwareDisplayPolicies.number(summary["avgSystemLoadW"])),
                    subtitle: String(format: "Wall avg %@", NativeHardwareDisplayPolicies.formatWatts(NativeHardwareDisplayPolicies.number(summary["avgWallPowerW"]))),
                    badge: summary["p95SystemLoadW"].isNull ? "—" : String(format: "P95 %.1f W", summary["p95SystemLoadW"].double)
                )
                statTile(
                    title: "Range Peak & Min Draw",
                    value: NativeHardwareDisplayPolicies.formatWatts(NativeHardwareDisplayPolicies.number(summary["peakSystemLoadW"])),
                    subtitle: String(format: "Min %@ · Wall peak %@", NativeHardwareDisplayPolicies.formatWatts(NativeHardwareDisplayPolicies.number(summary["minSystemLoadW"])), NativeHardwareDisplayPolicies.formatWatts(NativeHardwareDisplayPolicies.number(summary["peakWallPowerW"]))),
                    badge: "\(summary["sampleCount"].int) samples"
                )
                statTile(
                    title: "Battery Net Energy",
                    value: NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(summary["batteryNetWh"])),
                    subtitle: String(format: "+%@ in · -%@ out", NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(summary["batteryChargedWh"])), NativeHardwareDisplayPolicies.formatEnergyWh(NativeHardwareDisplayPolicies.number(summary["batteryDischargedWh"]))),
                    badge: summary["avgEfficiencyPercent"].isNull ? "Direct" : String(format: "%.1f%% eff", summary["avgEfficiencyPercent"].double)
                )
            }
            NativeCard(title: "Power draw (Watts)") {
                NativeLineChart(
                    series: powerSeries(kind: statistic),
                    includeZero: true,
                    xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) },
                    yFormat: { String(format: "%.1f W", $0) }
                )
            }
            NativeCard(title: "Energy consumed per bucket (Wh)") {
                NativeLineChart(
                    series: energyBucketSeries,
                    includeZero: true,
                    xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) },
                    yFormat: { String(format: "%.2f Wh", $0) }
                )
            }
            Text("Missing observations remain gaps. \(history["points"].array.count) buckets · ~\(ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file)) stored.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
        }
    }

    private func powerSeries(kind: String) -> [NativeChartSeries] {
        let samples = NativeEnergyHistory.discontinuousSamples(history["points"].array, kind: kind)
        let defs: [(id: String, label: String, key: String)] = [
            ("systemLoad", "System Load (W)", "systemLoadW"),
            ("wallPower", "Wall Power (W)", "wallPowerW"),
            ("batteryPower", "Battery Flow (W)", "batteryPowerW")
        ]
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
        return VStack(alignment: .leading, spacing: 12) {
            sectionIntro("Electrical rails & sensors", "\(snapshot["sensors"].array.count) live power, voltage and current channels.")
            HStack {
                T3Field(placeholder: "Find a power rail, voltage or current sensor…", text: $query, mono: true, leadingIcon: "search")
                NativeMenuSelect(
                    title: "Sensor category",
                    selection: $group,
                    options: ["All", "Favorites", "Telemetry", "System Power", "Processor & SoC", "Rails & Ports", "Power (W)", "Voltage (V)", "Current (A)"].map { ($0, $0) },
                    width: 165
                )
                Button("Reset session stats") { Task { await operation("resetSession") } }
            }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 22, height: 1)
                        Text("Sensor / Rail").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Current").frame(width: 95, alignment: .trailing)
                        Text("Session avg").frame(width: 95, alignment: .trailing)
                        Text("Session peak").frame(width: 100, alignment: .trailing)
                    }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 18).padding(.vertical, 16).background(Theme.well)
                    ForEach(sensorRows, id: \.self["id"]) { sensor in
                        let id = sensor["id"].string
                        let unit = sensor["unit"].string
                        Rectangle().fill(Theme.border).frame(height: 1)
                        HStack(spacing: 12) {
                            Button {
                                if !favorites.insert(id).inserted { favorites.remove(id) }
                                if !runtime.paths.readOnly {
                                    UserDefaults.standard.set(Array(favorites).sorted(), forKey: "uniapi.energy.favorites")
                                }
                            } label: {
                                NativeIcon("star", size: 14, strokeWidth: 1.65)
                                    .foregroundStyle(favorites.contains(id) ? Theme.warnFg : Theme.muted)
                            }.buttonStyle(.plain).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(NativeHardwareDisplayPolicies.energySensorName(id)).font(Theme.ui(12)).lineLimit(1)
                                Text("\(id) · \(NativeHardwareDisplayPolicies.energySensorGroup(id, unit: unit))").font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            NativeNumberText(text: formatSensorValue(NativeHardwareDisplayPolicies.number(sensor["value"]), unit: unit), font: Theme.ui(14, weight: .medium))
                                .frame(width: 95, alignment: .trailing)
                            Text(formatSensorValue(NativeHardwareDisplayPolicies.number(avgs[id]), unit: unit)).font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                                .frame(width: 95, alignment: .trailing)
                            Text(formatSensorValue(NativeHardwareDisplayPolicies.number(peaks[id]), unit: unit)).font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                                .frame(width: 100, alignment: .trailing)
                        }.padding(.horizontal, 18).padding(.vertical, 14)
                    }
                    if sensorRows.isEmpty {
                        NativeEmptyState(title: "No matching electrical sensors", detail: "Try another category or search term.")
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
            sectionIntro("Energy preferences", "Customize sidebar badge display, electricity tariff and history retention.").padding(.bottom, 12)
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
                settingRow("Electricity tariff", "Used to estimate session, historical and projected monthly energy cost.") {
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
                settingRow("History storage", "Detailed 10-second samples for up to \(history["storage"]["rawDays"].isNull ? 7 : history["storage"]["rawDays"].int) days, minute summaries for \(history["storage"]["minuteDays"].isNull ? 90 : history["storage"]["minuteDays"].int) days, and hourly summaries for \(history["storage"]["hourlyDays"].isNull ? 365 : history["storage"]["hourlyDays"].int) days. Daily Wh totals and peaks stay indefinitely.") {
                    Text(history.isNull ? "Reading…" : "~" + ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file)).font(Theme.mono(13))
                }
                settingRow("Session accumulator", "Resetting the session clears in-memory session Wh counters, min/peak/P95 draw and sensor peaks without deleting SQLite history.") {
                    Button("Reset session counters") { Task { await operation("resetSession") } }.disabled(pending)
                }
            }
        }
    }

    private func settingRow<Control: View>(_ title: String, _ description: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.ui(14, weight: .medium))
            Text(description).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            control()
        }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    private func sectionIntro(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.ui(30, weight: .semibold)).tracking(-0.9).accessibilityAddTraits(.isHeader)
            Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted)
        }
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
