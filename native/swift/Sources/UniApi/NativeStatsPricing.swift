import SwiftUI
import UniApiCore

/// The rates behind the cost estimate. Rarely read, so it stays folded under
/// the ledger it explains and grows from its own line.
struct NativeStatsPricing: View {
    let cost: JSONValue
    var compact = false
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
    private func width(_ field: String) -> CGFloat { field.hasPrefix("cache") ? 96 : 70 }
    var body: some View {
        NativeStatsDisclosure(title: "Rates and assumptions", summary: summary,
                              openLabel: "View model prices and unknown costs", closeLabel: "Hide model prices") {
            VStack(alignment: .leading, spacing: 10) {
                Text("USD per million tokens, checked " + cost["ratesDate"].string + ". Your bill can differ for subscriptions, free routes, discounts and historical prices.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                LazyVStack(alignment: .leading, spacing: 0) {
                    LedgerHead {
                        MicroLabel("Model").frame(maxWidth: .infinity, alignment: .leading)
                        if !compact {
                            ForEach(fields, id: \.0) { field in MicroLabel(field.1).fixedSize().frame(width: width(field.0), alignment: .trailing) }
                        }
                        MicroLabel("Estimate").frame(width: 84, alignment: .trailing)
                    }
                    ForEach(Array(cost["rows"].array.enumerated()), id: \.offset) { _, row in
                        NativeStatsPriceRow(row: row, fields: fields, compact: compact)
                    }
                }
            }
        }
    }
}

private struct NativeStatsPriceRow: View {
    let row: JSONValue
    let fields: [(String, String)]
    let compact: Bool
    private var partial: Bool { row["unpricedTokens"].double > 0 && !row["usd"].isNull }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row["model"].string).font(Theme.mono(12)).foregroundStyle(Theme.ink).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    if partial { Tag("partial", tone: Theme.warnFg) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !compact {
                    ForEach(fields, id: \.0) { field in
                        let value = row["rates"][field.0]
                        Text(value.isNull ? "--" : rate(value)).font(Theme.mono(11.5)).monospacedDigit()
                            .foregroundStyle(value.isNull ? Theme.faint : Theme.dim)
                            .frame(width: field.0.hasPrefix("cache") ? 96 : 70, alignment: .trailing)
                    }
                }
                Text(money(row["usd"])).font(Theme.mono(12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(row["usd"].isNull ? Theme.muted : Theme.ink)
                    .frame(width: 84, alignment: .trailing)
            }
            if compact && !row["rates"].isNull {
                Text(fields.map { $0.1 + " " + rate(row["rates"][$0.0]) }.joined(separator: " · "))
                    .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            if !row["reason"].string.isEmpty {
                Text(row["reason"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true)
            }
            if row["unpricedTokens"].double > 0 {
                Text(nativeStatsCount(row["unpricedTokens"].double) + " tokens have unknown cost; excluded from the estimate.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true)
            }
            if !row["assumption"].string.isEmpty {
                Text(row["assumption"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
            }
            if let url = URL(string: row["sourceURL"].string), url.scheme == "https" {
                Link(destination: url) {
                    HStack(spacing: 5) {
                        Text("Official pricing")
                        NativeIcon("external-link", size: 11, strokeWidth: 1.75)
                    }.font(Theme.ui(11.5)).foregroundStyle(Theme.link)
                }.buttonStyle(.plain).pointingHand().padding(.top, 1)
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rule() }
    }
    private func money(_ value: JSONValue) -> String {
        guard !value.isNull else { return "Unpriced" }
        return nativeStatsMoney(value.double)
    }
    private func rate(_ value: JSONValue) -> String {
        value.isNull ? "unpriced" : "$" + value.double.formatted(.number.precision(.fractionLength(0...6)))
    }
}
