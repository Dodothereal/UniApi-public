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
    @AppStorage("uniapi.home.setup.hidden") private var setupHidden = false
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
            if showsSetup {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Get started").font(Theme.ui(Theme.textSm, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Spacer(minLength: 8)
                        Button("Hide") { setupHidden = true }.buttonStyle(T3Button(.ghost))
                    }
                    NativeSetup(steps: setupSteps)
                }
            }
            if !waiting.isEmpty {
                NativeStack {
                    ForEach(waiting, id: \.title) { item in
                        NativeLinkRow(icon: item.icon, title: item.title, verb: item.verb, tone: Theme.accent) { navigate(item.page) }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                NativeRouteLine(tool: "Claude Code", stops: {
                    Text(route.name).font(Theme.ui(Theme.textSm, weight: .medium)).lineLimit(1).frame(height: 30)
                    NativeRouteArrow()
                    Text(route.model).font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    NativeRouteArrow()
                    Text("effort " + route.effort).font(Theme.mono(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1)
                }, action: {
                    Button("Change") { navigate(.switcher) }
                })
                if !switcher["shim"].isNull, !switcher["shim"]["ok"].bool {
                    NativeStatus(text: switcher["shim"]["legacyPresent"].bool ? "Legacy listener kept" : "Translation listener not running", tone: .warn).padding(.leading, 14)
                }
            }
            if !work.isEmpty {
                NativeStack {
                    ForEach(work, id: \.page) { item in
                        NativeLinkRow(icon: item.page.symbol, title: item.page.title, value: item.value, detail: item.detail) { navigate(item.page) }
                    }
                }
            }
            if !bench["runs"].array.isEmpty {
                NativeSection("Benchmark runs", trailing: { Button("All results") { navigate(.results) }.buttonStyle(T3Button(.ghost)) }) {
                    NativeStack {
                        ForEach(bench["runs"].array, id: \.self["id"]) { run in
                            NativeHomeRunRow(run: run, timestamp: stamp(run["started"].string)) { openRun(run["id"].string) }
                        }
                    }
                }
            }
            if !snapshot["jobs"].array.isEmpty {
                NativeSection("Jobs", trailing: { Button("All jobs") { navigate(.jobs) }.buttonStyle(T3Button(.ghost)) }) {
                    NativeStack {
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
    /// What a new installation needs before the other pages have anything to show.
    private var setupSteps: [NativeSetupStep] {
        [NativeSetupStep(id: "provider", title: "Add a provider", detail: "Its models become available to Benchmark, Arena, Code and Switcher.",
                         done: !switcher["providers"].array.isEmpty, actionTitle: "Open Switcher", actionIcon: "route", action: { navigate(.switcher) }),
         NativeSetupStep(id: "benchmark", title: "Benchmark its models", done: !bench["lastRun"].isNull, actionTitle: "Open Benchmark", actionIcon: "gauge", action: {
             UserDefaults.standard.set("bench", forKey: NativeBenchmarkPage.viewKey); navigate(.speed)
         })]
    }
    private var showsSetup: Bool {
        !setupHidden && !switcher.isNull && switcher["error"].isNull && !bench.isNull && bench["error"].isNull && !setupSteps.allSatisfy(\.done)
    }
    /// Pages that hold something. An unused page has no row.
    private var work: [(page: NativeDestination, value: String, detail: String)] {
        var rows: [(page: NativeDestination, value: String, detail: String)] = []
        func add(_ page: NativeDestination, used: Bool, value: String, detail: String) {
            let failed = !domains[page.rawValue]["error"].isNull && !(page == .stats && domains["stats"]["loaded"].bool)
            if failed { rows.append((page, "Unavailable", domains[page.rawValue]["error"].string)) }
            else if used { rows.append((page, value, detail)) }
        }
        let code = domains["code"], arena = domains["arena"], transcribe = domains["transcribe"], stats = domains["stats"]
        add(.code, used: code["threads"].int > 0, value: homeCount(code["activeThreads"].int, "running thread"),
            detail: code["lastTitle"].string.isEmpty ? homeCount(code["threads"].int, "thread") : code["lastTitle"].string)
        add(.arena, used: arena["matches"].int > 0, value: homeCount(arena["matches"].int, "match", plural: "matches"),
            detail: arena["running"].int > 0 ? "\(arena["running"].int) running" : "")
        add(.transcribe, used: transcribe["count"].int > 0, value: homeCount(transcribe["count"].int, "transcript"),
            detail: transcribe["running"].int > 0 ? "\(transcribe["running"].int) in progress" : transcribe["lastTitle"].string)
        add(.stats, used: stats["loaded"].bool && stats["grand"].double > 0, value: NativeNumberFormat.compact(stats["grand"].double) + " tokens",
            detail: homeCount(stats["responses"].int, "response") + " from " + homeCount(stats["models"].int, "model") + (stats["provenance"] == "cache" ? ", saved copy" : ""))
        return rows
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
            }.padding(.horizontal, 8).frame(height: 44).nativeRowHover(hovering).contentShape(Rectangle())
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
