import SwiftUI
import UniApiCore

struct NativeStatsPricing: View {
    let cost: JSONValue
    @Environment(\.nativeReducedMotion) private var reducedMotion
    @State private var expanded = false
    private let fields = [("input", "Input"), ("output", "Output"), ("cacheWrite", "Cache write"), ("cacheRead", "Cache read")]
    private var coverage: Int {
        let all = cost["pricedTokens"].double + cost["unpricedTokens"].double
        return all > 0 ? Int((100 * cost["pricedTokens"].double / all).rounded(.down)) : 0
    }
    private var summary: String {
        if cost.isNull { return "Prices not available yet" }
        let priced = cost["pricedTokens"].double, unknown = cost["unpricedTokens"].double
        if priced + unknown <= 0 { return "No usage recorded yet" }
        if unknown > 0 {
            let models = cost["unpriced"].array.count
            let missing = models > 0 ? "Cost unknown for \(models) " + (models == 1 ? "model" : "models") : "Some usage is unpriced"
            return priced > 0 ? "\(coverage)% of tokens priced · " + missing.lowercased() : missing
        }
        return "Based on current API rates"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Model costs").font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(summary).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button {
                    withAnimation(reducedMotion ? nil : .easeOut(duration: 0.16)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(expanded ? "Hide prices" : "View prices")
                        NativeIcon(expanded ? "chevron-up" : "chevron-down", size: 11)
                    }.foregroundStyle(Theme.link)
                }.buttonStyle(T3Button(.ghost))
                    .accessibilityLabel(expanded ? "Hide model prices" : "View model prices and unknown costs")
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            }.padding(.vertical, 4)
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Estimates use current API rates. Your bill can differ for subscriptions, free routes, discounts and historical prices.")
                        .font(Theme.ui(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Text("USD per million tokens · checked " + cost["ratesDate"].string)
                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(cost["rows"].array.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(row["model"].string).font(Theme.mono(12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Text(money(row["usd"]) + (row["unpricedTokens"].double > 0 && !row["usd"].isNull ? " · partial" : ""))
                                        .font(Theme.mono(12, weight: .medium)).fixedSize()
                                }
                                if !row["rates"].isNull {
                                    Text(fields.map { $0.1 + " " + rate(row["rates"][$0.0]) }.joined(separator: " · "))
                                        .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                }
                                if !row["reason"].string.isEmpty {
                                    Text(row["reason"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true)
                                }
                                if row["unpricedTokens"].double > 0 {
                                    Text(nativeStatsCount(row["unpricedTokens"].double) + " tokens have unknown cost; excluded from the estimate.")
                                        .font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true)
                                }
                                if !row["assumption"].string.isEmpty {
                                    Text(row["assumption"].string).font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                                }
                                if let url = URL(string: row["sourceURL"].string), url.scheme == "https" {
                                    Link("Official pricing", destination: url).font(Theme.ui(11.5))
                                }
                            }
                        }
                    }
                }.padding(.top, 14)
            }
        }
    }
    private func money(_ value: JSONValue) -> String {
        guard !value.isNull else { return "Unpriced" }
        return value.double > 0 && value.double < 0.01 ? "<$0.01" : value.double.formatted(.currency(code: "USD"))
    }
    private func rate(_ value: JSONValue) -> String {
        value.isNull ? "unpriced" : "$" + value.double.formatted(.number.precision(.fractionLength(0...6)))
    }
}
