import SwiftUI
import UniApiCore

/// Nine original benchmark views. Historical records can rank, while scaling
/// and arrival curves deliberately require a single run's denominator.
struct NativeResultsCharts: View {
    let cells: [NativeResultCell], rows: [JSONValue], history: Bool, open: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if history {
                Text("Open a source run to inspect its input scaling and token-arrival charts.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
            } else {
                scaling(cells.contains(where: \.browser) ? "First response vs input size" : "First token vs input size", field: "ttft_ms", caption: "Log₂ input size; browser entries measure first visible text.", format: nativeBenchMilliseconds)
                arrival
            }
            // Preserve the native's supplementary measured views without
            // repeating the main ranking board in the web reading order.
            DisclosureGroup("More measured views") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), alignment: .top)], alignment: .leading, spacing: 14) {
                    ranking(cells.contains(where: \.browser) ? "First response" : "First token", caption: history ? "Best run median; lower is better." : "Median with min/max spread; lower is better.", metric: "latency", lower: true, value: { $0.ttft }, format: nativeBenchMilliseconds)
                    ranking("Output speed", caption: "Generation-phase tokens per second; browser entries estimate visible updates.", metric: "throughput", value: { $0.speed }, format: { String(format: "%.2f tok/s", $0) })
                    ranking("Largest accepted input", caption: "Acceptance is a lower bound until a larger prompt fails. Browser sizes are estimated.", metric: "context", value: { $0.input }, format: nativeBenchTokens)
                    ranking("Reliability", caption: "Successful tests divided by all tests in this scope.", maximum: 100, value: { $0.reliability }, format: { String(format: "%.0f%%", $0) })
                    scaling("Effective prefill vs input", field: "prefill_tps", caption: "Input tokens / first-response time. Browser prefill remains unavailable.", format: { String(format: "%.0f tok/s", $0) })
                    ranking("Streaming pause p95", caption: "Inter-event gaps; browser gaps are between visible text updates.", metric: "throughput", lower: true, value: { $0.gap }, format: nativeBenchMilliseconds)
                    ranking("Longest measured answer", caption: "Generated tokens from the recorded max-output test. Browser caps cannot be enforced.", value: { BenchmarkMath.number($0.value["maxout"]["generated"]) })
                    if history {
                        scaling(cells.contains(where: \.browser) ? "First response vs input" : "First token vs input", field: "ttft_ms", caption: "Log₂ input size; browser entries measure first visible text.", format: nativeBenchMilliseconds)
                        arrival
                    }
                }.padding(.top, 12)
            }.font(Theme.ui(12)).foregroundStyle(Theme.dim)
        }
    }
    private func ranking(_ title: String, caption: String, metric: String = "", lower: Bool = false, maximum: Double? = nil,
                         value: (NativeResultCell) -> Double?, format: @escaping (Double) -> String = NativeNumberFormat.compact) -> some View {
        let available = cells.filter { value($0) != nil }.sorted { lower ? value($0)! < value($1)! : value($0)! > value($1)! }
        return NativeCard {
            NativeChartHeading(title: title, caption: caption)
            if available.isEmpty { NativeEmptyState(title: "No measurements", detail: "This scope has no available samples for this metric.", icon: "chart-bar") }
            else {
                NativeRankingChart(rows: available.map { cell in NativeRankEntry(id: cell.id, title: cell.short, detail: cell.value["provider_name"].string + (cell.browser ? " · Browser" : ""), value: value(cell), low: metric == "latency" ? BenchmarkMath.number(cell.value["latency"]["ttft_min_ms"]) : nil, high: metric == "latency" ? BenchmarkMath.number(cell.value["latency"]["ttft_max_ms"]) : nil, color: Theme.pairColor(cell.id)) }, lowerIsBetter: lower, fixedMaximum: maximum, format: format)
                if history && !metric.isEmpty {
                    NativeScrollRail { ForEach(available.filter { !$0.source(metric).isEmpty }) { cell in Button(cell.short + ": View run") { open(cell.source(metric)) }.buttonStyle(.link).font(Theme.ui(10.5)) } }
                }
            }
        }
    }
    private func scaling(_ title: String, field: String, caption: String, format: @escaping (Double) -> String) -> some View {
        let series = mostTested.compactMap { cell -> NativeChartSeries? in
            let points = cell.value["ctx"].object.compactMap { size, point -> NativeChartPoint? in
                guard point["ok"].bool, let x = Double(size), x > 0, let y = BenchmarkMath.number(point[field]) else { return nil }
                return .init(x: log2(x), y: y)
            }.sorted { $0.x < $1.x }
            return points.isEmpty ? nil : NativeChartSeries(id: cell.id, label: cell.short + " · " + cell.value["provider_name"].string, points: points, color: Theme.pairColor(cell.id))
        }
        return NativeCard {
            NativeChartHeading(title: title, caption: caption + (series.count > 8 ? " \(series.count - 8) less-sampled pairs omitted." : ""))
            if history { NativeEmptyState(title: "Choose an individual run", detail: "Historical records retain source runs; curves are not combined across them.", icon: "chart-no-axes-combined") }
            else { NativeLineChart(series: Array(series.prefix(8)), xFormat: { NativeNumberFormat.compact(pow(2, $0)) }, yFormat: format) }
        }
    }
    private var mostTested: [NativeResultCell] {
        cells.sorted { a, b in
            let ac = a.value["ok_count"].int + a.value["err_count"].int, bc = b.value["ok_count"].int + b.value["err_count"].int
            return ac == bc ? a.id < b.id : ac > bc
        }
    }
    private var arrival: some View {
        var latest: [String: JSONValue] = [:]
        for row in rows where row["test"] == "throughput" && row["ok"].bool && !row["curve"].array.isEmpty {
            let key = row["provider"].string + "|" + row["model"].string; if latest[key] == nil { latest[key] = row }
        }
        let chosen = latest.keys.sorted { a, b in
            let ac = cells.first { $0.id == a }.map { $0.value["ok_count"].int + $0.value["err_count"].int } ?? 0, bc = cells.first { $0.id == b }.map { $0.value["ok_count"].int + $0.value["err_count"].int } ?? 0
            return ac == bc ? a < b : ac > bc
        }
        let series = chosen.prefix(8).map { key -> NativeChartSeries in
            let row = latest[key]!
            return .init(id: key, label: row["model"].string + " · " + row["provider_name"].string, points: row["curve"].array.compactMap { point in guard point.array.count == 2, let x = BenchmarkMath.number(point.array[0]), let y = BenchmarkMath.number(point.array[1]) else { return nil }; return NativeChartPoint(x: x / 1000, y: y) }, color: Theme.pairColor(key))
        }
        return NativeCard {
            NativeChartHeading(title: "Token arrival over time", caption: "Steeper is faster; flat steps show stalls. Browser tokens are estimates." + (chosen.count > 8 ? " \(chosen.count - 8) less-sampled pairs omitted." : ""))
            if history { NativeEmptyState(title: "Choose an individual run", detail: "Arrival curves belong to actual requests.", icon: "chart-no-axes-combined") }
            else { NativeLineChart(series: series, height: 215, monotone: false, showPoints: false, xFormat: { String(format: "%.1f s", $0) }, yFormat: { NativeNumberFormat.compact($0) + " tok" }) }
        }
    }
}
