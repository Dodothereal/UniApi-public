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
        NativePage(title: "Airflow", subtitle: "Your Mac. In balance.", maxWidth: 1500, readiness: pageReadiness, showsHeader: false) {
            airflowHeader
            if let statusReadError { statusError(statusReadError) }
            if let error { NativeError(message: error) }
            if !state["error"].string.isEmpty { statusError(state["error"].string) }
            if state.isNull {
                if error == nil && statusReadError == nil {
                    ShimmerText(text: "Reading fans and temperature sensors…").padding(.vertical, 40)
                }
            } else if !state["supported"].bool {
                NativeEmptyState(title: "Fan Control is available on macOS", detail: "The other UniApi apps work on this platform.", icon: "monitor")
            } else if !state["installed"].bool {
                NativeEmptyState(title: "Fan reader is not installed", detail: "Rebuild the UniApi app to install its native fan reader.", icon: "fan")
            } else {
                if contentWidth >= 650 { HStack(spacing: 20) { tabRail; Spacer(minLength: 8); thermalStatus } }
                else { VStack(alignment: .leading, spacing: 12) { tabRail; thermalStatus } }
                switch tab { case "sensors": sensors; case "timeline": timeline; case "curve": curveStudio; case "settings": preferences; default: controls }
            }
        }
        .onChange(of: max(0, min(1500, viewport.size.width) - 2 * density.pageMargin), initial: true) { _, width in contentWidth = width }
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
        VStack(alignment: .leading, spacing: 10) {
            NativeError(message: message)
            Button("Retry") { Task { await reload() } }
        }
    }
    private var airflowHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 20) { airflowHeading.fixedSize(); Spacer(minLength: 0); headerActions.fixedSize() }
            VStack(alignment: .leading, spacing: 12) { airflowHeading; headerActions.frame(maxWidth: .infinity, alignment: .trailing) }
        }
    }
    private var airflowHeading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Airflow").font(Theme.ui(min(44, max(30, (contentWidth + 216 + 2 * density.pageMargin) * 0.04)), weight: .semibold)).tracking(-1.8).accessibilityAddTraits(.isHeader)
            Text("Your Mac. In balance.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
        }
    }
    private var headerActions: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) { NativeStatusDot(color: snapshot.isNull ? Theme.warnFg : Theme.okFg, pulse: !snapshot.isNull); Text(snapshot.isNull ? "Waiting for readings" : "Live").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            NativeMenuSelect(title: "Temperature unit", selection: Binding(get: { unit }, set: { value in Task { await operation("preferences", ["unit": .string(value)]) } }), options: [("c", "°C"), ("f", "°F")], width: 68)
            Button { Task { await reload(); if ["control", "timeline", "settings"].contains(tab) { await loadHistory() } } } label: { HStack(spacing: 6) { NativeIcon("refresh-cw", size: 12, strokeWidth: 1.65); Text("Refresh") } }
            if !state["enabled"].bool { Button(state["daemon"]["installed"].bool ? "Enable controls" : "Enable one-off session") { Task { await operation("enable") } }.buttonStyle(T3Button(.primary)).disabled(pending || snapshot.isNull || runtime.paths.readOnly) }
        }
    }
    private var tabRail: some View {
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.self) { value in
                Button { tab = value } label: {
                    Text(["control": "Control room", "sensors": "Sensors", "timeline": "Timeline", "curve": "Curve studio", "settings": "Preferences"][value] ?? value)
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
        .padding(5).frame(width: min(480, max(0, contentWidth))).background(Theme.well, in: RoundedRectangle(cornerRadius: 10)).accessibilityElement(children: .contain).accessibilityLabel("Fan control sections")
    }
    private var thermalStatus: some View {
        HStack(spacing: 8) { NativeStatusDot(color: snapshot.isNull || snapshot["thermal"].double >= 2 ? Theme.warnFg : Theme.okFg); Text(snapshot.isNull ? "Telemetry unavailable" : NativeHardwareDisplayPolicies.fanThermalLabel(snapshot)) }.font(Theme.ui(11)).foregroundStyle(Theme.muted)
    }
    private var thermal: some View {
        Card(padding: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) {
                    thermalSummary.frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                    thermalReadings.fixedSize(horizontal: true, vertical: true)
                }
                VStack(alignment: .leading, spacing: 20) { thermalSummary; thermalReadings }
            }
        }
    }
    private var thermalSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text("Thermal overview").font(Theme.ui(12)).foregroundStyle(Theme.muted); Spacer(minLength: 12); Text("°" + unit.uppercased()).font(Theme.mono(11)).foregroundStyle(Theme.muted) }
            Text(NativeHardwareDisplayPolicies.fanModeName(state["control"]["mode"].string)).font(Theme.ui(26, weight: .semibold)).tracking(-1)
            if !state["keep"].isNull { Text("Kept until you change it").font(Theme.ui(12)).foregroundStyle(Theme.muted).padding(.top, 6) }
            if !state["control"]["until"].isNull {
                if pageActive { TimelineView(.periodic(from: .now, by: 1)) { time in controlCountdown(at: time.date) } }
                else { controlCountdown(at: Date()) }
            }
        }
    }
    private func controlCountdown(at date: Date) -> some View {
        Text(countdown(max(0, state["control"]["until"].double - date.timeIntervalSince1970 * 1000))).font(Theme.mono(12))
    }
    private var thermalReadings: some View {
        HStack(spacing: 0) {
            ForEach(["CPU", "GPU", "Battery"], id: \.self) { name in
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.border).frame(width: 1)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            NativeIcon(name == "CPU" ? "cpu" : name == "GPU" ? "circuit-board" : "battery", size: 15, strokeWidth: 1.65)
                                .foregroundStyle(name == "CPU" ? Theme.accent : name == "GPU" ? Theme.pairPalette[6] : Theme.warn)
                            Text(name).font(Theme.ui(12))
                        }
                        NativeNumberText(text: thermalFormat(temperature(name)), font: Theme.ui(36, weight: .medium), isolateLayout: true).fixedSize()
                        Text(name == "CPU" ? "Die average" : name == "GPU" ? "Hottest sensor" : "Current temperature")
                            .font(Theme.ui(10)).foregroundStyle(Theme.muted).fixedSize()
                    }.padding(.leading, 20).frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 24) {
            thermal
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 24) { fanDeck.frame(minWidth: 480); profiles.frame(width: 290) }
                VStack(alignment: .leading, spacing: 24) { fanDeck; profiles }
            }
            if let historyError { NativeError(message: historyError) }
            Card(padding: 26) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Thermal trace").font(Theme.ui(14, weight: .medium))
                            Text("CPU, GPU and battery temperatures · last 30 minutes").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        Button { tab = "timeline" } label: { HStack(spacing: 6) { Text("Explore history"); NativeIcon("arrow-up-right", size: 12, strokeWidth: 1.65) } }.buttonStyle(T3Button(.ghost))
                    }
                    NativeLineChart(series: temperatureSeries, height: 190, showPoints: false, includeZero: false, xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .omitted, time: .shortened) }, yFormat: { String(format: "%.1f°%@", $0, unit.uppercased()) })
                }
            }
        }
    }
    private var fanDeck: some View {
        Card(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Text("Fan speeds").font(Theme.ui(15, weight: .medium))
                    if !["automatic", "external"].contains(state["control"]["mode"].string) || !state["keep"].isNull {
                        Button { Task { await operation("release") } } label: { HStack(spacing: 5) { NativeIcon("rotate-ccw", size: 12, strokeWidth: 1.65); Text(["automatic", "external"].contains(state["control"]["mode"].string) ? "Stop keeping" : "Reset to Auto") } }.disabled(pending || runtime.paths.readOnly)
                    }
                    Spacer(minLength: 8)
                    Text(NativeHardwareDisplayPolicies.fanModeName(state["control"]["mode"].string)).font(Theme.ui(11)).padding(.horizontal, 9).padding(.vertical, 5).background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 18)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: max(1, min(2, snapshot["fans"].array.count))), spacing: 18) {
                    ForEach(snapshot["fans"].array, id: \.self["id"]) { fan in
                        NativeFanSpeedCard(fan: fan, enabled: enabled, duration: duration) { rpm in Task { await manual(fan["id"].int, rpm) } }
                            .overlay(alignment: .trailing) { if snapshot["fans"].array.first?["id"] == fan["id"] && snapshot["fans"].array.count > 1 { Rectangle().fill(Theme.border).frame(width: 1) } }
                    }
                    if snapshot.isNull || snapshot["fans"].array.isEmpty { NativeEmptyState(title: snapshot.isNull ? "Waiting for live fan readings" : "This Mac has no controllable fans.", detail: snapshot.isNull ? "Controls wait for a fresh telemetry snapshot." : "Temperature readings remain available.", icon: "fan") }
                }.padding(.bottom, 14)
                Rectangle().fill(Theme.border).frame(height: 1)
                HStack(alignment: .top, spacing: 8) {
                    NativeIcon("shield-check", size: 14, strokeWidth: 1.65).foregroundStyle(Theme.okFg).padding(.top, 2)
                    Text(state["control"]["message"].string).font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.vertical, 16).background(Theme.well)
            }
        }
    }
    private var profiles: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Choose your flow").font(Theme.ui(15, weight: .medium))
                Text("A little quieter. A little cooler. Your call.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted).padding(.bottom, 9)
                NativeFanProfileChoice(title: "Automatic", detail: "Let macOS find the balance.", icon: "shield-check", active: state["control"]["mode"] == "automatic") { Task { await command(["command": "automatic"]) } }.disabled(!enabled)
                NativeFanProfileChoice(title: "Cooler", detail: "Start earlier. Rise with the heat.", icon: "snowflake", active: state["control"]["mode"] == "cooler") { Task { await command(["command": "cooler"]) } }.disabled(!enabled)
                NativeFanProfileChoice(title: "Custom curve", detail: "Your temperature-to-speed balance.", icon: "sliders-horizontal", active: state["control"]["mode"] == "curve", opensPage: true) { tab = "curve" }
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 6) { NativeIcon("zap", size: 13, strokeWidth: 1.65).foregroundStyle(Theme.muted); Text("Quick boost").font(Theme.ui(13, weight: .medium)) }
                    Text("Maximum cooling, then back to automatic.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        NativeFanDurationMenu(value: $boost, values: NativeHardwareDisplayPolicies.boostDurations, label: durationLabel)
                        Button("Boost") { Task { await command(["command": "boost", "duration": .number(Double(boost))]) } }.disabled(!enabled)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1) }.padding(.top, 11)
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 6) { NativeIcon("hourglass", size: 13, strokeWidth: 1.65).foregroundStyle(Theme.muted); Text("Duration").font(Theme.ui(13, weight: .medium)) }
                    Text(durationDescription).font(Theme.ui(11)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        NativeFanDurationMenu(value: $duration, values: NativeHardwareDisplayPolicies.fanDurations, label: durationLabel)
                        Button("Set") { if let input = currentDurationCommand { Task { await command(input) } } }.disabled(!enabled || currentDurationCommand == nil)
                    }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading).overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1) }.padding(.top, 3)
            }
        }
    }
    private var sensors: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionIntro("Inside your Mac", "\(snapshot["sensors"].array.count) sensors. Every reading in view.")
            HStack { T3Field(placeholder: "Find a sensor…", text: $query, mono: true, leadingIcon: "search"); NativeMenuSelect(title: "Sensor group", selection: $group, options: ["All", "Favorites", "CPU", "GPU", "Battery", "Memory", "Storage", "System"].map { ($0, $0) }, width: 150); Button("Clear peaks") { peaks = [:]; rememberPeaks() } }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: 22, height: 1)
                        Text("Sensor").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Current").frame(width: 90, alignment: .trailing)
                        Text("Session peak").frame(width: 100, alignment: .trailing)
                    }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 18).padding(.vertical, 17).background(Theme.well)
                    ForEach(sensorRows, id: \.self["id"]) { sensor in
                        Rectangle().fill(Theme.border).frame(height: 1)
                        HStack(spacing: 12) {
                            Button {
                                let id = sensor["id"].string
                                if !favorites.insert(id).inserted { favorites.remove(id) }
                                if !runtime.paths.readOnly { UserDefaults.standard.set(Array(favorites).sorted(), forKey: "uniapi.fans.favorites") }
                            } label: {
                                NativeIcon("star", size: 14, strokeWidth: 1.65).foregroundStyle(favorites.contains(sensor["id"].string) ? Theme.warnFg : Theme.muted)
                            }.buttonStyle(.plain).frame(width: 22)
                                .accessibilityLabel("\(favorites.contains(sensor["id"].string) ? "Unfavorite" : "Favorite") \(sensorName(sensor["id"].string))")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sensorName(sensor["id"].string)).font(Theme.ui(12)).lineLimit(1)
                                Text(sensor["id"].string).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                            }.help(sensor["id"].string).frame(maxWidth: .infinity, alignment: .leading)
                            NativeNumberText(text: format(NativeHardwareDisplayPolicies.number(sensor["value"])), font: Theme.ui(15))
                                .frame(width: 90, alignment: .trailing)
                            Text(format(peaks[sensor["id"].string])).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                                .frame(width: 100, alignment: .trailing)
                        }.padding(.horizontal, 18).padding(.vertical, 17)
                    }
                    if sensorRows.isEmpty { NativeEmptyState(title: "No matching sensors", detail: "Try another group or search term.") }
                }
            }
        }
    }
    private var timeline: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) { Text("Cooling over time").font(Theme.ui(18, weight: .medium)).accessibilityAddTraits(.isHeader); Text("Recent detail. Long-term trends. Peaks preserved.").font(Theme.ui(12)).foregroundStyle(Theme.muted) }
            HStack { NativeMenuSelect(title: "History range", selection: $range, options: [("30m", "30 minutes"), ("1h", "1 hour"), ("6h", "6 hours"), ("24h", "24 hours"), ("7d", "7 days"), ("30d", "30 days"), ("90d", "90 days"), ("1y", "1 year"), ("all", "All time"), ("custom", "Custom")], width: 125); T3Segmented(options: [("mean", "Average"), ("max", "Peak"), ("min", "Minimum")], selection: statistic) { statistic = $0 }; Spacer(); Button("Refresh") { Task { await loadHistory() } }; Button("Export CSV") { exportHistory() }.disabled(history["points"].array.isEmpty) }
            if range == "custom" { HStack { DatePicker("From", selection: $from, in: ...through, displayedComponents: .date); DatePicker("Through", selection: $through, in: from...Date(), displayedComponents: .date) } }
            if let historyError { NativeError(message: historyError) }
            NativeCard(title: "Temperatures") { NativeLineChart(series: temperatureSeries, includeZero: false, xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) }, yFormat: { String(format: "%.1f°%@", $0, unit.uppercased()) }) }
            NativeCard(title: "Fan speeds") { NativeLineChart(series: fanSeries, xFormat: { Date(timeIntervalSince1970: $0 / 1000).formatted(date: .abbreviated, time: .shortened) }, yFormat: { String(format: "%.0f RPM", $0) }) }
            Text("Missing observations remain gaps. \(history["points"].array.count) buckets · ~\(ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file)) stored.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
            Text(historyCaption).font(Theme.ui(11)).foregroundStyle(Theme.muted)
        }
    }
    private var historyCaption: String {
        guard !history.isNull else { return "Reading selected history…" }
        let first = history["storage"]["first"]
        let since = first.isNull ? "Logging has started" : "Since " + Date(timeIntervalSince1970: first.double / 1000).formatted(date: .abbreviated, time: .shortened)
        let pending = history["storage"]["pending"].int
        let upgrade = pending > 0 ? "Upgrading \(pending) older readings" : "Daily history kept indefinitely"
        return "Buckets: \(Int(history["resolutionMs"].double / 1000)) seconds · \(since) · \(upgrade)"
    }
    private var temperatureSeries: [NativeChartSeries] {
        ["CPU", "GPU", "Battery"].map { group in NativeChartSeries(id: group, label: group, points: NativeFanHistory.discontinuousSamples(history["points"].array, kind: tab == "timeline" ? statistic : "mean").map { s in return NativeChartPoint(x: s["date"].double, y: temperature(group, sample: s).map { unit == "f" ? $0 * 1.8 + 32 : $0 }) }) }
    }
    private var fanSeries: [NativeChartSeries] {
        let ids = Set(history["points"].array.flatMap { $0[statistic]["fans"].array.map { $0["id"].int } }).sorted()
        return ids.map { id in NativeChartSeries(id: "fan-\(id)", label: "Fan \(id + 1)", points: NativeFanHistory.discontinuousSamples(history["points"].array, kind: statistic).map { s in let fan = s["fans"].array.first { $0["id"].int == id }; return NativeChartPoint(x: s["date"].double, y: fan.flatMap { NativeHardwareDisplayPolicies.number($0["actual"]) }) }) }
    }
    private var curveStudio: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) { curveIntroduction; Spacer(minLength: 8); applyCurveButton.fixedSize() }
                VStack(alignment: .leading, spacing: 12) { curveIntroduction; applyCurveButton }
            }
            Card(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top, spacing: 12) {
                        Text("Fan output")
                        Spacer(minLength: 0)
                        Text(curveReadout).monospacedDigit().multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }.font(Theme.ui(11)).foregroundStyle(Theme.muted).padding(.horizontal, 20).padding(.top, 16)
                    if contentWidth >= 700 {
                        HStack(alignment: .top, spacing: 0) {
                            curveChart.padding(20)
                            VStack(spacing: 0) { curvePointRows }.frame(width: 220).overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                        }
                    } else {
                        curveChart.padding(20)
                        Divider()
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)], spacing: 0) { curvePointRows }
                    }
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { curveFooter; Spacer(minLength: 8); curveTools }
                VStack(alignment: .leading, spacing: 12) { curveFooter; curveTools }
            }
            Text("Focus a chart point and use Left/Right for temperature or Up/Down for output.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
        }
    }
    private var curveIntroduction: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Draw your comfort zone").font(Theme.ui(18, weight: .medium)).accessibilityAddTraits(.isHeader)
            Text("Drag a point up for more cooling, or sideways to change when it starts. The curve follows the higher of the CPU die average and the hottest GPU sensor.").font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var curveReadout: String {
        if let index = draggingPoint ?? focusedCurvePoint, curve.indices.contains(index) {
            return String(format: "%.0f°C · %.0f%%", curve[index]["temperature"].double, curve[index]["percent"].double)
        }
        if let governing {
            return String(format: "Now %.0f°C · %.0f%% output", governing, NativeHardwareDisplayPolicies.fanCurvePercent(curve, temperature: governing))
        }
        return "Four points. Your balance."
    }
    private var applyCurveButton: some View { Button(state["control"]["mode"].string == "curve" ? "Apply changes" : "Use curve") { Task { await command(["command": "curve", "curve": .array(curve)]) } }.buttonStyle(T3Button(.primary)).disabled(!enabled) }
    @ViewBuilder private var curvePointRows: some View {
        ForEach(curve.indices, id: \.self) { index in
            if let bounds = NativeHardwareDisplayPolicies.curveBounds(curve, index: index) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(["Start cooling", "Comfort", "Performance", "Full cooling"][min(index, 3)]).font(Theme.ui(11)).foregroundStyle(Theme.muted)
                    HStack(spacing: 8) {
                        NativeCurveNumber(value: curve[index]["temperature"].double, unit: "°C", bounds: bounds.temperature, label: "Point \(index + 1) temperature Celsius") { updateCurve(index, temperature: $0, percent: curve[index]["percent"].double) }
                        Text("/").foregroundStyle(Theme.muted)
                        NativeCurveNumber(value: curve[index]["percent"].double, unit: "%", bounds: bounds.percent, disabled: index == 3, label: "Point \(index + 1) output percent") { updateCurve(index, temperature: curve[index]["temperature"].double, percent: $0) }
                    }
                    if showCurveSliders {
                        Slider(value: Binding(get: { curve[index]["percent"].double }, set: { updateCurve(index, temperature: curve[index]["temperature"].double, percent: $0) }), in: bounds.percent.lowerBound...max(bounds.percent.lowerBound + 1, bounds.percent.upperBound), step: 1)
                            .disabled(bounds.percent.lowerBound == bounds.percent.upperBound).accessibilityLabel("Point \(index + 1) output slider")
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            }
        }
    }
    private var curveFooter: some View {
        Text("Saved on this Mac. Full cooling by \(Int(curve.last?["temperature"].double ?? 90))°C. Apply to activate your changes.").font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
    }
    private var curveTools: some View {
        HStack(spacing: 8) {
            Button { showCurveSliders.toggle() } label: { HStack(spacing: 5) { NativeIcon("sliders-horizontal", size: 12, strokeWidth: 1.65); Text(showCurveSliders ? "Hide sliders" : "Show sliders") } }.buttonStyle(T3Button(.ghost))
            Button { curve = NativeHardwareDisplayPolicies.defaultFanCurve; saveCurve() } label: { HStack(spacing: 5) { NativeIcon("rotate-cw", size: 12, strokeWidth: 1.65); Text("Default curve") } }.buttonStyle(T3Button(.ghost))
        }.fixedSize()
    }
    private var curveChart: some View {
        Chart {
            ForEach(Array(curve.enumerated()), id: \.offset) { _, point in
                LineMark(x: .value("Temperature", point["temperature"].double), y: .value("Output", point["percent"].double)).foregroundStyle(Theme.accent)
                PointMark(x: .value("Temperature", point["temperature"].double), y: .value("Output", point["percent"].double)).foregroundStyle(Theme.accent).symbolSize(80).annotation(position: .top) { Text(String(format: "%.0f%%", point["percent"].double)).font(Theme.mono(10)) }
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
                        if let temperature = value.as(Double.self) { Text(String(format: "%.0f°C", temperature)).font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0.0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(Theme.grid)
                    AxisValueLabel {
                        if let percent = value.as(Double.self) { Text(String(format: "%.0f%%", percent)).font(Theme.ui(10)).foregroundStyle(Theme.muted).fixedSize(horizontal: true, vertical: false) }
                    }
                }
            }
            .frame(height: 330)
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
        VStack(alignment: .leading, spacing: 0) {
            sectionIntro("Make it yours", "Your display, menu bar and recording preferences.").padding(.bottom, 12)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 50, alignment: .topLeading), count: contentWidth >= 700 ? 2 : 1), alignment: .leading, spacing: 0) {
                fanSetting("Temperature unit", "Shared with the native menu bar.") {
                    T3Segmented(options: [("c", "Celsius"), ("f", "Fahrenheit")], selection: unit) { value in Task { await operation("preferences", ["unit": .string(value)]) } }
                }
                fanSetting("Menu bar display", "Keep the reading you care about in reach.") {
                    NativeMenuSelect(title: "Menu bar display", selection: Binding(get: { state["preferences"]["menuMetric"].string }, set: { value in Task { await operation("preferences", ["menuMetric": .string(value)]) } }), options: [("temperature", "Temperature"), ("rpm", "Fan RPM"), ("both", "Temperature and RPM"), ("icon", "Icon only")], width: 170)
                }
                fanSetting("History storage", "Detailed samples for up to \(history["storage"]["rawDays"].isNull ? 7 : history["storage"]["rawDays"].int) days, minute summaries for \(history["storage"]["minuteDays"].isNull ? 90 : history["storage"]["minuteDays"].int) days, and hourly summaries for \(history["storage"]["hourlyDays"].isNull ? 365 : history["storage"]["hourlyDays"].int) days. Daily averages and peaks stay indefinitely. Storage compacts sooner near the 500 MB target.") {
                    Text(history.isNull ? "Reading…" : "~" + ByteCountFormatter.string(fromByteCount: Int64(history["storage"]["bytes"].double), countStyle: .file)).font(Theme.mono(13))
                }
                fanSetting("Background logging", "Readings are saved while the UniApi service runs, including with the window closed. No readings can be captured while your Mac is asleep or shut down.") { HStack(spacing: 8) { NativeStatusDot(color: Theme.okFg); Text("Automatic").font(Theme.ui(12)).foregroundStyle(Theme.okFg) } }
                fanSetting("Fan control helper", state["daemon"]["installed"].bool ? "Installed as a background service.\(state["daemon"]["current"].bool ? " The helper is current." : " A newer helper is available; updating needs your password once.")" : "Install the helper once to avoid a temporary session and password prompt after every restart.") {
                    VStack(alignment: .leading, spacing: 8) {
                        if !state["daemon"]["installed"].bool || !state["daemon"]["current"].bool { Button(state["daemon"]["installed"].bool ? "Update helper" : "Install helper") { Task { await operation("install") } }.disabled(pending || runtime.paths.readOnly) }
                        if state["daemon"]["installed"].bool { Button("Remove helper") { Task { await operation("uninstall") } }.disabled(pending || runtime.paths.readOnly || !state["daemon"]["installed"].bool) }
                    }
                }
                fanSetting("Kept profile", state["keep"].isNull ? "Cooler, a custom curve and a manual speed with Duration set to Never are remembered and restored. A boost or timed speed ends as requested." : "Re-applied after restarting, waking and rebooting. Safety protection can release control at any time. Choose Automatic to stop keeping it.") {
                    HStack(spacing: 8) { NativeStatusDot(color: state["keep"].isNull ? Theme.muted : Theme.okFg); Text(state["keep"].isNull ? "Nothing kept" : NativeHardwareDisplayPolicies.fanModeName(state["keep"]["command"].string)).font(Theme.ui(12)).foregroundStyle(state["keep"].isNull ? Theme.muted : Theme.okFg) }
                }
                fanSetting("Protection stays active", "Hardware speed limits, thermal safeguards, timed overrides and connection recovery remain active for every profile and manual speed.") { EmptyView() }
            }
        }
    }
    private func fanSetting<Control: View>(_ title: String, _ description: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(Theme.ui(14, weight: .medium))
            Text(description).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            control()
        }.padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
    private func sectionIntro(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(Theme.ui(30, weight: .semibold)).tracking(-0.9).accessibilityAddTraits(.isHeader); Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.muted) }
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

private struct NativeFanProfileChoice: View {
    let title: String, detail: String, icon: String
    let active: Bool
    var opensPage = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                NativeIcon(icon, size: 16, strokeWidth: 1.65).foregroundStyle(active ? Theme.pairPalette[6] : Theme.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Theme.ui(13, weight: .medium))
                    Text(detail).font(Theme.ui(10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if opensPage { NativeIcon("arrow-up-right", size: 14, strokeWidth: 1.65).foregroundStyle(Theme.muted) }
                else if active { NativeIcon("check", size: 14, strokeWidth: 1.65).foregroundStyle(Theme.pairPalette[6]) }
            }.padding(.horizontal, 10).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .background(active ? Theme.pairPalette[6].opacity(0.06) : hovering ? Theme.subtle2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(active ? Theme.pairPalette[6].opacity(0.4) : .clear, lineWidth: 1) }
                .contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }.accessibilityAddTraits(active ? [.isSelected] : [])
    }
}

private struct NativeFanDurationMenu: View {
    @Binding var value: Int
    let values: [Int]
    let label: (Int) -> String
    var body: some View {
        Menu { ForEach(values, id: \.self) { option in Button(label(option)) { value = option } } } label: {
            HStack(spacing: 6) { if value == 0 { NativeIcon("infinity", size: 16, strokeWidth: 1.65).accessibilityLabel("Never") } else { Text(label(value)).font(Theme.ui(11)) }; Spacer(minLength: 0); NativeIcon("chevron-down", size: 12, strokeWidth: 1.65) }
                .padding(.horizontal, 8).frame(width: 100, height: 30)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                .overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1) }
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}
