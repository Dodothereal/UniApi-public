import SwiftUI
import UniApiCore

/// Curves that belong to one run: how the first token and the prefill rate
/// change with input size, and how tokens arrive over time.
struct NativeResultsCharts: View {
    let cells: [NativeResultCell], rows: [JSONValue], history: Bool, margin: CGFloat
    /// The target selected in the table. Its line is drawn alone.
    var focus: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if history {
                Text("Scaling and arrival curves belong to one run. Choose a run to see them.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.muted).padding(.horizontal, margin).padding(.top, 20)
            } else {
                let browser = cells.contains(where: \.browser)
                section(browser ? "First response by input size" : "First token by input size", caption: "Input size on a log₂ scale. Browser entries measure first visible text.", omitted: omitted) {
                    NativeLineChart(series: scaling("ttft_ms"), focus: focus, xFormat: { NativeNumberFormat.compact(pow(2, $0)) }, yFormat: nativeBenchMilliseconds)
                }
                section("Token arrival", caption: "Steeper is faster; flat steps are stalls. Browser tokens are estimates.", omitted: max(0, arrivals.count - 8)) {
                    NativeLineChart(series: Array(arrivals.prefix(8)), height: 215, monotone: false, showPoints: false, focus: focus,
                                    xFormat: { String(format: "%.1f s", $0) }, yFormat: { NativeNumberFormat.compact($0) + " tok" })
                }
                section("Prefill rate by input size", caption: "Input tokens divided by the time to the first response. Not available for browser entries.", omitted: omitted) {
                    NativeLineChart(series: scaling("prefill_tps"), focus: focus, xFormat: { NativeNumberFormat.compact(pow(2, $0)) }, yFormat: { String(format: "%.0f tok/s", $0) })
                }
            }
        }
    }
    private func section<Content: View>(_ title: String, caption: String, omitted: Int, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeChartHeading(title: title, caption: caption + (omitted > 0 ? " \(omitted) less-sampled targets are left out." : ""))
            content()
        }
        .padding(.horizontal, margin).padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Theme.rule.frame(height: 1).padding(.horizontal, margin) }
        .padding(.top, 18)
    }
    private var mostTested: [NativeResultCell] {
        cells.sorted { a, b in
            let ac = a.value["ok_count"].int + a.value["err_count"].int, bc = b.value["ok_count"].int + b.value["err_count"].int
            return ac == bc ? a.id < b.id : ac > bc
        }
    }
    private var omitted: Int { max(0, cells.count - 8) }
    private func scaling(_ field: String) -> [NativeChartSeries] {
        Array(mostTested.compactMap { cell -> NativeChartSeries? in
            let points = cell.value["ctx"].object.compactMap { size, point -> NativeChartPoint? in
                guard point["ok"].bool, let x = Double(size), x > 0, let y = BenchmarkMath.number(point[field]) else { return nil }
                return .init(x: log2(x), y: y)
            }.sorted { $0.x < $1.x }
            return points.isEmpty ? nil : NativeChartSeries(id: cell.id, label: cell.short + " · " + cell.value["provider_name"].string, points: points, color: Theme.pairColor(cell.id))
        }.prefix(8))
    }
    private var arrivals: [NativeChartSeries] {
        var latest: [String: JSONValue] = [:]
        for row in rows where row["test"] == "throughput" && row["ok"].bool && !row["curve"].array.isEmpty {
            let key = row["provider"].string + "|" + row["model"].string; if latest[key] == nil { latest[key] = row }
        }
        let known = Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.value["ok_count"].int + $0.value["err_count"].int) })
        return latest.keys.filter { known[$0] != nil }.sorted { a, b in
            let ac = known[a] ?? 0, bc = known[b] ?? 0
            return ac == bc ? a < b : ac > bc
        }.map { key in
            let row = latest[key]!
            return NativeChartSeries(id: key, label: row["model"].string + " · " + row["provider_name"].string, points: row["curve"].array.compactMap { point in
                guard point.array.count == 2, let x = BenchmarkMath.number(point.array[0]), let y = BenchmarkMath.number(point.array[1]) else { return nil }
                return NativeChartPoint(x: x / 1000, y: y)
            }, color: Theme.pairColor(key))
        }
    }
}
