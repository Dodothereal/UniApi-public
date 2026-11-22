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
        let contentWidth = min(880, geometry.size.width) - 2 * density.pageMargin
        NativePage(title: "Home", maxWidth: 880, readiness: pageReadiness) {
            if let error { NativeError(message: error) }
            ForEach(domains.object.keys.sorted().filter { !domains[$0]["error"].isNull }, id: \.self) { domain in NativeError(message: domain.capitalized + ": " + domains[domain]["error"].string) }
            // The two facts the app exists for, side by side: where Claude
            // Code is pointed, and what the last benchmark measured.
            Group {
                if contentWidth < 620 { VStack(alignment: .leading, spacing: 28) { routeLead; benchLead } }
                else { HStack(alignment: .top, spacing: 40) { routeLead; NativeRule(vertical: true); benchLead } }
            }.padding(.top, 14).padding(.bottom, 10)
            VStack(spacing: 0) {
                NativeRule()
                destinationRow(.code, value: domains["code"].isNull ? "" : String(domains["code"]["activeThreads"].int), unit: domains["code"]["activeThreads"].int == 1 ? "live thread" : "live threads",
                               detail: domains["code"]["pendingPermissions"].int > 0 ? homeCount(domains["code"]["pendingPermissions"].int, "permission") + " waiting" : domains["code"]["lastTitle"].string.isEmpty ? homeCount(domains["code"]["threads"].int, "thread") : domains["code"]["lastTitle"].string,
                               urgent: domains["code"]["pendingPermissions"].int > 0)
                destinationRow(.arena, value: domains["arena"].isNull ? "" : String(domains["arena"]["pendingVotes"].int), unit: "to judge",
                               detail: domains["arena"]["running"].int > 0 ? homeCount(domains["arena"]["running"].int, "match", plural: "matches") + " running" : homeCount(domains["arena"]["matches"].int, "match", plural: "matches"),
                               urgent: domains["arena"]["pendingVotes"].int > 0)
                destinationRow(.transcribe, value: domains["transcribe"].isNull ? "" : String(domains["transcribe"]["count"].int), unit: domains["transcribe"]["count"].int == 1 ? "transcript" : "transcripts",
                               detail: domains["transcribe"]["running"].int > 0 ? "\(domains["transcribe"]["running"].int) in progress" : domains["transcribe"]["lastTitle"].string)
                destinationRow(.stats, value: domains["stats"]["loaded"].bool ? NativeNumberFormat.compact(domains["stats"]["grand"].double) : "", unit: "tokens",
                               detail: domains["stats"]["loaded"].bool ? homeCount(domains["stats"]["responses"].int, "response") + " · " + homeCount(domains["stats"]["models"].int, "model") : "")
            }
            if !bench["runs"].array.isEmpty {
                NativeSection("Runs", ruled: true, trailing: { Button("All results") { navigate(.results) }.buttonStyle(T3Button(.ghost)) }) {
                    VStack(spacing: 0) {
                        ForEach(Array(bench["runs"].array.enumerated()), id: \.element["id"]) { index, run in
                            NativeHomeRunRow(run: run, timestamp: stamp(run["started"].string), last: index == bench["runs"].array.count - 1) { openRun(run["id"].string) }
                        }
                    }.padding(.top, -14)
                }
            }
            if !snapshot["jobs"].array.isEmpty {
                NativeSection("Jobs", trailing: { Button("All jobs") { navigate(.jobs) }.buttonStyle(T3Button(.ghost)) }) {
                    VStack(spacing: 8) {
                        ForEach(snapshot["jobs"].array.prefix(4), id: \.self["id"]) { job in
                            NativeJobRow(row: job.object, cancel: { Task { do { _ = try await runtime.jobs.cancel(job["id"].string); await reload(force: true) } catch { self.error = error.localizedDescription } } })
                        }
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
        }
        }.nativePageActivity(reads: reads)
    }
    private var shimColor: Color {
        switcher["shim"].isNull ? Theme.muted : switcher["shim"]["ok"].bool ? Theme.okFg : switcher["shim"]["legacyPresent"].bool ? Theme.warnFg : Theme.failFg
    }
    private var routeLead: some View {
        NativeHomeLead(label: "Claude Code", action: { navigate(.switcher) }) {
            NativeNumberText(text: route.name, font: Theme.display(34), isolateLayout: true).lineLimit(1).minimumScaleFactor(0.6)
            Text(route.model).font(Theme.mono(12)).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 14) {
                Text("effort " + route.effort).font(Theme.ui(12)).foregroundStyle(Theme.muted)
                if !switcher["shim"].isNull && !switcher["shim"]["ok"].bool {
                    NativeStatusText(text: switcher["shim"]["legacyPresent"].bool ? "Legacy listener" : "Shim down", color: shimColor)
                }
            }.padding(.top, 2)
        }
    }
    @ViewBuilder private var benchLead: some View {
        let run = bench["lastRun"]
        NativeHomeLead(label: "Benchmark", action: { navigate(bench["running"].bool || run.isNull ? .speed : .results) }) {
            if !bench["error"].isNull {
                Text("Unavailable").font(Theme.display(34)).foregroundStyle(Theme.muted)
            } else if bench["running"].bool {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    NativeNumberText(text: String(Int((bench["progress"].double * 100).rounded())), font: Theme.display(34), color: Theme.accent)
                    Text("%").font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.muted)
                }
                CapsuleBar(fraction: bench["progress"].double, color: Theme.accent).frame(maxWidth: 220)
                NativeStatusText(text: "Measuring " + homeCount(bench["planned"].int, "pair"), color: Theme.accent, pulse: true).padding(.top, 2)
            } else if !run.isNull {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    NativeNumberText(text: String(run["pairs"].array.count), font: Theme.display(34))
                    Text(run["pairs"].array.count == 1 ? "pair measured" : "pairs measured").font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Text(stamp(run["started"].string) + " · " + run["tier"].string).font(Theme.ui(12)).foregroundStyle(Theme.dim)
                Text(run["err"].int == 0 ? homeCount(run["ok"].int, "test") + " passed" : "\(run["err"].int) of \(run["ok"].int + run["err"].int) failed")
                    .font(Theme.ui(12)).foregroundStyle(run["err"].int == 0 ? Theme.muted : Theme.warnFg).padding(.top, 2)
            } else {
                Text(bench.isNull ? " " : "No runs").font(Theme.display(34)).foregroundStyle(Theme.muted)
                if !bench.isNull { Text(homeCount(bench["planned"].int, "pair") + " selected").font(Theme.ui(12)).foregroundStyle(Theme.dim) }
            }
        }
    }
    private func destinationRow(_ page: NativeDestination, value: String, unit: String, detail: String, urgent: Bool = false) -> some View {
        let failed = !domains[page.rawValue]["error"].isNull && !(page == .stats && domains["stats"]["loaded"].bool)
        return NativeLedgerRow(height: 52, action: { navigate(page) }) {
            NativeIcon(page.symbol, size: 15, strokeWidth: 1.6).foregroundStyle(Theme.muted).frame(width: 18)
            Text(page.title).font(Theme.ui(13.5, weight: .medium)).frame(width: 96, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                NativeNumberText(text: failed ? "Unavailable" : value, font: Theme.num(15), color: failed ? Theme.muted : urgent ? Theme.accent : Theme.ink)
                if !failed && !value.isEmpty { Text(unit).font(Theme.ui(12.5)).foregroundStyle(Theme.muted) }
            }.lineLimit(1).fixedSize()
        } trailing: {
            Text(failed ? "" : detail).font(Theme.ui(12.5)).foregroundStyle(urgent ? Theme.dim : Theme.muted).lineLimit(1).truncationMode(.tail)
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

/// One of the two leading statements. The whole block opens its page; the
/// arrow only appears when the pointer is over it.
private struct NativeHomeLead<Content: View>: View {
    let label: String
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text(label).font(Theme.ui(12)).foregroundStyle(hovering ? Theme.ink : Theme.muted)
                    NativeIcon("arrow-up-right", size: 11).foregroundStyle(Theme.accent).opacity(hovering ? 1 : 0).offset(x: hovering ? 0 : -3)
                }.padding(.bottom, 2)
                content()
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading).contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}

private struct NativeHomeRunRow: View {
    let run: JSONValue
    let timestamp: String
    var last = false
    let action: () -> Void
    var body: some View {
        let total = run["ok"].int + run["err"].int
        NativeLedgerRow(height: 44, last: last, action: action) {
            Text(timestamp).font(Theme.num(13, weight: .medium)).frame(width: 150, alignment: .leading).help(run["id"].string)
            Text(run["tier"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).frame(width: 80, alignment: .leading)
            Text(homeCount(run["pairs"].array.count, "pair")).font(Theme.num(12.5, weight: .regular)).foregroundStyle(Theme.dim)
        } trailing: {
            Text(duration).font(Theme.num(12.5, weight: .regular)).foregroundStyle(Theme.muted)
            Text(run["err"].int == 0 ? "\(total) passed" : "\(run["err"].int) of \(total) failed").font(Theme.num(12.5, weight: .regular))
                .foregroundStyle(run["err"].int == 0 ? Theme.dim : Theme.warnFg).frame(width: 110, alignment: .trailing)
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
