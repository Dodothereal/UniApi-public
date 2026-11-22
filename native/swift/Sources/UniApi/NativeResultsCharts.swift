import SwiftUI
import UniApiCore

/// The curves behind a run's numbers. Scaling and arrival need one run's
/// denominator, so the all-time scope points at its source runs instead.
/// The five rankings live on the Results ledger; the views here are the ones
/// a ledger cannot show.
struct NativeResultsCharts: View {
    let cells: [NativeResultCell], rows: [JSONValue], history: Bool, more: Bool, open: (String) -> Void
    private var browser: Bool { cells.contains(where: \.browser) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if history {
                Text("Open a source run to inspect its input scaling and token-arrival charts.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
            } else {
                scaling(browser ? "First response vs input size" : "First token vs input size", field: "ttft_ms", caption: "Log₂ input size; browser entries measure first visible text.", format: nativeBenchMilliseconds)
                arrival
            }
            if more {
                if !history {
                    scaling("Effective prefill vs input", field: "prefill_tps", caption: "Input tokens / first-response time. Browser prefill remains unavailable.", format: { String(format: "%.0f tok/s", $0) })
                }
                ranking("Longest measured answer", caption: "Generated tokens from the recorded max-output test. Browser caps cannot be enforced.", value: { BenchmarkMath.number($0.value["maxout"]["generated"]) })
            }
        }
    }
    private func ranking(_ title: String, caption: String, value: (NativeResultCell) -> Double?, format: @escaping (Double) -> String = NativeNumberFormat.compact) -> some View {
        let available = cells.filter { value($0) != nil }.sorted { value($0)! > value($1)! }
        return VStack(alignment: .leading, spacing: 10) {
            NativeChartHeading(title: title, caption: caption)
            if available.isEmpty { Blank(icon: "chart-bar", title: "No measurements", detail: "This scope has no available samples for this metric.") }
            else {
                // The chart's rows carry their own inset; pull them back to the content edge.
                NativeRankingChart(rows: available.map { cell in NativeRankEntry(id: cell.id, title: cell.short, detail: cell.value["provider_name"].string + (cell.browser ? " · Browser" : ""), value: value(cell), color: Theme.pairColor(cell.id)) }, format: format)
                    .padding(.horizontal, -9)
            }
        }
        .padding(.top, 8)
    }
    private func scaling(_ title: String, field: String, caption: String, format: @escaping (Double) -> String) -> some View {
        let series = mostTested.compactMap { cell -> NativeChartSeries? in
            let points = cell.value["ctx"].object.compactMap { size, point -> NativeChartPoint? in
                guard point["ok"].bool, let x = Double(size), x > 0, let y = BenchmarkMath.number(point[field]) else { return nil }
                return .init(x: log2(x), y: y)
            }.sorted { $0.x < $1.x }
            return points.isEmpty ? nil : NativeChartSeries(id: cell.id, label: cell.short + " · " + cell.value["provider_name"].string, points: points, color: Theme.pairColor(cell.id))
        }
        return Well {
            VStack(alignment: .leading, spacing: 14) {
                NativeChartHeading(title: title, caption: caption + (series.count > 8 ? " \(series.count - 8) less-sampled pairs omitted." : ""))
                NativeLineChart(series: Array(series.prefix(8)), xFormat: { NativeNumberFormat.compact(pow(2, $0)) }, yFormat: format)
            }
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
        return Well {
            VStack(alignment: .leading, spacing: 14) {
                NativeChartHeading(title: "Token arrival over time", caption: "Steeper is faster; flat steps show stalls. Browser tokens are estimates." + (chosen.count > 8 ? " \(chosen.count - 8) less-sampled pairs omitted." : ""))
                NativeLineChart(series: series, height: 215, monotone: false, showPoints: false, xFormat: { String(format: "%.1f s", $0) }, yFormat: { NativeNumberFormat.compact($0) + " tok" })
            }
        }
    }
}
