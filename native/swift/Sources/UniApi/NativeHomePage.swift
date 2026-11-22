import SwiftUI
import UniApiCore
import UniApiPresentation

struct NativeHomePage: View {
    let runtime: NativeRuntime
    let navigate: (NativeDestination) -> Void
    @EnvironmentObject private var session: NativeAppSession
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
    private var shimText: String {
        switcher["shim"].isNull ? "Checking shim" : switcher["shim"]["ok"].bool ? "Shim up"
            : switcher["shim"]["legacyPresent"].bool ? "Legacy listener kept" : "Shim down"
    }
    private var shimColor: Color {
        switcher["shim"].isNull ? Theme.muted : switcher["shim"]["ok"].bool ? Theme.okFg
            : switcher["shim"]["legacyPresent"].bool ? Theme.warnFg : Theme.failFg
    }
    var body: some View {
        NativePage(title: "Home", eyebrow: "Bench overview", readiness: pageReadiness) {
            Button(bench["running"].bool ? "Watch the run" : "Run a benchmark", nativeIcon: bench["running"].bool ? "activity" : "play") { navigate(.speed) }
                .buttonStyle(Press(.primary))
        } content: {
            if let error { Notice(text: error, tone: .fail) }
            ForEach(domains.object.keys.sorted().filter { !domains[$0]["error"].isNull }, id: \.self) { domain in
                Notice(text: domain.capitalized + ": " + domains[domain]["error"].string, tone: .fail)
            }
            ColumnFlow(minimum: 300, spacing: 32, rowSpacing: 28, maxColumns: 2) {
                HomeReading(label: "Claude Code routes to", tint: Theme.signal, action: { navigate(.switcher) }) {
                    NativeNumberText(text: route.name, font: Theme.display(26), color: Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(route.model).font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    HStack(spacing: 6) {
                        Tag("effort " + route.effort)
                        Tag(shimText, tone: shimColor, dot: true)
                    }.padding(.top, 4)
                }
                HomeReading(label: bench["running"].bool ? "Benchmark running" : "Last benchmark", tint: bench["running"].bool ? Theme.ok : nil,
                            action: { navigate(bench["running"].bool ? .speed : .results) }) {
                    benchReading
                }
            }
            ColumnFlow(minimum: 160, spacing: 32, rowSpacing: 24, maxColumns: 4) {
                summary(.code, value: domains["code"].isNull ? "" : String(domains["code"]["activeThreads"].int),
                        unit: domains["code"]["activeThreads"].int == 1 ? "live thread" : "live threads",
                        detail: domains["code"].isNull ? "Reading saved threads" : domains["code"]["pendingPermissions"].int > 0 ? homeCount(domains["code"]["pendingPermissions"].int, "permission") + " waiting" : domains["code"]["lastTitle"].string.isEmpty ? homeCount(domains["code"]["threads"].int, "thread") + " saved" : domains["code"]["lastTitle"].string,
                        alert: domains["code"]["pendingPermissions"].int > 0)
                summary(.arena, value: domains["arena"].isNull ? "" : String(domains["arena"]["pendingVotes"].int), unit: "to judge",
                        detail: domains["arena"].isNull ? "Reading saved matches" : domains["arena"]["running"].int > 0 ? homeCount(domains["arena"]["running"].int, "match", plural: "matches") + " running" : homeCount(domains["arena"]["matches"].int, "match", plural: "matches") + " played",
                        alert: domains["arena"]["pendingVotes"].int > 0)
                summary(.transcribe, value: domains["transcribe"].isNull ? "" : String(domains["transcribe"]["count"].int),
                        unit: domains["transcribe"]["count"].int == 1 ? "transcript" : "transcripts",
                        detail: domains["transcribe"]["running"].int > 0 ? "\(domains["transcribe"]["running"].int) in progress" : domains["transcribe"]["lastTitle"].string.isEmpty ? "Links and files to text" : domains["transcribe"]["lastTitle"].string)
                summary(.stats, value: domains["stats"]["loaded"].bool ? NativeNumberFormat.compact(domains["stats"]["grand"].double) : "", unit: "tokens",
                        detail: domains["stats"]["loaded"].bool ? (domains["stats"]["provenance"] == "cache" ? "Saved usage · " : "") + homeCount(domains["stats"]["responses"].int, "response") + " · " + homeCount(domains["stats"]["models"].int, "model") : "Usage refresh runs in the background")
            }
            if !bench["runs"].array.isEmpty {
                Band(title: "Recent runs", spacing: 0) {
                    Button("All results") { navigate(.results) }.buttonStyle(Press(.quiet))
                } content: {
                    ForEach(bench["runs"].array, id: \.self["id"]) { run in
                        NativeHomeRunRow(run: run, timestamp: stamp(run["started"].string)) { openRun(run["id"].string) }
                    }
                }
            }
            Band(title: "Background work", spacing: 0) {
                Button("All jobs") { navigate(.jobs) }.buttonStyle(Press(.quiet))
            } content: {
                if snapshot.isNull {
                    if error == nil { Text("Reading recent jobs").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20) }
                } else if snapshot["jobs"].array.isEmpty {
                    Blank(icon: NativeDestination.jobs.symbol, title: "Nothing running in the background", detail: "Benchmarks, transcriptions and Arena matches report here while they work.")
                } else {
                    ForEach(snapshot["jobs"].array.prefix(4), id: \.self["id"]) { job in
                        NativeJobRow(row: job.object, cancel: { Task { do { _ = try await runtime.jobs.cancel(job["id"].string); await reload(force: true) } catch { self.error = error.localizedDescription } } })
                            .overlay(alignment: .bottom) { Rule() }
                    }
                }
            }
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
        }.nativePageActivity(reads: reads)
    }
    @ViewBuilder private var benchReading: some View {
        if !bench["error"].isNull {
            Text("Unavailable").font(Theme.display(26)).foregroundStyle(Theme.muted)
        } else if bench["running"].bool {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                NativeNumberText(text: String(Int((bench["progress"].double * 100).rounded())), font: Theme.readout(34), color: Theme.ink)
                MicroLabel("percent")
            }
            Scale(fraction: bench["progress"].double, color: Theme.ok, ticks: true).frame(maxWidth: 280).padding(.top, 2)
        } else if !bench["lastRun"].isNull {
            let run = bench["lastRun"]
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                NativeNumberText(text: String(run["pairs"].array.count), font: Theme.readout(34), color: Theme.ink)
                MicroLabel(run["pairs"].array.count == 1 ? "pair measured" : "pairs measured")
            }
            Text(stamp(run["started"].string) + " · " + run["tier"].string).font(Theme.mono(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            HStack(spacing: 6) {
                Tag(run["err"].int == 0 ? "all " + homeCount(run["ok"].int, "test") + " passed" : "\(run["err"].int) of \(run["ok"].int + run["err"].int) failed",
                    tone: run["err"].int == 0 ? Theme.okFg : Theme.warnFg, dot: true)
                Tag("\(bench["planned"].int) selected")
            }.padding(.top, 4)
        } else {
            Text(bench.isNull ? "Reading history" : "Nothing measured").font(Theme.display(26)).foregroundStyle(bench.isNull ? Theme.muted : Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text("Pick providers and models, then start a run.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            if !bench.isNull { Tag(homeCount(bench["planned"].int, "pair") + " selected").padding(.top, 4) }
        }
    }
    private func summary(_ page: NativeDestination, value: String, unit: String, detail: String, alert: Bool = false) -> some View {
        let failed = !(domains[page.rawValue]["error"].isNull || page == .stats && domains["stats"]["loaded"].bool)
        return HomeReading(label: page.title, tint: alert ? Theme.signal : nil, action: { navigate(page) }) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                NativeNumberText(text: failed ? "--" : value.isEmpty ? "--" : value, font: Theme.readout(34),
                                 color: failed || value.isEmpty ? Theme.faint : Theme.ink)
                if !failed { MicroLabel(unit) }
            }
            Text(domains[page.rawValue]["error"].isNull ? detail : domains[page.rawValue]["error"].string)
                .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
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

/// A reading that is also the way into its page. It hangs from a ticked rule;
/// hovering strengthens the rule and shows where the click leads.
private struct HomeReading<Content: View>: View {
    let label: String
    var tint: Color? = nil
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    (hovering ? Theme.ruleStrong : Theme.rule).frame(height: 1)
                    (tint ?? Theme.ink).frame(width: 2, height: 7)
                }.frame(height: 7, alignment: .top).padding(.bottom, 10)
                HStack(spacing: 6) {
                    MicroLabel(label, color: hovering ? Theme.ink : Theme.muted)
                    Spacer(minLength: 0)
                    NativeIcon("arrow-up-right", size: 11, strokeWidth: 1.75).foregroundStyle(Theme.ink)
                        .opacity(hovering ? 1 : 0).offset(x: hovering ? 0 : -3, y: hovering ? 0 : 3)
                }
                VStack(alignment: .leading, spacing: 5) { content() }.padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}

private struct NativeHomeRunRow: View {
    let run: JSONValue
    let timestamp: String
    let action: () -> Void
    var body: some View {
        LedgerRow(minHeight: 40, action: action) {
            HStack(spacing: 12) {
                Text(timestamp).font(Theme.mono(12)).foregroundStyle(Theme.ink).frame(width: 150, alignment: .leading)
                Tag(run["tier"].string)
                Text(homeCount(run["pairs"].array.count, "pair") + " in " + duration).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1).help(run["id"].string)
                Spacer(minLength: 8)
                Text("\(run["ok"].int) passed").font(Theme.mono(11)).foregroundStyle(Theme.okFg).frame(width: 78, alignment: .trailing)
                Text("\(run["err"].int) failed").font(Theme.mono(11)).foregroundStyle(run["err"].int == 0 ? Theme.faint : Theme.warnFg).frame(width: 78, alignment: .trailing)
                NativeIcon("arrow-up-right", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
            }
        }
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
