import SwiftUI
import UniApiCore

struct NativeStatsPricing: View {
    let cost: JSONValue
    private let fields = [("input", "Input"), ("output", "Output"), ("cacheWrite", "Cache write"), ("cacheRead", "Cache read")]
    private var coverage: Int {
        let all = cost["pricedTokens"].double + cost["unpricedTokens"].double
        return all > 0 ? Int((100 * cost["pricedTokens"].double / all).rounded(.down)) : 0
    }
    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current API reference-price estimate, not your account bill. Subscription fees, free routes, historical prices, request tiers and cache storage can differ.")
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
            }.padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("API pricing and coverage · \(coverage)% of tokens priced").font(Theme.ui(12, weight: .medium))
                Text(cost["unpricedTokens"].double > 0
                     ? "Unknown cost: " + nativeStatsCount(cost["unpricedTokens"].double) + " tokens across \(cost["unpriced"].array.count) models. Actual billed spend unavailable."
                     : "API reference value. Actual billed spend unavailable.")
                    .font(Theme.ui(11.5)).foregroundStyle(cost["unpricedTokens"].double > 0 ? Theme.warnFg : Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
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
