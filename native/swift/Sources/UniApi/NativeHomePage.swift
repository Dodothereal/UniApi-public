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
    var body: some View {
        NativePage(title: "Home", readiness: pageReadiness) {
            if let error { NativeError(message: error) }
            ForEach(domains.object.keys.sorted().filter { !domains[$0]["error"].isNull }, id: \.self) { domain in NativeError(message: domain.capitalized + ": " + domains[domain]["error"].string) }
            NativeReadoutStrip(minCell: 300) {
                routeCell
                benchmarkCell
            }
            if !waiting.isEmpty {
                NativeSection("Waiting on you") {
                    Card(padding: 0) {
                        NativeStack {
                            ForEach(waiting, id: \.title) { item in
                                NativeLinkRow(icon: item.icon, title: item.title, verb: item.verb, tone: Theme.accent) { navigate(item.page) }
                            }
                        }
                    }
                }
            }
            Card(padding: 0) {
                NativeStack {
                    workRow(.code, icon: "bot", value: domains["code"].isNull ? "" : homeCount(domains["code"]["activeThreads"].int, "running thread"),
                            detail: domains["code"].isNull ? "" : domains["code"]["lastTitle"].string.isEmpty ? homeCount(domains["code"]["threads"].int, "thread") : domains["code"]["lastTitle"].string)
                    workRow(.arena, icon: "swords", value: domains["arena"].isNull ? "" : homeCount(domains["arena"]["matches"].int, "match", plural: "matches"),
                            detail: domains["arena"].isNull ? "" : domains["arena"]["running"].int > 0 ? "\(domains["arena"]["running"].int) running" : "")
                    workRow(.transcribe, icon: "mic", value: domains["transcribe"].isNull ? "" : homeCount(domains["transcribe"]["count"].int, "transcript"),
                            detail: domains["transcribe"]["running"].int > 0 ? "\(domains["transcribe"]["running"].int) in progress" : domains["transcribe"]["lastTitle"].string)
                    workRow(.stats, icon: "chart-line", value: domains["stats"]["loaded"].bool ? NativeNumberFormat.compact(domains["stats"]["grand"].double) + " tokens" : "",
                            detail: domains["stats"]["loaded"].bool ? homeCount(domains["stats"]["responses"].int, "response") + " from " + homeCount(domains["stats"]["models"].int, "model") + (domains["stats"]["provenance"] == "cache" ? ", saved copy" : "") : "")
                }
            }
            if !bench["runs"].array.isEmpty {
                NativeSection("Recent runs", trailing: { Button("All results") { navigate(.results) }.buttonStyle(T3Button(.ghost)) }) {
                    Card(padding: 0) {
                        NativeStack {
                            ForEach(bench["runs"].array, id: \.self["id"]) { run in
                                NativeHomeRunRow(run: run, timestamp: stamp(run["started"].string)) { openRun(run["id"].string) }
                            }
                        }
                    }
                }
            }
            if !snapshot["jobs"].array.isEmpty {
                NativeSection("Jobs", trailing: { Button("All jobs") { navigate(.jobs) }.buttonStyle(T3Button(.ghost)) }) {
                    Card(padding: 0) {
                        NativeStack {
                            ForEach(snapshot["jobs"].array.prefix(4), id: \.self["id"]) { job in
                                NativeJobRow(row: job.object, cancel: { Task { do { _ = try await runtime.jobs.cancel(job["id"].string); await reload(force: true) } catch { self.error = error.localizedDescription } } })
                            }
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
        }.nativePageActivity(reads: reads)
    }

    /// Things only the user can move forward. Nothing here when nothing waits.
    private var waiting: [(icon: String, title: String, verb: String, page: NativeDestination)] {
        var items: [(icon: String, title: String, verb: String, page: NativeDestination)] = []
        let permissions = domains["code"]["pendingPermissions"].int, votes = domains["arena"]["pendingVotes"].int
        if permissions > 0 { items.append(("key-round", homeCount(permissions, "permission request") + " in Code", "Review", .code)) }
        if votes > 0 { items.append(("swords", homeCount(votes, "match", plural: "matches") + " to judge", "Judge", .arena)) }
        return items
    }
    private var routeCell: some View {
        let shim = switcher["shim"]
        return NativeHomeCell(label: "Claude Code route", icon: "route", verb: "Switch route", action: { navigate(.switcher) }) {
            NativeNumberText(text: route.name, font: Theme.ui(Theme.textDisplay - 4, weight: .semibold)).tracking(Theme.tracking(24))
            Text(route.model).font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).padding(.top, 6)
            HStack(spacing: 10) {
                MonoChip(text: "effort " + route.effort)
                if !shim.isNull, !shim["ok"].bool {
                    NativeStatus(text: shim["legacyPresent"].bool ? "Legacy listener kept" : "Shim not running", tone: .warn)
                }
            }.padding(.top, 12)
        }
    }
    private var benchmarkCell: some View {
        let run = bench["lastRun"], running = bench["running"].bool
        return NativeHomeCell(label: "Benchmark", icon: "gauge", verb: running ? "Watch run" : run.isNull ? "Set up a run" : "Open results",
                              action: { navigate(running || run.isNull ? .speed : .results) }) {
            if !bench["error"].isNull {
                Text("Unavailable").font(Theme.ui(Theme.textDisplay - 4, weight: .semibold)).tracking(Theme.tracking(24))
            } else if running {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    NativeNumberText(text: String(Int((bench["progress"].double * 100).rounded())), font: Theme.num(Theme.textDisplay - 4)).tracking(Theme.tracking(24))
                    Text("% measured").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                }
                NativeTickMeter(fraction: bench["progress"].double, color: Theme.accent).padding(.top, 12)
            } else if !run.isNull {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    NativeNumberText(text: String(run["pairs"].array.count), font: Theme.num(Theme.textDisplay - 4)).tracking(Theme.tracking(24))
                    Text(run["pairs"].array.count == 1 ? "pair measured" : "pairs measured").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                }
                Text(stamp(run["started"].string) + "  " + run["tier"].string).font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 6)
                HStack(spacing: 10) {
                    NativeStatus(text: run["err"].int == 0 ? homeCount(run["ok"].int, "test") + " passed" : "\(run["err"].int) of \(run["ok"].int + run["err"].int) failed",
                                 tone: run["err"].int == 0 ? .ok : .warn)
                    if bench["planned"].int > 0 { MonoChip(text: "\(bench["planned"].int) selected") }
                }.padding(.top, 12)
            } else {
                Text(bench.isNull ? " " : "No runs yet").font(Theme.ui(Theme.textDisplay - 4, weight: .semibold)).tracking(Theme.tracking(24))
                if !bench.isNull {
                    Text(bench["planned"].int > 0 ? homeCount(bench["planned"].int, "pair") + " selected" : "No models selected").font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted).padding(.top, 6)
                }
            }
        }
    }
    private func workRow(_ page: NativeDestination, icon: String, value: String, detail: String) -> some View {
        let failed = !domains[page.rawValue]["error"].isNull && !(page == .stats && domains["stats"]["loaded"].bool)
        return NativeLinkRow(icon: icon, title: page.title, value: failed ? "Unavailable" : value,
                             detail: failed ? domains[page.rawValue]["error"].string : detail) { navigate(page) }
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

/// One of the two facts Home leads with. The whole cell is the control; the
/// last line names where it goes.
private struct NativeHomeCell<Content: View>: View {
    let label: String, icon: String, verb: String
    let action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeInterfaceDensity) private var density
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    NativeIcon(icon, size: 14).foregroundStyle(Theme.faint)
                    Text(label).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                }.padding(.bottom, 14)
                content()
                Spacer(minLength: 18)
                HStack(spacing: 5) {
                    Text(verb).font(Theme.ui(Theme.textXs, weight: .medium))
                    NativeIcon("arrow-right", size: 12).offset(x: hovering ? 3 : 0)
                }.foregroundStyle(hovering ? Theme.ink : Theme.muted)
            }
            .padding(20 * density.cardScale)
            .frame(maxWidth: .infinity, minHeight: 172, maxHeight: .infinity, alignment: .topLeading)
            .background(hovering ? Theme.subtle : .clear)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
            .accessibilityElement(children: .combine).accessibilityHint(verb)
    }
}

private struct NativeHomeRunRow: View {
    let run: JSONValue
    let timestamp: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(timestamp).font(Theme.ui(Theme.textSm, weight: .medium)).monospacedDigit().lineLimit(1).frame(width: 118, alignment: .leading)
                MonoChip(text: run["tier"].string).frame(width: 84, alignment: .leading)
                Text(homeCount(run["pairs"].array.count, "pair") + " in " + duration).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).help(run["id"].string)
                Spacer(minLength: 8)
                Text("\(run["ok"].int) passed").font(Theme.mono(11)).foregroundStyle(Theme.okFg).frame(width: 76, alignment: .trailing)
                Text("\(run["err"].int) failed").font(Theme.mono(11)).foregroundStyle(run["err"].int == 0 ? Theme.faint : Theme.warnFg).frame(width: 70, alignment: .trailing)
                NativeIcon("arrow-right", size: 13).foregroundStyle(Theme.muted).opacity(hovering ? 1 : 0).offset(x: hovering ? 0 : -4).frame(width: 16)
            }.padding(.horizontal, 16).frame(height: 44).nativeRowHover(hovering).contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
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
