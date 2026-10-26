import SwiftUI
import UniApiCore
import UniApiPresentation

struct NativeHomePage: View {
    let runtime: NativeRuntime
    let navigate: (NativeDestination) -> Void
    @EnvironmentObject private var session: NativeAppSession
    @Environment(\.nativeInterfaceDensity) private var density
    @State private var snapshot: JSONValue = .null
    @State private var domains: JSONValue = .null
    @State private var error: String?
    @State private var reads = NativePageReadScope()
    @State private var subscription: NativePageReadScope.Ticket?
    private var switcher: JSONValue { domains["switcher"] }
    private var bench: JSONValue { domains["bench"] }
    private var route: NativeShellPolicy.Route { NativeShellPolicy.route(switcher, dashboard: snapshot) }
    private var pageReadiness: NativePageReadiness {
        if error != nil || domains.object.values.contains(where: { !$0["error"].isNull }) { return .failed }
        if snapshot.isNull || domains.isNull || !domains["stats"]["loaded"].bool { return .pending }
        return .ready
    }
    var body: some View {
        GeometryReader { geometry in
        let contentWidth = min(820, geometry.size.width) - 2 * density.pageMargin
        NativePage(title: "Home", readiness: pageReadiness, showsHeader: false) {
            VStack(spacing: 12) {
                UniApiMark(size: 54)
                (Text("Uni").fontWeight(.bold) + Text("Api").fontWeight(.light)).font(Theme.ui(34)).tracking(-0.34)
                Text("Benchmark every provider you hold a key for, judge them blind, point Claude Code at whichever one wins, and do the work here.")
                    .font(Theme.ui(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 430)
            }.frame(maxWidth: .infinity).padding(.top, 22).padding(.bottom, 6)
            if let error { NativeError(message: error) }
            ForEach(domains.object.keys.sorted().filter { !domains[$0]["error"].isNull }, id: \.self) { domain in NativeError(message: domain.capitalized + ": " + domains[domain]["error"].string) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: contentWidth < 600 ? 1 : 2), spacing: 14) {
                NativeHomeCard(title: "Claude Code", symbol: "route", action: { navigate(.switcher) }) {
                    NativeNumberText(text: route.name, font: Theme.ui(21, weight: .semibold))
                    Text(route.model).font(Theme.mono(12)).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 3)
                    HStack(spacing: 6) {
                        Text("effort " + route.effort).font(Theme.mono(11)).padding(.horizontal, 7).padding(.vertical, 3).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 5))
                        HStack(spacing: 5) {
                            NativeStatusDot(color: switcher["shim"]["ok"].bool ? Theme.okFg : Theme.muted, size: 5)
                            Text(switcher["shim"].isNull ? "Checking shim" : switcher["shim"]["ok"].bool ? "Swift shim available" : switcher["shim"]["legacyPresent"].bool ? "Legacy listener preserved" : "Swift shim unavailable").font(Theme.ui(11))
                        }.padding(.horizontal, 7).padding(.vertical, 3).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 5))
                    }.foregroundStyle(Theme.muted).padding(.top, 4)
                }
                NativeHomeCard(title: "Benchmark", symbol: "play", action: { navigate(bench["running"].bool ? .speed : .results) }) {
                    if !bench["error"].isNull {
                        Text("Benchmark unavailable").font(Theme.ui(21, weight: .semibold))
                    } else if bench["running"].bool {
                        NativeNumberText(text: "Run in progress", font: Theme.ui(21, weight: .semibold))
                        CapsuleBar(fraction: bench["progress"].double, color: Theme.ok)
                        HStack { NativeStatusDot(color: Theme.okFg, pulse: true); Text("Measuring now").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
                    } else if !bench["lastRun"].isNull {
                        let run = bench["lastRun"]
                        NativeNumberText(text: homeCount(run["pairs"].array.count, "pair") + " measured", font: Theme.ui(21, weight: .semibold))
                        Text(stamp(run["started"].string) + " · " + run["tier"].string).font(Theme.mono(12)).foregroundStyle(Theme.muted).padding(.top, 3)
                        HStack(spacing: 6) {
                            Text(run["err"].int == 0 ? "All " + homeCount(run["ok"].int, "test") + " passed" : "\(run["err"].int) of \(run["ok"].int + run["err"].int) failed")
                                .font(Theme.ui(11)).foregroundStyle(run["err"].int == 0 ? Theme.okFg : Theme.warnFg)
                            Text("\(bench["planned"].int) selected").font(Theme.mono(10)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                        }.padding(.top, 4)
                    } else {
                        Text(bench.isNull ? "Reading run history…" : "Nothing measured yet").font(Theme.ui(21, weight: .semibold))
                        Text("Choose providers and models, then start a run.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                        if !bench.isNull { Text(homeCount(bench["planned"].int, "selected pair")).font(Theme.mono(10)).foregroundStyle(Theme.muted) }
                    }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: contentWidth < 350 ? 1 : contentWidth < 600 ? 2 : 4), spacing: 12) {
                summaryCard(.code, value: domains["code"].isNull ? "Reading…" : homeCount(domains["code"]["activeThreads"].int, "live thread"), detail: domains["code"].isNull ? "Reading saved threads…" : domains["code"]["pendingPermissions"].int > 0 ? homeCount(domains["code"]["pendingPermissions"].int, "permission") + " waiting" : domains["code"]["lastTitle"].string.isEmpty ? homeCount(domains["code"]["threads"].int, "thread") : domains["code"]["lastTitle"].string)
                summaryCard(.arena, value: domains["arena"].isNull ? "Reading…" : "\(domains["arena"]["pendingVotes"].int) to judge", detail: domains["arena"].isNull ? "Reading saved matches…" : domains["arena"]["running"].int > 0 ? homeCount(domains["arena"]["running"].int, "match", plural: "matches") + " running" : homeCount(domains["arena"]["matches"].int, "match", plural: "matches"))
                summaryCard(.transcribe, value: domains["transcribe"].isNull ? "Reading…" : homeCount(domains["transcribe"]["count"].int, "transcript"), detail: domains["transcribe"]["running"].int > 0 ? "\(domains["transcribe"]["running"].int) in progress" : domains["transcribe"]["lastTitle"].string.isEmpty ? "Links and files to text" : domains["transcribe"]["lastTitle"].string)
                summaryCard(.stats, value: domains["stats"]["loaded"].bool ? NativeNumberFormat.compact(domains["stats"]["grand"].double) + " tokens" : "Reading…", detail: domains["stats"]["loaded"].bool ? (domains["stats"]["provenance"] == "cache" ? "Saved usage · " : "") + homeCount(domains["stats"]["responses"].int, "response") + " · " + homeCount(domains["stats"]["models"].int, "model") : "Usage refresh runs in the background")
            }
            if !bench["runs"].array.isEmpty {
                VStack(spacing: 11) {
                    SectionLabel(text: "Recent runs") { Button("See all results") { navigate(.results) }.buttonStyle(T3Button(.ghost)) }
                    Card(padding: 0) {
                        ForEach(Array(bench["runs"].array.enumerated()), id: \.element["id"]) { index, run in
                            if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                            NativeHomeRunRow(run: run, timestamp: stamp(run["started"].string)) { openRun(run["id"].string) }
                        }
                    }
                }
            }
            SectionLabel(text: "Activity") { Button("All jobs") { navigate(.jobs) }.buttonStyle(T3Button(.ghost)) }
            if snapshot.isNull {
                if error == nil { ShimmerText(text: "Reading recent jobs…").frame(maxWidth: .infinity).padding(.vertical, 28) }
            } else if snapshot["jobs"].array.isEmpty { NativeEmptyState(title: "No recent jobs", detail: "Background work appears here once started.") }
            else { ForEach(snapshot["jobs"].array.prefix(4), id: \.self["id"]) { job in
                NativeJobRow(row: job.object, cancel: { Task { do { _ = try await runtime.jobs.cancel(job["id"].string); await reload(force: true) } catch { self.error = error.localizedDescription } } })
            } }
        }.nativePageTask {
            // Subscribe before fanout so a completed usage refresh cannot land
            // between the initial cached read and event subscription.
            guard let listener = reads.begin("events") else { return }
            let events = await runtime.events.stream()
            guard reads.accepts(listener) else { return }
            subscription = listener
            await reload(force: true)
            guard reads.accepts(listener) else { return }
            for await event in events {
                guard reads.accepts(listener) else { break }
                if event.topic == "job.progress" || event.topic == "job.log" {
                    var jobs = snapshot["jobs"].array
                    if let index = jobs.firstIndex(where: { $0["id"] == event.data["id"] }) { jobs[index] = event.data; snapshot["jobs"] = .array(jobs) }
                } else if NativeShellPolicy.refreshesHome(event.topic) {
                    await reload(force: true)
                }
            }
        }.nativePageTask {
            // Health can change without a settings mutation; freshness also
            // recovers dropped events after a long hidden/occluded interval.
            guard let periodic = reads.begin("periodic") else { return }
            while reads.accepts(periodic) {
                do { try await Task.sleep(nanoseconds: 30_000_000_000); try Task.checkCancellation() }
                catch { return }
                guard reads.accepts(periodic) else { return }
                await reload(force: true)
            }
        }
        }.nativePageActivity(reads: reads)
    }
    private func summaryCard(_ page: NativeDestination, value: String, detail: String) -> some View {
        NativeHomeCard(title: page.title, symbol: page == .code ? "bot" : page == .arena ? "swords" : page == .transcribe ? "mic" : "chart-line", minHeight: 118, action: { navigate(page) }) {
            NativeNumberText(text: domains[page.rawValue]["error"].isNull || page == .stats && domains["stats"]["loaded"].bool ? value : "Unavailable", font: Theme.ui(17, weight: .semibold))
            Text(domains[page.rawValue]["error"].isNull ? detail : domains[page.rawValue]["error"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(2)
        }
    }
    private func reload(force: Bool = false) async {
        guard let subscription, reads.accepts(subscription), let ticket = reads.begin("snapshot") else { return }
        do {
            if force { await runtime.cache.invalidate("dashboard") }
            guard reads.accepts(ticket) else { return }
            let nextSnapshot = try await NativeDashboardService(runtime: runtime).snapshot()
            guard reads.accepts(ticket) else { return }
            var nextDomains = domains
            if let summaries = session.summaries { nextDomains = try await summaries.snapshot(force: force) }
            guard reads.accepts(ticket) else { return }
            snapshot = nextSnapshot; domains = nextDomains; error = nil
        } catch {
            guard reads.accepts(ticket) else { return }
            self.error = error.localizedDescription
        }
    }
    private func openRun(_ id: String) {
        Task {
            do { _ = try await NativeBenchmarkService.shared(runtime: runtime).handle("saveResultsState", input: ["scope": .string(id), "family": "", "tab": "table", "newestRun": .string(id)]) }
            catch { if !runtime.paths.readOnly { self.error = error.localizedDescription } }
            NotificationCenter.default.post(name: .nativeResultsScope, object: id); navigate(.results)
        }
    }
    private func stamp(_ value: String) -> String { let date = BenchmarkMath.timestamp(value); return date.isFinite && date > 0 ? NativeListTimeFormat.stamp(Date(timeIntervalSince1970: date)) : value }
}

private struct NativeHomeCard<Content: View>: View {
    let title: String, symbol: String
    var minHeight: CGFloat = 152
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeInterfaceDensity) private var density
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) { NativeIcon(symbol, size: 13); Text(title).font(Theme.ui(14, weight: .medium)); Spacer(minLength: 0); NativeIcon("arrow-up-right", size: 12).opacity(hovering ? 1 : 0).offset(x: hovering ? 0 : -4) }.foregroundStyle(hovering ? Theme.dim : Theme.muted)
                VStack(alignment: .leading, spacing: minHeight == 118 ? 6 : 8) { content() }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(20 * density.cardScale).frame(maxWidth: .infinity, minHeight: minHeight, maxHeight: .infinity, alignment: .topLeading)
                .background(hovering ? Theme.popover : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(hovering ? Theme.input : Theme.border, lineWidth: 1) }
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }.animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: hovering)
    }
}

private struct NativeHomeRunRow: View {
    let run: JSONValue
    let timestamp: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(timestamp).font(Theme.mono(12))
                        Text(run["tier"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.subtle, in: RoundedRectangle(cornerRadius: 5))
                    }
                    Text(homeCount(run["pairs"].array.count, "pair") + " · took " + duration).font(Theme.ui(12)).foregroundStyle(Theme.muted).lineLimit(1).help(run["id"].string)
                }
                Spacer(minLength: 8)
                Text("\(run["ok"].int) passed").font(Theme.mono(11)).foregroundStyle(Theme.okFg).frame(width: 78, alignment: .trailing)
                Text("\(run["err"].int) failed").font(Theme.mono(11)).foregroundStyle(run["err"].int == 0 ? Theme.muted : Theme.warnFg).frame(width: 78, alignment: .trailing)
                HStack(spacing: 4) { Text("View"); NativeIcon("arrow-up-right", size: 12) }.font(Theme.ui(12)).foregroundStyle(hovering ? Theme.ink : Theme.muted).frame(width: 54, alignment: .trailing)
            }.padding(.horizontal, 14).padding(.vertical, 10).background(hovering ? Theme.subtle : .clear).contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
    }
    private var duration: String {
        let started = BenchmarkMath.timestamp(run["started"].string), finished = BenchmarkMath.timestamp(run["finished"].string)
        return NativeListTimeFormat.duration(started.isFinite && finished.isFinite && started > 0 && finished > 0 ? max(0, finished - started) * 1000 : 0)
    }
}

private func homeCount(_ count: Int, _ noun: String, plural: String? = nil) -> String {
    "\(count) " + (count == 1 ? noun : plural ?? noun + "s")
}

extension Notification.Name { static let nativeResultsScope = Notification.Name("UniApi.NativeResultsScope") }
