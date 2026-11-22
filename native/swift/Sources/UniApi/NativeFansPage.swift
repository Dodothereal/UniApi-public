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
    @Environment(\.nativePageActive) private var pageActive
    private static let tabs = ["control", "sensors", "timeline", "curve", "settings"]
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
        NativePage(title: "Fan Control", eyebrow: "Cooling and thermals", readiness: pageReadiness) {
            headerActions
        } content: {
            if let statusReadError { statusError(statusReadError) }
            if let error { failure(error) }
            if !state["error"].string.isEmpty { statusError(state["error"].string) }
            if state.isNull {
                if error == nil && statusReadError == nil {
                    Text("Reading fans and temperature sensors").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20)
                }
            } else if !state["supported"].bool {
                Blank(icon: "monitor", title: "Fan Control is available on macOS", detail: "The other UniApi apps work on this platform.")
            } else if !state["installed"].bool {
                Blank(icon: "fan", title: "Fan reader is not installed", detail: "Rebuild the UniApi app to install its native fan reader.")
            } else {
                viewRail
                switch tab { case "sensors": sensors; case "timeline": timeline; case "curve": curveStudio; case "settings": preferences; default: controls }
            }
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

    // MARK: Header

    private func failure(_ message: String) -> some View {
        Notice(text: message, tone: .fail).accessibilityLabel("Error: " + message)
    }
    private func statusError(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            failure(message)
            Button("Retry", nativeIcon: "refresh-cw") { Task { await reload() } }
        }
    }
    @ViewBuilder private var headerActions: some View {
        HStack(spacing: 6) {
            NativeStatusDot(color: snapshot.isNull ? Theme.warn : Theme.signal, pulse: !snapshot.isNull)
            MicroLabel(snapshot.isNull ? "Waiting for readings" : "Live", color: snapshot.isNull ? Theme.muted : Theme.ink)
        }
        .padding(.trailing, 4).accessibilityElement(children: .combine)
        IconPress(icon: "refresh-cw", help: "Refresh") { Task { await reload(); if ["control", "timeline", "settings"].contains(tab) { await loadHistory() } } }
        if !state["enabled"].bool {
            Button(state["daemon"]["installed"].bool ? "Enable controls" : "Enable one-off session", nativeIcon: "power") { Task { await operation("enable") } }
                .buttonStyle(Press(.primary)).disabled(pending || snapshot.isNull || runtime.paths.readOnly)
        } else if tab == "curve" {
            Button(state["control"]["mode"].string == "curve" ? "Apply changes" : "Use curve", nativeIcon: "check") { Task { await command(["command": "curve", "curve": .array(curve)]) } }
                .buttonStyle(Press(.primary)).disabled(!enabled)
        }
    }
    private var viewRail: some View {
        HStack(spacing: 16) {
            Stops(options: [("control", "Control"), ("sensors", "Sensors"), ("timeline", "History"), ("curve", "Curve"), ("settings", "Setup")], selection: tab) { tab = $0 }
                .accessibilityLabel("Fan control sections")
            Spacer(minLength: 8)
            thermalStatus
        }
    }
    private var thermalStatus: some View {
        let pressure = snapshot["thermal"].double
        return Tag(snapshot.isNull ? "Telemetry unavailable" : NativeHardwareDisplayPolicies.fanThermalLabel(snapshot),
                   tone: snapshot.isNull || pressure == 2 ? Theme.warnFg : pressure >= 3 ? Theme.failFg : pressure >= 1 ? Theme.warnFg : Theme.okFg, dot: true)
    }

    // MARK: Control

    private static let groupTint: [String: Color] = ["CPU": Theme.pairPalette[0], "GPU": Theme.pairPalette[3], "Battery": Theme.pairPalette[2]]
    private var hottestGroup: String {
        guard let cpu = temperature("CPU") else { return temperature("GPU") == nil ? "" : "GPU" }
        return (temperature("GPU") ?? -.infinity) > cpu ? "GPU" : "CPU"
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: density.pageGap) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 32) {
                    thermalColumn.frame(width: 248)
                    fanDeck.frame(minWidth: snapshot["fans"].array.count > 1 ? 512 : 240)
                }
                VStack(alignment: .leading, spacing: 28) { thermalColumn; fanDeck }
            }
            modeBand
            if let historyError { failure(historyError) }
            Band(title: "Last 30 minutes", hint: "CPU, GPU and battery") {
                Button { tab = "timeline" } label: { HStack(spacing: 6) { Text("All history"); NativeIcon("arrow-up-right", size: 12, strokeWidth: 1.75) } }.buttonStyle(Press(.quiet))
            } content: {
                Well {
                    if history.isNull {
                        Text(historyError == nil ? "Reading the last 30 minutes" : "History is unavailable").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
                    } else {
                        NativeLineChart(series: temperatureSeries, height: 190, showPoints: false, includeZero: false, xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .omitted, time: .shortened) }, yFormat: { String(format: "%.1f°%@", $0, unit.uppercased()) })
                    }
                }
            }
        }
    }
    /// The hero reading: the temperature the fans answer to.
    private var thermalColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeInstrumentHang()
            MicroLabel(hottestGroup.isEmpty ? "Hottest" : "Hottest · " + hottestGroup)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                NativeNumberText(text: degrees(governing), font: Theme.readout(54), color: governing == nil ? Theme.faint : Theme.ink, isolateLayout: true)
                MicroLabel("°" + unit.uppercased(), size: 11)
            }
            .padding(.top, 4)
            .accessibilityElement(children: .ignore).accessibilityLabel("Hottest temperature").accessibilityValue(format(governing))
            NativeThermalScale(celsius: governing, fahrenheit: unit == "f").padding(.top, 10).padding(.bottom, 24)
            HStack(alignment: .top, spacing: 16) {
                ForEach(["CPU", "GPU", "Battery"], id: \.self) { name in
                    Readout(label: name, value: degrees(temperature(name)), unit: "°" + unit.uppercased(), size: .small,
                            tint: Self.groupTint[name], color: temperature(name) == nil ? Theme.faint : Theme.ink, isolateLayout: true)
                        .help(name == "CPU" ? "Die average" : name == "GPU" ? "Hottest sensor" : "Current temperature")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    @ViewBuilder private var fanDeck: some View {
        if snapshot.isNull || snapshot["fans"].array.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                NativeInstrumentHang()
                MicroLabel("Fans")
                Blank(icon: "fan", title: snapshot.isNull ? "Waiting for live fan readings" : "This Mac has no controllable fans",
                      detail: snapshot.isNull ? "Controls wait for a fresh telemetry snapshot." : "Temperature readings remain available.")
            }
        } else {
            ColumnFlow(minimum: 240, spacing: 32, rowSpacing: 28, maxColumns: 3) {
                ForEach(snapshot["fans"].array, id: \.self["id"]) { fan in
                    NativeFanInstrument(fan: fan, enabled: enabled, duration: duration) { rpm in Task { await manual(fan["id"].int, rpm) } }
                }
            }
        }
    }
    private var mode: String { state["control"]["mode"].string }
    private var modeBand: some View {
        Band(title: "Mode", spacing: 12) {
            if !["automatic", "external"].contains(mode) || !state["keep"].isNull {
                Button(["automatic", "external"].contains(mode) ? "Stop keeping" : "Return to automatic", nativeIcon: "rotate-ccw") { Task { await operation("release") } }
                    .disabled(pending || runtime.paths.readOnly)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 20) { modeStops; Spacer(minLength: 0); modeStatus }
                    VStack(alignment: .leading, spacing: 10) { modeStops; modeStatus }
                }
                if !state["control"]["message"].string.isEmpty {
                    Text(state["control"]["message"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true).padding(.top, 12).padding(.bottom, 8)
                }
                Rule()
                OptionRow(title: "Timer", detail: durationDescription) {
                    HStack(spacing: 8) {
                        Pick(title: "Timer", selection: $duration, options: NativeHardwareDisplayPolicies.fanDurations.map { ($0, durationLabel($0)) }, width: 112)
                        Button("Set") { if let input = currentDurationCommand { Task { await command(input) } } }.disabled(!enabled || currentDurationCommand == nil)
                    }
                }
                OptionRow(title: "Boost length", detail: "Maximum cooling, then back to automatic.", ruled: false) {
                    Pick(title: "Boost length", selection: $boost, options: NativeHardwareDisplayPolicies.boostDurations.map { ($0, durationLabel($0)) }, width: 112)
                }
            }
        }
    }
    private var modeStops: some View {
        Stops(options: [("automatic", "Automatic"), ("cooler", "Cooler"), ("curve", "Curve"), ("boost", "Boost"), ("manual", "Manual")], selection: mode,
              icons: ["automatic": "shield-check", "cooler": "snowflake", "curve": "chart-line", "boost": "zap", "manual": "sliders-horizontal"], enabled: enabled) { choice in
            Task {
                switch choice {
                case "curve": await command(["command": "curve", "curve": .array(curve)])
                case "boost": await command(["command": "boost", "duration": .number(Double(boost))])
                case "manual": await holdCurrentSpeeds()
                default: await command(["command": .string(choice)])
                }
            }
        }
        .accessibilityLabel("Fan mode")
    }
    @ViewBuilder private var modeStatus: some View {
        HStack(spacing: 8) {
            if ["unknown", "external"].contains(mode) { Tag(NativeHardwareDisplayPolicies.fanModeName(mode), tone: Theme.warnFg, dot: true) }
            if !state["keep"].isNull { Tag("Kept until you change it") }
            if !state["control"]["until"].isNull {
                if pageActive { TimelineView(.periodic(from: .now, by: 1)) { time in controlCountdown(at: time.date) } }
                else { controlCountdown(at: Date()) }
            }
        }
    }
    private func controlCountdown(at date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(countdown(max(0, state["control"]["until"].double - date.timeIntervalSince1970 * 1000))).font(Theme.readout(17)).foregroundStyle(Theme.ink)
            MicroLabel("left")
        }
    }
    /// Manual starts from where the fans are now; the rulers take it from there.
    private func holdCurrentSpeeds() async {
        guard let fan = snapshot["fans"].array.first else { error = "Wait for valid fan limits before setting a target"; return }
        await manual(fan["id"].int, fan["target"].double > 0 ? fan["target"].double : fan["actual"].double)
    }

    // MARK: Sensors

    private var sensors: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Entry(placeholder: "Find a sensor", text: $query, mono: true, icon: "search").frame(maxWidth: 280)
                Pick(title: "Sensor group", selection: $group, options: ["All", "Favorites", "CPU", "GPU", "Battery", "Memory", "Storage", "System"].map { ($0, $0) }, width: 132)
                Spacer(minLength: 8)
                MicroLabel("\(sensorRows.count) of \(snapshot["sensors"].array.count)")
                Button("Clear peaks") { peaks = [:]; rememberPeaks() }.buttonStyle(Press(.quiet))
            }
            VStack(alignment: .leading, spacing: 0) {
                LedgerHead {
                    Color.clear.frame(width: 20, height: 1)
                    MicroLabel("Sensor").frame(maxWidth: .infinity, alignment: .leading)
                    MicroLabel(unit == "f" ? "68 to 212 °F" : "20 to 100 °C").frame(width: 168, alignment: .leading)
                    MicroLabel("Now °" + unit.uppercased()).frame(width: 64, alignment: .trailing)
                    MicroLabel("Peak").frame(width: 56, alignment: .trailing)
                }
                ForEach(sensorRows, id: \.self["id"]) { sensor in sensorRow(sensor) }
                if sensorRows.isEmpty { Blank(icon: "thermometer", title: "No matching sensors", detail: "Try another group or search term.") }
            }
        }
    }
    private func sensorRow(_ sensor: JSONValue) -> some View {
        let id = sensor["id"].string, value = NativeHardwareDisplayPolicies.number(sensor["value"])
        let now = NativeThermalScale.fraction(value), peak = max(now, NativeThermalScale.fraction(peaks[id] ?? value))
        return LedgerRow {
            HStack(spacing: 12) {
                Button {
                    if !favorites.insert(id).inserted { favorites.remove(id) }
                    if !runtime.paths.readOnly { UserDefaults.standard.set(Array(favorites).sorted(), forKey: "uniapi.fans.favorites") }
                } label: {
                    NativeIcon(favorites.contains(id) ? "star.fill" : "star", size: 13, strokeWidth: 1.75).foregroundStyle(favorites.contains(id) ? Theme.ink : Theme.faint)
                        .frame(width: 20, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).pointingHand()
                    .accessibilityLabel("\(favorites.contains(id) ? "Unfavorite" : "Favorite") \(sensorName(id))")
                HStack(spacing: 8) {
                    Text(sensorName(id)).font(Theme.ui(13)).lineLimit(1)
                    Text(id).font(Theme.mono(10.5)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                }.help(id).frame(maxWidth: .infinity, alignment: .leading)
                Scale(fraction: now, spread: now...peak).frame(width: 168)
                NativeNumberText(text: reading(value), font: Theme.readout(17)).frame(width: 64, alignment: .trailing)
                    .accessibilityLabel(sensorName(id)).accessibilityValue(format(value))
                Text(reading(peaks[id])).font(Theme.mono(11.5)).foregroundStyle(Theme.muted).frame(width: 56, alignment: .trailing)
                    .accessibilityLabel("Session peak").accessibilityValue(format(peaks[id]))
            }
        }
    }

    // MARK: History

    private var timeline: some View {
        VStack(alignment: .leading, spacing: density.pageGap) {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { timelineScope; Spacer(minLength: 8); exportButton }
                    VStack(alignment: .leading, spacing: 12) { timelineScope; exportButton }
                }
                if range == "custom" {
                    HStack(spacing: 16) {
                        DatePicker("From", selection: $from, in: ...through, displayedComponents: .date)
                        DatePicker("Through", selection: $through, in: from...Date(), displayedComponents: .date)
                    }.font(Theme.ui(12.5)).fixedSize()
                }
            }
            if let historyError { failure(historyError) }
            Band("Temperatures") { Well { NativeLineChart(series: temperatureSeries, includeZero: false, xFormat: historyStamp, yFormat: { String(format: "%.1f°%@", $0, unit.uppercased()) }) } }
            Band("Fan speeds") { Well { NativeLineChart(series: fanSeries, xFormat: historyStamp, yFormat: { String(format: "%.0f RPM", $0) }) } }
            VStack(alignment: .leading, spacing: 4) {
                Text(historyCaption)
                Text("Missing observations remain gaps · \(history["points"].array.count) buckets · ~\(ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file)) stored")
            }.font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
        }
    }
    /// Short ranges read as times; longer ones need the day as well.
    private func historyStamp(_ milliseconds: Double) -> String {
        let date = Date(timeIntervalSince1970: milliseconds / 1000)
        return ["30m", "1h", "6h", "24h"].contains(range) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.abbreviated).hour())
    }
    private var timelineScope: some View {
        HStack(spacing: 20) {
            Pick(title: "History range", selection: $range, options: [("30m", "30 minutes"), ("1h", "1 hour"), ("6h", "6 hours"), ("24h", "24 hours"), ("7d", "7 days"), ("30d", "30 days"), ("90d", "90 days"), ("1y", "1 year"), ("all", "All time"), ("custom", "Custom")], width: 132)
            Stops(options: [("mean", "Average"), ("max", "Peak"), ("min", "Minimum")], selection: statistic) { statistic = $0 }
                .accessibilityLabel("Statistic")
        }
    }
    private var exportButton: some View {
        Button("Export CSV", nativeIcon: "download") { exportHistory() }.disabled(history["points"].array.isEmpty)
    }
    private var historyCaption: String {
        guard !history.isNull else { return "Reading selected history" }
        let first = history["storage"]["first"]
        let since = first.isNull ? "Logging has started" : "Since " + Date(timeIntervalSince1970: first.double / 1000).formatted(date: .abbreviated, time: .shortened)
        let pending = history["storage"]["pending"].int
        let upgrade = pending > 0 ? "Upgrading \(pending) older readings" : "Daily history kept indefinitely"
        return "Buckets: \(Int(history["resolutionMs"].double / 1000)) seconds · \(since) · \(upgrade)"
    }
    private var temperatureSeries: [NativeChartSeries] {
        ["CPU", "GPU", "Battery"].map { group in NativeChartSeries(id: group, label: group, points: NativeFanHistory.discontinuousSamples(history["points"].array, kind: tab == "timeline" ? statistic : "mean").map { s in return NativeChartPoint(x: s["date"].double, y: temperature(group, sample: s).map { unit == "f" ? $0 * 1.8 + 32 : $0 }) }, color: Self.groupTint[group]) }
    }
    private static let fanTints = [6, 10, 7, 9, 5, 11, 4, 1]
    private var fanSeries: [NativeChartSeries] {
        let ids = Set(history["points"].array.flatMap { $0[statistic]["fans"].array.map { $0["id"].int } }).sorted()
        return ids.map { id in NativeChartSeries(id: "fan-\(id)", label: "Fan \(id + 1)", points: NativeFanHistory.discontinuousSamples(history["points"].array, kind: statistic).map { s in let fan = s["fans"].array.first { $0["id"].int == id }; return NativeChartPoint(x: s["date"].double, y: fan.flatMap { NativeHardwareDisplayPolicies.number($0["actual"]) }) }, color: Theme.pairPalette[Self.fanTints[max(0, id) % Self.fanTints.count]]) }
    }

    // MARK: Curve

    private var curveStudio: some View {
        VStack(alignment: .leading, spacing: density.pageGap) {
            ReadoutStrip(minimum: 150) {
                Readout(label: curveReadout.label, value: curveReadout.temperature, unit: "°C", size: .large, tint: curveReadout.live ? Theme.signal : nil)
                Readout(label: "Fan output", value: curveReadout.percent, unit: "%", size: .large)
                Readout(label: "Full cooling by", value: String(Int(curve.last?["temperature"].double ?? 90)), unit: "°C",
                        detail: state["control"]["mode"].string == "curve" ? "Saved here. Apply to send changes." : "Saved on this Mac", size: .large)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 32) {
                    Well { curveChart }.frame(minWidth: 420)
                    VStack(spacing: 0) { curvePointRows }.frame(width: 220)
                }
                VStack(alignment: .leading, spacing: 20) {
                    Well { curveChart }
                    ColumnFlow(minimum: 200, spacing: 32, rowSpacing: 0, maxColumns: 2) { curvePointRows }
                }
            }
            HStack(alignment: .top, spacing: 20) { curveHint.frame(maxWidth: 460, alignment: .leading); Spacer(minLength: 0); curveTools }
        }
    }
    private var curveHint: some View {
        Text("Drag a point, or focus it and use the arrow keys. The curve follows the hotter of the CPU die average and the hottest GPU sensor.")
            .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }
    private var curveReadout: (label: String, temperature: String, percent: String, live: Bool) {
        if let index = draggingPoint ?? focusedCurvePoint, curve.indices.contains(index) {
            return (Self.curvePointNames[min(index, 3)], String(format: "%.0f", curve[index]["temperature"].double), String(format: "%.0f", curve[index]["percent"].double), false)
        }
        if let governing {
            return ("Hottest now", String(format: "%.0f", governing), String(format: "%.0f", NativeHardwareDisplayPolicies.fanCurvePercent(curve, temperature: governing)), true)
        }
        return ("Hottest now", "--", "--", false)
    }
    private static let curvePointNames = ["Start cooling", "Comfort", "Performance", "Full cooling"]
    @ViewBuilder private var curvePointRows: some View {
        ForEach(curve.indices, id: \.self) { index in
            if let bounds = NativeHardwareDisplayPolicies.curveBounds(curve, index: index) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        (draggingPoint ?? focusedCurvePoint) == index ? Theme.signal.frame(width: 2, height: 9) : Theme.ink.frame(width: 2, height: 9)
                        MicroLabel(Self.curvePointNames[min(index, 3)], color: (draggingPoint ?? focusedCurvePoint) == index ? Theme.ink : Theme.muted)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        NativeCurveNumber(value: curve[index]["temperature"].double, unit: "°C", bounds: bounds.temperature, label: "Point \(index + 1) temperature Celsius") { updateCurve(index, temperature: $0, percent: curve[index]["percent"].double) }
                        NativeIcon("arrow-right", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.faint)
                        NativeCurveNumber(value: curve[index]["percent"].double, unit: "%", bounds: bounds.percent, disabled: index == 3, label: "Point \(index + 1) output percent") { updateCurve(index, temperature: curve[index]["temperature"].double, percent: $0) }
                    }
                    if showCurveSliders {
                        let span = bounds.percent.lowerBound...max(bounds.percent.lowerBound + 1, bounds.percent.upperBound)
                        NativeFanSlider(value: Binding(get: { curve[index]["percent"].double }, set: { updateCurve(index, temperature: curve[index]["temperature"].double, percent: $0) }),
                                        bounds: span, enabled: bounds.percent.lowerBound != bounds.percent.upperBound, label: "Point \(index + 1) output slider", step: 1,
                                        editingChanged: { _ in }, keyPressed: { key in
                            let percent = curve[index]["percent"].double
                            guard key != .cancel else { return }
                            updateCurve(index, temperature: curve[index]["temperature"].double,
                                        percent: key == .start ? span.lowerBound : key == .end ? span.upperBound : percent + (key == .decrement ? -1 : 1))
                        })
                    }
                }
                .padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) { if index < 3 { Rule() } }
            }
        }
    }
    private var curveTools: some View {
        HStack(spacing: 4) {
            Button(showCurveSliders ? "Hide sliders" : "Show sliders", nativeIcon: "sliders-horizontal") { showCurveSliders.toggle() }.buttonStyle(Press(.quiet))
            Button("Default curve", nativeIcon: "rotate-cw") { curve = NativeHardwareDisplayPolicies.defaultFanCurve; saveCurve() }.buttonStyle(Press(.quiet))
        }.fixedSize()
    }
    private var curveChart: some View {
        Chart {
            ForEach(Array(curve.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Temperature", point["temperature"].double), y: .value("Output", point["percent"].double)).foregroundStyle(Theme.ink)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                PointMark(x: .value("Temperature", point["temperature"].double), y: .value("Output", point["percent"].double)).foregroundStyle(Theme.ink).symbolSize(70).annotation(position: .top, spacing: 6) { Text(String(format: "%.0f%%", point["percent"].double)).font(Theme.mono(10.5)).foregroundStyle(Theme.dim) }
            }
            if let governing {
                RuleMark(x: .value("Governing", max(30, min(95, governing)))).foregroundStyle(Theme.signal).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Governing", max(30, min(95, governing))), y: .value("Curve output", NativeHardwareDisplayPolicies.fanCurvePercent(curve, temperature: governing))).foregroundStyle(Theme.signal).symbolSize(46)
            }
        }.chartXScale(domain: 30...95).chartYScale(domain: 0...100)
            .chartXAxis {
                AxisMarks(values: [30.0, 45, 60, 75, 90]) { value in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisTick(length: 5).foregroundStyle(Theme.faint)
                    AxisValueLabel {
                        if let temperature = value.as(Double.self) { Text(String(format: "%.0f°C", temperature)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0.0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisTick(length: 5).foregroundStyle(Theme.faint)
                    AxisValueLabel {
                        if let percent = value.as(Double.self) { Text(String(format: "%.0f%%", percent)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false) }
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
            Circle().fill(Theme.signal.opacity(focusedCurvePoint == index ? 0.14 : 0)).frame(width: 30, height: 30)
                .overlay(Circle().stroke(Theme.signal.opacity(focusedCurvePoint == index ? 1 : 0), lineWidth: 1))
                .frame(width: 44, height: 44).contentShape(Circle())
        }.buttonStyle(.plain).focused($focusedCurvePoint, equals: index).focusEffectDisabled()
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

    // MARK: Setup

    private var preferences: some View {
        VStack(alignment: .leading, spacing: density.pageGap) {
            Band("Display", spacing: 0) {
                OptionRow(title: "Temperature unit", detail: "Shared with the menu bar.") {
                    Stops(options: [("c", "Celsius"), ("f", "Fahrenheit")], selection: unit) { value in Task { await operation("preferences", ["unit": .string(value)]) } }
                        .accessibilityLabel("Temperature unit")
                }
                OptionRow(title: "Menu bar reading", detail: "What sits beside the fan in the menu bar.", ruled: false) {
                    Pick(title: "Menu bar display", selection: Binding(get: { state["preferences"]["menuMetric"].string }, set: { value in Task { await operation("preferences", ["menuMetric": .string(value)]) } }), options: [("temperature", "Temperature"), ("rpm", "Fan RPM"), ("both", "Temperature and RPM"), ("icon", "Icon only")], width: 176)
                }
            }
            Band("Control", spacing: 0) {
                OptionRow(title: "Fan control helper", detail: state["daemon"]["installed"].bool ? (state["daemon"]["current"].bool ? "Installed as a background service and current." : "Installed. A newer helper is available; updating needs your password once.") : "Install once to skip the temporary session and password prompt after every restart.") {
                    HStack(spacing: 8) {
                        if !state["daemon"]["installed"].bool || !state["daemon"]["current"].bool { Button(state["daemon"]["installed"].bool ? "Update helper" : "Install helper") { Task { await operation("install") } }.disabled(pending || runtime.paths.readOnly) }
                        if state["daemon"]["installed"].bool { Button("Remove helper") { Task { await operation("uninstall") } }.buttonStyle(Press(.danger)).disabled(pending || runtime.paths.readOnly || !state["daemon"]["installed"].bool) }
                    }
                }
                OptionRow(title: "Kept profile", detail: state["keep"].isNull ? "Cooler, a curve, or a manual speed with no timer is remembered and restored. A boost or timed speed ends as requested." : "Re-applied after restart, wake and reboot. Choose Automatic to stop keeping it.") {
                    Tag(state["keep"].isNull ? "Nothing kept" : NativeHardwareDisplayPolicies.fanModeName(state["keep"]["command"].string), tone: state["keep"].isNull ? nil : Theme.okFg, dot: !state["keep"].isNull)
                }
                OptionRow(title: "Protection", detail: "Hardware speed limits, thermal safeguards, timed overrides and connection recovery stay active in every mode.", ruled: false) {
                    Tag("Always on", tone: Theme.okFg, dot: true)
                }
            }
            Band("History", spacing: 0) {
                OptionRow(title: "Storage", detail: "Detail for \(history["storage"]["rawDays"].isNull ? 7 : history["storage"]["rawDays"].int) days, minutes for \(history["storage"]["minuteDays"].isNull ? 90 : history["storage"]["minuteDays"].int), hours for \(history["storage"]["hourlyDays"].isNull ? 365 : history["storage"]["hourlyDays"].int); daily averages and peaks stay. Compacts sooner near 500 MB.") {
                    Text(history.isNull ? "Reading" : "~" + ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file)).font(Theme.mono(12)).foregroundStyle(history.isNull ? Theme.muted : Theme.ink)
                }
                OptionRow(title: "Background logging", detail: "Saved while the UniApi service runs, window open or closed. Nothing is captured while the Mac sleeps or is shut down.", ruled: false) {
                    Tag("Automatic", tone: Theme.okFg, dot: true)
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
    private func degrees(_ value: Double?) -> String { guard let value, value.isFinite else { return "--" }; return String(format: "%.0f", floor((unit == "f" ? value * 1.8 + 32 : value) + 0.5)) }
    private func reading(_ value: Double?) -> String { guard let value else { return "--" }; return String(format: "%.1f", unit == "f" ? value * 1.8 + 32 : value) }
    private func format(_ value: Double?) -> String { guard let value else { return "--" }; return String(format: "%.1f°%@", unit == "f" ? value * 1.8 + 32 : value, unit.uppercased()) }
    private func countdown(_ ms: Double) -> String { let s = Int(ms / 1000); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60) }
    private func durationLabel(_ seconds: Int) -> String { seconds == 0 ? "No timer" : "\(seconds / 60) min" }
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
