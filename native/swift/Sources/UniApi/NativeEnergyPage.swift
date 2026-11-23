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
    @State private var reads = NativePageReadScope()
    @State private var preferencesRestored = false
    @State private var state: JSONValue = .null
    @State private var historySelection = NativeFanHistorySelection()
    @AppStorage("uniapi.energy.tab") private var tab = "flow"
    @Environment(\.nativeHostTabs) private var host
    @AppStorage("uniapi.energy.range") private var range = "24h"
    @AppStorage("uniapi.energy.statistic") private var statistic = "mean"
    @AppStorage("uniapi.energy.chart") private var chartMeasure = "power"
    @State private var bucket: Double?
    @State private var sensor: String?
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

    private var supported: Bool { state["supported"].bool }
    private var margin: CGFloat { density.pageMargin }
    private static let categories = ["All", "Favorites", "Telemetry", "System Power", "Processor & SoC", "Rails & Ports", "Power (W)", "Voltage (V)", "Current (A)"]

    var body: some View {
        NativePage(title: "Energy", maxWidth: .infinity, readiness: pageReadiness, scrolls: false, tabs: {
            if supported {
                NativeTabs(options: [("flow", "Now"), ("history", "History"), ("sensors", "Sensors"), ("settings", "Preferences")], selection: tab) { tab = $0; host?.select($0) }
                    .nativeHostedView(Self.tabs) { tab = $0 }
            }
        }, actions: {
            if supported, tab == "sensors" {
                T3Field(placeholder: "Filter channels", text: $query, width: 200, leadingIcon: "search")
                NativeMenuSelect(title: "Sensor category", selection: $group, options: Self.categories.map { ($0, $0) }, width: 150)
            }
            if supported, ["flow", "history"].contains(tab) {
                NativeMenuSelect(title: "Range", selection: $range, options: [("30m", "30 minutes"), ("1h", "1 hour"), ("6h", "6 hours"), ("24h", "24 hours"), ("7d", "7 days"), ("30d", "30 days"), ("all", "All time"), ("custom", "Custom")], width: 120)
            }
            T3IconButton(system: "refresh-cw", help: "Refresh") { Task { await reload(force: true); if ["flow", "history", "settings"].contains(tab) { await loadHistory() } } }
        }) {
            GeometryReader { geometry in content(width: geometry.size.width) }
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
        .onChange(of: tab) { _, _ in bucket = nil; sensor = nil }
        .onChange(of: historyScope) { _, _ in bucket = nil }
        .nativePageActivity(reads: reads)
    }

    @ViewBuilder private var notices: some View {
        if let statusReadError { statusError(statusReadError) }
        if let error { NativeError(message: error) }
        if !state["error"].string.isEmpty { statusError(state["error"].string) }
    }

    @ViewBuilder private func content(width: CGFloat) -> some View {
        if state.isNull || !supported || tab == "settings" {
            NativePane(maxWidth: 1280) {
                if tab != "settings" || !supported { notices }
                if state.isNull {
                    if error == nil && statusReadError == nil { ShimmerText(text: "Loading…") }
                } else if !supported {
                    NativeEmptyState(title: "No power readings", detail: "This Mac does not expose its power controller.", icon: "zap")
                } else {
                    preferencesTab
                }
            }
        } else {
            let mainWidth = NativeBoard<EmptyView, EmptyView, EmptyView>.mainWidth(width)
            NativeBoard(width: width, onMove: tab == "flow" ? nil : { move($0) }) {
                VStack(alignment: .leading, spacing: 12) { notices; if let historyError, tab != "sensors" { NativeError(message: historyError) } }
                    .padding(.horizontal, margin).padding(.top, error == nil && statusReadError == nil && state["error"].string.isEmpty && historyError == nil ? 0 : 16)
                switch tab {
                case "history": historyMain(mainWidth)
                case "sensors": sensorsMain(mainWidth)
                default: flowMain(mainWidth)
                }
            } pane: {
                VStack(alignment: .leading, spacing: 0) {
                    if tab == "sensors" { sensorPane }
                    else if tab == "history", let point = selectedBucket { bucketPane(point) }
                    else { rangePane }
                }
            } actions: { paneActions }
            .onExitCommand { bucket = nil; sensor = nil }
        }
    }

    private func watts(_ value: Double?) -> String { NativeHardwareDisplayPolicies.formatWatts(value) }
    private func columnHeader(_ title: String, _ width: CGFloat? = nil) -> some View {
        Text(title).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).lineLimit(1)
            .frame(width: width, alignment: .trailing).frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
    private func split(_ text: String) -> (String, String) {
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    // MARK: - Now

    private func flowMain(_ mainWidth: CGFloat) -> some View {
        let wallW = number(snapshot["wallPowerW"]), sysLoadW = number(snapshot["systemLoadW"]), eff = number(snapshot["efficiencyPercent"])
        let hourly = ((wallW ?? sysLoadW ?? 0) / 1000.0) * ratePerKwh
        var facts = [NativeHeroFact(label: "Wall", value: watts(wallW), help: "Drawn from the outlet, before the adapter's conversion loss")]
        if let eff { facts.append(NativeHeroFact(label: "Efficiency", value: String(format: "%.1f%%", eff), help: "Share of wall power that reaches the Mac")) }
        if batteryPresent { facts.append(NativeHeroFact(label: "Battery", value: String(format: "%.0f%%", battery["percent"].double))) }
        facts.append(NativeHeroFact(label: "Per hour", value: String(format: "%@%.3f", currency, hourly), help: "At the current draw and your electricity price"))
        return VStack(alignment: .leading, spacing: 0) {
            NativeHero(value: sysLoadW.map { String(format: "%.1f", $0) } ?? "—", numeric: sysLoadW, unit: "W", facts: facts, maxFacts: mainWidth >= 760 ? 4 : mainWidth >= 560 ? 2 : 0) {
                Text("System load")
            } trailing: { statisticPicker }
                .padding(.horizontal, margin).padding(.top, 20)
            flowSplit.padding(.horizontal, margin).padding(.top, 20)
            if range == "custom" { customRange.padding(.horizontal, margin).padding(.top, 16) }
            NativeLineChart(series: powerSeries(kind: statistic), height: 200, showPoints: false, includeZero: true, xFormat: { formatAxisDate($0) }, yFormat: { String(format: "%.1f W", $0) })
                .padding(.horizontal, margin).padding(.top, 20)
            rails(mainWidth).padding(.top, 20)
        }
    }

    /// Where the power comes from and where it goes, on one scale.
    private var flowSplit: some View {
        let wall = max(0, number(snapshot["wallPowerW"]) ?? 0), batt = number(snapshot["batteryPowerW"]) ?? 0
        let system = max(0, number(snapshot["systemLoadW"]) ?? 0), loss = max(0, number(snapshot["adapterLossW"]) ?? 0)
        var from: [NativeSplitPart] = [], to = [NativeSplitPart(id: "system", label: "System", amount: system, color: Theme.ink)]
        if wall > 0.05 { from.append(NativeSplitPart(id: "wall", label: "Wall", amount: wall, color: Theme.ink)) }
        if batt < -0.05 { from.append(NativeSplitPart(id: "battery", label: "Battery", amount: -batt, color: Theme.accent)) }
        if batt > 0.05 { to.append(NativeSplitPart(id: "charge", label: "Battery", amount: batt, color: Theme.accent)) }
        if loss > 0.01 { to.append(NativeSplitPart(id: "loss", label: "Conversion loss", amount: loss, color: Theme.faint)) }
        let total = max(from.reduce(0) { $0 + $1.amount }, to.reduce(0) { $0 + $1.amount })
        return VStack(alignment: .leading, spacing: 14) {
            if !from.isEmpty { splitRow("From", from, total, note: sourceLabel) }
            splitRow("To", to, total)
        }
    }
    private func splitRow(_ title: String, _ parts: [NativeSplitPart], _ total: Double, note: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                Text(title).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(width: 34, alignment: .leading)
                ForEach(parts) { part in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1).fill(part.color).frame(width: 3, height: 12).accessibilityHidden(true)
                        Text(part.label).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim).lineLimit(1)
                        Text(watts(part.amount)).font(Theme.num(Theme.textXs, weight: .medium)).lineLimit(1)
                        if total > 0, parts.count > 1 { Text(String(format: "%.0f%%", part.amount * 100 / total)).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted) }
                    }.fixedSize().accessibilityElement(children: .combine)
                }
                Spacer(minLength: 0)
                if !note.isEmpty { Text(note).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            NativeSplitTicks(parts: parts, total: total)
        }
    }

    private func rails(_ mainWidth: CGFloat) -> some View {
        let subsystems = snapshot["subsystems"].array.sorted { $0["watts"].double > $1["watts"].double }
        let load = max(0.1, snapshot["systemLoadW"].double)
        let top = max(0.1, subsystems.first?["watts"].double ?? load)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) { columnHeader("Rail"); columnHeader("Share", 48); columnHeader("Now", 72) }.frame(height: 30).padding(.horizontal, margin)
            ForEach(Array(subsystems.enumerated()), id: \.offset) { _, item in
                let value = max(0, item["watts"].double)
                HStack(spacing: 12) {
                    Text(item["label"].string).font(Theme.ui(Theme.textSm)).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).help(item["group"].string)
                    if mainWidth >= 620 { NativeTickMeter(fraction: min(1, value / top), color: Theme.ink, height: 8).frame(width: 140) }
                    Text(String(format: "%.0f%%", min(1, value / load) * 100)).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 48, alignment: .trailing)
                    Text(String(format: "%.2f W", value)).font(Theme.num(Theme.textXs, weight: .medium)).frame(width: 72, alignment: .trailing)
                }
                .frame(height: 36).padding(.horizontal, margin)
                .overlay(alignment: .top) { Theme.rule.frame(height: 1).padding(.horizontal, margin) }
                .accessibilityElement(children: .combine)
            }
            Theme.rule.frame(height: 1).padding(.horizontal, margin)
            if subsystems.isEmpty { Text("No rail readings").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).padding(.horizontal, margin).padding(.vertical, 12) }
        }
    }

    // MARK: - History

    private var recentBuckets: [JSONValue] { Array(history["points"].array.suffix(60).reversed()) }
    private var selectedBucket: JSONValue? { bucket.flatMap { date in history["points"].array.first { $0["mean"]["date"].double == date } } }

    private func historyMain(_ mainWidth: CGFloat) -> some View {
        let summary = history["summary"], points = history["points"].array, recent = recentBuckets
        let used = split(wh(summary["systemEnergyWh"]))
        let facts = [NativeHeroFact(label: "At the wall", value: wh(summary["wallEnergyWh"])),
                     NativeHeroFact(label: "Cost", value: cost(summary["wallEnergyWh"])),
                     NativeHeroFact(label: "Average", value: watts(number(summary["avgSystemLoadW"]))),
                     NativeHeroFact(label: "Peak", value: watts(number(summary["peakSystemLoadW"])))]
        let wide = mainWidth >= 640
        return VStack(alignment: .leading, spacing: 0) {
            NativeHero(value: used.0, numeric: number(summary["systemEnergyWh"]), unit: used.1, facts: facts, maxFacts: mainWidth >= 860 ? 4 : mainWidth >= 700 ? 2 : 0) {
                Text("Energy used")
            } trailing: {
                HStack(spacing: 8) {
                    if chartMeasure == "power" { statisticPicker }
                    T3Segmented(options: [("power", "Power"), ("energy", "Energy")], selection: chartMeasure) { chartMeasure = $0 }
                }
            }
                .padding(.horizontal, margin).padding(.top, 20)
            if range == "custom" { customRange.padding(.horizontal, margin).padding(.top, 16) }
            Group {
                if chartMeasure == "energy" {
                    NativeLineChart(series: energyBucketSeries, height: 220, showPoints: points.count <= 48, includeZero: true, xFormat: { formatAxisDate($0) }, yFormat: { String(format: "%.2f Wh", $0) })
                } else {
                    NativeLineChart(series: powerSeries(kind: statistic), height: 220, showPoints: points.count <= 48, includeZero: true, xFormat: { formatAxisDate($0) }, yFormat: { String(format: "%.1f W", $0) })
                }
            }.padding(.horizontal, margin).padding(.top, 20)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    columnHeader("Time"); columnHeader("Average", 82); columnHeader("Peak", 82)
                    if wide { columnHeader("Wall", 82) }
                    columnHeader("Energy", 92)
                    if wide { columnHeader("Cost", 76) }
                }.frame(height: 30).padding(.horizontal, margin)
                ForEach(Array(recent.enumerated()), id: \.offset) { _, pt in
                    let date = pt["mean"]["date"].double
                    NativeBoardRow(selected: bucket == date, margin: margin, height: 32) { bucket = bucket == date ? nil : date } content: {
                        HStack(spacing: 10) {
                            Text(Date(timeIntervalSince1970: date / 1000).formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                                .foregroundStyle(Theme.dim).lineLimit(1).fixedSize().frame(maxWidth: .infinity, alignment: .leading)
                            Text(watts(number(pt["mean"]["systemLoadW"]))).fontWeight(.medium).frame(width: 82, alignment: .trailing)
                            Text(watts(number(pt["max"]["systemLoadW"]))).foregroundStyle(Theme.dim).frame(width: 82, alignment: .trailing)
                            if wide { Text(watts(number(pt["mean"]["wallPowerW"]))).foregroundStyle(Theme.dim).frame(width: 82, alignment: .trailing) }
                            Text(wh(pt["systemEnergyWh"])).fontWeight(.medium).frame(width: 92, alignment: .trailing)
                            if wide { Text(cost(pt["wallEnergyWh"])).foregroundStyle(Theme.muted).frame(width: 76, alignment: .trailing) }
                        }.font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.ink)
                    }
                }
                Theme.rule.frame(height: 1).padding(.horizontal, margin)
                Text(recent.isEmpty ? "No buckets in this range" : points.count > recent.count ? "Latest \(recent.count) of \(points.count) buckets" : "\(points.count) buckets")
                    .font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint).padding(.horizontal, margin).padding(.top, 10)
            }.padding(.top, 20)
        }
    }

    private func move(_ step: Int) {
        guard step != 0 else { return }
        if tab == "history" {
            let dates = recentBuckets.map { $0["mean"]["date"].double }
            guard !dates.isEmpty else { return }
            let index = bucket.flatMap { dates.firstIndex(of: $0) }
            bucket = dates[min(dates.count - 1, max(0, (index ?? (step > 0 ? -1 : dates.count)) + step))]
        } else if tab == "sensors" {
            let ids = sensorRows.map { $0["id"].string }
            guard !ids.isEmpty else { return }
            let index = sensor.flatMap { ids.firstIndex(of: $0) }
            sensor = ids[min(ids.count - 1, max(0, (index ?? (step > 0 ? -1 : ids.count)) + step))]
        }
    }

    // MARK: - Sensors

    private func sensorsMain(_ mainWidth: CGFloat) -> some View {
        let peaks = sessionStats["sensorPeaks"], avgs = sessionStats["sensorAverages"], rows = sensorRows
        let wide = mainWidth >= 700
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                columnHeader("Channel")
                if wide { Text("Category").font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(width: 130, alignment: .leading) }
                columnHeader("Now", 90); columnHeader("Mean", 84); columnHeader("Peak", 84)
            }.frame(height: 36).padding(.horizontal, margin)
            ForEach(rows, id: \.self["id"]) { row in
                let id = row["id"].string, unit = row["unit"].string
                NativeBoardRow(selected: sensor == id, margin: margin) { sensor = sensor == id ? nil : id } content: {
                    HStack(spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(NativeHardwareDisplayPolicies.energySensorName(id)).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(id).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                            if favorites.contains(id) { NativeIcon("star", size: 11).foregroundStyle(Theme.accent).accessibilityLabel("Favorite") }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if wide {
                            Text(NativeHardwareDisplayPolicies.energySensorGroup(id, unit: unit)).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 130, alignment: .leading)
                        }
                        NativeNumberText(text: formatSensorValue(number(row["value"]), unit: unit), font: Theme.num(Theme.textSm, weight: .medium)).frame(width: 90, alignment: .trailing)
                        Text(formatSensorValue(number(avgs[id]), unit: unit)).font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.dim).frame(width: 84, alignment: .trailing)
                        Text(formatSensorValue(number(peaks[id]), unit: unit)).font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 84, alignment: .trailing)
                    }
                }
            }
            Theme.rule.frame(height: 1).padding(.horizontal, margin)
            if rows.isEmpty { Text("No match").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).padding(.horizontal, margin).padding(.vertical, 12) }
        }
    }

    private func toggleFavorite(_ id: String) {
        if !favorites.insert(id).inserted { favorites.remove(id) }
        if !runtime.paths.readOnly { UserDefaults.standard.set(Array(favorites).sorted(), forKey: "uniapi.energy.favorites") }
    }

    // MARK: - Pane

    private func paneHeader(_ title: String, _ caption: String, mono: Bool = false, clear: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(Theme.textSm, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if !caption.isEmpty { Text(caption).font(mono ? Theme.mono(11) : Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if let clear { T3IconButton(system: "x", help: "Clear the selection", size: 13, action: clear) }
        }.padding(.horizontal, 16).padding(.vertical, 14).frame(minHeight: 56, alignment: .top)
    }

    /// What was used in the range, since boot and in total.
    @ViewBuilder private var rangePane: some View {
        let summary = history["summary"]
        let short = ["30m": "30 min", "1h": "1 hour", "6h": "6 hours", "24h": "24 hours", "7d": "7 days", "30d": "30 days", "all": "Recorded", "custom": "Custom"][historyRange] ?? historyRange
        let rows: [(String, String, String, String)] = [
            ("System", wh(summary["systemEnergyWh"]), wh(bootStats["systemEnergyWh"]), wh(allTimeStats["systemEnergyWh"])),
            ("Wall", wh(summary["wallEnergyWh"]), wh(bootStats["wallEnergyWh"]), wh(allTimeStats["wallEnergyWh"])),
            ("Loss", wh(summary["adapterLossWh"]), wh(bootStats["adapterLossWh"]), wh(allTimeStats["adapterLossWh"])),
            ("Cost", cost(summary["wallEnergyWh"]), cost(bootStats["wallEnergyWh"]), cost(allTimeStats["wallEnergyWh"]))
        ]
        let basisW = number(bootStats["avgSystemPowerInW"]) ?? number(snapshot["wallPowerW"]) ?? number(snapshot["systemLoadW"]) ?? 0
        let monthlyWh = basisW * 24.0 * 30.0
        paneHeader(rangeDisplayName, history.isNull ? "" : "\(history["points"].array.count) buckets")
        NativePaneSection(title: "Used") {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("").frame(maxWidth: .infinity, alignment: .leading)
                    ForEach([short, "Boot", "All time"], id: \.self) { Text($0).lineLimit(1).frame(width: 70, alignment: .trailing) }
                }.font(Theme.ui(11)).foregroundStyle(Theme.muted).padding(.bottom, 6)
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 6) {
                        Text(row.0).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(Array([row.1, row.2, row.3].enumerated()), id: \.offset) { index, value in
                            Text(value).font(Theme.num(11, weight: index == 0 ? .medium : .regular)).foregroundStyle(value == "—" ? Theme.faint : index == 0 ? Theme.ink : Theme.dim)
                                .lineLimit(1).minimumScaleFactor(0.8).frame(width: 70, alignment: .trailing)
                        }
                    }.frame(height: 24).accessibilityElement(children: .combine)
                }
            }
        }
        NativePaneSection(title: "Load") {
            NativePaneFact(label: "Average", value: watts(number(summary["avgSystemLoadW"])))
            NativePaneFact(label: "95th percentile", value: watts(number(summary["p95SystemLoadW"])))
            NativePaneFact(label: "Peak", value: watts(number(summary["peakSystemLoadW"])))
            NativePaneFact(label: "Minimum", value: watts(number(summary["minSystemLoadW"])))
            if let boot = number(bootStats["avgSystemLoadW"]) { NativePaneFact(label: "Average since boot", value: watts(boot)) }
        }
        NativePaneSection(title: "At this rate") {
            NativePaneFact(label: "Per month", value: String(format: "%.2f kWh", monthlyWh / 1000.0))
            NativePaneFact(label: "Cost per month", value: NativeHardwareDisplayPolicies.formatCost(wh: monthlyWh, ratePerKwh: ratePerKwh, currency: currency))
            NativePaneFact(label: "Price", value: String(format: "%@%.2f per kWh", currency, ratePerKwh))
        }
        if batteryPresent {
            NativePaneSection(title: "Battery") {
                NativePaneFact(label: "Charge", value: String(format: "%.0f%% · %.1f of %.1f Wh", battery["percent"].double, battery["remainingWh"].double, battery["maxCapacityWh"].double))
                NativePaneFact(label: "Flow", value: NativeHardwareDisplayPolicies.formatWatts(number(snapshot["batteryPowerW"]), signed: true))
                if battery["designCapacityWh"].double > 0 { NativePaneFact(label: "Capacity", value: String(format: "%.0f%% of design", battery["maxCapacityWh"].double * 100 / battery["designCapacityWh"].double)) }
                if !battery["cycleCount"].isNull { NativePaneFact(label: "Cycles", value: "\(battery["cycleCount"].int)") }
                if let temperature = number(battery["temperatureC"]) { NativePaneFact(label: "Temperature", value: String(format: "%.1f °C", temperature)) }
                if !battery["timeRemainingMinutes"].isNull { NativePaneFact(label: battery["charging"].bool ? "Until full" : "Remaining", value: "\(battery["timeRemainingMinutes"].int / 60) h \(battery["timeRemainingMinutes"].int % 60) min") }
            }
        }
        NativePaneSection(title: "Supply") {
            NativePaneFact(label: "Input", value: String(format: "%.2f V · %.2f A", snapshot["voltageInV"].double, snapshot["currentInA"].double))
            if let budget = number(snapshot["powerBudgetW"]), budget > 0 { NativePaneFact(label: "Budget", value: String(format: "%.0f W", budget)) }
            if !battery["adapterDescription"].string.isEmpty { NativePaneFact(label: "Adapter", value: battery["adapterDescription"].string) }
            if let loss = number(snapshot["adapterLossW"]) { NativePaneFact(label: "Conversion loss", value: String(format: "%.2f W", loss)) }
        }
    }

    @ViewBuilder private func bucketPane(_ point: JSONValue) -> some View {
        let mean = point["mean"], high = point["max"], low = point["min"]
        let minutes = point["resolutionMs"].double / 60000
        paneHeader(Date(timeIntervalSince1970: mean["date"].double / 1000).formatted(date: .abbreviated, time: .shortened),
                   minutes >= 60 ? String(format: "%.0f-hour bucket", minutes / 60) : minutes >= 1 ? String(format: "%.0f-minute bucket", minutes) : "", clear: { bucket = nil })
        NativePaneSection(title: "System load") {
            NativePaneFact(label: "Average", value: watts(number(mean["systemLoadW"])))
            NativePaneFact(label: "Peak", value: watts(number(high["systemLoadW"])))
            NativePaneFact(label: "Minimum", value: watts(number(low["systemLoadW"])))
        }
        NativePaneSection(title: "Supply") {
            NativePaneFact(label: "Wall, average", value: watts(number(mean["wallPowerW"])))
            NativePaneFact(label: "Wall, peak", value: watts(number(high["wallPowerW"])))
            NativePaneFact(label: "Conversion loss", value: watts(number(mean["adapterLossW"])))
            if batteryPresent { NativePaneFact(label: "Battery", value: NativeHardwareDisplayPolicies.formatWatts(number(mean["batteryPowerW"]), signed: true)) }
        }
        NativePaneSection(title: "Energy") {
            NativePaneFact(label: "System", value: wh(point["systemEnergyWh"]))
            NativePaneFact(label: "Wall", value: wh(point["wallEnergyWh"]))
            NativePaneFact(label: "Cost", value: cost(point["wallEnergyWh"]))
        }
        let rails = mean["subsystems"].array.sorted { $0["watts"].double > $1["watts"].double }.prefix(6)
        if !rails.isEmpty {
            NativePaneSection(title: "Rails") {
                ForEach(Array(rails.enumerated()), id: \.offset) { _, rail in
                    NativePaneFact(label: rail["label"].string, value: String(format: "%.2f W", rail["watts"].double))
                }
            }
        }
    }

    @ViewBuilder private var sensorPane: some View {
        let all = snapshot["sensors"].array
        if let id = sensor, let row = all.first(where: { $0["id"].string == id }) {
            let unit = row["unit"].string, value = number(row["value"])
            paneHeader(NativeHardwareDisplayPolicies.energySensorName(id), id, mono: true, clear: { sensor = nil })
            NativePaneSection(title: "Reading") {
                NativePaneFact(label: "Now", value: formatSensorValue(value, unit: unit))
                NativePaneFact(label: "Mean", value: formatSensorValue(number(sessionStats["sensorAverages"][id]), unit: unit))
                NativePaneFact(label: "Peak", value: formatSensorValue(number(sessionStats["sensorPeaks"][id]), unit: unit))
                if unit == "W", let value, snapshot["systemLoadW"].double > 0 {
                    NativePaneFact(label: "Of system load", value: String(format: "%.0f%%", min(1, max(0, value / snapshot["systemLoadW"].double)) * 100))
                }
            }
            NativePaneSection(title: "Channel") {
                NativePaneFact(label: "Category", value: NativeHardwareDisplayPolicies.energySensorGroup(id, unit: unit))
                NativePaneFact(label: "Key", value: id, mono: true)
            }
        } else {
            let pinned = all.filter { favorites.contains($0["id"].string) }
            paneHeader("\(all.count) channels", "Mean and peak are measured since UniApi started.")
            NativePaneSection(title: "Favorites") {
                if pinned.isEmpty {
                    Text("Select a channel to mark it as a favorite.").font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(pinned, id: \.self["id"]) { row in
                    NativePaneFact(label: NativeHardwareDisplayPolicies.energySensorName(row["id"].string), value: formatSensorValue(number(row["value"]), unit: row["unit"].string))
                }
            }
            NativePaneSection(title: "Units") {
                ForEach([("W", "Power"), ("V", "Voltage"), ("A", "Current")], id: \.0) { unit, name in
                    NativePaneFact(label: name, value: "\(all.filter { $0["unit"].string == unit }.count)")
                }
            }
        }
    }

    @ViewBuilder private var paneActions: some View {
        HStack(spacing: 8) {
            if tab == "sensors" {
                if let id = sensor {
                    Button(favorites.contains(id) ? "Remove favorite" : "Favorite", nativeIcon: "star") { toggleFavorite(id) }.buttonStyle(T3Button(.outline))
                }
            } else {
                Button("Export CSV", nativeIcon: "download") { exportHistory() }.buttonStyle(T3Button(.outline)).disabled(history["points"].array.isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).frame(height: tab == "sensors" && sensor == nil ? 0 : 52).clipped()
        .overlay(alignment: .top) { Theme.rule.frame(height: tab == "sensors" && sensor == nil ? 0 : 1) }
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

    private func formatAxisDate(_ ms: Double) -> String {
        let d = Date(timeIntervalSince1970: ms / 1000)
        if ["30m", "1h", "6h", "24h"].contains(historyRange) {
            return d.formatted(date: .omitted, time: .shortened)
        }
        if historyRange == "7d" { return d.formatted(.dateTime.weekday(.abbreviated).hour()) }
        return d.formatted(.dateTime.day().month(.abbreviated))
    }

    private func powerSeries(kind: String) -> [NativeChartSeries] {
        let samples = NativeEnergyHistory.discontinuousSamples(history["points"].array, kind: kind)
        // The same colours as the From and To bars above the chart.
        var defs: [(id: String, label: String, key: String, color: Color)] = [
            ("systemLoad", "System", "systemLoadW", Theme.ink),
            ("wallPower", "Wall", "wallPowerW", Theme.muted)
        ]
        if batteryPresent {
            defs.append(("batteryPower", "Battery", "batteryPowerW", Theme.accent))
        } else {
            defs.append(("adapterLoss", "Conversion loss", "adapterLossW", Theme.faint))
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
                label: "System",
                points: points.map { pt in
                    NativeChartPoint(x: pt["mean"]["date"].double, y: NativeHardwareDisplayPolicies.number(pt["systemEnergyWh"]))
                },
                color: Theme.ink
            ),
            NativeChartSeries(
                id: "wallWh",
                label: "Wall",
                points: points.map { pt in
                    NativeChartPoint(x: pt["mean"]["date"].double, y: NativeHardwareDisplayPolicies.number(pt["wallEnergyWh"]))
                },
                color: Theme.muted
            )
        ]
    }


    private func formatSensorValue(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f %@", value, unit)
    }

    // MARK: - Preferences

    private var preferencesTab: some View {
        let storage = history["storage"]
        return NativeSheet {
            if let error { NativeError(message: error) }
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
