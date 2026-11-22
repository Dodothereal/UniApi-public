import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

struct NativeJobsPage: View {
    let runtime: NativeRuntime
    @State private var rows: [JSONObject] = []
    @State private var scope = "active"
    @State private var error: String?
    @State private var loaded = false
    @State private var notice: String?
    @State private var confirmPrune = false
    @State private var pruning = false
    @State private var reads = NativePageReadScope()
    @State private var subscription: NativePageReadScope.Ticket?
    private func matches(_ row: JSONObject, _ scope: String) -> Bool {
        let status = row["status"]?.string ?? ""
        return scope == "all" || (scope == "active" ? ["queued", "running"].contains(status) : ["failed", "cancelled"].contains(status))
    }
    private var filtered: [JSONObject] { rows.filter { matches($0, scope) } }
    var body: some View {
        NativePage(title: "Jobs", readiness: error != nil ? .failed : loaded ? .ready : .pending, tabs: {
            NativeTabs(options: [("active", "Active"), ("failed", "Failed"), ("all", "All")], selection: scope,
                       counts: ["active": rows.filter { matches($0, "active") }.count, "failed": rows.filter { matches($0, "failed") }.count]) { scope = $0 }
        }, actions: {
            Button(pruning ? "Clearing…" : "Clear old jobs…") { confirmPrune = true }
                .buttonStyle(T3Button(.ghost))
                .disabled(runtime.paths.readOnly || pruning)
                .help("Review removal of completed, failed and cancelled job entries older than seven days")
            T3IconButton(system: "refresh-cw", help: "Reload") { Task { await reload() } }
        }) {
            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    NativeError(message: error)
                    Button("Retry") { Task { await reload() } }
                }
            }
            if let notice { Text(notice).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted) }
            if !loaded && rows.isEmpty {
                if error == nil { ShimmerText(text: "Reading background jobs…") }
            } else if filtered.isEmpty {
                EmptyState(icon: "list-checks", title: scope == "active" ? "Nothing running" : scope == "failed" ? "Nothing failed" : "No jobs",
                           detail: scope == "failed" ? "" : "Benchmark runs, arena matches and transcriptions appear here and keep running with the window closed.")
            } else {
                Card(padding: 0) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filtered.enumerated()), id: \.element["id"]) { index, row in
                            if index > 0 { Theme.rule.frame(height: 1) }
                            NativeJobRow(row: row, cancel: { Task { do { _ = try await runtime.jobs.cancel(row["id"]!.string); await reload() } catch { self.error = error.localizedDescription } } }, compact: false)
                        }
                    }
                }
            }
        }
        .nativePageTask {
            guard let listener = reads.begin("events") else { return }
            let events = await runtime.events.stream()
            guard reads.accepts(listener) else { return }
            subscription = listener
            await reload()
            guard reads.accepts(listener) else { return }
            for await event in events {
                guard reads.accepts(listener) else { break }
                if ["job.updated", "job.progress", "job.log"].contains(event.topic) {
                    let row = event.data.object
                    guard let id = row["id"]?.string, !id.isEmpty else { continue }
                    if let index = rows.firstIndex(where: { $0["id"]?.string == id }) { rows[index] = row }
                    else { rows.append(row); rows.sort { ($0["created_at"]?.double ?? 0) > ($1["created_at"]?.double ?? 0) }; rows = Array(rows.prefix(200)) }
                }
            }
        }
        .nativePageActivity(reads: reads)
        .alert("Clear old job history?", isPresented: $confirmPrune) {
            Button("Cancel", role: .cancel) { }
            Button("Clear old jobs", role: .destructive) { Task { await prune() } }
        } message: {
            Text("Permanently remove completed, failed and cancelled job entries older than seven days, including their logs and job details. Running and queued jobs, benchmark results and saved transcripts are kept.")
        }
    }
    private func prune() async {
        guard !runtime.paths.readOnly, !pruning else { return }
        pruning = true; defer { pruning = false }
        do {
            let removed = try await runtime.jobs.prune(olderThan: NativeJobQueue.defaultPruneAge)
            notice = "Removed \(removed) finished jobs older than seven days."
            await reload()
        } catch { self.error = error.localizedDescription }
    }
    private func reload() async {
        guard let subscription, reads.accepts(subscription), let ticket = reads.begin("list") else { return }
        do {
            let nextRows = try await runtime.jobs.list()
            guard reads.accepts(ticket) else { return }
            rows = nextRows; error = nil; loaded = true
        } catch {
            guard reads.accepts(ticket) else { return }
            self.error = error.localizedDescription
        }
    }
}

/// One background job: state as a mark and a word, what it is, how far it is,
/// when it started. Expands to its parameters, log and result.
struct NativeJobRow: View {
    let row: JSONObject
    let cancel: () -> Void
    var compact = true
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var value: JSONValue { .object(row) }
    private var status: String { value["status"].string }
    private var live: Bool { ["running", "queued"].contains(status) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: {
                    NativeIcon("chevron-right", size: 13).rotationEffect(.degrees(expanded ? 90 : 0)).foregroundStyle(Theme.muted).frame(width: 18, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).pointingHand().help("Job details").accessibilityLabel("\(expanded ? "Collapse" : "Expand") details for \(value["title"].string)")
                Group {
                    if status == "running" { NativeStatusDot(color: Theme.accent, size: 7, pulse: true) }
                    else { NativeIcon(status == "done" ? "check" : status == "failed" ? "circle-alert" : status == "cancelled" ? "ban" : "clock", size: 14).foregroundStyle(tone) }
                }.frame(width: 16)
                VStack(alignment: .leading, spacing: 4) {
                    Text(value["title"].string).font(Theme.ui(Theme.textSm, weight: .medium)).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(status).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(tone)
                        if !compact, !value["app"].string.isEmpty { Text(value["app"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                        if status == "running" { NativeTickMeter(fraction: value["progress"].double, color: Theme.accent, height: 9).frame(width: 120) }
                        if !value["progress_text"].string.isEmpty { Text(value["progress_text"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1) }
                    }
                    if status != "cancelled", !value["error"].string.isEmpty { Text(value["error"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.failFg).lineLimit(1).help(value["error"].string).textSelection(.enabled) }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(NativeListTimeFormat.ago(value["created_at"].double))
                    if !value["started_at"].isNull {
                        Text(NativeListTimeFormat.duration(max(0, (value["finished_at"].isNull ? Date().timeIntervalSince1970 * 1000 : value["finished_at"].double) - value["started_at"].double)))
                    }
                }.font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize()
                if live { T3IconButton(system: "x", help: "Cancel job", size: 14, action: cancel).accessibilityLabel("Cancel \(value["title"].string)") }
                else { Color.clear.frame(width: 28, height: 1) }
            }.padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 10).nativeRowHover(hovering).onHover { hovering = $0 }
                .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
                .animation(reduceMotion ? nil : NativeMotion.reveal, value: expanded)
            if expanded {
                Theme.rule.frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    if !value["error"].string.isEmpty, status != "cancelled" {
                        fieldLabel("Error")
                        ViewThatFits(in: .vertical) {
                            errorText
                            ScrollView { errorText }.frame(height: 96)
                        }.frame(maxHeight: 96, alignment: .leading)
                    }
                    ForEach(["params", "log", "result"], id: \.self) { field in
                        if !value[field].isNull && (field != "log" || !value[field].array.isEmpty) {
                            fieldLabel(field.capitalized)
                            ScrollView { Text(field == "log" ? value[field].array.map(\.string).joined(separator: "\n") : pretty(value[field])).font(Theme.mono(11)).foregroundStyle(Theme.dim).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: field == "log" ? 240 : 160)
                        }
                    }
                }.padding(.leading, 56).padding(.trailing, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.well)
            }
        }
    }
    private func fieldLabel(_ text: String) -> some View {
        Text(text.uppercased()).font(Theme.ui(10.5, weight: .semibold)).tracking(0.9).foregroundStyle(Theme.faint)
    }
    private var errorText: some View {
        Text(value["error"].string).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.failFg)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private var tone: Color {
        switch status { case "done": return Theme.okFg; case "failed": return Theme.failFg; case "running": return Theme.accent; case "cancelled": return Theme.warnFg; default: return Theme.muted }
    }
    private func pretty(_ json: JSONValue) -> String { (try? String(decoding: json.encoded(pretty: true), as: UTF8.self)) ?? "" }
}

// Compact labels from the web list kit; no additional polling clock is needed.
enum NativeListTimeFormat {
    static func ago(_ timestamp: Double) -> String {
        ArenaPresentationPolicy.verdictAge(.number(timestamp), now: Date())
    }
    static func duration(_ milliseconds: Double) -> String {
        guard milliseconds.isFinite, milliseconds >= 0 else { return "—" }
        if milliseconds < 1000 { return "\(Int(milliseconds.rounded())) ms" }
        let seconds = milliseconds / 1000
        if seconds < 60 { return String(format: seconds < 10 ? "%.1f s" : "%.0f s", seconds) }
        if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds.truncatingRemainder(dividingBy: 60).rounded()))s" }
        return String(format: "%.0fh %.0fm", floor(seconds / 3600), floor(seconds.truncatingRemainder(dividingBy: 3600) / 60))
    }
    static func stamp(_ date: Date) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        return date.formatted(.dateTime.month(.abbreviated).day()) + ", " + clock.string(from: date)
    }
}
