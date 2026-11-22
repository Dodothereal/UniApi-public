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
    @Environment(\.nativeHostTabs) private var host
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
            NativePage(title: "Energy", maxWidth: 1280, readiness: pageReadiness, tabs: {
                if state["supported"].bool {
                    NativeTabs(options: [("flow", "Flow"), ("history", "History"), ("sensors", "Sensors"), ("settings", "Preferences")], selection: tab) { tab = $0; host?.select($0) }
                        .nativeHostedView(["flow", "history", "sensors", "settings"]) { tab = $0 }
                }
            }, actions: {
                if state["supported"].bool, ["flow", "history"].contains(tab) {
                    NativeMenuSelect(title: "Range", selection: $range, options: [("30m", "30 minutes"), ("1h", "1 hour"), ("6h", "6 hours"), ("24h", "24 hours"), ("7d", "7 days"), ("30d", "30 days"), ("all", "All time"), ("custom", "Custom")], width: 120)
                }
                if tab == "history" { T3IconButton(system: "download", help: "Export CSV") { exportHistory() }.disabled(history["points"].array.isEmpty) }
                T3IconButton(system: "refresh-cw", help: "Refresh") { Task { await reload(force: true); if ["flow", "history", "settings"].contains(tab) { await loadHistory() } } }
            }) {
                if let statusReadError { statusError(statusReadError) }
                if let error { NativeError(message: error) }
                if !state["error"].string.isEmpty { statusError(state["error"].string) }
                if state.isNull {
                    if error == nil && statusReadError == nil { ShimmerText(text: "Loading…") }
                } else if !state["supported"].bool {
                    NativeEmptyState(title: "No power readings", detail: "This Mac does not expose its power controller.", icon: "zap")
                } else {
                    switch tab {
                    case "history": historyTab
                    case "sensors": sensorsTab
                    case "settings": preferencesTab
                    default: powerFlowTab
                    }
                }
            }
            .onChange(of: max(0, min(1280, viewport.size.width) - 2 * density.pageMargin), initial: true) { _, width in contentWidth = width }
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
        HStack(spacing: 8) {
            NativeError(message: message)
            Button("Retry") { Task { await reload(force: true) } }.buttonStyle(T3Button(.outline))
        }
    }
    private func number(_ value: JSONValue) -> Double? { NativeHardwareDisplayPolicies.number(value) }
    private func wh(_ value: JSONValue) -> String { NativeHardwareDisplayPolicies.formatEnergyWh(number(value)) }
    private func cost(_ value: JSONValue) -> String { NativeHardwareDisplayPolicies.formatCost(wh: number(value), ratePerKwh: ratePerKwh, currency: currency) }

    /// Where the power is coming from right now, in one line.
    private var sourceLabel: String {
        if snapshot.isNull { return "" }
        let mode = snapshot["powerMode"].string, battW = snapshot["batteryPowerW"].double
        if !batteryPresent || mode == "wall-only" { return String(format: "Mains · %.2f V at %.2f A", snapshot["voltageInV"].double, snapshot["currentInA"].double) }
        if snapshot["externalConnected"].bool {
            if mode == "ac-charging" || battW > 0.2 { return String(format: "Mains, charging at %.1f W", battW) }
            if mode == "ac-assisting" || battW < -0.2 { return String(format: "Mains, battery assisting with %.1f W", abs(battW)) }
            return "Mains"
        }
        return "Battery"
    }

    private var customRange: some View {
        HStack(spacing: 8) {
            DatePicker("From", selection: $from, in: ...through, displayedComponents: .date).labelsHidden().accessibilityLabel("From")
            Text("to").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
            DatePicker("Through", selection: $through, in: from...Date(), displayedComponents: .date).labelsHidden().accessibilityLabel("Through")
            Spacer(minLength: 0)
        }
    }
    private var statisticPicker: some View {
        T3Segmented(options: [("mean", "Average"), ("max", "Peak"), ("min", "Minimum")], selection: statistic) { statistic = $0 }
    }

    // MARK: - Flow

    private var powerFlowTab: some View {
        VStack(alignment: .leading, spacing: 24) {
            pipeline
            if range == "custom" { customRange }
            energySummaryStrip
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 32) {
                    rails.frame(minWidth: 400, maxWidth: .infinity)
                    ledger.frame(width: 400)
                }
                VStack(alignment: .leading, spacing: 24) { rails; ledger }
            }
            if let historyError { NativeError(message: historyError) }
            NativeSection(rangeDisplayName, detail: "\(history["points"].array.count) buckets", trailing: { statisticPicker }) {
                NativeLineChart(series: powerSeries(kind: statistic), height: 200, showPoints: false, includeZero: true, xFormat: { formatAxisDate($0) }, yFormat: { String(format: "%.1f W", $0) })
            }
        }
    }

    /// Wall to load, left to right. Every meter is a share of the supply's budget.
    private var pipeline: some View {
        let wallW = number(snapshot["wallPowerW"]), sysInW = number(snapshot["systemPowerInW"]), lossW = number(snapshot["adapterLossW"])
        let sysLoadW = number(snapshot["systemLoadW"]), battW = number(snapshot["batteryPowerW"]), eff = number(snapshot["efficiencyPercent"])
        let budgetW = number(snapshot["powerBudgetW"]).flatMap { $0 > 0 ? $0 : nil }
        let socW = snapshot["subsystems"].array.first(where: { $0["id"].string == "soc" }).flatMap { number($0["watts"]) }
        let thermalW = snapshot["subsystems"].array.first(where: { $0["id"].string == "thermal" }).flatMap { number($0["watts"]) }
        let hourlyCost = ((wallW ?? sysLoadW ?? 0) / 1000.0) * ratePerKwh
        func share(_ watts: Double?) -> Double? { budgetW.map { min(1, max(0, (watts ?? 0) / $0)) } }
        return NativeSection("Now", detail: sourceLabel) {
            NativeReadoutStrip(minCell: 170) {
                NativeReadout(label: "Wall", value: NativeHardwareDisplayPolicies.formatWatts(wallW),
                              detail: [eff.map { String(format: "%.1f%% efficient", $0) }, lossW.map { String(format: "%.2f W lost", $0) }].compactMap { $0 }.joined(separator: " · "),
                              icon: "plug-zap", meter: share(wallW))
                NativeReadout(label: "DC in", value: NativeHardwareDisplayPolicies.formatWatts(sysInW),
                              detail: budgetW.map { String(format: "%.0f W of %.0f W", sysInW ?? 0, $0) } ?? String(format: "%.2f V × %.2f A", number(snapshot["voltageInV"]) ?? 0, number(snapshot["currentInA"]) ?? 0),
                              icon: "plug", meter: share(sysInW))
                NativeReadout(label: "System", value: NativeHardwareDisplayPolicies.formatWatts(sysLoadW),
                              detail: String(format: "%@%.3f per hour", currency, hourlyCost), icon: "cpu", meter: share(sysLoadW), meterColor: Theme.accent)
                if batteryPresent {
                    NativeReadout(label: (battW ?? 0) > 0.05 ? "Battery, charging" : (battW ?? 0) < -0.05 ? "Battery, discharging" : "Battery",
                                  value: NativeHardwareDisplayPolicies.formatWatts(battW, signed: true),
                                  detail: String(format: "%.0f%% · %.1f of %.1f Wh", battery["percent"].double, battery["remainingWh"].double, battery["maxCapacityWh"].double),
                                  icon: "battery-charging", meter: max(0, min(1, battery["percent"].double / 100.0)))
                } else {
                    NativeReadout(label: "SoC", value: NativeHardwareDisplayPolicies.formatWatts(socW ?? thermalW ?? sysLoadW),
                                  detail: thermalW.map { String(format: "Thermal zone %.2f W", $0) } ?? "",
                                  icon: "activity", meter: (sysLoadW ?? 0) > 0 ? min(1, max(0, (socW ?? 0) / max(1, sysLoadW ?? 1))) : nil)
                }
            }
        }
    }

    private var energySummaryStrip: some View {
        let summary = history["summary"]
        let windowAvgW = number(summary["avgSystemLoadW"]), bootAvgW = number(bootStats["avgSystemLoadW"])
        let basisW = bootAvgW ?? windowAvgW ?? number(snapshot["systemLoadW"]) ?? 0
        let wallBasisW = number(bootStats["avgSystemPowerInW"]) ?? number(snapshot["wallPowerW"]) ?? basisW
        let monthlyWh = wallBasisW * 24.0 * 30.0
        return NativeReadoutStrip(minCell: 170) {
            NativeReadout(label: "Used", value: wh(summary["systemEnergyWh"]), detail: "\(wh(summary["wallEnergyWh"])) at the wall · \(cost(summary["wallEnergyWh"]))")
            NativeReadout(label: "Since boot", value: wh(bootStats["systemEnergyWh"]), detail: bootAvgW.map { String(format: "%.1f W average", $0) } ?? "")
            NativeReadout(label: "Load, min to peak", value: NativeHardwareDisplayPolicies.formatWatts(number(summary["minSystemLoadW"])) + " – " + NativeHardwareDisplayPolicies.formatWatts(number(summary["peakSystemLoadW"])),
                          detail: [windowAvgW.map { String(format: "%.1f W average", $0) }, number(summary["p95SystemLoadW"]).map { String(format: "p95 %.1f W", $0) }].compactMap { $0 }.joined(separator: " · "))
            NativeReadout(label: "At this rate", value: String(format: "%.2f", monthlyWh / 1000.0), unit: "kWh / month",
                          detail: NativeHardwareDisplayPolicies.formatCost(wh: monthlyWh, ratePerKwh: ratePerKwh, currency: currency) + " per month")
        }
    }

    private var rails: some View {
        let subsystems = snapshot["subsystems"].array
        let sysLoad = max(0.1, snapshot["systemLoadW"].double)
        let maxRail = max(sysLoad, subsystems.map { $0["watts"].double }.max() ?? sysLoad)
        return NativeSection("Rails", trailing: {
            Button("\(snapshot["sensors"].array.count) sensors", nativeIcon: "arrow-right") { tab = "sensors" }.buttonStyle(T3Button(.ghost))
        }) {
            VStack(spacing: 0) {
                Theme.rule.frame(height: 1)
                ForEach(Array(subsystems.enumerated()), id: \.offset) { _, item in
                    let watts = max(0, item["watts"].double)
                    HStack(spacing: 12) {
                        Text(item["label"].string).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.ink).lineLimit(1).frame(width: 150, alignment: .leading).help(item["group"].string)
                        NativeTickMeter(fraction: min(1, max(0, watts / maxRail)), color: Theme.ink, height: 10)
                        Text(String(format: "%.0f%%", min(1, max(0, watts / sysLoad)) * 100)).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 38, alignment: .trailing)
                        Text(String(format: "%.2f W", watts)).font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink).frame(width: 64, alignment: .trailing)
                    }.frame(height: 34).overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
                        .accessibilityElement(children: .combine)
                }
                if subsystems.isEmpty { Text("No rail readings").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 10) }
            }
        }
    }

    /// One table: what was used, by period.
    private var ledger: some View {
        let summary = history["summary"]
        let short = ["30m": "30 min", "1h": "1 hour", "6h": "6 hours", "24h": "24 hours", "7d": "7 days", "30d": "30 days", "all": "Recorded", "custom": "Custom"][historyRange] ?? historyRange
        let rows: [(String, String, String, String)] = [
            ("System", wh(summary["systemEnergyWh"]), wh(bootStats["systemEnergyWh"]), wh(allTimeStats["systemEnergyWh"])),
            ("Wall", wh(summary["wallEnergyWh"]), wh(bootStats["wallEnergyWh"]), wh(allTimeStats["wallEnergyWh"])),
            ("Conversion loss", wh(summary["adapterLossWh"]), wh(bootStats["adapterLossWh"]), "—"),
            ("Efficiency", "—", bootStats["efficiencyPercent"].isNull ? "—" : String(format: "%.1f%%", bootStats["efficiencyPercent"].double), "—"),
            ("Cost", cost(summary["wallEnergyWh"]), cost(bootStats["wallEnergyWh"]), cost(allTimeStats["wallEnergyWh"]))
        ]
        return NativeSection("Ledger") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach([short, "Since boot", "All time"], id: \.self) { Text($0).frame(width: 84, alignment: .trailing) }
                }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 24, alignment: .top)
                Theme.rule.frame(height: 1)
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 8) {
                        Text(row.0).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array([row.1, row.2, row.3].enumerated()), id: \.offset) { _, value in
                            Text(value).font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(value == "—" ? Theme.faint : Theme.ink).lineLimit(1).minimumScaleFactor(0.8).frame(width: 84, alignment: .trailing)
                        }
                    }.frame(height: 34).overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
                }
            }
        }
    }

    // MARK: - History

    private var historyTab: some View {
        let points = history["points"].array
        return VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) { statisticPicker; if range == "custom" { customRange } else { Spacer(minLength: 0) } }
            if let historyError { NativeError(message: historyError) }
            energySummaryStrip
            NativeCard(title: "Power") {
                NativeLineChart(series: powerSeries(kind: statistic), height: 220, showPoints: points.count <= 48, includeZero: true, xFormat: { formatAxisDate($0) }, yFormat: { String(format: "%.1f W", $0) })
            }
            NativeCard(title: "Energy per bucket") {
                NativeLineChart(series: energyBucketSeries, height: 190, showPoints: points.count <= 48, includeZero: true, xFormat: { formatAxisDate($0) }, yFormat: { String(format: "%.2f Wh", $0) })
            }
            historyBucketTableCard(points: points)
            Text("\(points.count) buckets · \(ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file)) stored")
                .font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint)
        }
    }

    private func historyBucketTableCard(points: [JSONValue]) -> some View {
        let recent = Array(points.suffix(60).reversed())
        return NativeSection("Buckets", detail: points.count > recent.count ? "latest \(recent.count) of \(points.count)" : "") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("Time").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Average").frame(width: 82, alignment: .trailing)
                    Text("Peak").frame(width: 82, alignment: .trailing)
                    Text("Wall").frame(width: 82, alignment: .trailing)
                    Text("Energy").frame(width: 92, alignment: .trailing)
                    Text("Cost").frame(width: 76, alignment: .trailing)
                }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 30)
                ForEach(Array(recent.enumerated()), id: \.offset) { _, pt in
                    Theme.rule.frame(height: 1)
                    HStack(spacing: 10) {
                        Text(Date(timeIntervalSince1970: pt["mean"]["date"].double / 1000).formatted(date: .abbreviated, time: .standard))
                            .foregroundStyle(Theme.dim).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(NativeHardwareDisplayPolicies.formatWatts(number(pt["mean"]["systemLoadW"]))).fontWeight(.medium).frame(width: 82, alignment: .trailing)
                        Text(NativeHardwareDisplayPolicies.formatWatts(number(pt["max"]["systemLoadW"]))).foregroundStyle(Theme.dim).frame(width: 82, alignment: .trailing)
                        Text(NativeHardwareDisplayPolicies.formatWatts(number(pt["mean"]["wallPowerW"]))).foregroundStyle(Theme.dim).frame(width: 82, alignment: .trailing)
                        Text(wh(pt["systemEnergyWh"])).fontWeight(.medium).frame(width: 92, alignment: .trailing)
                        Text(cost(pt["wallEnergyWh"])).foregroundStyle(Theme.muted).frame(width: 76, alignment: .trailing)
                    }.font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.ink).frame(height: 32)
                }
                Theme.rule.frame(height: 1)
                if recent.isEmpty { Text("No buckets in this range").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).padding(.vertical, 12) }
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
            ("systemLoad", "System", "systemLoadW"),
            ("wallPower", "Wall", "wallPowerW")
        ]
        if batteryPresent {
            defs.append(("batteryPower", "Battery", "batteryPowerW"))
        } else {
            defs.append(("adapterLoss", "Conversion loss", "adapterLossW"))
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
                label: "System",
                points: points.map { pt in
                    NativeChartPoint(x: pt["mean"]["date"].double, y: NativeHardwareDisplayPolicies.number(pt["systemEnergyWh"]))
                }
            ),
            NativeChartSeries(
                id: "wallWh",
                label: "Wall",
                points: points.map { pt in
                    NativeChartPoint(x: pt["mean"]["date"].double, y: NativeHardwareDisplayPolicies.number(pt["wallEnergyWh"]))
                }
            )
        ]
    }


    // MARK: - Sensors

    private var sensorsTab: some View {
        let peaks = sessionStats["sensorPeaks"], avgs = sessionStats["sensorAverages"]
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                T3Field(placeholder: "Filter \(snapshot["sensors"].array.count) channels by key or name", text: $query, leadingIcon: "search").frame(maxWidth: 320)
                NativeMenuSelect(title: "Sensor category", selection: $group,
                                 options: ["All", "Favorites", "Telemetry", "System Power", "Processor & SoC", "Rails & Ports", "Power (W)", "Voltage (V)", "Current (A)"].map { ($0, $0) }, width: 160)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 22, height: 1)
                    Text("Channel").frame(maxWidth: .infinity, alignment: .leading)
                    if contentWidth >= 760 { Text("Category").frame(width: 130, alignment: .leading) }
                    Text("Now").frame(width: 90, alignment: .trailing)
                    Text("Mean").frame(width: 84, alignment: .trailing)
                    Text("Peak").frame(width: 84, alignment: .trailing)
                }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 30)
                ForEach(sensorRows, id: \.self["id"]) { sensor in
                    let id = sensor["id"].string, unit = sensor["unit"].string, favorite = favorites.contains(id)
                    Theme.rule.frame(height: 1)
                    HStack(spacing: 12) {
                        Button {
                            if !favorites.insert(id).inserted { favorites.remove(id) }
                            if !runtime.paths.readOnly { UserDefaults.standard.set(Array(favorites).sorted(), forKey: "uniapi.energy.favorites") }
                        } label: {
                            NativeIcon("star", size: 13).foregroundStyle(favorite ? Theme.accent : Theme.faint).frame(width: 22, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).pointingHand()
                            .accessibilityLabel("\(favorite ? "Unfavorite" : "Favorite") \(NativeHardwareDisplayPolicies.energySensorName(id))")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(NativeHardwareDisplayPolicies.energySensorName(id)).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(id).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if contentWidth >= 760 {
                            Text(NativeHardwareDisplayPolicies.energySensorGroup(id, unit: unit)).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 130, alignment: .leading)
                        }
                        NativeNumberText(text: formatSensorValue(number(sensor["value"]), unit: unit), font: Theme.num(Theme.textSm, weight: .medium)).frame(width: 90, alignment: .trailing)
                        Text(formatSensorValue(number(avgs[id]), unit: unit)).font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.dim).frame(width: 84, alignment: .trailing)
                        Text(formatSensorValue(number(peaks[id]), unit: unit)).font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 84, alignment: .trailing)
                    }.frame(height: 36)
                }
                Theme.rule.frame(height: 1)
                if sensorRows.isEmpty { Text("No match").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).padding(.leading, 34).padding(.vertical, 12) }
            }
        }
    }

    private func formatSensorValue(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f %@", value, unit)
    }

    // MARK: - Preferences

    private var preferencesTab: some View {
        let storage = history["storage"]
        return NativeSheet {
            NativeSection("Sidebar") {
                SettingRow(title: "Reading beside Energy") {
                    NativeMenuSelect(title: "Sidebar badge metric",
                                     selection: Binding(get: { prefs["badgeMetric"].string.isEmpty ? "systemLoad" : prefs["badgeMetric"].string },
                                                        set: { value in Task { await operation("preferences", ["badgeMetric": .string(value)]) } }),
                                     options: [("systemLoad", "System load"), ("wallPower", "Wall power"), ("batteryNet", "Battery net flow"), ("none", "Hidden")], width: 170)
                }
            }
            NativeSection("Cost") {
                SettingRow(title: "Electricity price", desc: "Per kWh. Used for every cost on this page.") {
                    HStack(spacing: 8) {
                        T3Field(placeholder: "$", text: $currencyText).frame(width: 56).accessibilityLabel("Currency")
                        T3Field(placeholder: "0.30", text: $rateText).frame(width: 84).accessibilityLabel("Price per kWh")
                        Button("Save") {
                            if let rate = Double(rateText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")) {
                                Task { await operation("preferences", ["ratePerKwh": .number(rate), "currency": .string(currencyText)]) }
                            } else { error = "Enter a number for the price per kWh" }
                        }.buttonStyle(T3Button(.outline)).disabled(pending || runtime.paths.readOnly)
                    }
                }
            }
            NativeSection("History") {
                SettingRow(title: "Stored", desc: "10-second samples for \(storage["rawDays"].isNull ? 7 : storage["rawDays"].int) days, minute summaries for \(storage["minuteDays"].isNull ? 90 : storage["minuteDays"].int), hourly for \(storage["hourlyDays"].isNull ? 365 : storage["hourlyDays"].int). Daily totals are kept.") {
                    HStack(spacing: 8) {
                        Text(history.isNull ? "—" : ByteCountFormatter.string(fromByteCount: Int64(storage["bytes"].double), countStyle: .file)).font(Theme.num(Theme.textSm, weight: .medium))
                        Button("Export CSV", nativeIcon: "download") { exportHistory() }.buttonStyle(T3Button(.outline)).disabled(history["points"].array.isEmpty)
                    }
                }
            }
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
