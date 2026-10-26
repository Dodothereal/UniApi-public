import SwiftUI
import Charts
import UniApiCore
import UniApiPresentation

private struct NativeStatsPoint: Identifiable {
    let id: String, series: String, date: Date, value: Double
}

/// One retained projection per mounted component. Requests use value equality,
/// not a hash alone, so a refreshed payload cannot reuse stale chart readings.
/// Pointer/selection state lives below this boundary and never checks the JSON.
@MainActor private final class NativeStatsProjectionCache<Value> {
    private var request: [JSONValue]?
    private var cached: Value?

    func value(for request: [JSONValue], build: () -> Value) -> Value {
        if self.request == request, let cached { return cached }
        let result = build()
        self.request = request; cached = result
        return result
    }
}

private struct NativeStatsPlotProjection {
    let points: [NativeStatsPoint]
    let index: NativeStatsSampleIndex

    init(points: [NativeStatsPoint], label: (NativeStatsPoint) -> String,
         value: (Double) -> String, color: (NativeStatsPoint) -> Color,
         sampling: NativeStatsSampleIndex.Sampling = .nearest) {
        self.points = points
        index = NativeStatsSampleIndex(points: points, label: label, value: value, color: color, sampling: sampling)
    }
}

/// Preserve every mark. Only the inspection lookup is indexed: binary search
/// by date, then direct access to the exact measured values at that timestamp.
private final class NativeStatsSampleIndex {
    enum Sampling { case nearest, day, previous }
    let sampling: Sampling
    let dates: [Date]
    let lines: [Date: [NativeTooltipLine]]
    let readings: [Date: String]

    init(points: [NativeStatsPoint], label: (NativeStatsPoint) -> String,
         value: (Double) -> String, color: (NativeStatsPoint) -> Color, sampling: Sampling) {
        self.sampling = sampling
        var grouped: [Date: [NativeTooltipLine]] = [:]
        for point in points {
            grouped[point.date, default: []].append(NativeTooltipLine(
                label: label(point), value: value(point.value), color: color(point)))
        }
        lines = grouped
        dates = grouped.keys.sorted()
        readings = grouped.mapValues { $0.map { "\($0.label) \($0.value)" }.joined(separator: " · ") }
    }

    private func lowerBound(for date: Date) -> Int {
        var lower = 0, upper = dates.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if dates[middle] < date { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    func sample(at date: Date) -> Date? {
        guard !dates.isEmpty else { return nil }
        if sampling == .day {
            // Bar marks are day bins, not point samples at midnight. The latter
            // would report tomorrow during the second half of today's bar.
            let calendar = Calendar.current
            let lower = lowerBound(for: calendar.startOfDay(for: date))
            return lower < dates.count && calendar.isDate(dates[lower], inSameDayAs: date) ? dates[lower] : nil
        }
        let lower = lowerBound(for: date)
        if sampling == .previous {
            if lower < dates.count, dates[lower] == date { return dates[lower] }
            return lower > 0 ? dates[lower - 1] : nil
        }
        if lower == 0 { return dates[0] }
        if lower == dates.count { return dates[lower - 1] }
        return date.timeIntervalSince(dates[lower - 1]) <= dates[lower].timeIntervalSince(date)
            ? dates[lower - 1] : dates[lower]
    }

    func crosshairDate(for date: Date) -> Date {
        guard sampling == .day, let day = Calendar.current.dateInterval(of: .day, for: date) else { return date }
        return day.start.addingTimeInterval(day.duration / 2)
    }
}

/// Drag selection re-evaluates this small view; pointer movement only changes
/// the overlay below. Neither path reprojects data or sorts the ranking board.
private struct NativeStatsChartInspection<Plot: View>: View {
    let index: NativeStatsSampleIndex
    var readingFont: Font = Theme.ui(11)
    @ViewBuilder var plot: () -> Plot
    @State private var selected: Date?
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            plot()
                .chartXSelection(value: $selected)
                .chartOverlay { proxy in NativeStatsChartHover(proxy: proxy, index: index) }
            if let selected, let date = index.sample(at: selected) {
                Text("\(nativeStatsDate(date.timeIntervalSince1970 * 1000)): " + (index.readings[date] ?? ""))
                    .font(readingFont).textSelection(.enabled)
                    .transaction { $0.animation = nil }
            }
        }
        .onChange(of: ObjectIdentifier(index)) { _, _ in selected = nil }
        .onChange(of: visible) { _, visible in if !visible { selected = nil } }
    }
}

private struct NativeStatsChartHover: View {
    let proxy: ChartProxy
    let index: NativeStatsSampleIndex
    @State private var hovered: Date?
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame {
                let frame = geometry[anchor]
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            let next: Date?
                            switch phase {
                            case .active(let location):
                                if visible, frame.contains(location),
                                   let date: Date = proxy.value(atX: location.x - frame.minX) {
                                    next = index.sample(at: date)
                                } else { next = nil }
                            case .ended: next = nil
                            }
                            if next != hovered { hovered = next }
                        }
                    if visible, let hovered, let x = proxy.position(forX: index.crosshairDate(for: hovered)) {
                        Rectangle().fill(Theme.crosshair).frame(width: 1, height: frame.height)
                            .offset(x: frame.minX + x, y: frame.minY).allowsHitTesting(false)
                        let width = min(276, geometry.size.width)
                        NativeChartTooltip(title: nativeStatsDate(hovered.timeIntervalSince1970 * 1000),
                                           lines: index.lines[hovered] ?? [], width: width)
                            .offset(x: min(max(0, frame.minX + x + 12), max(0, geometry.size.width - width)),
                                    y: frame.minY + 6)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        // Inspection follows the pointer immediately, even under an ancestor's
        // incidental transaction. Plot entrances and value motion stay intact.
        .transaction { $0.animation = nil }
        .onChange(of: ObjectIdentifier(index)) { _, _ in hovered = nil }
        .onChange(of: visible) { _, visible in if !visible { hovered = nil } }
        .onDisappear { hovered = nil }
    }
}

private struct NativeStatsLegend: View {
    let entries: [NativeLegendEntry]
    @Binding var selection: String?
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        NativeScrollRail {
            ForEach(entries) { entry in
                let selected = selection == entry.id
                let included = selection == nil || selected
                Button { selection = selected ? nil : entry.id } label: {
                    HStack(spacing: 6) {
                        Capsule().fill(entry.color).frame(width: 10, height: 3)
                        Text(entry.label).font(Theme.mono(10)).lineLimit(1)
                    }
                    .foregroundStyle(included ? Theme.dim : Theme.muted)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(selected ? Theme.subtle2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(selected ? Theme.input : .clear))
                    .opacity(included ? 1 : 0.4)
                    .animation(reduceMotion || !visible ? nil : .easeOut(duration: 0.2), value: selection)
                }
                .buttonStyle(.plain).pointingHand().nativeStatsRowHover(radius: Theme.radiusSm)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .help(selected ? "Show every series" : "Show only " + entry.label)
            }
        }
    }
}
private func nativeStatsHarnessColor(_ source: String) -> Color {
    let palette = ["claude": "ec4899", "codex": "3b82f6", "antigravity": "f97316", "zcode": "f59e0b", "opencode": "a855f7", "dsh": "06b6d4"]
    return nativeStatsColor(palette[source] ?? "346bf1")
}
func nativeStatsColor(_ hex: String) -> Color {
    let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard text.count == 6, let value = UInt32(text, radix: 16) else { return Theme.accent }
    return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
}

struct NativeStatsDaily: View {
    let data: JSONValue, colors: JSONValue
    @AppStorage("uniapi.stats.measure") private var measure = "all"
    @State private var isolated: String?
    @State private var projection = NativeStatsProjectionCache<NativeStatsPlotProjection>()
    private var series: [String] { data["stackModels"].array.map(\.string) + (data["stackDropped"].int > 0 ? ["other"] : []) }
    private func amount(_ totals: JSONValue) -> Double { measure == "all" ? nativeStatsGrand(totals) : totals[measure == "messages" ? "messages" : measure == "thinking" ? "thinking" : "output"].double }
    private func project(series: [String], isolation: String?) -> NativeStatsPlotProjection {
        var result: [NativeStatsPoint] = []
        let included = Set(series)
        for day in data["days"].array {
            let stamp = day["day"].double, date = Date(timeIntervalSince1970: stamp / 1000)
            for name in series where isolation == nil || name == isolation {
                let value = name == "other" ? day["perModel"].object.reduce(0) { $0 + (included.contains($1.key) ? 0 : amount($1.value)) } : amount(day["perModel"][name])
                result.append(NativeStatsPoint(id: "\(stamp):\(name)", series: name, date: date, value: value))
            }
        }
        return NativeStatsPlotProjection(points: result, label: { $0.series }, value: nativeStatsCount,
                                         color: { $0.series == "other" ? Theme.muted : nativeStatsColor(colors[$0.series].string) }, sampling: .day)
    }
    var body: some View {
        let series = self.series
        let activeIsolation = isolated.flatMap { series.contains($0) ? $0 : nil }
        let chart = projection.value(for: [data["days"], data["stackModels"], data["stackDropped"], colors,
                                           .string(measure), activeIsolation.map(JSONValue.string) ?? .null]) {
            project(series: series, isolation: activeIsolation)
        }
        NativeCard {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { heading; Spacer(minLength: 8); measures }
            VStack(alignment: .leading, spacing: 10) { heading; measures }
        }
        NativeStatsChartInspection(index: chart.index) {
            Chart(chart.points) { p in BarMark(x: .value("Date", p.date, unit: .day), y: .value("Usage", p.value)).foregroundStyle(by: .value("Model", p.series)) }
                .chartForegroundStyleScale(domain: series, range: series.map { $0 == "other" ? Theme.muted : nativeStatsColor(colors[$0].string) })
                .chartLegend(.hidden).chartYAxis { AxisMarks(position: .trailing) }.frame(height: 225)
                .chartPlotStyle { plot in plot.nativeEntrance(.growVertical) }
                .accessibilityLabel("Daily \(measure) by model, dated records only")
        }
        NativeStatsLegend(entries: series.map { NativeLegendEntry(id: $0, label: $0 == "other" ? "\(data["stackDropped"].int) more" : $0.split(separator: "/").last.map(String.init) ?? $0, color: $0 == "other" ? Theme.muted : nativeStatsColor(colors[$0].string)) }, selection: Binding(get: { activeIsolation }, set: { isolated = $0 }))
        if data["stackDropped"].int > 0 { Text("\(data["stackDropped"].int) smaller models are combined into other.").foregroundStyle(Theme.muted) }
    }.onChange(of: series) { _, available in
        if let isolated, !available.contains(isolated) { self.isolated = nil }
    } }
    private var heading: some View { NativeChartHeading(title: "Tokens per day", caption: measure == "output" ? "Generated output per day, including reported reasoning tokens." : measure == "thinking" ? "Reported reasoning tokens per day. Some models do not provide this breakdown." : measure == "messages" ? "One count per API response, after de-duplicating the transcript." : "Every token read or written, per day, stacked by the model that handled it.") }
    private var measures: some View { T3Segmented(options: [("all", "All tokens"), ("output", "Output"), ("thinking", "Thinking"), ("messages", "Messages")], selection: measure) { measure = $0 } }
}

struct NativeStatsCumulative: View {
    let days: [JSONValue]
    @State private var measure = "tokens"
    @State private var projection = NativeStatsProjectionCache<NativeStatsPlotProjection>()
    private func project() -> NativeStatsPlotProjection {
        var running: Double = 0
        let points = days.map { day in running += measure == "tokens" ? nativeStatsGrand(day["totals"]) : day["totals"][measure == "output" ? "output" : "messages"].double; return NativeStatsPoint(id: "\(day["day"].double):\(measure)", series: measure, date: Date(timeIntervalSince1970: day["day"].double / 1000), value: running) }
        return NativeStatsPlotProjection(points: points, label: { $0.series }, value: nativeStatsCount, color: { _ in Theme.accent }, sampling: .previous)
    }
    var body: some View {
        let chart = projection.value(for: [.array(days), .string(measure)], build: project)
        NativeCard {
        HStack(alignment: .top, spacing: 16) {
            NativeChartHeading(title: "Cumulative usage", caption: "Running total from dated records in this range.")
            Spacer(minLength: 8)
            T3Segmented(options: [("tokens", "Tokens"), ("output", "Output"), ("messages", "Responses")], selection: measure) { measure = $0 }
        }
        NativeStatsChartInspection(index: chart.index, readingFont: Theme.ui(13)) {
            Chart(chart.points) { p in LineMark(x: .value("Day", p.date), y: .value("Cumulative", p.value)).foregroundStyle(Theme.accent) }
                .chartYAxis { AxisMarks(position: .trailing) }.frame(height: 225)
                .chartPlotStyle { plot in plot.nativeEntrance(.fade) }
        }
    } }
}

private struct NativeStatsSpeedRow: Identifiable {
    let id: [String]
    let data: JSONValue
    let label: String
    let coverage: String
    let color: Color
    let model: String?
    let metric: NativeStatsRateMetric
    var speed: Double? { NativeStatsThroughputPresentation.rate(data) }

    init(data: JSONValue, group: String, colors: JSONValue, metric: NativeStatsRateMetric) {
        self.data = data; self.metric = metric
        id = [group, data["source"].string, data["model"].string]
        label = group == "harnesses" ? nativeStatsSourceName(data["source"].string)
            : group == "pairs" ? "\(data["model"].string) · \(nativeStatsSourceName(data["source"].string))" : data["model"].string
        coverage = metric.coverage(data)
        color = group == "harnesses" ? nativeStatsHarnessColor(data["source"].string) : nativeStatsColor(colors[data["model"].string].string)
        model = group == "harnesses" ? nil : data["model"].string
    }
}

private struct NativeStatsSpeedRanking {
    let rows: [NativeStatsSpeedRow]
    let peak: Double
}

private struct NativeStatsSpeedTrend {
    let available: [String]
    let choice: String
    let names: [String]
    let isolation: String?
    let plot: NativeStatsPlotProjection
    let colors: [String: Color]
    let legend: [NativeLegendEntry]
}

private struct NativeStatsSpeedReading: View {
    let row: NativeStatsSpeedRow
    let peak: Double
    let selectModel: ((String) -> Void)?

    var body: some View {
        Group {
            if let model = row.model, let selectModel {
                Button { selectModel(model) } label: { reading }
                    .buttonStyle(.plain).pointingHand().accessibilityLabel("View statistics for \(model)")
            } else { reading }
        }
        .nativeStatsRowHover()
        .help(row.metric.timingDetail(row.data))
        .accessibilityValue(row.metric.title + ": " + (row.speed.map { String(format: "%.1f tokens per second", $0) } ?? "Unavailable") + ". " + row.coverage)
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.label).font(Theme.mono(12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).help(row.label)
                Text(row.coverage).font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
                Text(row.speed.map { String(format: "%.1f tok/s", $0) } ?? "—")
                    .font(Theme.mono(12, weight: .medium)).nativeStatsNumberTransition(row.speed)
                    .frame(width: 80, alignment: .trailing)
            }
            NativeGrowBar(fraction: (row.speed ?? 0) / peak, color: row.color)
        }.padding(.horizontal, 8).padding(.vertical, 8).contentShape(Rectangle())
    }
}

struct NativeStatsThroughput: View {
    let data: JSONValue, colors: JSONValue
    let availableWidth: CGFloat
    let selectModel: ((String) -> Void)?
    @State private var metric = NativeStatsRateMetric.streaming
    @State private var by = "models"
    @State private var trendBy = "models"
    @State private var seriesChoice = "top"
    @State private var isolated: String?
    @State private var ranking = NativeStatsProjectionCache<NativeStatsSpeedRanking>()
    @State private var trend = NativeStatsProjectionCache<NativeStatsSpeedTrend>()
    init(data: JSONValue, colors: JSONValue, availableWidth: CGFloat, modelDetail: Bool = false, selectModel: ((String) -> Void)? = nil) {
        self.data = data; self.colors = colors; self.availableWidth = availableWidth; self.selectModel = selectModel
        _by = State(initialValue: modelDetail ? "harnesses" : "models")
        _trendBy = State(initialValue: modelDetail ? "harnesses" : "models")
    }
    private var board: JSONValue { metric.board(data) }
    private func projectRanking() -> NativeStatsSpeedRanking {
        let rows = board[by].array.map { NativeStatsSpeedRow(data: $0, group: by, colors: colors, metric: metric) }.sorted {
            let a = $0.speed ?? -1, b = $1.speed ?? -1
            return a == b ? $0.label < $1.label : a > b
        }
        return NativeStatsSpeedRanking(rows: rows, peak: max(1, rows.compactMap(\.speed).max() ?? 0))
    }
    private func trendLabel(_ name: String) -> String { trendBy == "harnesses" ? nativeStatsSourceName(name) : name }
    private func projectTrend() -> NativeStatsSpeedTrend {
        let key = trendBy == "models" ? "model" : "source"
        let available = board[trendBy].array.filter { $0["timedResponses"].int > 0 && NativeStatsThroughputPresentation.rate($0) != nil }.sorted {
            let a = $0["timedResponses"].int, b = $1["timedResponses"].int
            return a == b ? $0[key].string < $1[key].string : a > b
        }.map { $0[key].string }
        let choice = seriesChoice == "top" || available.contains(where: { "series:" + $0 == seriesChoice }) ? seriesChoice : "top"
        let names = choice == "top" ? Array(available.prefix(8)) : available.filter { "series:" + $0 == choice }
        let isolation = isolated.flatMap { names.contains($0) ? $0 : nil }
        let legend = names.map { NativeLegendEntry(id: $0, label: trendLabel($0), color: trendBy == "harnesses" ? nativeStatsHarnessColor($0) : nativeStatsColor(colors[$0].string)) }
        let colorByName = Dictionary(legend.map { ($0.id, $0.color) }, uniquingKeysWith: { first, _ in first })
        var result: [NativeStatsPoint] = []
        var colorBySegment: [String: Color] = [:]
        for name in names where isolation == nil || isolation == name {
            var segment = 0, last: Double?
            for day in board["days"].array {
                let stamp = day["day"].double
                guard let value = NativeStatsThroughputPresentation.rate(day[trendBy][name]) else { segment += 1; last = nil; continue }
                if let last, stamp - last > 1.5 * 86_400_000 { segment += 1 }
                let series = "\(name):\(segment)"
                result.append(NativeStatsPoint(id: "\(name):\(stamp)", series: series, date: Date(timeIntervalSince1970: stamp / 1000), value: value))
                colorBySegment[series] = colorByName[name]; last = stamp
            }
        }
        let plot = NativeStatsPlotProjection(points: result, label: { point in
            let name = point.series.lastIndex(of: ":").map { String(point.series[..<$0]) } ?? point.series
            return trendLabel(name)
        }, value: { metric.title + ": " + String(format: "%.1f tok/s", $0) }, color: { colorBySegment[$0.series] ?? Theme.accent })
        return NativeStatsSpeedTrend(available: available, choice: choice, names: names, isolation: isolation,
                                     plot: plot, colors: colorBySegment, legend: legend)
    }
    var body: some View {
        let ranking = self.ranking.value(for: [board[by], .string(by), .string(metric.rawValue), colors], build: projectRanking)
        let trend = self.trend.value(for: [board[trendBy], board["days"], colors, .string(trendBy), .string(metric.rawValue),
                                          .string(seriesChoice), isolated.map(JSONValue.string) ?? .null], build: projectTrend)
        VStack(alignment: .leading, spacing: 14) {
        let summary = board["summary"]
        T3Segmented(options: NativeStatsRateMetric.allCases.map { ($0, $0.shortTitle) }, selection: metric) { metric = $0 }
            .accessibilityLabel("Speed measurement")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: availableWidth >= 780 ? 3 : 1), spacing: 10) {
            NativeStatsValueTile(label: metric.title, value: NativeStatsThroughputPresentation.rate(summary), unit: "tok/s", detail: metric == .streaming ? "Output ÷ matched streaming duration" : "Includes request latency; may be estimated", accent: nativeStatsColor("10b981"), format: { String(format: "%.1f", $0) })
            NativeStatsValueTile(label: metric == .streaming ? "Streaming clock coverage" : "Response timing coverage", value: summary["timedResponses"].isNull ? nil : summary["timedResponses"].double, detail: metric.coverage(summary))
            NativeStatsValueTile(label: metric == .streaming ? "Output with streaming timing" : "Output with response timing", value: summary["outputTokens"].isNull ? nil : summary["outputTokens"].double, detail: metric == .streaming ? "Only output matched to streaming clocks" : "\(summary["estimatedResponses"].int) responses timed from transcript boundaries", format: nativeStatsCount)
        }
        NativeCard {
        NativeChartHeading(title: metric.title, caption: metric.caption)
        T3Segmented(options: [("models", "Models"), ("harnesses", "Harnesses"), ("pairs", "Model + harness")], selection: by) { by = $0 }
        if summary["timedResponses"].int == 0 { NativeEmptyState(title: metric.emptyTitle, detail: metric == .streaming ? "Token totals are preserved. Missing streaming clocks remain unknown; response averages use a separate timing basis." : "Token totals are preserved. Missing response durations remain unavailable.") }
        if !ranking.rows.isEmpty {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(ranking.rows) { row in
                        NativeStatsSpeedReading(row: row, peak: ranking.peak, selectModel: selectModel)
                    }
                }.accessibilityElement(children: .contain)
            }.frame(height: min(420, CGFloat(ranking.rows.count) * 44)).scrollIndicators(.visible)
        } else if summary["timedResponses"].int > 0 {
            NativeEmptyState(title: "No responses in this range", detail: "Choose a longer range or another coding harness.")
        }
        }
        NativeCard {
        NativeChartHeading(title: metric == .streaming ? "Streaming speed over time" : "Response average over time", caption: "Daily output ÷ daily \(metric.durationName). Gaps indicate days without matching clocks." + (metric == .response ? " Includes request latency; timings may be estimated." : " Reported or host-observed streaming clocks.") + (trend.choice == "top" && trend.available.count > 8 ? " Showing the 8 most sampled series; \(trend.available.count - 8) more are available in the picker." : ""))
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { trendGroups; seriesPicker(trend) }
            VStack(alignment: .leading, spacing: 8) { trendGroups; seriesPicker(trend) }
        }
        if !trend.plot.points.isEmpty {
            NativeStatsChartInspection(index: trend.plot.index) {
                Chart(trend.plot.points) { p in
                    LineMark(x: .value("Day", p.date), y: .value(metric.title, p.value), series: .value("Series", p.series)).foregroundStyle(trend.colors[p.series] ?? Theme.accent).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).interpolationMethod(.monotone)
                    PointMark(x: .value("Day", p.date), y: .value(metric.title, p.value)).foregroundStyle(trend.colors[p.series] ?? Theme.accent).symbolSize(12)
                }
                .chartLegend(.hidden).chartYAxis { AxisMarks(position: .trailing) }.frame(height: 225)
                .chartPlotStyle { plot in plot.nativeEntrance(.fade) }
                .accessibilityLabel("Daily " + metric.title + " for " + trend.names.filter { trend.isolation == nil || $0 == trend.isolation }.map(trendLabel).joined(separator: ", "))
            }
            NativeStatsLegend(entries: trend.legend, selection: Binding(get: { trend.isolation }, set: { isolated = $0 }))
        } else { NativeEmptyState(title: metric.emptyTitle, detail: metric == .streaming ? "Token usage is retained. Days without streaming clocks are left unplotted." : "Token usage is retained. Response averages need usable response durations.") }
        }
    }.onChange(of: trendBy) { _, _ in seriesChoice = "top"; isolated = nil }
        .onChange(of: metric) { _, _ in seriesChoice = "top"; isolated = nil }
        .onChange(of: seriesChoice) { _, _ in isolated = nil }
        .onChange(of: trend.available) { _, _ in if trend.choice != seriesChoice { seriesChoice = "top" } }
        .onChange(of: trend.names) { _, available in if let isolated, !available.contains(isolated) { self.isolated = nil } } }
    private var trendGroups: some View {
        T3Segmented(options: [("models", "Models"), ("harnesses", "Harnesses")], selection: trendBy) { trendBy = $0 }
    }
    private func seriesPicker(_ trend: NativeStatsSpeedTrend) -> some View {
        Menu {
            Button("Most sampled") { seriesChoice = "top" }
            ForEach(trend.available, id: \.self) { name in Button(trendLabel(name)) { seriesChoice = "series:" + name } }
        } label: { NativeStatsMenuLabel(title: trend.choice == "top" ? "Most sampled" : trend.names.first.map(trendLabel) ?? "Most sampled", width: 220).nativeStatsRowHover() }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Choose a speed series").accessibilityLabel("Choose a speed series")
    }
}

private struct NativeStatsBenchmarkProjection {
    let plot: NativeStatsPlotProjection
    let keys: [String]
    let isolation: String?
}

struct NativeStatsBenchmark: View {
    let data: JSONValue
    @AppStorage("uniapi.stats.ttft.log") private var logarithmic = true
    @State private var isolated: String?
    @State private var projection = NativeStatsProjectionCache<NativeStatsBenchmarkProjection>()
    private func project() -> NativeStatsBenchmarkProjection {
        let keys = Array(Set(data["trend"].array.map { $0["key"].string })).sorted()
        let isolation = isolated.flatMap { keys.contains($0) ? $0 : nil }
        let points = data["trend"].array.filter {
            (isolation == nil || $0["key"].string == isolation) && (!logarithmic || $0["ms"].double > 0)
        }.map {
            NativeStatsPoint(id: $0["key"].string + $0["runId"].string, series: $0["key"].string,
                             date: Date(timeIntervalSince1970: $0["at"].double / 1000), value: $0["ms"].double)
        }
        return NativeStatsBenchmarkProjection(plot: NativeStatsPlotProjection(points: points, label: { $0.series },
            value: { String(format: "%.0f ms", $0) }, color: { Theme.pairColor($0.series) }), keys: keys, isolation: isolation)
    }
    var body: some View {
        let chart = projection.value(for: [data["trend"], .bool(logarithmic), isolated.map(JSONValue.string) ?? .null], build: project)
        Group {
        if data["spend"]["calls"].int > 0 { NativeCard {
            let s = data["spend"]
            NativeChartHeading(title: "What the benchmark spent", caption: "Tokens UniApi's own measuring pushed through each provider. Separate from coding-app usage.")
            HStack {
                spendReading("Benchmark tokens", nativeStatsCount(s["input"].double + s["output"].double), value: s["input"].double + s["output"].double)
                spendReading("Calls", nativeStatsCount(s["calls"].double) + " · \(s["runs"].int) runs · \(s["pairs"].array.count) targets")
                spendReading("Estimated coverage", s["calls"].double > 0 ? String(format: "%.1f%%", s["estimated"].double * 100 / s["calls"].double) : "—", value: s["calls"].double > 0 ? s["estimated"].double * 100 / s["calls"].double : nil)
            }
            Text("Input \(nativeStatsCount(s["input"].double)) · output \(nativeStatsCount(s["output"].double)) · reasoning \(nativeStatsCount(s["reasoning"].double)) inside output · cached \(nativeStatsCount(s["cached"].double)) inside input")
            ForEach(Array(s["pairs"].array.enumerated()), id: \.offset) { _, p in HStack { Text("\(p["model"].string) · \(p["providerName"].string)").lineLimit(1).help(p["model"].string); Spacer(); Text("\(nativeStatsCount(p["input"].double)) in / \(nativeStatsCount(p["output"].double)) out · \(p["calls"].int) calls").font(Theme.mono(11)) }.nativeStatsRowHover() }
        } }
        if !data["trend"].array.isEmpty { NativeCard {
            HStack(alignment: .top, spacing: 16) {
                NativeChartHeading(title: "First token over time", caption: "Median successful latency per provider/model/run. A rising line is a provider getting slower.")
                Spacer(minLength: 8)
                T3Segmented(options: [(true, "Log"), (false, "Linear")], selection: logarithmic) { logarithmic = $0 }
            }
            NativeStatsChartInspection(index: chart.plot.index) {
                Chart(chart.plot.points) { p in LineMark(x: .value("Date", p.date), y: .value("Median ms", p.value)).foregroundStyle(by: .value("Provider / model", p.series)); PointMark(x: .value("Date", p.date), y: .value("Median ms", p.value)).foregroundStyle(by: .value("Provider / model", p.series)) }
                    .chartForegroundStyleScale(domain: chart.keys, range: chart.keys.map { Theme.pairColor($0) })
                    .chartYScale(type: logarithmic ? .log : .linear).chartLegend(.hidden).chartYAxis { AxisMarks(position: .trailing) }.frame(height: 225)
                    .chartPlotStyle { plot in plot.nativeEntrance(.fade) }
            }
            ScrollView(.horizontal) { HStack { ForEach(chart.keys, id: \.self) { key in
                Button(key) { isolated = chart.isolation == key ? nil : key }
                    .buttonStyle(.plain).font(Theme.mono(10)).opacity(chart.isolation == nil || chart.isolation == key ? 1 : 0.4)
                    .nativeStatsRowHover(radius: Theme.radiusSm).pointingHand()
                    .accessibilityAddTraits(chart.isolation == key ? [.isSelected] : [])
                    .help(chart.isolation == key ? "Show every series" : "Show only " + key)
            } } }
            Text("Median successful latency samples per provider/model/run. Benchmark history is separate from coding usage.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
        } }
        }.onChange(of: chart.keys) { _, available in
            if let isolated, !available.contains(isolated) { self.isolated = nil }
        }
    }
    private func spendReading(_ label: String, _ reading: String, value: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.muted)
            Text(reading).font(Theme.mono(18, weight: .semibold)).monospacedDigit().lineLimit(1)
                .nativeStatsNumberTransition(value)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
}
