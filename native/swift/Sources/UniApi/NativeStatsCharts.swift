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


func nativeStatsHarnessColor(_ source: String) -> Color {
    let palette = ["claude": "ec4899", "codex": "3b82f6", "antigravity": "f97316", "zcode": "f59e0b", "opencode": "a855f7", "dsh": "06b6d4"]
    return nativeStatsColor(palette[source] ?? "346bf1")
}
func nativeStatsColor(_ hex: String) -> Color {
    let text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard text.count == 6, let value = UInt32(text, radix: 16) else { return Theme.accent }
    return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
}
func nativeStatsAmount(_ totals: JSONValue, _ measure: String) -> Double {
    measure == "all" ? nativeStatsGrand(totals) : totals[measure == "messages" ? "messages" : measure == "thinking" ? "thinking" : "output"].double
}

private struct NativeStatsPlotPlaceholder: View {
    let text: String, height: CGFloat
    var body: some View {
        Text(text).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
    }
}

/// One measure per day, stacked by model. The table under it is the legend:
/// selecting a row there isolates that model here.
struct NativeStatsUsageChart: View {
    let data: JSONValue, colors: JSONValue
    let measure: String
    let isolated: String?
    var height: CGFloat = 196
    @State private var projection = NativeStatsProjectionCache<NativeStatsPlotProjection>()
    private var stacked: [String] { data["stackModels"].array.map(\.string) + (data["stackDropped"].int > 0 ? ["other"] : []) }
    private func color(_ name: String) -> Color { name == "other" ? Theme.muted : nativeStatsColor(colors[name].string) }
    private func project(series: [String]) -> NativeStatsPlotProjection {
        var result: [NativeStatsPoint] = []
        let included = Set(data["stackModels"].array.map(\.string))
        for day in data["days"].array {
            let stamp = day["day"].double, date = Date(timeIntervalSince1970: stamp / 1000)
            for name in series {
                let value = name == "other" ? day["perModel"].object.reduce(0) { $0 + (included.contains($1.key) ? 0 : nativeStatsAmount($1.value, measure)) } : nativeStatsAmount(day["perModel"][name], measure)
                result.append(NativeStatsPoint(id: "\(stamp):\(name)", series: name, date: date, value: value))
            }
        }
        return NativeStatsPlotProjection(points: result, label: { $0.series == "other" ? "\(data["stackDropped"].int) more" : $0.series },
                                         value: nativeStatsCount, color: { color($0.series) }, sampling: .day)
    }
    var body: some View {
        // A model below the stacked top eight is still plotted on its own.
        let series = isolated.map { [$0] } ?? stacked
        let chart = projection.value(for: [data["days"], data["stackModels"], data["stackDropped"], colors,
                                           .string(measure), isolated.map(JSONValue.string) ?? .null]) { project(series: series) }
        if data["days"].array.isEmpty {
            NativeStatsPlotPlaceholder(text: data["isLifetime"].bool ? "Earlier transcripts are no longer on disk, so there is no dated history" : "No dated history in this range", height: height)
        } else {
            NativeStatsChartInspection(index: chart.index) {
                Chart(chart.points) { p in BarMark(x: .value("Date", p.date, unit: .day), y: .value("Usage", p.value)).foregroundStyle(by: .value("Model", p.series)) }
                    .chartForegroundStyleScale(domain: series, range: series.map(color))
                    .chartLegend(.hidden)
                    .chartYAxis { AxisMarks(position: .trailing) { value in
                        AxisGridLine(); AxisValueLabel { if let amount = value.as(Double.self) { Text(nativeStatsCount(amount)) } }
                    } }
                    .frame(height: height)
                    .chartPlotStyle { plot in plot.nativeEntrance(.growVertical) }
                    .accessibilityLabel("Daily \(measure == "all" ? "tokens" : measure) by model, dated records only")
            }
        }
    }
}

/// Daily tokens per second, one line per model or app.
struct NativeStatsSpeedChart: View {
    let board: JSONValue, colors: JSONValue
    let metric: NativeStatsRateMetric
    /// "models" or "harnesses".
    let group: String
    let isolated: String?
    var height: CGFloat = 196
    @State private var projection = NativeStatsProjectionCache<(plot: NativeStatsPlotProjection, colors: [String: Color], names: [String])>()
    private func label(_ name: String) -> String { group == "harnesses" ? nativeStatsSourceName(name) : name }
    private func project() -> (plot: NativeStatsPlotProjection, colors: [String: Color], names: [String]) {
        let key = group == "models" ? "model" : "source"
        let available = board[group].array.filter { $0["timedResponses"].int > 0 && NativeStatsThroughputPresentation.rate($0) != nil }.sorted {
            let a = $0["timedResponses"].int, b = $1["timedResponses"].int
            return a == b ? $0[key].string < $1[key].string : a > b
        }.map { $0[key].string }
        // The eight most sampled series, or exactly the selected one.
        let names = isolated.map { available.contains($0) ? [$0] : [] } ?? Array(available.prefix(8))
        var result: [NativeStatsPoint] = [], segments: [String: Color] = [:]
        for name in names {
            let tone = group == "harnesses" ? nativeStatsHarnessColor(name) : nativeStatsColor(colors[name].string)
            var segment = 0, last: Double?
            for day in board["days"].array {
                let stamp = day["day"].double
                guard let value = NativeStatsThroughputPresentation.rate(day[group][name]) else { segment += 1; last = nil; continue }
                if let last, stamp - last > 1.5 * 86_400_000 { segment += 1 }
                let series = "\(name):\(segment)"
                result.append(NativeStatsPoint(id: "\(name):\(stamp)", series: series, date: Date(timeIntervalSince1970: stamp / 1000), value: value))
                segments[series] = tone; last = stamp
            }
        }
        let plot = NativeStatsPlotProjection(points: result, label: { point in
            label(point.series.lastIndex(of: ":").map { String(point.series[..<$0]) } ?? point.series)
        }, value: { String(format: "%.1f tok/s", $0) }, color: { segments[$0.series] ?? Theme.accent })
        return (plot, segments, names)
    }
    var body: some View {
        let chart = projection.value(for: [board[group], board["days"], colors, .string(group), .string(metric.rawValue),
                                           isolated.map(JSONValue.string) ?? .null], build: project)
        if chart.plot.points.isEmpty {
            NativeStatsPlotPlaceholder(text: metric == .streaming ? "No streaming clocks in this range" : "No timed responses in this range", height: height)
        } else {
            NativeStatsChartInspection(index: chart.plot.index) {
                Chart(chart.plot.points) { p in
                    LineMark(x: .value("Day", p.date), y: .value(metric.title, p.value), series: .value("Series", p.series)).foregroundStyle(chart.colors[p.series] ?? Theme.accent).lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).interpolationMethod(.monotone)
                    PointMark(x: .value("Day", p.date), y: .value(metric.title, p.value)).foregroundStyle(chart.colors[p.series] ?? Theme.accent).symbolSize(12)
                }
                .chartLegend(.hidden).chartYAxis { AxisMarks(position: .trailing) }.frame(height: height)
                .chartPlotStyle { plot in plot.nativeEntrance(.fade) }
                .accessibilityLabel("Daily " + metric.title + " for " + chart.names.map(label).joined(separator: ", "))
            }
        }
    }
}

/// Median first-token latency per benchmark run, one line per provider and model.
struct NativeStatsBenchmarkChart: View {
    let trend: [JSONValue]
    let logarithmic: Bool
    let isolated: String?
    var height: CGFloat = 196
    @State private var projection = NativeStatsProjectionCache<(plot: NativeStatsPlotProjection, keys: [String])>()
    private func project() -> (plot: NativeStatsPlotProjection, keys: [String]) {
        let keys = Array(Set(trend.map { $0["key"].string })).sorted()
        let shown = isolated.flatMap { keys.contains($0) ? [$0] : nil } ?? keys
        let labels = Dictionary(trend.map { ($0["key"].string, $0["label"].string) }, uniquingKeysWith: { first, _ in first })
        let points = trend.filter { shown.contains($0["key"].string) && (!logarithmic || $0["ms"].double > 0) }.map {
            NativeStatsPoint(id: $0["key"].string + $0["runId"].string, series: $0["key"].string,
                             date: Date(timeIntervalSince1970: $0["at"].double / 1000), value: $0["ms"].double)
        }
        return (NativeStatsPlotProjection(points: points, label: { labels[$0.series].flatMap { $0.isEmpty ? nil : $0 } ?? $0.series },
            value: { String(format: "%.0f ms", $0) }, color: { Theme.pairColor($0.series) }), shown)
    }
    var body: some View {
        let chart = projection.value(for: [.array(trend), .bool(logarithmic), isolated.map(JSONValue.string) ?? .null], build: project)
        if chart.plot.points.isEmpty {
            NativeStatsPlotPlaceholder(text: "No latency samples yet", height: height)
        } else {
            NativeStatsChartInspection(index: chart.plot.index) {
                Chart(chart.plot.points) { p in LineMark(x: .value("Date", p.date), y: .value("Median ms", p.value)).foregroundStyle(by: .value("Provider / model", p.series)); PointMark(x: .value("Date", p.date), y: .value("Median ms", p.value)).foregroundStyle(by: .value("Provider / model", p.series)).symbolSize(16) }
                    .chartForegroundStyleScale(domain: chart.keys, range: chart.keys.map { Theme.pairColor($0) })
                    .chartYScale(type: logarithmic ? .log : .linear).chartLegend(.hidden).chartYAxis { AxisMarks(position: .trailing) }.frame(height: height)
                    .chartPlotStyle { plot in plot.nativeEntrance(.fade) }
                    .accessibilityLabel("Median first-token latency per benchmark run")
            }
        }
    }
}
