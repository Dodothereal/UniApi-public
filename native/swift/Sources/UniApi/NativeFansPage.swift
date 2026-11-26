import SwiftUI
import Charts
import AppKit
import UniApiCore
import UniApiPresentation

struct NativeFansPage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var motionVisible
    @Environment(\.nativePageActive) private var pageActive
    private static let tabs = ["control", "sensors", "timeline", "curve", "settings"]
    @State private var contentWidth: CGFloat = 882
    @State private var reads = NativePageReadScope()
    @State private var preferencesRestored = false
    @State private var state: JSONValue = .null
    @State private var historySelection = NativeFanHistorySelection()
    @AppStorage("uniapi.fans.tab") private var tab = "control"
    @State private var query = ""
    @State private var group = "All"
    @State private var favorites = Set<String>()
    @State private var peaks: [String: Double] = [:]
    @AppStorage("uniapi.fans.duration") private var duration = NativeHardwareDisplayPolicies.defaultFanDuration
    @AppStorage("uniapi.fans.boost") private var boost = 300
    @AppStorage("uniapi.fans.range") private var range = "30m"
    @AppStorage("uniapi.fans.statistic") private var statistic = "mean"
    @State private var from = Date().addingTimeInterval(-86400)
    @State private var through = Date()
    @State private var curve = NativeHardwareDisplayPolicies.defaultFanCurve
    @State private var error: String?
    // This UI read marker recovers independently so status updates cannot erase command failures.
    @State private var statusReadError: String?
    @State private var pending = false
    @State private var draggingPoint: Int?
    @State private var showCurveSliders = false
    @FocusState private var focusedCurvePoint: Int?
    private var snapshot: JSONValue { state["snapshot"] }
    private var historyRange: String { tab == "timeline" ? range : "30m" }
    private var historyScope: String { historyRange == "custom" ? "custom:\(from.timeIntervalSince1970):\(through.timeIntervalSince1970)" : historyRange }
    private var history: JSONValue { historySelection.value(for: historyScope) }
    private var historyError: String? { historySelection.error(for: historyScope) }
    private var enabled: Bool { !runtime.paths.readOnly && state["enabled"].bool && !state["busy"].bool && !pending && !snapshot.isNull && state["control"]["mode"].string != "unknown" }
    private var unit: String { state["preferences"]["unit"].string == "f" ? "f" : "c" }
    private var governing: Double? { [temperature("CPU"), temperature("GPU")].compactMap { $0 }.max() }
    private var currentDurationCommand: JSONObject? { NativeHardwareDisplayPolicies.currentFanCommand(state: state, duration: duration, curve: curve) }
    private var sensorRows: [JSONValue] { NativeHardwareDisplayPolicies.sensorRows(snapshot["sensors"].array, favorites: favorites, group: group, query: query) }
    private var pageReadiness: NativePageReadiness {
        if error != nil || statusReadError != nil || !state["error"].string.isEmpty { return .failed }
        if state.isNull { return .pending }
        if !state["supported"].bool || !state["installed"].bool { return .ready }
        let needsHistory = ["control", "timeline", "settings"].contains(tab)
        if needsHistory && historyError != nil { return .failed }
        if snapshot.isNull || needsHistory && history.isNull { return .pending }
        return .ready
    }
    var body: some View {
        GeometryReader { viewport in
        NativePage(title: "Fan Control", maxWidth: 1280, readiness: pageReadiness, tabs: {
            if state["supported"].bool, state["installed"].bool { NativeTabs(options: [("control", "Control"), ("sensors", "Sensors"), ("timeline", "Timeline"), ("curve", "Curve"), ("settings", "Preferences")], selection: tab) { tab = $0 } }
        }, actions: {
            if tab == "timeline" { T3IconButton(system: "download", help: "Export CSV") { exportHistory() }.disabled(history["points"].array.isEmpty) }
            T3IconButton(system: "refresh-cw", help: "Refresh") { Task { await reload(); if ["control", "timeline", "settings"].contains(tab) { await loadHistory() } } }
            if tab == "curve" { applyCurveButton }
            if tab != "control", !state.isNull, state["supported"].bool, state["installed"].bool, !state["enabled"].bool {
                Button(state["daemon"]["installed"].bool ? "Reconnect helper" : "Install helper") { Task { await operation("install") } }
                    .buttonStyle(T3Button(tab == "curve" ? .ghost : .primary)).disabled(pending || snapshot.isNull || runtime.paths.readOnly)
            }
        }) {
            if let statusReadError { statusError(statusReadError) }
            if let error { NativeError(message: error) }
            if !state["error"].string.isEmpty { statusError(state["error"].string) }
            if state.isNull {
                if error == nil && statusReadError == nil { ShimmerText(text: "Loading…") }
            } else if !state["supported"].bool {
                NativeEmptyState(title: "No fans", detail: "This Mac does not expose a fan controller.", icon: "fan")
            } else if !state["installed"].bool {
                NativeEmptyState(title: "Fan reader not installed", detail: "Rebuild the UniApi app to install it.", icon: "fan")
            } else {
                switch tab { case "sensors": sensors; case "timeline": timeline; case "curve": curveStudio; case "settings": preferences; default: controls }
            }
        }
        .onChange(of: max(0, min(1280, viewport.size.width) - 2 * density.pageMargin), initial: true) { _, width in contentWidth = width }
        }
        .nativePageTask {
            if !preferencesRestored {
                if let saved = UserDefaults.standard.array(forKey: "uniapi.fans.favorites") as? [String] { favorites = Set(saved) }
                if let bytes = UserDefaults.standard.data(forKey: "uniapi.fans.curve"), let saved = try? JSONValue.decode(bytes).array,
                   NativeHardwareDisplayPolicies.validFanCurve(saved) { curve = saved }
                preferencesRestored = true
            }
            let events = await runtime.events.stream()
            await reload()
            for await event in events {
                if Task.isCancelled { break }
                if event.topic == "fans.state" {
                    reads.invalidate("status"); state = event.data
                    if case .object = event.data,
                       case .bool = event.data["supported"], case .bool = event.data["installed"] { statusReadError = nil }
                    rememberPeaks()
                }
            }
        }
        .nativePageTask(id: "\(tab):\(historyScope)") {
            guard ["control", "timeline", "settings"].contains(tab) else { return }
            while !Task.isCancelled {
                await loadHistory()
                do { try await Task.sleep(nanoseconds: tab == "control" ? 10_000_000_000 : 30_000_000_000) } catch { return }
            }
        }
        .nativePageTask {
            // A visible control page is a client lease independently of the
            // menu bar. Event subscriptions alone never renew that lease.
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                await reload()
            }
        }
        .nativePageActivity(reads: reads, suspended: { draggingPoint = nil; focusedCurvePoint = nil })
    }
    private func statusError(_ message: String) -> some View {
        HStack(spacing: 8) {
            NativeError(message: message)
            Button("Retry") { Task { await reload() } }.buttonStyle(T3Button(.outline))
        }
    }
    private var modeDetail: String {
        if snapshot["thermal"].double >= 2 { return NativeHardwareDisplayPolicies.fanThermalLabel(snapshot) }
        return state["keep"].isNull ? "" : "Kept"
    }
    /// The processor leads; what else is measured sits beside it.
    private var thermal: some View {
        NativeHero(value: thermalFormat(temperature("CPU")), numeric: temperature("CPU"), unit: temperature("CPU") == nil ? "" : unit.uppercased(),
                   facts: [NativeHeroFact(label: "GPU, hottest sensor", value: thermalFormat(temperature("GPU"))),
                           NativeHeroFact(label: "Battery pack", value: thermalFormat(temperature("Battery")))]) {
            Text("CPU, die average")
        } trailing: { EmptyView() }
            .padding(.top, 4)
    }
    private func controlCountdown(at date: Date) -> some View {
        Text(countdown(max(0, state["control"]["until"].double - date.timeIntervalSince1970 * 1000)) + " left").font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.accent)
    }
    /// The control first, as one line; then what it acts on.
    private var controls: some View {
        let mode = state["control"]["mode"].string, released = ["automatic", "external"].contains(mode)
        return VStack(alignment: .leading, spacing: 24) {
            if !state["enabled"].bool {
                NativeSetup(steps: [NativeSetupStep(
                    id: "enable",
                    title: state["daemon"]["installed"].bool ? "Reconnect fan control helper" : "Install fan control helper",
                    detail: state["daemon"]["installed"].bool ? "The installed helper is not responding yet." : "Asks for your password once; stays enabled across sleep and restarts.",
                    done: false,
                    enabled: !(pending || snapshot.isNull || runtime.paths.readOnly),
                    actionTitle: state["daemon"]["installed"].bool ? "Reconnect" : "Install",
                    actionIcon: "power",
                    action: { Task { await operation("install") } })])
            }
            VStack(alignment: .leading, spacing: 8) {
                NativeRouteLine(tool: "Fans", icon: "fan", stops: {
                    T3Segmented(options: [("automatic", "Automatic"), ("cooler", "Cooler"), ("curve", "Curve")], selection: mode, enabled: enabled) { choice in
                        if choice == "curve" { tab = "curve" } else { Task { await command(["command": .string(choice)]) } }
                    }.accessibilityLabel("Fan profile")
                    NativeRouteArrow()
                    HStack(spacing: 6) {
                        Text("Hold").font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.muted).help(durationDescription)
                        NativeFanDurationMenu(value: $duration, values: NativeHardwareDisplayPolicies.fanDurations, label: durationLabel)
                        Button("Set") { if let input = currentDurationCommand { Task { await command(input) } } }.disabled(!enabled || currentDurationCommand == nil)
                    }
                }, action: {
                    HStack(spacing: 6) {
                        NativeFanDurationMenu(value: $boost, values: NativeHardwareDisplayPolicies.boostDurations, label: durationLabel)
                        Button("Boost", nativeIcon: "zap") { Task { await command(["command": "boost", "duration": .number(Double(boost))]) } }
                            .disabled(!enabled).help("Maximum cooling, then back to automatic")
                    }
                })
                HStack(spacing: 10) {
                    if !["automatic", "cooler", "curve"].contains(mode) {
                        Text(NativeHardwareDisplayPolicies.fanModeName(mode)).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.dim)
                    }
                    if !state["control"]["until"].isNull {
                        if pageActive { TimelineView(.periodic(from: .now, by: 1)) { time in controlCountdown(at: time.date) } }
                        else { controlCountdown(at: Date()) }
                    } else if !modeDetail.isEmpty {
                        Text(modeDetail).font(Theme.ui(Theme.textXs)).foregroundStyle(snapshot["thermal"].double >= 2 ? Theme.warnFg : Theme.muted)
                    }
                    if !state["control"]["message"].string.isEmpty {
                        Text(state["control"]["message"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if !released || !state["keep"].isNull {
                        Button(released ? "Stop keeping" : "Reset to Auto", nativeIcon: "rotate-ccw") { Task { await operation("release") } }.buttonStyle(T3Button(.ghost)).disabled(pending || runtime.paths.readOnly)
                    }
                }.padding(.leading, 14)
            }
            thermal
            fanDeck
            if let historyError { NativeError(message: historyError) }
            NativeSection("Last 30 minutes", trailing: {
                Button("Timeline", nativeIcon: "arrow-right") { tab = "timeline" }.buttonStyle(T3Button(.ghost))
            }) {
                NativeLineChart(series: temperatureSeries, height: 180, showPoints: false, includeZero: false, xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .omitted, time: .shortened) }, yFormat: { String(format: "%.1f°%@", $0, unit.uppercased()) })
            }
        }
    }
    private var fanDeck: some View {
        VStack(alignment: .leading, spacing: 0) {
            Theme.rule.frame(height: 1)
            if snapshot.isNull || snapshot["fans"].array.isEmpty {
                Text(snapshot.isNull ? "Waiting for fan readings" : "This Mac has no controllable fans").font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.muted).padding(.vertical, 14)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: max(1, min(2, snapshot["fans"].array.count))), spacing: 0) {
                    ForEach(snapshot["fans"].array, id: \.self["id"]) { fan in
                        NativeFanSpeedCard(fan: fan, enabled: enabled, duration: duration) { rpm in Task { await manual(fan["id"].int, rpm) } }
                            .overlay(alignment: .trailing) { if snapshot["fans"].array.first?["id"] == fan["id"] && snapshot["fans"].array.count > 1 { Theme.rule.frame(width: 1) } }
                    }
                }
            }
            Theme.rule.frame(height: 1)
        }
    }
    private var sensors: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                T3Field(placeholder: "Filter \(snapshot["sensors"].array.count) sensors", text: $query, leadingIcon: "search").frame(maxWidth: 280)
                NativeMenuSelect(title: "Sensor group", selection: $group, options: ["All", "Favorites", "CPU", "GPU", "Battery", "Memory", "Storage", "System"].map { ($0, $0) }, width: 130)
                Spacer(minLength: 8)
                Button("Clear peaks", nativeIcon: "rotate-ccw") { peaks = [:]; rememberPeaks() }.buttonStyle(T3Button(.ghost))
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Color.clear.frame(width: 22, height: 1)
                    Text("Sensor").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Now").frame(width: 90, alignment: .trailing)
                    Text("Peak").frame(width: 90, alignment: .trailing)
                }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 30)
                ForEach(sensorRows, id: \.self["id"]) { sensor in
                    let favorite = favorites.contains(sensor["id"].string)
                    Theme.rule.frame(height: 1)
                    HStack(spacing: 12) {
                        Button {
                            let id = sensor["id"].string
                            if !favorites.insert(id).inserted { favorites.remove(id) }
                            if !runtime.paths.readOnly { UserDefaults.standard.set(Array(favorites).sorted(), forKey: "uniapi.fans.favorites") }
                        } label: {
                            NativeIcon("star", size: 13).foregroundStyle(favorite ? Theme.accent : Theme.faint).frame(width: 22, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain).pointingHand()
                            .accessibilityLabel("\(favorite ? "Unfavorite" : "Favorite") \(sensorName(sensor["id"].string))")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(sensorName(sensor["id"].string)).font(Theme.ui(Theme.textSm)).lineLimit(1)
                            Text(sensor["id"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        NativeNumberText(text: format(NativeHardwareDisplayPolicies.number(sensor["value"])), font: Theme.num(Theme.textSm, weight: .medium))
                            .frame(width: 90, alignment: .trailing)
                        Text(format(peaks[sensor["id"].string])).font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted)
                            .frame(width: 90, alignment: .trailing)
                    }.frame(height: 36)
                }
                Theme.rule.frame(height: 1)
                if sensorRows.isEmpty { Text("No match").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint).padding(.leading, 34).padding(.vertical, 12) }
            }
        }
    }
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 8) {
                NativeMenuSelect(title: "History range", selection: $range, options: [("30m", "30 minutes"), ("1h", "1 hour"), ("6h", "6 hours"), ("24h", "24 hours"), ("7d", "7 days"), ("30d", "30 days"), ("90d", "90 days"), ("1y", "1 year"), ("all", "All time"), ("custom", "Custom")], width: 125)
                T3Segmented(options: [("mean", "Average"), ("max", "Peak"), ("min", "Minimum")], selection: statistic) { statistic = $0 }
                if range == "custom" {
                    DatePicker("From", selection: $from, in: ...through, displayedComponents: .date).labelsHidden().accessibilityLabel("From")
                    Text("to").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    DatePicker("Through", selection: $through, in: from...Date(), displayedComponents: .date).labelsHidden().accessibilityLabel("Through")
                }
                Spacer(minLength: 0)
            }
            if let historyError { NativeError(message: historyError) }
            NativeCard(title: "Temperature") { NativeLineChart(series: temperatureSeries, includeZero: false, xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) }, yFormat: { String(format: "%.1f°%@", $0, unit.uppercased()) }) }
            NativeCard(title: "Fan speed") { NativeLineChart(series: fanSeries, xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) }, yFormat: { String(format: "%.0f RPM", $0) }) }
            Text(historyCaption).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint)
        }
    }
    private var historyCaption: String {
        guard !history.isNull else { return "" }
        let first = history["storage"]["first"]
        var parts = ["\(history["points"].array.count) buckets of \(Int(history["resolutionMs"].double / 1000)) s"]
        if !first.isNull { parts.append("since " + Date(timeIntervalSince1970: first.double / 1000).formatted(date: .abbreviated, time: .shortened)) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file) + " stored")
        let pending = history["storage"]["pending"].int
        if pending > 0 { parts.append("upgrading \(pending) older readings") }
        return parts.joined(separator: " · ")
    }
    private var temperatureSeries: [NativeChartSeries] {
        ["CPU", "GPU", "Battery"].map { group in NativeChartSeries(id: group, label: group, points: NativeFanHistory.discontinuousSamples(history["points"].array, kind: tab == "timeline" ? statistic : "mean").map { s in return NativeChartPoint(x: s["date"].double, y: temperature(group, sample: s).map { unit == "f" ? $0 * 1.8 + 32 : $0 }) }) }
    }
    private var fanSeries: [NativeChartSeries] {
        let ids = Set(history["points"].array.flatMap { $0[statistic]["fans"].array.map { $0["id"].int } }).sorted()
        return ids.map { id in NativeChartSeries(id: "fan-\(id)", label: "Fan \(id + 1)", points: NativeFanHistory.discontinuousSamples(history["points"].array, kind: statistic).map { s in let fan = s["fans"].array.first { $0["id"].int == id }; return NativeChartPoint(x: s["date"].double, y: fan.flatMap { NativeHardwareDisplayPolicies.number($0["actual"]) }) }) }
    }
    private var curveStudio: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(curveReadout).font(Theme.num(Theme.textSm, weight: .medium)).foregroundStyle(Theme.ink)
                    .help("The curve follows the higher of the CPU die average and the hottest GPU sensor")
                Spacer(minLength: 8)
                curveTools
            }
            VStack(alignment: .leading, spacing: 0) {
                if contentWidth >= 700 {
                    HStack(alignment: .top, spacing: 0) {
                        curveChart.padding(20)
                        VStack(spacing: 0) { curvePointRows }.frame(width: 220).overlay(alignment: .leading) { Theme.rule.frame(width: 1) }
                    }
                } else {
                    curveChart.padding(20)
                    Theme.rule.frame(height: 1)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) { curvePointRows }
                }
            }.background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            HStack(spacing: 6) {
                Text("Drag a point, or focus it and use")
                NativeKbd("←"); NativeKbd("→"); Text("for temperature,"); NativeKbd("↑"); NativeKbd("↓"); Text("for output.")
            }.font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                .accessibilityElement(children: .ignore).accessibilityLabel("Drag a point, or focus it and use Left and Right for temperature, Up and Down for output.")
        }
    }
    private var curveReadout: String {
        if let index = draggingPoint ?? focusedCurvePoint, curve.indices.contains(index) {
            return String(format: "%.0f°C · %.0f%%", curve[index]["temperature"].double, curve[index]["percent"].double)
        }
        if let governing {
            return String(format: "Now %.0f°C → %.0f%% output", governing, NativeHardwareDisplayPolicies.fanCurvePercent(curve, temperature: governing))
        }
        return "No temperature reading"
    }
    private var applyCurveButton: some View { Button(state["control"]["mode"].string == "curve" ? "Apply changes" : "Use curve") { Task { await command(["command": "curve", "curve": .array(curve)]) } }.buttonStyle(T3Button(.primary)).disabled(!enabled) }
    @ViewBuilder private var curvePointRows: some View {
        ForEach(curve.indices, id: \.self) { index in
            if let bounds = NativeHardwareDisplayPolicies.curveBounds(curve, index: index) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(["Start", "Comfort", "Performance", "Full"][min(index, 3)]).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        NativeCurveNumber(value: curve[index]["temperature"].double, unit: "°C", bounds: bounds.temperature, label: "Point \(index + 1) temperature Celsius") { updateCurve(index, temperature: $0, percent: curve[index]["percent"].double) }
                        Text("/").foregroundStyle(Theme.muted)
                        NativeCurveNumber(value: curve[index]["percent"].double, unit: "%", bounds: bounds.percent, disabled: index == 3, label: "Point \(index + 1) output percent") { updateCurve(index, temperature: curve[index]["temperature"].double, percent: $0) }
                    }
                    if showCurveSliders {
                        Slider(value: Binding(get: { curve[index]["percent"].double }, set: { updateCurve(index, temperature: curve[index]["temperature"].double, percent: $0) }), in: bounds.percent.lowerBound...max(bounds.percent.lowerBound + 1, bounds.percent.upperBound), step: 1)
                            .disabled(bounds.percent.lowerBound == bounds.percent.upperBound).accessibilityLabel("Point \(index + 1) output slider")
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .bottom) { Theme.rule.frame(height: 1).opacity(index == curve.count - 1 && contentWidth >= 700 ? 0 : 1) }
            }
        }
    }
    private var curveTools: some View {
        HStack(spacing: 4) {
            T3IconButton(system: "sliders-horizontal", help: showCurveSliders ? "Hide sliders" : "Show sliders", active: showCurveSliders) { showCurveSliders.toggle() }
            T3IconButton(system: "rotate-ccw", help: "Restore the default curve") { curve = NativeHardwareDisplayPolicies.defaultFanCurve; saveCurve() }
        }.fixedSize()
    }
    private var curveChart: some View {
        Chart {
            ForEach(Array(curve.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Temperature", point["temperature"].double), y: .value("Output", point["percent"].double)).foregroundStyle(Theme.accent)
                PointMark(x: .value("Temperature", point["temperature"].double), y: .value("Output", point["percent"].double)).foregroundStyle(Theme.accent).symbolSize(80).annotation(position: .top) { Text(String(format: "%.0f%%", point["percent"].double)).font(Theme.num(10, weight: .medium)).foregroundStyle(Theme.dim) }
            }
            if let governing {
                RuleMark(x: .value("Governing", max(30, min(95, governing)))).foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                PointMark(x: .value("Governing", max(30, min(95, governing))), y: .value("Curve output", NativeHardwareDisplayPolicies.fanCurvePercent(curve, temperature: governing))).foregroundStyle(Theme.ink).symbolSize(60)
            }
        }.chartXScale(domain: 30...95).chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: [30.0, 45, 60, 75, 90]) { value in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel {
                        if let temperature = value.as(Double.self) { Text(String(format: "%.0f°C", temperature)).font(Theme.num(10, weight: .regular)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0.0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel {
                        if let percent = value.as(Double.self) { Text(String(format: "%.0f%%", percent)).font(Theme.num(10, weight: .regular)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false) }
                    }
                }
            }
            .frame(height: 300)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let frame = proxy.plotFrame {
                        let origin = geometry[frame].origin
                        ZStack(alignment: .topLeading) {
                            Rectangle().fill(.clear).contentShape(Rectangle())
                            ForEach(curve.indices, id: \.self) { index in
                                if let x = proxy.position(forX: curve[index]["temperature"].double), let y = proxy.position(forY: curve[index]["percent"].double) {
                                    curveHandle(index).position(x: origin.x + x, y: origin.y + y)
                                }
                            }
                        }.simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { value in
                            if draggingPoint == nil {
                                draggingPoint = curve.indices.first { index in
                                    guard let x = proxy.position(forX: curve[index]["temperature"].double), let y = proxy.position(forY: curve[index]["percent"].double) else { return false }
                                    return hypot(value.startLocation.x - origin.x - x, value.startLocation.y - origin.y - y) <= 24
                                }
                                focusedCurvePoint = draggingPoint
                            }
                            guard let index = draggingPoint,
                                  let temperature: Double = proxy.value(atX: value.location.x - origin.x),
                                  let percent: Double = proxy.value(atY: value.location.y - origin.y) else { return }
                            updateCurve(index, temperature: temperature, percent: percent)
                        }.onEnded { _ in draggingPoint = nil })
                    }
                }
            }
    }
    private func curveHandle(_ index: Int) -> some View {
        Button { focusedCurvePoint = index } label: {
            Circle().fill(Theme.accent.opacity(focusedCurvePoint == index ? 0.16 : 0)).frame(width: 36, height: 36)
                .overlay(Circle().stroke(Theme.accent.opacity(focusedCurvePoint == index ? 0.7 : 0), lineWidth: 1))
                .frame(width: 44, height: 44).contentShape(Circle())
        }.buttonStyle(.plain).focused($focusedCurvePoint, equals: index)
            .accessibilityLabel("Curve point \(index + 1)")
            .accessibilityValue("\(curve[index]["temperature"].string) degrees Celsius, \(curve[index]["percent"].string) percent")
            .accessibilityHint("Left and Right adjust temperature; Up and Down adjust output")
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { key in
                let dt = key.key == .leftArrow ? -1.0 : key.key == .rightArrow ? 1.0 : 0
                let dp = key.key == .downArrow ? -1.0 : key.key == .upArrow ? 1.0 : 0
                updateCurve(index, temperature: curve[index]["temperature"].double + dt, percent: curve[index]["percent"].double + dp)
                return .handled
            }.accessibilityAdjustableAction { direction in
                updateCurve(index, temperature: curve[index]["temperature"].double, percent: curve[index]["percent"].double + (direction == .increment ? 1 : -1))
            }
    }
    private var preferences: some View {
        let storage = history["storage"], daemon = state["daemon"]
        return NativeSheet {
            NativeSection("Display") {
                SettingRow(title: "Temperature unit", desc: "Also used by the menu bar.") {
                    T3Segmented(options: [("c", "°C"), ("f", "°F")], selection: unit) { value in Task { await operation("preferences", ["unit": .string(value)]) } }
                }
                SettingRow(title: "Menu bar") {
                    NativeMenuSelect(title: "Menu bar display", selection: Binding(get: { state["preferences"]["menuMetric"].string }, set: { value in Task { await operation("preferences", ["menuMetric": .string(value)]) } }), options: [("temperature", "Temperature"), ("rpm", "Fan RPM"), ("both", "Temperature and RPM"), ("icon", "Icon only")], width: 190)
                }
            }
            NativeSection("Helper") {
                SettingRow(title: daemon["installed"].bool ? daemon["current"].bool ? (state["enabled"].bool ? "Installed" : "Installed (not running)") : "Update available" : "Not installed",
                           desc: daemon["installed"].bool ? (daemon["current"].bool ? (state["enabled"].bool ? nil : "Reconnect or reinstall to start the helper.") : "Updating asks for your password once.") : "Install once so fan controls stay enabled across sleep and restarts.") {
                    HStack(spacing: 8) {
                        if !daemon["installed"].bool && !state["enabled"].bool { Button("Just this session") { Task { await operation("enable") } }.buttonStyle(T3Button(.ghost)).disabled(pending || snapshot.isNull || runtime.paths.readOnly) }
                        if daemon["installed"].bool { Button("Remove") { Task { await operation("uninstall") } }.buttonStyle(T3Button(.ghost)).disabled(pending || runtime.paths.readOnly) }
                        if !daemon["installed"].bool || !daemon["current"].bool || !state["enabled"].bool { Button(!daemon["installed"].bool ? "Install" : !daemon["current"].bool ? "Update" : "Reconnect") { Task { await operation("install") } }.buttonStyle(T3Button(.outline)).disabled(pending || snapshot.isNull || runtime.paths.readOnly) }
                    }
                }
                SettingRow(title: "Kept profile", desc: state["keep"].isNull ? "Cooler, a custom curve, or a manual speed held with Never is restored after sleep and restart." : "Restored after sleep and restart. Choose Automatic to stop.") {
                    Text(state["keep"].isNull ? "None" : NativeHardwareDisplayPolicies.fanModeName(state["keep"]["command"].string)).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(state["keep"].isNull ? Theme.faint : Theme.ink)
                }
            }
            NativeSection("History") {
                SettingRow(title: "Stored", desc: "Samples for \(storage["rawDays"].isNull ? 7 : storage["rawDays"].int) days, minute summaries for \(storage["minuteDays"].isNull ? 90 : storage["minuteDays"].int), hourly for \(storage["hourlyDays"].isNull ? 365 : storage["hourlyDays"].int). Daily averages and peaks are kept. Nothing is recorded while the Mac sleeps.") {
                    Text(history.isNull ? "—" : ByteCountFormatter.string(fromByteCount: Int64(storage["bytes"].double), countStyle: .file)).font(Theme.num(Theme.textSm, weight: .medium))
                }
            }
        }
    }
    private func reload() async {
        guard let service = session.fans, let ticket = reads.begin("status") else { return }
        do {
            let next = try await service.handle("status")
            guard reads.accepts(ticket) else { return }
            state = next; statusReadError = nil; rememberPeaks()
        } catch { if reads.accepts(ticket) { statusReadError = error.localizedDescription } }
    }
    private func operation(_ name: String, _ input: JSONObject = [:]) async { guard let service = session.fans, !pending else { return }; pending = true; defer { pending = false }; do { _ = try await service.handle(name, input: input); await reload(); error = nil } catch { self.error = error.localizedDescription; await reload() } }
    private func command(_ input: JSONObject) async { await operation("control", input) }
    private func manual(_ id: Int, _ rpm: Double) async { guard let input = NativeHardwareDisplayPolicies.manualFanCommand(snapshot: snapshot, id: id, rpm: rpm, duration: duration) else { error = "Wait for valid fan limits before setting a target"; return }; await command(input) }
    private func rememberPeaks() { for sensor in snapshot["sensors"].array { if let value = NativeHardwareDisplayPolicies.number(sensor["value"]) { peaks[sensor["id"].string] = max(peaks[sensor["id"].string] ?? value, value) } } }
    private func sensorName(_ id: String) -> String { NativeHardwareDisplayPolicies.sensorName(id) }
    private func temperature(_ group: String, sample: JSONValue? = nil) -> Double? { NativeHardwareDisplayPolicies.temperature(sample ?? snapshot, group: group) }
    private func thermalFormat(_ value: Double?) -> String { guard let value, value.isFinite else { return "—" }; return String(format: "%.0f°", floor((unit == "f" ? value * 1.8 + 32 : value) + 0.5)) }
    private func format(_ value: Double?) -> String { guard let value else { return "—" }; return String(format: "%.1f°%@", unit == "f" ? value * 1.8 + 32 : value, unit.uppercased()) }
    private func countdown(_ ms: Double) -> String { let s = Int(ms / 1000); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
    private func durationLabel(_ seconds: Int) -> String { seconds == 0 ? "Never" : "\(seconds / 60) min" }
    private var durationDescription: String {
        if state["control"]["mode"].string == "boost" && duration == 0 { return "A boost always ends. Choose a timed duration to restart it." }
        if currentDurationCommand != nil { return duration == 0 ? "Set keeps the current profile without a timer." : "Set restarts the current profile's timer from now." }
        return duration == 0 ? "Your next manual target remains kept until replaced." : "The next manual target ends after its selected duration."
    }
    private func saveCurve() { guard !runtime.paths.readOnly, NativeHardwareDisplayPolicies.validFanCurve(curve) else { return }; if let data = try? JSONValue.array(curve).encoded() { UserDefaults.standard.set(data, forKey: "uniapi.fans.curve") } }
    private func updateCurve(_ index: Int, temperature: Double, percent: Double) { curve = NativeHardwareDisplayPolicies.moveFanCurve(curve, index: index, temperature: temperature, percent: percent); saveCurve() }
    private func loadHistory() async {
        guard let service = session.fans, let ticket = reads.begin("history") else { return }
        let scope = historyScope, selectedRange = historyRange
        let request = historySelection.begin(scope: scope)
        do {
            var input: JSONObject = ["range": .string(selectedRange)]
            if selectedRange == "custom" { input.merge(try NativeHardwareDisplayPolicies.fanHistoryDays(from: from, through: through)) { _, new in new } }
            let next = try await service.handle("history", input: input)
            guard reads.accepts(ticket) else { return }
            historySelection.resolve(request, value: next)
        } catch { if reads.accepts(ticket) { historySelection.reject(request, message: error.localizedDescription) } }
    }
    private func exportHistory() {
        // Capture the selected data before the save sheet; a background refresh must not change the export.
        let csv = NativeHardwareDisplayPolicies.fanHistoryCSV(history["points"].array)
        let panel = NSSavePanel(); panel.nameFieldStringValue = "UniApi-fan-history-\(range).csv"
        panel.nativeBegin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try Data(csv.utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
        }
    }
}

private struct NativeFanDurationMenu: View {
    @Binding var value: Int
    let values: [Int]
    let label: (Int) -> String
    var body: some View {
        Menu { ForEach(values, id: \.self) { option in Button(label(option)) { value = option } } } label: {
            HStack(spacing: 6) { if value == 0 { NativeIcon("infinity", size: 15).accessibilityLabel("Never") } else { Text(label(value)).font(Theme.num(Theme.textXs, weight: .medium)) }; Spacer(minLength: 0); NativeIcon("chevrons-up-down", size: 11).foregroundStyle(Theme.faint) }
                .foregroundStyle(Theme.ink).padding(.horizontal, 10).frame(width: 84, height: Theme.control)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(Theme.input, lineWidth: 1) }
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
