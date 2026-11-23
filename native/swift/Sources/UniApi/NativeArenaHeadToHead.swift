import SwiftUI
import UniApiCore

struct NativeArenaHeadToHead: View {
    let rows: [JSONValue], comparisons: [JSONValue]
    @State private var expanded = true
    @State private var rowPage = 0
    @State private var columnPage = 0
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @Environment(\.nativeMotionVisible) private var motionVisible
    private let pageSize = 8
    private var pages: Int { max(1, (rows.count + pageSize - 1) / pageSize) }

    private func page(_ index: Int) -> ArraySlice<JSONValue> {
        rows.dropFirst(min(index, pages - 1) * pageSize).prefix(pageSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(reducedMotion || !motionVisible ? nil : NativeMotion.reveal) { expanded.toggle() }
            } label: {
                HStack {
                    NativeIcon(expanded ? "chevron-down" : "chevron-right", size: 12)
                    Text("Head-to-head win rate").font(Theme.ui(Theme.textSm, weight: .semibold))
                    Spacer()
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHand().accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                Text("Each row’s wins against the column model. Draws count in the sample, not as wins. A dash means the pair has not been rated.")
                    .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if pages > 1 {
                    HStack {
                        pagePicker("Rows", selection: $rowPage)
                        pagePicker("Columns", selection: $columnPage)
                    }
                }
                grid
            }
        }.padding(.horizontal, density.pageMargin).padding(.vertical, 16)
            .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
            .onChange(of: rows.map { $0["key"].string }) { _, _ in rowPage = 0; columnPage = 0 }
    }

    private func pagePicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(0..<pages, id: \.self) { index in
                Text("\(index * pageSize + 1)–\(min(rows.count, (index + 1) * pageSize)) of \(rows.count)").tag(index)
            }
        }.controlSize(.small).fixedSize()
    }

    private var grid: some View {
        let matrix = ArenaPairMatrix(comparisons), columns = page(columnPage)
        return HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Model").font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 32)
                ForEach(page(rowPage), id: \.self["key"]) { row in axis(row, width: 100, alignment: .leading) }
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        ForEach(columns, id: \.self["key"]) { column in axis(column, width: 70, alignment: .center) }
                    }
                    ForEach(page(rowPage), id: \.self["key"]) { row in
                        HStack(spacing: 4) {
                            ForEach(columns, id: \.self["key"]) { column in
                                cell(matrix[row["key"].string, column["key"].string], row: row, column: column)
                            }
                        }
                    }
                }
            }
        }
    }

    private func label(_ row: JSONValue) -> String { row["model"].string + " · " + row["route"].string }

    private func axis(_ row: JSONValue, width: CGFloat, alignment: Alignment) -> some View {
        Text(row["model"].string).font(Theme.mono(11)).lineLimit(1).truncationMode(.middle)
            .frame(width: width, height: 32, alignment: alignment).help(label(row)).accessibilityLabel(label(row))
    }

    private func cell(_ result: ArenaPairResult?, row: JSONValue, column: JSONValue) -> some View {
        let rate = result?.winRate, same = row["key"] == column["key"]
        let display = rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let detail = result.map { "\(display), \($0.wins) wins, \($0.losses) losses, \($0.draws) draws in \($0.sample) comparisons" }
            ?? (same ? "Same model" : "No rated comparisons")
        let title = "\(label(row)) against \(label(column))"
        return VStack(spacing: 0) {
            Text(display).font(Theme.num(11, weight: .semibold)).foregroundStyle(rate == nil ? Theme.muted : Theme.ink)
            if let result { Text("n=\(result.sample)").font(Theme.num(10, weight: .regular)).foregroundStyle(Theme.dim) }
        }.frame(width: 70, height: 32)
            .background(rate.map { Theme.series[0].opacity(0.08 + $0 * 0.38) } ?? Theme.sunken, in: RoundedRectangle(cornerRadius: 4))
            .help("\(title): \(detail)").accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityValue(detail)
    }
}
