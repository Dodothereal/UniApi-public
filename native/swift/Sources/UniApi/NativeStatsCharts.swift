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
    /// The value ruler: a domain from zero, labelled ticks and the short
    /// graduations between them. Stacked plots measure each day's sum.
    let yDomain: ClosedRange<Double>
    let yMajors: [Double]
    let yMinors: [Double]
    /// One short tick per day while days are wide enough to count.
    let minor: Calendar.Component

    init(points: [NativeStatsPoint], label: (NativeStatsPoint) -> String,
         value: (Double) -> String, color: (NativeStatsPoint) -> Color,
         sampling: NativeStatsSampleIndex.Sampling = .nearest, stacked: Bool = false) {
        self.points = points
        index = NativeStatsSampleIndex(points: points, label: label, value: value, color: color,
                                       sampling: sampling, totals: stacked)
        var heights: [Double]
        if stacked {
            var sums: [Date: Double] = [:]
            for point in points { sums[point.date, default: 0] += max(0, point.value) }
            heights = Array(sums.values)
        } else { heights = points.map(\.value) }
        if heights.isEmpty { heights = [0] }
        yDomain = NativeChartMath.domain(heights)
        yMajors = NativeChartMath.ticks(yDomain)
        yMinors = NativeChartMath.minorTicks(yMajors, in: yDomain)
        let span = (index.dates.last?.timeIntervalSince(index.dates.first ?? Date()) ?? 0) / 86_400
        minor = span <= 100 ? .day : span <= 800 ? .weekOfYear : .month
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
    let totals: [Date: String]

    init(points: [NativeStatsPoint], label: (NativeStatsPoint) -> String,
         value: (Double) -> String, color: (NativeStatsPoint) -> Color, sampling: Sampling, totals: Bool = false) {
        self.sampling = sampling
        var grouped: [Date: [NativeTooltipLine]] = [:]
        var sums: [Date: Double] = [:]
        for point in points {
            if totals { sums[point.date, default: 0] += point.value }
            // A stacked day lists only the series that measured something.
            if totals && point.value <= 0 { grouped[point.date, default: []] += []; continue }
            grouped[point.date, default: []].append(NativeTooltipLine(
                label: label(point), value: value(point.value), color: color(point)))
        }
        lines = grouped
        dates = grouped.keys.sorted()
        readings = grouped.mapValues { $0.map { "\($0.label) \($0.value)" }.joined(separator: " · ") }
        self.totals = sums.mapValues(value)
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
    @ViewBuilder var plot: () -> Plot
    @State private var selected: Date?
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            plot()
                .chartXSelection(value: $selected)
                .chartOverlay { proxy in NativeStatsChartHover(proxy: proxy, index: index) }
            if let selected, let date = index.sample(at: selected) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Theme.signal.frame(width: 2, height: 9)
                    Text("\(nativeStatsDate(date.timeIntervalSince1970 * 1000)): " + (index.readings[date] ?? ""))
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.dim).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
                        Rectangle().fill(Theme.signal).frame(width: 1, height: frame.height)
                            .offset(x: frame.minX + x, y: frame.minY).allowsHitTesting(false)
                        let width = min(276, geometry.size.width)
                        NativeChartTooltip(title: nativeStatsDate(hovered.timeIntervalSince1970 * 1000),
                                           lines: index.lines[hovered] ?? [], width: width,
                                           detail: index.totals[hovered] ?? "")
                            .offset(x: NativeChartTooltipPlacement.x(anchor: frame.minX + x, width: width, container: geometry.size.width),
                                    y: frame.minY + 6)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        // Inspection follows the pointer immediately, even under an ancestor's
        // incidental transaction. Value motion stays intact.
        .transaction { $0.animation = nil }
        .onChange(of: ObjectIdentifier(index)) { _, _ in hovered = nil }
        .onChange(of: visible) { _, visible in if !visible { hovered = nil } }
        .onDisappear { hovered = nil }
    }
}

/// The scan assigns every model one of twelve series slots. The slot, not the
/// service's own hex, picks the hue, so plots stay on the Meter series palette.
private let nativeStatsSeriesSlots = ["3b82f6", "f97316", "10b981", "a855f7", "f59e0b", "ec4899",
                                      "06b6d4", "84cc16", "ef4444", "6366f1", "d946ef", "eab308"]
func nativeStatsColor(_ hex: String) -> Color {
    let text = (hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).lowercased()
    if let slot = nativeStatsSeriesSlots.firstIndex(of: text) { return Theme.pairPalette[slot % Theme.pairPalette.count] }
    return text.isEmpty ? Theme.muted : Theme.pairColor(text)
}
func nativeStatsHarnessColor(_ source: String) -> Color {
    let slots = ["claude": 5, "codex": 0, "antigravity": 1, "zcode": 4, "opencode": 3, "dsh": 6]
    return slots[source].map { Theme.pairPalette[$0] } ?? Theme.pairColor(source)
}
/// Each key keeps its stable pair hue; when two keys in one plot land on the
/// same hue, the later one moves to the next free slot so lines stay distinct.
func nativeStatsDistinctColors(_ keys: [String]) -> [String: Color] {
    let palette = Theme.pairPalette
    var taken = Set<Int>(), result: [String: Color] = [:]
    for key in keys {
        let home = palette.firstIndex(of: Theme.pairColor(key)) ?? 0
        var slot = home
        if taken.count < palette.count { while taken.contains(slot) { slot = (slot + 1) % palette.count } }
        taken.insert(slot)
        result[key] = palette[slot]
    }
    return result
}
private func nativeStatsRate(_ value: Double) -> String { String(format: "%.1f", value) }

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
                                         color: { $0.series == "other" ? Theme.muted : nativeStatsColor(colors[$0.series].string) },
                                         sampling: .day, stacked: true)
    }
    private var hint: String {
        measure == "output" ? "Generated output, reported reasoning included"
            : measure == "thinking" ? "Reported reasoning tokens; some models do not report them"
            : measure == "messages" ? "One count per API response, de-duplicated"
            : "Every token read or written, stacked by model"
    }
    var body: some View {
        let series = self.series
        let activeIsolation = isolated.flatMap { series.contains($0) ? $0 : nil }
        let chart = projection.value(for: [data["days"], data["stackModels"], data["stackDropped"], colors,
                                           .string(measure), activeIsolation.map(JSONValue.string) ?? .null]) {
            project(series: series, isolation: activeIsolation)
        }
        NativeStatsBand(title: "Per day", hint: hint) {
            Stops(options: [("all", "All tokens"), ("output", "Output"), ("thinking", "Thinking"), ("messages", "Messages")], selection: measure) { measure = $0 }
        } content: {
            Well {
                VStack(alignment: .leading, spacing: 14) {
                    NativeStatsChartInspection(index: chart.index) {
                        Chart(chart.points) { p in
                            BarMark(x: .value("Date", p.date, unit: .day), y: .value("Usage", p.value))
                                .foregroundStyle(by: .value("Model", p.series)).cornerRadius(0)
                        }
                        .chartForegroundStyleScale(domain: series, range: series.map { $0 == "other" ? Theme.muted : nativeStatsColor(colors[$0].string) })
                        .chartYScale(domain: chart.yDomain)
                        .chartXAxis { NativeChartAxis.dates(minor: chart.minor) }
                        .chartYAxis { NativeChartAxis.numeric(chart.yMajors, minors: chart.yMinors, position: .trailing, format: NativeNumberFormat.compact) }
                        .chartLegend(.hidden).chartPlotStyle { plot in plot.nativePlotSpine() }
                        .frame(height: 232)
                        .accessibilityLabel("Daily \(measure) by model, dated records only")
                    }
                    NativeChartLegend(entries: series.map { NativeLegendEntry(id: $0, label: $0 == "other" ? "\(data["stackDropped"].int) more" : $0.split(separator: "/").last.map(String.init) ?? $0, color: $0 == "other" ? Theme.muted : nativeStatsColor(colors[$0].string)) },
                                      selection: Binding(get: { activeIsolation }, set: { isolated = $0 }))
                    if data["stackDropped"].int > 0 {
                        Text("\(data["stackDropped"].int) smaller models are combined into one series.")
                            .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .onChange(of: series) { _, available in
            if let isolated, !available.contains(isolated) { self.isolated = nil }
        }
    }
}

struct NativeStatsCumulative: View {
    let days: [JSONValue]
    @State private var measure = "tokens"
    @State private var projection = NativeStatsProjectionCache<NativeStatsPlotProjection>()
    private func project() -> NativeStatsPlotProjection {
        var running: Double = 0
        let points = days.map { day in running += measure == "tokens" ? nativeStatsGrand(day["totals"]) : day["totals"][measure == "output" ? "output" : "messages"].double; return NativeStatsPoint(id: "\(day["day"].double):\(measure)", series: measure, date: Date(timeIntervalSince1970: day["day"].double / 1000), value: running) }
        return NativeStatsPlotProjection(points: points, label: { $0.series }, value: nativeStatsCount, color: { _ in Theme.ink }, sampling: .previous)
    }
    var body: some View {
        let chart = projection.value(for: [.array(days), .string(measure)], build: project)
        NativeStatsBand(title: "Running total", hint: "From dated records in this range") {
            Stops(options: [("tokens", "Tokens"), ("output", "Output"), ("messages", "Responses")], selection: measure) { measure = $0 }
        } content: {
            Well {
                NativeStatsChartInspection(index: chart.index) {
                    Chart(chart.points) { p in
                        LineMark(x: .value("Day", p.date), y: .value("Cumulative", p.value))
                            .foregroundStyle(Theme.ink)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .round))
                            .interpolationMethod(.stepEnd)
                    }
                    .chartYScale(domain: chart.yDomain)
                    .chartXAxis { NativeChartAxis.dates(minor: chart.minor) }
                    .chartYAxis { NativeChartAxis.numeric(chart.yMajors, minors: chart.yMinors, position: .trailing, format: NativeNumberFormat.compact) }
                    .chartLegend(.hidden).chartPlotStyle { plot in plot.nativePlotSpine() }
                    .frame(height: 200)
                    .accessibilityLabel("Cumulative \(measure) over the selected range")
                }
            }
        }
    }
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
    let compact: Bool
    let selectModel: ((String) -> Void)?

    var body: some View {
        Group {
            if let model = row.model, let selectModel {
                LedgerRow(action: { selectModel(model) }) { reading }
                    .accessibilityLabel("View statistics for \(model)")
            } else { LedgerRow { reading } }
        }
        .help(row.metric.timingDetail(row.data))
        .accessibilityValue(row.metric.title + ": " + (row.speed.map { String(format: "%.1f tokens per second", $0) } ?? "Unavailable") + ". " + row.coverage)
    }

    private var reading: some View {
        HStack(alignment: .center, spacing: 12) {
            NativeSeriesTick(color: row.color)
            Text(row.label).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !compact {
                Text(row.coverage).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    .frame(width: 236, alignment: .leading)
            }
            Scale(fraction: (row.speed ?? 0) / peak, color: row.color).frame(width: compact ? 88 : 200)
            Text(row.speed.map(nativeStatsRate) ?? "--")
                .font(Theme.readout(17)).monospacedDigit().foregroundStyle(row.speed == nil ? Theme.faint : Theme.ink)
                .nativeStatsNumberTransition(row.speed)
                .frame(width: 56, alignment: .trailing)
        }
    }
}

struct NativeStatsThroughput: View {
    let data: JSONValue, colors: JSONValue
    let compact: Bool
    let selectModel: ((String) -> Void)?
    @State private var metric = NativeStatsRateMetric.streaming
    @State private var by = "models"
    @State private var trendBy = "models"
    @State private var seriesChoice = "top"
    @State private var isolated: String?
    @State private var showsAll = false
    @State private var ranking = NativeStatsProjectionCache<NativeStatsSpeedRanking>()
    @State private var trend = NativeStatsProjectionCache<NativeStatsSpeedTrend>()
    init(data: JSONValue, colors: JSONValue, compact: Bool, modelDetail: Bool = false, selectModel: ((String) -> Void)? = nil) {
        self.data = data; self.colors = colors; self.compact = compact; self.selectModel = selectModel
        _by = State(initialValue: modelDetail ? "harnesses" : "models")
        _trendBy = State(initialValue: modelDetail ? "harnesses" : "models")
    }
    private var board: JSONValue { metric.board(data) }
    private func projectRanking() -> NativeStatsSpeedRanking {
        let available = metric == .streaming ? NativeStatsThroughputPresentation.measuredRows(board[by].array) : board[by].array
        let rows = available.map { NativeStatsSpeedRow(data: $0, group: by, colors: colors, metric: metric) }.sorted {
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
        }, value: { String(format: "%.1f tok/s", $0) }, color: { colorBySegment[$0.series] ?? Theme.muted })
        return NativeStatsSpeedTrend(available: available, choice: choice, names: names, isolation: isolation,
                                     plot: plot, colors: colorBySegment, legend: legend)
    }
    private var groupTitle: String { by == "harnesses" ? "Harness" : by == "pairs" ? "Model and harness" : "Model" }
    var body: some View {
        let ranking = self.ranking.value(for: [board[by], .string(by), .string(metric.rawValue), colors], build: projectRanking)
        let trend = self.trend.value(for: [board[trendBy], board["days"], colors, .string(trendBy), .string(metric.rawValue),
                                          .string(seriesChoice), isolated.map(JSONValue.string) ?? .null], build: projectTrend)
        let summary = board["summary"]
        NativeStatsBand(title: "Speed", hint: metric == .streaming ? "Output over matched streaming time" : "Output over elapsed response time, latency included") {
            Stops(options: NativeStatsRateMetric.allCases.map { ($0, $0.shortTitle) }, selection: metric) { metric = $0 }
                .accessibilityLabel("Speed measurement")
        } content: {
            if metric == .streaming && !NativeStatsThroughputPresentation.hasMeasurements(board) {
                let fallback = NativeStatsThroughputPresentation.hasMeasurements(data)
                Blank(icon: "gauge", title: "Streaming speed needs token-arrival timestamps",
                      detail: "These responses have token totals but no matching streaming clock. That is a limit of the history, not zero speed. Antigravity and DeepSeek Harness can supply streaming clocks."
                        + (fallback ? " Response averages include latency and are a different measurement." : ""),
                      actionTitle: fallback ? "Show response averages instead" : nil, actionIcon: "timer", primary: false,
                      action: fallback ? { metric = .response } : nil)
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    ReadoutStrip(minimum: 180) {
                        NativeStatsReadout(label: metric.title, value: NativeStatsThroughputPresentation.rate(summary), unit: "tok/s",
                                           detail: metric == .streaming ? "" : "May be estimated from transcript boundaries",
                                           format: nativeStatsRate)
                        NativeStatsReadout(label: metric == .streaming ? "Clock coverage" : "Timing coverage",
                                           value: summary["timedResponses"].isNull ? nil : summary["timedResponses"].double,
                                           unit: "responses", detail: metric.coverage(summary))
                        NativeStatsReadout(label: "Timed output",
                                           value: summary["outputTokens"].isNull ? nil : summary["outputTokens"].double, unit: "tokens",
                                           detail: metric == .streaming ? "Only output matched to streaming clocks" : "\(summary["estimatedResponses"].int) responses timed from transcript boundaries",
                                           format: nativeStatsCount)
                    }
                    .help(metric.caption)
                    rankingLedger(ranking, summary: summary)
                    trendPlot(trend)
                }
            }
        }
        .onChange(of: trendBy) { _, _ in seriesChoice = "top"; isolated = nil }
        .onChange(of: metric) { _, _ in seriesChoice = "top"; isolated = nil }
        .onChange(of: seriesChoice) { _, _ in isolated = nil }
        .onChange(of: trend.available) { _, _ in if trend.choice != seriesChoice { seriesChoice = "top" } }
        .onChange(of: trend.names) { _, available in if let isolated, !available.contains(isolated) { self.isolated = nil } }
    }

    @ViewBuilder private func rankingLedger(_ ranking: NativeStatsSpeedRanking, summary: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                MicroLabel("Fastest first")
                Spacer(minLength: 8)
                Stops(options: [("models", "Models"), ("harnesses", "Harnesses"), ("pairs", "Model + harness")], selection: by) { by = $0 }
            }
            .padding(.bottom, 6)
            if summary["timedResponses"].int == 0 {
                Blank(icon: "timer", title: metric.emptyTitle,
                      detail: metric == .streaming ? "Token totals are preserved. Missing streaming clocks remain unknown; response averages use a separate timing basis." : "Token totals are preserved. Missing response durations remain unavailable.")
            }
            if !ranking.rows.isEmpty {
                LedgerHead {
                    MicroLabel(groupTitle).frame(maxWidth: .infinity, alignment: .leading)
                    if !compact { MicroLabel("Coverage").frame(width: 236, alignment: .leading) }
                    Color.clear.frame(width: compact ? 88 : 200, height: 1)
                    MicroLabel("Tok/s").frame(width: 56, alignment: .trailing)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(showsAll ? ranking.rows : Array(ranking.rows.prefix(8))) { row in
                        NativeStatsSpeedReading(row: row, peak: ranking.peak, compact: compact, selectModel: selectModel)
                    }
                }.accessibilityElement(children: .contain)
                if ranking.rows.count > 8 {
                    Button(showsAll ? "Show the fastest 8" : "Show all \(ranking.rows.count)") { showsAll.toggle() }
                        .buttonStyle(Press(.quiet)).padding(.leading, -8).padding(.top, 6)
                }
                if metric == .streaming && board[by].array.count > ranking.rows.count {
                    Text("\(board[by].array.count - ranking.rows.count) more entries have token totals without a usable streaming clock.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).padding(.top, 8)
                }
            } else if summary["timedResponses"].int > 0 {
                Blank(icon: "timer", title: "No responses in this range", detail: "Choose a longer range or another coding harness.")
            }
        }
    }

    @ViewBuilder private func trendPlot(_ trend: NativeStatsSpeedTrend) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { trendCaption; Spacer(minLength: 8); trendGroups; seriesPicker(trend) }
                VStack(alignment: .leading, spacing: 8) { trendCaption; HStack(spacing: 12) { trendGroups; seriesPicker(trend) } }
            }
            if !trend.plot.points.isEmpty {
                Well {
                    VStack(alignment: .leading, spacing: 14) {
                        NativeStatsChartInspection(index: trend.plot.index) {
                            Chart(trend.plot.points) { p in
                                LineMark(x: .value("Day", p.date), y: .value(metric.title, p.value), series: .value("Series", p.series))
                                    .foregroundStyle(trend.colors[p.series] ?? Theme.muted)
                                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .miter)).interpolationMethod(.linear)
                                PointMark(x: .value("Day", p.date), y: .value(metric.title, p.value))
                                    .foregroundStyle(trend.colors[p.series] ?? Theme.muted).symbol(.square).symbolSize(14)
                            }
                            .chartYScale(domain: trend.plot.yDomain)
                            .chartXAxis { NativeChartAxis.dates(minor: trend.plot.minor) }
                            .chartYAxis { NativeChartAxis.numeric(trend.plot.yMajors, minors: trend.plot.yMinors, position: .trailing, format: NativeNumberFormat.compact) }
                            .chartLegend(.hidden).chartPlotStyle { plot in plot.nativePlotSpine() }
                            .frame(height: 216)
                            .accessibilityLabel("Daily " + metric.title + " for " + trend.names.filter { trend.isolation == nil || $0 == trend.isolation }.map(trendLabel).joined(separator: ", "))
                        }
                        NativeChartLegend(entries: trend.legend, selection: Binding(get: { trend.isolation }, set: { isolated = $0 }))
                    }
                }
                if trend.choice == "top" && trend.available.count > 8 {
                    Text("Showing the 8 most sampled series; \(trend.available.count - 8) more are in the picker.")
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                }
            } else {
                Blank(icon: "chart-line", title: metric.emptyTitle,
                      detail: metric == .streaming ? "Token usage is retained. Days without streaming clocks are left unplotted." : "Token usage is retained. Response averages need usable response durations.")
            }
        }
    }
    private var trendCaption: some View {
        MicroLabel(metric == .streaming ? "Streaming speed per day" : "Response average per day")
            .help("Daily output ÷ daily \(metric.durationName). Gaps indicate days without matching clocks." + (metric == .response ? " Includes request latency; timings may be estimated." : " Reported or host-observed streaming clocks."))
    }
    private var trendGroups: some View {
        Stops(options: [("models", "Models"), ("harnesses", "Harnesses")], selection: trendBy) { trendBy = $0 }
    }
    private func seriesPicker(_ trend: NativeStatsSpeedTrend) -> some View {
        Pick(title: "Choose a speed series",
             selection: Binding(get: { trend.choice }, set: { seriesChoice = $0 }),
             options: [(value: "top", label: "Most sampled")] + trend.available.map { (value: "series:" + $0, label: trendLabel($0)) },
             width: compact ? 180 : 220)
            .help("Choose a speed series")
    }
}

private struct NativeStatsBenchmarkProjection {
    let plot: NativeStatsPlotProjection
    let keys: [String]
    let labels: [String: String]
    let colors: [String: Color]
    let isolation: String?
    /// The latency ruler: a padded positive domain with its graduations.
    let domain: ClosedRange<Double>
    let majors: [Double]
    let minors: [Double]
}

struct NativeStatsBenchmark: View {
    let data: JSONValue
    var detail = false
    var compact = false
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
        // The payload names each series "model · provider"; the key stays its identity.
        var labels: [String: String] = [:]
        for point in data["trend"].array where labels[point["key"].string] == nil && !point["label"].string.isEmpty {
            labels[point["key"].string] = point["label"].string
        }
        let colors = nativeStatsDistinctColors(keys)
        let plot = NativeStatsPlotProjection(points: points, label: { labels[$0.series] ?? $0.series },
            value: { String(format: "%.0f ms", $0) }, color: { colors[$0.series] ?? Theme.pairColor($0.series) })
        let values = points.map(\.value).filter { $0.isFinite && (!logarithmic || $0 > 0) }
        guard logarithmic, let low = values.min(), let high = values.max() else {
            return NativeStatsBenchmarkProjection(plot: plot, keys: keys, labels: labels, colors: colors, isolation: isolation,
                                                  domain: plot.yDomain, majors: plot.yMajors, minors: plot.yMinors)
        }
        let domain = (low / 1.25)...(high * 1.25)
        let ruler = NativeChartMath.logTicks(domain)
        return NativeStatsBenchmarkProjection(plot: plot, keys: keys, labels: labels, colors: colors, isolation: isolation,
                                              domain: domain, majors: ruler.majors, minors: ruler.minors)
    }
    private func milliseconds(_ value: Double) -> String { NativeNumberFormat.compact(value) + " ms" }
    var body: some View {
        let chart = projection.value(for: [data["trend"], .bool(logarithmic), isolated.map(JSONValue.string) ?? .null], build: project)
        Group {
            if data["spend"]["calls"].int > 0 { NativeStatsBenchmarkSpend(spend: data["spend"], detail: detail) }
            if !data["trend"].array.isEmpty { trendBand(chart) }
        }
        .onChange(of: chart.keys) { _, available in
            if let isolated, !available.contains(isolated) { self.isolated = nil }
        }
    }

    private func trendBand(_ chart: NativeStatsBenchmarkProjection) -> some View {
        let palette = chart.keys.map { chart.colors[$0] ?? Theme.pairColor($0) }
        let legend = zip(chart.keys, palette).map { NativeLegendEntry(id: $0, label: chart.labels[$0] ?? $0, color: $1) }
        return NativeStatsBand(title: detail && data["spend"]["calls"].int == 0 ? "Benchmarks for this model" : "First token",
                    hint: "Median successful latency per provider, model and run; a rising line is a provider getting slower") {
            Stops(options: [(true, "Log"), (false, "Linear")], selection: logarithmic) { logarithmic = $0 }
        } content: {
            Well {
                VStack(alignment: .leading, spacing: 14) {
                    NativeStatsChartInspection(index: chart.plot.index) {
                        Chart(chart.plot.points) { p in
                            LineMark(x: .value("Date", p.date), y: .value("Median ms", p.value))
                                .foregroundStyle(by: .value("Provider / model", p.series))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .round))
                            PointMark(x: .value("Date", p.date), y: .value("Median ms", p.value))
                                .foregroundStyle(by: .value("Provider / model", p.series)).symbol(.square).symbolSize(14)
                        }
                        .chartForegroundStyleScale(domain: chart.keys, range: palette)
                        .chartYScale(domain: chart.domain, type: logarithmic ? .log : .linear)
                        .chartXAxis { NativeChartAxis.dates(minor: chart.plot.minor) }
                        .chartYAxis { NativeChartAxis.numeric(chart.majors, minors: chart.minors, position: .trailing, format: milliseconds) }
                        .chartLegend(.hidden).chartPlotStyle { plot in plot.nativePlotSpine() }
                        .frame(height: 216)
                    }
                    NativeChartLegend(entries: legend, selection: Binding(get: { chart.isolation }, set: { isolated = $0 }))
                }
            }
        }
    }
}

/// What UniApi's own measuring cost, kept apart from coding-app usage.
private struct NativeStatsBenchmarkSpend: View {
    let spend: JSONValue
    let detail: Bool
    var body: some View {
        let tokens = spend["input"].double + spend["output"].double
        let calls = spend["calls"].double
        let coverage: Double? = calls > 0 ? spend["estimated"].double * 100 / calls : nil
        NativeStatsBand(detail ? "Benchmarks for this model" : "Benchmark spend",
             hint: detail ? "This exact model and date range, across providers; separate from coding-app usage" : "Tokens UniApi's own measuring pushed through each provider") {
            VStack(alignment: .leading, spacing: 20) {
                ReadoutStrip(minimum: 180) {
                    NativeStatsReadout(label: "Benchmark tokens", value: tokens, unit: "tokens",
                                       detail: "Input \(nativeStatsCount(spend["input"].double)) · output \(nativeStatsCount(spend["output"].double)) · reasoning \(nativeStatsCount(spend["reasoning"].double)) · cached \(nativeStatsCount(spend["cached"].double))",
                                       format: nativeStatsCount)
                    NativeStatsReadout(label: "Calls", value: calls, detail: "\(spend["runs"].int) \(spend["runs"].int == 1 ? "run" : "runs") · \(spend["pairs"].array.count) \(spend["pairs"].array.count == 1 ? "target" : "targets")",
                                       format: nativeStatsCount)
                    NativeStatsReadout(label: "Estimated coverage", value: coverage, unit: "%",
                                       detail: "Calls whose token counts are estimates", format: nativeStatsRate)
                }
                .help("Reasoning \(nativeStatsCount(spend["reasoning"].double)) inside output · cached \(nativeStatsCount(spend["cached"].double)) inside input")
                VStack(alignment: .leading, spacing: 0) {
                    LedgerHead {
                        MicroLabel("Target").frame(maxWidth: .infinity, alignment: .leading)
                        MicroLabel("Input").frame(width: 64, alignment: .trailing)
                        MicroLabel("Output").frame(width: 64, alignment: .trailing)
                        MicroLabel("Calls").frame(width: 56, alignment: .trailing)
                    }
                    ForEach(Array(spend["pairs"].array.enumerated()), id: \.offset) { _, pair in
                        NativeStatsBenchmarkTarget(pair: pair)
                    }
                }
            }
        }
    }
}

private struct NativeStatsBenchmarkTarget: View {
    let pair: JSONValue
    var body: some View {
        LedgerRow(minHeight: 28) {
            HStack(spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(pair["model"].string).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Text(pair["providerName"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).help(pair["model"].string)
                number(nativeStatsCount(pair["input"].double), width: 64)
                number(nativeStatsCount(pair["output"].double), width: 64)
                number("\(pair["calls"].int)", width: 56)
            }
        }
    }
    private func number(_ text: String, width: CGFloat) -> some View {
        Text(text).font(Theme.mono(11.5)).monospacedDigit().foregroundStyle(Theme.dim).frame(width: width, alignment: .trailing)
    }
}
