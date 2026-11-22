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

    /// Unlabelled graduations between the labelled ticks of a ruler axis.
    static func minorTicks(_ majors: [Double], in domain: ClosedRange<Double>, divisions: Int = 5) -> [Double] {
        guard majors.count >= 2, divisions > 1 else { return [] }
        let step = (majors[1] - majors[0]) / Double(divisions)
        guard step.isFinite, step > 0 else { return [] }
        let below = ((majors[0] - domain.lowerBound) / step).rounded(.down)
        let above = ((domain.upperBound - majors[0]) / step).rounded(.down)
        guard below.isFinite, above.isFinite, below + above < 400 else { return [] }
        var result: [Double] = []
        for index in Int(-below)...Int(above) where index % divisions != 0 {
            result.append(majors[0] + Double(index) * step)
        }
        return result
    }

    /// A logarithmic ruler: 1, 2 and 5 of each decade carry labels (only the
    /// decades themselves across a wide span); the other digits graduate it.
    static func logTicks(_ domain: ClosedRange<Double>) -> (majors: [Double], minors: [Double]) {
        guard domain.lowerBound > 0, domain.upperBound.isFinite, domain.upperBound > domain.lowerBound else { return ([], []) }
        let first = floor(log10(domain.lowerBound)), last = ceil(log10(domain.upperBound))
        guard first.isFinite, last.isFinite, last - first <= 24 else { return ([], []) }
        let wide = last - first > 2
        var majors: [Double] = [], minors: [Double] = []
        for exponent in Int(first)...Int(last) {
            let decade = pow(10, Double(exponent))
            for digit in 1...9 {
                let value = decade * Double(digit)
                guard domain.contains(value) else { continue }
                if digit == 1 || (!wide && (digit == 2 || digit == 5)) { majors.append(value) } else { minors.append(value) }
            }
        }
        // A span inside one decade leaves too few labelled graduations: label 3 and 7 as well, or fall back to an even ruler.
        if majors.count < 3 {
            let promoted = minors.filter { value in
                let digit = (value / pow(10, floor(log10(value)))).rounded()
                return digit == 3 || digit == 7
            }
            majors = (majors + promoted).sorted()
            minors.removeAll(where: promoted.contains)
        }
        if majors.count < 3 { majors = ticks(domain).filter(domain.contains); minors = [] }
        return (majors, minors)
    }

    private static func endpoints(_ domain: ClosedRange<Double>) -> [Double] {
        var result = [domain.lowerBound]
        if domain.lowerBound < 0 && domain.upperBound > 0 { result.append(0) }
        if domain.upperBound != domain.lowerBound { result.append(domain.upperBound) }
        return result
    }
}

/// A plot's name and one line saying how to read it.
struct NativeChartHeading: View {
    var title: String
    var caption: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.heading()).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if !caption.isEmpty {
                Text(caption).font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

typealias ChartHeading = NativeChartHeading

/// The mark that ties a row, a legend entry or a tooltip line to its series.
struct NativeSeriesTick: View {
    var color: Color
    var height: CGFloat = 10
    var body: some View {
        Rectangle().fill(color).frame(width: 3, height: height).accessibilityHidden(true)
    }
}

/// Left-aligned items that wrap onto further lines instead of scrolling away.
struct NativeChartFlow: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    private func rows(_ width: CGFloat, _ subviews: Subviews) -> [(range: Range<Int>, height: CGFloat)] {
        var result: [(range: Range<Int>, height: CGFloat)] = []
        var start = 0, x: CGFloat = 0, height: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if index > start, x + size.width > width {
                result.append((start..<index, height)); start = index; x = 0; height = 0
            }
            x += size.width + spacing; height = max(height, size.height)
        }
        if start < subviews.count { result.append((start..<subviews.count, height)) }
        return result
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? .greatestFiniteMagnitude
        let lines = rows(width, subviews)
        let height = lines.reduce(0) { $0 + $1.height } + rowSpacing * CGFloat(max(0, lines.count - 1))
        let widest = lines.map { line in
            line.range.reduce(-spacing) { $0 + subviews[$1].sizeThatFits(.unspecified).width + spacing }
        }.max() ?? 0
        return CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? max(0, widest), height: height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in rows(bounds.width, subviews) {
            var x = bounds.minX
            for index in line.range {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), anchor: .topLeading,
                                      proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
                x += size.width + spacing
            }
            y += line.height + rowSpacing
        }
    }
}

struct NativeLegendEntry: Identifiable {
    var id: String
    var label: String
    var color: Color
}

/// The legend is a line of tags. Choosing one isolates its series and marks it
/// with the signal tick; choosing it again shows every series.
struct NativeChartLegend: View {
    var entries: [NativeLegendEntry]
    @Binding var selection: String?
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var body: some View {
        NativeChartFlow {
            ForEach(entries) { entry in
                let selected = selection == entry.id
                NativeLegendTag(entry: entry, selected: selected, included: selection == nil || selected) {
                    selection = selected ? nil : entry.id
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion || !visible ? nil : NativeMotion.isolation, value: selection)
    }
}

private struct NativeLegendTag: View {
    let entry: NativeLegendEntry
    let selected: Bool
    let included: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                NativeSeriesTick(color: entry.color)
                Text(entry.label).font(Theme.mono(10.5)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(selected || hovering ? Theme.ink : Theme.dim)
            .padding(.horizontal, 6).frame(height: 20).frame(maxWidth: 260)
            .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(selected ? Theme.pressed : hovering ? Theme.pressed : Theme.hover))
            .overlay(alignment: .bottom) { if selected { Theme.signal.frame(height: 2) } }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .opacity(included ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand(enabled)
        .onHover { hovering = $0 && enabled }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(selected ? "Show every series" : "Show only " + entry.label)
    }
}

struct NativeTooltipLine {
    var label: String
    var value: String
    var color: Color
}

/// A ruled popover: the position on the rule above, one line per series below.
struct NativeChartTooltip: View {
    var title: String
    var lines: [NativeTooltipLine]
    var width: CGFloat = 276
    var detail: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Theme.signal.frame(width: 2, height: 9)
                Text(title).font(Theme.mono(10.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                if !detail.isEmpty {
                    Text(detail).font(Theme.mono(10.5, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).frame(height: 26)
            if !lines.isEmpty {
                Rule()
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(lines.prefix(6).enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 7) {
                            NativeSeriesTick(color: line.color, height: 9)
                            Text(line.label).font(Theme.mono(10.5)).foregroundStyle(Theme.dim)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(line.value).font(Theme.mono(10.5, weight: .medium)).foregroundStyle(Theme.ink)
                                .lineLimit(1)
                        }
                    }
                    if lines.count > 6 {
                        Text("\(lines.count - 6) more series").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
        }
        .frame(width: max(0, width), alignment: .leading)
        .background(Theme.popover, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.ruleStrong))
        .shadow(color: Theme.shadow, radius: 10, y: 4)
        .allowsHitTesting(false)
    }
}

/// Where a tooltip goes: beside the crosshair, on whichever side has room.
enum NativeChartTooltipPlacement {
    static func x(anchor: CGFloat, width: CGFloat, container: CGFloat) -> CGFloat {
        let right = anchor + 12
        if right + width <= container { return max(0, right) }
        let left = anchor - 12 - width
        return left >= 0 ? left : max(0, container - width)
    }
}

/// Ruler axes. Short ticks graduate the edge, long ticks carry the labels, and
/// the plot keeps a hairline spine instead of a grid.
enum NativeChartAxis {
    static let tick = StrokeStyle(lineWidth: 1)

    @AxisContentBuilder
    static func numeric(_ majors: [Double], minors: [Double], position: AxisMarkPosition,
                        format: @escaping (Double) -> String) -> some AxisContent {
        AxisMarks(position: position, values: minors) { _ in
            AxisTick(length: 3, stroke: tick).foregroundStyle(Theme.faint)
        }
        AxisMarks(position: position, values: majors) { value in
            AxisTick(length: 6, stroke: tick).foregroundStyle(Theme.muted)
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(format(number)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    /// Calendar axis: one short tick per `minor` unit, labelled long ticks at
    /// whatever spacing the width allows.
    @AxisContentBuilder
    static func dates(minor: Calendar.Component, labels: Int = 6) -> some AxisContent {
        AxisMarks(values: .stride(by: minor)) { _ in
            AxisTick(length: 3, stroke: tick).foregroundStyle(Theme.faint)
        }
        AxisMarks(values: .automatic(desiredCount: labels)) { _ in
            AxisTick(length: 6, stroke: tick).foregroundStyle(Theme.muted)
            AxisValueLabel().font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
        }
    }

    /// Labelled ticks at positions the chart chooses (logarithmic scales).
    @AxisContentBuilder
    static func automatic(position: AxisMarkPosition, format: @escaping (Double) -> String) -> some AxisContent {
        AxisMarks(position: position) { value in
            AxisTick(length: 6, stroke: tick).foregroundStyle(Theme.muted)
            AxisValueLabel {
                if let number = value.as(Double.self) {
                    Text(format(number)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

extension View {
    /// The plot's spine: a hairline along the bottom and along the value axis.
    func nativePlotSpine(trailing: Bool = true) -> some View {
        overlay(alignment: .bottom) { Theme.baseline.frame(height: 1).allowsHitTesting(false) }
            .overlay(alignment: trailing ? .trailing : .leading) { Theme.baseline.frame(width: 1).allowsHitTesting(false) }
    }
}

/// State is owned by the overlay: every mouse pixel updates just the readout,
/// not the chart's marks or its parent page. Snapping reports measured points.
private struct NativeChartOverlay: View {
    var proxy: ChartProxy
    var samples: [NativeChartSample]
    var markers: Bool
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
                let hovered = nearest
                ZStack(alignment: .topLeading) {
                    if let sample = hovered.first, let x = proxy.position(forX: sample.x) {
                        Rectangle().fill(Theme.signal).frame(width: 1, height: plot.height)
                            .offset(x: plot.minX + x, y: plot.minY)
                        if markers {
                            ForEach(hovered) { point in
                                if let y = proxy.position(forY: point.y) {
                                    Rectangle().fill(Theme.well).frame(width: 7, height: 7)
                                        .overlay(Rectangle().strokeBorder(point.color, lineWidth: 1.5))
                                        .offset(x: plot.minX + x - 3, y: plot.minY + y - 3.5)
                                }
                            }
                        }
                        let width = min(276, geometry.size.width)
                        NativeChartTooltip(title: xFormat(sample.x), lines: hovered.map {
                            NativeTooltipLine(label: $0.label, value: yFormat($0.y), color: $0.color)
                        }, width: width)
                        .offset(x: NativeChartTooltipPlacement.x(anchor: plot.minX + x, width: width, container: geometry.size.width),
                                y: plot.minY + 6)
                    }
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            let next: Double?
                            switch phase {
                            case .active(let location):
                                next = plot.contains(location) ? proxy.value(atX: location.x - plot.minX) : nil
                            case .ended: next = nil
                            }
                            if next != cursor { cursor = next }
                        }
                }
            }
        }
        // The readout follows the pointer at once, whatever transaction an
        // ancestor happens to be in.
        .transaction { $0.animation = nil }
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
        VStack(alignment: .leading, spacing: 14) {
            if points.isEmpty {
                Blank(icon: "chart-line", title: "No measured points", detail: "Measurements appear here when they are available.")
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
        let xDomain = NativeChartMath.domain(points.map(\.x), includeZero: false)
        let yDomain = NativeChartMath.domain(points.map(\.y), includeZero: includeZero)
        let xMajors = NativeChartMath.ticks(xDomain, count: 6), yMajors = NativeChartMath.ticks(yDomain)
        let xMinors = NativeChartMath.minorTicks(xMajors, in: xDomain)
        let yMinors = NativeChartMath.minorTicks(yMajors, in: yDomain)
        return Chart {
            ForEach(points) { point in
                LineMark(x: .value("Position", point.x), y: .value("Value", point.y),
                         series: .value("Path", point.pathID))
                    .foregroundStyle(point.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .round))
                    .interpolationMethod(monotone ? .monotone : .linear)
                if showPoints {
                    PointMark(x: .value("Position", point.x), y: .value("Value", point.y))
                        .foregroundStyle(point.color).symbol(.square).symbolSize(isolated == nil ? 14 : 26)
                        .accessibilityLabel(point.label + ", " + xFormat(point.x))
                        .accessibilityValue(yFormat(point.y))
                }
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis { NativeChartAxis.numeric(xMajors, minors: xMinors, position: .bottom, format: xFormat) }
        .chartYAxis { NativeChartAxis.numeric(yMajors, minors: yMinors, position: .trailing, format: yFormat) }
        .chartLegend(.hidden)
        .chartPlotStyle { plot in plot.nativePlotSpine() }
        .chartOverlay { proxy in
            NativeChartOverlay(proxy: proxy, samples: points, markers: true, xFormat: xFormat, yFormat: yFormat)
        }
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
        VStack(alignment: .leading, spacing: 14) {
            if points.isEmpty {
                Blank(icon: "chart-bar", title: "No measured columns", detail: "Missing readings remain gaps.")
            } else {
                chart(points)
            }
            NativeChartLegend(entries: series.map { NativeLegendEntry(id: $0.id, label: $0.label, color: $0.color) }, selection: $isolated)
        }
        .onChange(of: series) {
            if let isolated, !series.contains(where: { $0.id == isolated }) { self.isolated = nil }
        }
    }

    private func chart(_ points: [NativeChartSample]) -> some View {
        let sums = Dictionary(grouping: points, by: \.x).values.flatMap { group in
            [group.reduce(0) { $0 + max(0, $1.y) }, group.reduce(0) { $0 + min(0, $1.y) }]
        }
        let yDomain = NativeChartMath.domain(sums)
        let yMajors = NativeChartMath.ticks(yDomain)
        let yMinors = NativeChartMath.minorTicks(yMajors, in: yDomain)
        return Chart(points) { point in
            BarMark(x: .value("Position", point.x), y: .value("Value", point.y))
                .foregroundStyle(point.color)
                .cornerRadius(0)
                .accessibilityLabel(point.label + ", " + xFormat(point.x))
                .accessibilityValue(yFormat(point.y))
        }
        .chartYScale(domain: yDomain)
        .chartXAxis { NativeChartAxis.automatic(position: .bottom, format: xFormat) }
        .chartYAxis { NativeChartAxis.numeric(yMajors, minors: yMinors, position: .trailing, format: yFormat) }
        .chartLegend(.hidden)
        .chartPlotStyle { plot in plot.nativePlotSpine() }
        .chartOverlay { proxy in
            NativeChartOverlay(proxy: proxy, samples: points, markers: false, xFormat: xFormat, yFormat: yFormat)
        }
        .frame(height: height)
        .animation(reduceMotion || !visible ? nil : NativeMotion.isolation, value: isolated)
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

/// A ranked ledger: each line is its own meter, drawn against the best value.
struct NativeRankingChart: View {
    var rows: [NativeRankEntry]
    var lowerIsBetter: Bool = false
    var fixedMaximum: Double? = nil
    var format: (Double) -> String = NativeNumberFormat.compact

    var body: some View {
        let values = rows.compactMap(\.value).filter(\.isFinite)
        let best = fixedMaximum ?? (lowerIsBetter ? values.min() : values.max()) ?? 1
        VStack(spacing: 0) {
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
        HStack(alignment: .center, spacing: 12) {
            Text(String(format: "%02d", rank)).font(Theme.mono(10.5)).foregroundStyle(Theme.faint)
                .frame(width: 18, alignment: .leading)
            NativeSeriesTick(color: color)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.title).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                if !row.detail.isEmpty {
                    Text(row.detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Scale(fraction: row.value.map(fraction) ?? 0, color: color, spread: spread)
                .frame(maxWidth: .infinity)
            NativeNumberText(text: row.value.flatMap { $0.isFinite ? format($0) : nil } ?? "-",
                             font: Theme.readout(17), color: row.value == nil ? Theme.faint : Theme.ink)
                .frame(width: 84, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .overlay(alignment: .bottom) { Rule() }
        .accessibilityElement(children: .combine)
    }
}
