import SwiftUI
import UniApiCore

struct NativeArenaStandingsPreview: View {
    let rows: [JSONValue]
    let trend: [JSONValue]
    let standings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Standings").font(Theme.ui(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                Text("Submit a verdict to start the leaderboard.").foregroundStyle(Theme.muted)
            } else {
                podium
                leaderboard
                NativeCard(title: "Elo trend") {
                    if chartSeries.isEmpty {
                        Text("No rated matches in recent ledger history.").foregroundStyle(Theme.muted)
                    } else {
                        let series = chartSeries
                        let dates = series.flatMap { $0.points.map(\.x) }
                        let first = Date(timeIntervalSince1970: (dates.min() ?? 0) / 1000)
                        let last = Date(timeIntervalSince1970: (dates.max() ?? 0) / 1000)
                        let sameDay = Calendar.current.isDate(first, inSameDayAs: last)
                        let format: (Double) -> String = { timestamp in
                            let date = Date(timeIntervalSince1970: timestamp / 1000)
                            return sameDay ? date.formatted(date: .omitted, time: .shortened) : date.formatted(.dateTime.month(.abbreviated).day())
                        }
                        NativeLineChart(series: series, height: 130, monotone: false, includeZero: false,
                            xFormat: format, yFormat: { String(format: "%.0f", $0) },
                            xTicks: { ArenaPresentationPolicy.trendTicks($0, label: format) }, legend: trendLegend(series))
                            .nativeEntrance(.fade)
                    }
                }
            }
            Button("Full standings", nativeIcon: "arrow-right", action: standings).buttonStyle(T3Button(.outline))
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1).allowsHitTesting(false))
    }

    private var podium: some View {
        let top = Array(rows.prefix(3))
        let names = ArenaPresentationPolicy.compactModelNames(top.map { $0["model"].string }, trimSharedSuffix: true)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(top.indices, id: \.self) { index in
                let row = top[index], key = row["key"].string
                let label = row["model"].string
                VStack(alignment: .leading, spacing: 5) {
                    Text("#\(index + 1)").font(Theme.num(Theme.textXs, weight: .semibold)).foregroundStyle(Theme.muted)
                    Text(names[label] ?? label).font(Theme.mono(10))
                        .lineLimit(2, reservesSpace: true).truncationMode(names[label] == nil ? .middle : .tail)
                        .accessibilityLabel(label)
                    NativeNumberText(text: row["elo"].string, font: Theme.num(Theme.textSm, weight: .semibold))
                    NativeGrowBar(fraction: Double(top.count - index) / Double(top.count), color: Theme.pairColor(key), delay: Double(index) * NativeMotion.stagger)
                        .accessibilityHidden(true)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.sunken, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .help("\(label) · \(row["route"].string)").accessibilityElement(children: .combine)
            }
        }
    }

    private var leaderboard: some View {
        let rows = Array(rows.prefix(6))
        let names = ArenaPresentationPolicy.compactModelNames(rows.map { $0["model"].string })
        return NativeCard(title: "Leaderboard") {
            ForEach(Array(rows.enumerated()), id: \.element["key"]) { index, row in
                let name = row["model"].string, route = row["route"].string
                HStack(spacing: 8) {
                    Text("\(index + 1)").font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted).frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(names[name] ?? name).font(Theme.mono(Theme.textXs)).truncationMode(names[name] == nil ? .middle : .tail)
                        Text(route).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    }.lineLimit(1)
                    Spacer(minLength: 4)
                    NativeNumberText(text: row["elo"].string, font: Theme.num(Theme.textXs, weight: .semibold))
                }.help("\(name) · \(route)").accessibilityElement(children: .combine)
            }
        }
    }

    private var chartSeries: [NativeChartSeries] {
        trend.map { series in
            let points = series["points"].array.map { NativeChartPoint(x: $0["ts"].double, y: $0["elo"].double) }
            return NativeChartSeries(id: series["key"].string, label: "\(series["model"].string) · \(series["route"].string)", points: points)
        }
    }

    private func trendLegend(_ series: [NativeChartSeries]) -> [NativeLegendEntry] {
        rows.prefix(3).enumerated().compactMap { index, row in
            guard let line = series.first(where: { $0.id == row["key"].string }) else { return nil }
            return NativeLegendEntry(id: line.id, label: "#\(index + 1)", color: line.color, detail: line.label)
        }
    }
}
