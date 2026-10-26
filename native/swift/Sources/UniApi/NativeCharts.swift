import SwiftUI
import Charts
import UniApiCore

struct NativeChartPoint: Equatable {
    var x: Double
    var y: Double?
    init(x: Double, y: Double?) { self.x = x; self.y = y }
    init(date: Date, value: Double?) { x = date.timeIntervalSince1970; y = value }
}

struct NativeChartSeries: Identifiable, Equatable {
    var id: String
    var label: String
    var points: [NativeChartPoint]
    var color: Color
    init(id: String, label: String, points: [NativeChartPoint], color: Color? = nil) {
        self.id = id; self.label = label; self.points = points
        self.color = color ?? Theme.pairColor(id)
    }
}

struct NativeChartSample: Identifiable, Equatable {
    var id: String
    var seriesID: String
    var pathID: String
    var label: String
    var color: Color
    var x: Double
    var y: Double
}

enum NativeChartMath {
    /// Missing samples split paths instead of bridging a period we did not read.
    static func samples(_ series: [NativeChartSeries]) -> [NativeChartSample] {
        var result: [NativeChartSample] = []
        for series in series {
            var segment = 0
            let points = series.points.enumerated().sorted {
                let a = $0.element.x, b = $1.element.x
                if !a.isFinite { return false }
                if !b.isFinite { return true }
                return a == b ? $0.offset < $1.offset : a < b
            }
            for (index, point) in points {
                guard point.x.isFinite, let y = point.y, y.isFinite else { segment += 1; continue }
                result.append(NativeChartSample(id: series.id + "-\(index)", seriesID: series.id,
                                               pathID: series.id + "-segment-\(segment)",
                                               label: series.label, color: series.color, x: point.x, y: y))
            }
        }
        return result
    }

    static func domain(_ values: [Double], includeZero: Bool = true) -> ClosedRange<Double> {
        let values = values.filter(\.isFinite)
        guard var lower = values.min(), var upper = values.max() else { return 0...1 }
        if includeZero { lower = min(0, lower); upper = max(0, upper) }
        if lower == upper {
            let padding = max(abs(lower) * 0.1, Double.leastNormalMagnitude)
            if lower == 0 { return 0...1 }
            lower = max(-Double.greatestFiniteMagnitude, lower - padding)
            upper = min(Double.greatestFiniteMagnitude, upper + padding)
        } else {
            let padding = (upper / 2 - lower / 2) * 0.12
            if !includeZero || lower < 0 { lower = max(-Double.greatestFiniteMagnitude, lower - padding) }
            if !includeZero || upper > 0 { upper = min(Double.greatestFiniteMagnitude, upper + padding) }
        }
        return lower...upper
    }

    /// Bounded 1-2-5 ticks, including degenerate and extreme finite data. Axis
    /// labels format actual ticks, independently of headline number animation.
    static func ticks(_ domain: ClosedRange<Double>, count: Int = 5) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        let raw = span / Double(max(2, min(10, count)))
        guard raw.isFinite, raw > 0 else { return endpoints(domain) }
        let power = pow(10, floor(log10(raw)))
        guard power.isFinite, power > 0 else { return endpoints(domain) }
        let normalized = raw / power
        let step = (normalized <= 1 ? 1 : (normalized <= 2 ? 2 : (normalized <= 5 ? 5 : 10))) * power
        guard step.isFinite, step > 0 else { return endpoints(domain) }
        let first = ceil(domain.lowerBound / step) * step
        guard first.isFinite else { return endpoints(domain) }
        var result: [Double] = []
        for i in 0..<16 {
            let value = first + Double(i) * step
            guard value.isFinite, value <= domain.upperBound else { break }
            if domain.contains(value), result.last != value { result.append(value == 0 ? 0 : value) }
        }
        return result.isEmpty ? endpoints(domain) : result
    }

    private static func endpoints(_ domain: ClosedRange<Double>) -> [Double] {
        var result = [domain.lowerBound]
        if domain.lowerBound < 0 && domain.upperBound > 0 { result.append(0) }
        if domain.upperBound != domain.lowerBound { result.append(domain.upperBound) }
        return result
    }
}

struct NativeChartHeading: View {
    var title: String
    var caption: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if !caption.isEmpty {
                Text(caption).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

typealias ChartHeading = NativeChartHeading

struct NativeLegendEntry: Identifiable {
    var id: String
    var label: String
    var color: Color
}

struct NativeChartLegend: View {
    var entries: [NativeLegendEntry]
    @Binding var selection: String?
    @Environment(\.nativeReducedMotion) private var reduceMotion
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
                    .background(selected ? Theme.subtle2 : .clear,
                                in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm)
                        .strokeBorder(selected ? Theme.input : .clear))
                    .opacity(included ? 1 : 0.4)
                }
                .buttonStyle(.plain).pointingHand()
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .help(selected ? "Show every series" : "Show only " + entry.label)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selection)
    }
}

struct NativeTooltipLine {
    var label: String
    var value: String
    var color: Color
}

struct NativeChartTooltip: View {
    var title: String
    var lines: [NativeTooltipLine]
    var width: CGFloat = 276
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(Theme.mono(10, weight: .medium)).foregroundStyle(Theme.muted)
            ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    StatusDot(color: line.color, size: 5)
                    Text(line.label).font(Theme.mono(10)).foregroundStyle(Theme.dim)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(line.value).font(Theme.mono(10, weight: .medium)).foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
            }
            if lines.count > 6 {
                Text("\(lines.count - 6) more series").font(Theme.ui(10)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(width: max(0, width), alignment: .leading)
        .background(Theme.popover, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input))
        .shadow(color: Theme.shadow, radius: 12, y: 4)
        .allowsHitTesting(false)
    }
}

/// State is owned by the overlay: every mouse pixel updates just the readout,
/// not the chart's marks or its parent page. Snapping reports measured points.
private struct NativeChartOverlay: View {
    var proxy: ChartProxy
    var samples: [NativeChartSample]
    var xFormat: (Double) -> String
    var yFormat: (Double) -> String
    @State private var cursor: Double?

    private var nearest: [NativeChartSample] {
        guard let cursor, let snap = samples.min(by: { abs($0.x - cursor) < abs($1.x - cursor) }) else { return [] }
        return samples.filter { $0.x == snap.x }.sorted { $0.y > $1.y }
    }

    var body: some View {
        GeometryReader { geometry in
            if let plotFrame = proxy.plotFrame {
                let plot = geometry[plotFrame]
                ZStack(alignment: .topLeading) {
                    if let sample = nearest.first, let x = proxy.position(forX: sample.x) {
                        Rectangle().fill(Theme.crosshair).frame(width: 1, height: plot.height)
                            .offset(x: plot.minX + x, y: plot.minY)
                        let width = min(276, geometry.size.width)
                        NativeChartTooltip(title: xFormat(sample.x), lines: nearest.map {
                            NativeTooltipLine(label: $0.label, value: yFormat($0.y), color: $0.color)
                        }, width: width)
                        .offset(x: min(max(0, plot.minX + x + 12), max(0, geometry.size.width - width)),
                                y: plot.minY + 6)
                    }
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                cursor = plot.contains(location) ? proxy.value(atX: location.x - plot.minX) : nil
                            case .ended: cursor = nil
                            }
                        }
                }
            }
        }
        .onChange(of: samples) { cursor = nil }
    }
}

/// Numeric x supports prompt sizes, elapsed seconds and epoch dates. Pass a
/// date formatter for the latter. Nil y-values explicitly preserve gaps.
struct NativeLineChart: View {
    var series: [NativeChartSeries]
    var height: CGFloat = 230
    var monotone: Bool = true
    var showPoints: Bool = true
    var includeZero: Bool = true
    var xFormat: (Double) -> String = NativeNumberFormat.compact
    var yFormat: (Double) -> String = NativeNumberFormat.compact
    @State private var isolated: String?
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    private var samples: [NativeChartSample] {
        NativeChartMath.samples(series.filter { isolated == nil || $0.id == isolated })
    }

    var body: some View {
        let points = samples
        VStack(alignment: .leading, spacing: 12) {
            if points.isEmpty {
                NativeEmptyState(title: "No measured points", detail: "Measurements appear here when they are available.", icon: "chart.xyaxis.line")
            } else {
                chart(points)
            }
            NativeChartLegend(entries: series.map { NativeLegendEntry(id: $0.id, label: $0.label, color: $0.color) },
                              selection: $isolated)
        }
        .onChange(of: series) {
            if let isolated, !series.contains(where: { $0.id == isolated }) { self.isolated = nil }
        }
    }

    private func chart(_ points: [NativeChartSample]) -> some View {
        let yDomain = NativeChartMath.domain(points.map(\.y), includeZero: includeZero)
        return Chart {
            ForEach(points) { point in
                LineMark(x: .value("Position", point.x), y: .value("Value", point.y),
                         series: .value("Path", point.pathID))
                    .foregroundStyle(point.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(monotone ? .monotone : .linear)
                if showPoints {
                    PointMark(x: .value("Position", point.x), y: .value("Value", point.y))
                        .foregroundStyle(point.color).symbolSize(isolated == nil ? 20 : 34)
                        .accessibilityLabel(point.label + ", " + xFormat(point.x))
                        .accessibilityValue(yFormat(point.y))
                }
            }
        }
        .chartXScale(domain: NativeChartMath.domain(points.map(\.x), includeZero: false))
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine().foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let x = value.as(Double.self) { Text(xFormat(x)).font(Theme.mono(9)).foregroundStyle(Theme.muted) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: NativeChartMath.ticks(yDomain)) { value in
                AxisGridLine().foregroundStyle(Theme.grid)
                AxisValueLabel {
                    if let y = value.as(Double.self) { Text(yFormat(y)).font(Theme.mono(9)).foregroundStyle(Theme.muted) }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in NativeChartOverlay(proxy: proxy, samples: points, xFormat: xFormat, yFormat: yFormat) }
        .frame(height: height)
        .animation(reduceMotion || !visible ? nil : NativeMotion.isolation, value: isolated)
    }
}

struct NativeStackedBarChart: View {
    var series: [NativeChartSeries]
    var height: CGFloat = 250
    var xFormat: (Double) -> String = NativeNumberFormat.compact
    var yFormat: (Double) -> String = NativeNumberFormat.compact
    @State private var isolated: String?
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        let points = NativeChartMath.samples(series.filter { isolated == nil || $0.id == isolated })
        let sums = Dictionary(grouping: points, by: \.x).values.flatMap { group in
            [group.reduce(0) { $0 + max(0, $1.y) }, group.reduce(0) { $0 + min(0, $1.y) }]
        }
        let yDomain = NativeChartMath.domain(sums)
        VStack(alignment: .leading, spacing: 12) {
            if points.isEmpty {
                NativeEmptyState(title: "No measured columns", detail: "Missing readings remain gaps.", icon: "chart.bar")
            } else {
                Chart(points) { point in
                    BarMark(x: .value("Position", point.x), y: .value("Value", point.y))
                        .foregroundStyle(point.color)
                        .cornerRadius(0)
                        .accessibilityLabel(point.label + ", " + xFormat(point.x))
                        .accessibilityValue(yFormat(point.y))
                }
                .chartYScale(domain: yDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) { value in
                        AxisGridLine().foregroundStyle(Theme.grid)
                        AxisValueLabel {
                            if let x = value.as(Double.self) { Text(xFormat(x)).font(Theme.mono(9)).foregroundStyle(Theme.muted) }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: NativeChartMath.ticks(yDomain)) { value in
                        AxisGridLine().foregroundStyle(Theme.grid)
                        AxisValueLabel {
                            if let y = value.as(Double.self) { Text(yFormat(y)).font(Theme.mono(9)).foregroundStyle(Theme.muted) }
                        }
                    }
                }
                .chartLegend(.hidden)
                // The plot grows as one unit; individual segments never bounce
                // apart or acquire pill-shaped corners during the entrance.
                .chartPlotStyle { plot in plot.nativeEntrance(.growVertical) }
                .chartOverlay { proxy in NativeChartOverlay(proxy: proxy, samples: points, xFormat: xFormat, yFormat: yFormat) }
                .frame(height: height)
                .animation(reduceMotion || !visible ? nil : NativeMotion.isolation, value: isolated)
            }
            NativeChartLegend(entries: series.map { NativeLegendEntry(id: $0.id, label: $0.label, color: $0.color) }, selection: $isolated)
        }
        .onChange(of: series) {
            if let isolated, !series.contains(where: { $0.id == isolated }) { self.isolated = nil }
        }
    }
}

struct NativeRankEntry: Identifiable {
    var id: String
    var title: String
    var detail: String = ""
    var value: Double?
    var low: Double? = nil
    var high: Double? = nil
    var color: Color? = nil
}

struct NativeRankingChart: View {
    var rows: [NativeRankEntry]
    var lowerIsBetter: Bool = false
    var fixedMaximum: Double? = nil
    var format: (Double) -> String = NativeNumberFormat.compact

    var body: some View {
        let values = rows.compactMap(\.value).filter(\.isFinite)
        let best = fixedMaximum ?? (lowerIsBetter ? values.min() : values.max()) ?? 1
        VStack(spacing: 2) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                NativeRankBarRow(row: row, rank: index + 1, best: best,
                                 lowerIsBetter: lowerIsBetter, format: format)
            }
        }
    }
}

private struct NativeRankBarRow: View {
    var row: NativeRankEntry
    var rank: Int
    var best: Double
    var lowerIsBetter: Bool
    var format: (Double) -> String
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var color: Color { row.color ?? Theme.pairColor(row.id) }
    private func fraction(_ value: Double) -> Double {
        guard best.isFinite, best >= 0, value.isFinite, value >= 0 else { return 0 }
        if lowerIsBetter {
            if value == 0 { return 1 }
            return NativeMotion.fraction(best / value)
        }
        return best > 0 ? NativeMotion.fraction(value / best) : 0
    }
    private var spread: ClosedRange<Double>? {
        guard let low = row.low, let high = row.high, low.isFinite, high.isFinite, high > low else { return nil }
        let a = fraction(low), b = fraction(high)
        return min(a, b)...max(a, b)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%02d", rank)).font(Theme.mono(10)).foregroundStyle(Theme.muted)
                    .frame(width: 18, alignment: .leading)
                Text(row.title).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                if !row.detail.isEmpty { Text(row.detail).font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1) }
                Spacer(minLength: 12)
                NativeNumberText(text: row.value.flatMap { $0.isFinite ? format($0) : nil } ?? "-",
                                 font: Theme.mono(12, weight: .medium), delay: Double(rank - 1) * 0.045)
            }
            NativeGrowBar(fraction: row.value.map(fraction) ?? 0, color: color,
                          delay: Double(rank - 1) * 0.045, spread: spread)
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(hovering ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .combine)
    }
}
