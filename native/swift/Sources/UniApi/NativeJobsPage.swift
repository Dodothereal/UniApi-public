import SwiftUI
import AppKit
import UniApiCore
import UniApiPresentation

struct NativeJobsPage: View {
    let runtime: NativeRuntime
    @State private var rows: [JSONObject] = []
    @State private var scope = "all"
    @State private var error: String?
    @State private var loaded = false
    @State private var notice: String?
    @State private var confirmPrune = false
    @State private var pruning = false
    @State private var reads = NativePageReadScope()
    @State private var subscription: NativePageReadScope.Ticket?
    private static let scopes: [(value: String, label: String)] = [("all", "All"), ("done", "Done"), ("failed", "Failed"), ("cancelled", "Cancelled")]
    private func status(_ row: JSONObject) -> String { row["status"]?.string ?? "" }
    private func count(_ status: String) -> Int { rows.filter { self.status($0) == status }.count }
    /// Running work first, then what waits for a slot; newest first within each.
    private var live: [JSONObject] { rows.filter { status($0) == "running" } + rows.filter { status($0) == "queued" } }
    private var finished: [JSONObject] {
        rows.filter { row in
            let status = status(row)
            return !["running", "queued"].contains(status) && (scope == "all" || scope == status)
        }
    }
    private var reading: Bool { !loaded && rows.isEmpty }
    var body: some View {
        NativePage(title: "Jobs", eyebrow: "Background work", readiness: error != nil ? .failed : loaded ? .ready : .pending, actions: {
            Button("Reload", nativeIcon: "rotate-cw") { Task { await reload() } }
        }) {
            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    Notice(text: error, tone: .fail).accessibilityLabel("Error: " + error)
                    Button("Retry") { Task { await reload() } }
                }
            }
            if let notice { Notice(text: notice, tone: .ok) }
            lead
            Band("Live", spacing: 0) {
                if reading {
                    if error == nil { JobsQuietLine(text: "Reading background jobs") }
                } else if rows.isEmpty {
                    Blank(icon: "list-checks", title: "No background work yet",
                          detail: "Start a benchmark, an Arena match or a transcription and it reports here.")
                } else if live.isEmpty {
                    JobsQuietLine(text: "Nothing is running or waiting.")
                } else {
                    ForEach(live, id: \.self["id"]) { row in
                        NativeJobRow(row: row, cancel: { cancel(row) }, compact: false)
                            .overlay(alignment: .bottom) { Rule() }
                    }
                }
            }
            Band(title: "Finished", spacing: 0) {
                Stops(options: Self.scopes, selection: scope) { scope = $0 }
                Button(pruning ? "Clearing…" : "Clear old jobs…") { confirmPrune = true }
                    .buttonStyle(Press(.quiet)).padding(.trailing, -8)
                    .disabled(runtime.paths.readOnly || pruning)
                    .help("Review removal of completed, failed and cancelled job entries older than seven days")
            } content: {
                NativeJobLedgerHead()
                if finished.isEmpty {
                    if !reading {
                        JobsQuietLine(text: scope == "all" ? "No finished jobs." : "No \(scope) jobs.")
                    }
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(finished, id: \.self["id"]) { row in
                            NativeJobRow(row: row, cancel: { cancel(row) }, compact: false)
                                .overlay(alignment: .bottom) { Rule() }
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
    /// The reading the page opens with: how much is running, then what waits and how the rest ended.
    private var lead: some View {
        let running = count("running"), stopped = count("failed")
        let latest: Double? = rows.filter { status($0) == "done" }.compactMap { $0["finished_at"]?.double }.max()
        return JobsLead {
            JobsReading(label: "Running", value: reading ? "--" : String(running), unit: running == 1 ? "job" : "jobs",
                        detail: "Keeps working with the window closed", hero: true, tint: running > 0 ? Theme.signal : nil, known: !reading)
        } rest: {
            JobsReading(label: "Queued", value: reading ? "--" : String(count("queued")), detail: "waiting for a slot", known: !reading)
            JobsReading(label: "Failed", value: reading ? "--" : String(stopped), detail: count("cancelled") > 0 ? "\(count("cancelled")) cancelled" : "",
                        color: stopped > 0 ? Theme.failFg : Theme.ink, known: !reading)
            JobsReading(label: "Done", value: reading ? "--" : String(count("done")), detail: latest.map { "latest " + NativeListTimeFormat.ago($0) } ?? "", known: !reading)
        }
    }
    private func cancel(_ row: JSONObject) {
        Task { do { _ = try await runtime.jobs.cancel(row["id"]!.string); await reload() } catch { self.error = error.localizedDescription } }
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

/// A line of muted text where rows will be: nothing to show, said once.
private struct JobsQuietLine: View {
    let text: String
    var body: some View {
        Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

/// One large reading and the smaller ones that qualify it, all standing on
/// the same numeral baseline. On a narrow page the smaller ones drop below.
private struct JobsLead<Hero: View, Rest: View>: View {
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var rest: () -> Rest
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 40) {
                hero().frame(width: 300, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 24) { rest() }.frame(minWidth: 420)
            }
            VStack(alignment: .leading, spacing: 20) {
                hero()
                HStack(alignment: .firstTextBaseline, spacing: 24) { rest() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A reading whose numerals carry the first baseline, so readings of
/// different sizes line up in a row. The label hangs above its numerals.
private struct JobsReading: View {
    var label: String
    var value: String
    var unit: String = ""
    var detail: String = ""
    var hero = false
    var tint: Color? = nil
    var color: Color = Theme.ink
    var known = true
    var body: some View {
        VStack(alignment: .leading, spacing: hero ? 2 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                NativeNumberText(text: value, font: Theme.readout(hero ? 54 : 24), color: known ? color : Theme.faint)
                if !unit.isEmpty { MicroLabel(unit, size: hero ? 11 : 9.5) }
            }
            .padding(.top, 18)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    if let tint { tint.frame(width: 2, height: 9) }
                    MicroLabel(label)
                }.fixedSize()
            }
            Text(detail.isEmpty ? " " : detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: hero ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, unit, detail].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

/// Fixed columns of the Finished ledger; the head and each row share them.
private enum JobColumn {
    static let lead: CGFloat = 26
    static let app: CGFloat = 96
    static let status: CGFloat = 88
    static let started: CGFloat = 76
    static let took: CGFloat = 68
    /// Width below which the App column gives its room to the title.
    static let wide: CGFloat = lead + 320 + app + status + started + took + 48
}

private struct NativeJobLedgerHead: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            head(app: true).frame(minWidth: JobColumn.wide)
            head(app: false)
        }
    }
    private func head(app: Bool) -> some View {
        LedgerHead {
            MicroLabel("Job").padding(.leading, JobColumn.lead).frame(minWidth: 0, idealWidth: 220, maxWidth: .infinity, alignment: .leading)
            if app { MicroLabel("App").frame(width: JobColumn.app, alignment: .leading) }
            MicroLabel("Status").frame(width: JobColumn.status, alignment: .leading)
            MicroLabel("Started").frame(width: JobColumn.started, alignment: .trailing)
            MicroLabel("Took").frame(width: JobColumn.took, alignment: .trailing)
        }
    }
}

/// One job. Live work carries a ticked meter with the signal tick at its
/// head; finished work is a dense ledger line. Details open in place beneath.
/// The row draws on the content edge and leaves its bottom rule to the caller.
struct NativeJobRow: View {
    let row: JSONObject
    let cancel: () -> Void
    var compact = true
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var value: JSONValue { .object(row) }
    private var status: String { value["status"].string }
    private var title: String { value["title"].string }
    private var live: Bool { ["running", "queued"].contains(status) }
    private var running: Bool { status == "running" }
    private var failed: Bool { status != "cancelled" && !value["error"].string.isEmpty }
    private var started: String { NativeListTimeFormat.ago(value["created_at"].double) }
    private var took: String {
        guard !value["started_at"].isNull else { return "" }
        let end = value["finished_at"].isNull ? Date().timeIntervalSince1970 * 1000 : value["finished_at"].double
        return NativeListTimeFormat.duration(max(0, end - value["started_at"].double))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                details.transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: toggle) {
                NativeIcon("chevron-right", size: 13, strokeWidth: 1.75)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .foregroundStyle(expanded || hovering ? Theme.ink : Theme.muted)
                    .frame(width: 14, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHand().help("Job details")
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") details for \(title)")
            VStack(alignment: .leading, spacing: 8) {
                if compact { compactLine } else if live { liveLine } else { finishedLine }
                if running && !compact { NativeJobMeter(fraction: value["progress"].double) }
                if compact && (live || !value["progress_text"].string.isEmpty) {
                    HStack(spacing: 10) {
                        if running { NativeJobMeter(fraction: value["progress"].double, divisions: 20).frame(maxWidth: 220) }
                        progressText
                    }
                }
                if failed {
                    Text(value["error"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.failFg).lineLimit(1)
                        .help(value["error"].string).textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, running && !compact ? 14 : 8)
        .frame(maxWidth: .infinity, minHeight: live || compact ? 44 : 36, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(hovering ? Theme.hover : .clear).padding(.horizontal, -8)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
    /// Home: any state on one line, with the trailing slot kept so mixed rows align.
    private var compactLine: some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.ui(13)).foregroundStyle(Theme.ink).lineLimit(1)
            statusTag
            Spacer(minLength: 8)
            Text([started, took].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize()
            cancelSlot
        }.frame(minHeight: 20)
    }
    private var liveLine: some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).layoutPriority(1)
            Tag(value["app"].string).fixedSize().layoutPriority(1)
            if !running { statusTag.fixedSize().layoutPriority(1) }
            Spacer(minLength: 8)
            progressText
            if !took.isEmpty { Text(took).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize() }
            if running {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    NativeNumberText(text: String(Int((NativeMotion.fraction(value["progress"].double) * 100).rounded())),
                                     font: Theme.readout(17), color: Theme.ink)
                    MicroLabel("%")
                }.frame(minWidth: 44, alignment: .trailing)
            }
            cancelSlot
        }.frame(minHeight: 20)
    }
    private var finishedLine: some View {
        ViewThatFits(in: .horizontal) {
            finishedColumns(app: true).frame(minWidth: JobColumn.wide - JobColumn.lead)
            finishedColumns(app: false)
        }.frame(minHeight: 20)
    }
    private func finishedColumns(app: Bool) -> some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.ui(13)).foregroundStyle(Theme.ink).lineLimit(1)
                .frame(minWidth: 0, idealWidth: 220 - JobColumn.lead, maxWidth: .infinity, alignment: .leading)
            if app {
                Text(value["app"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    .frame(width: JobColumn.app, alignment: .leading)
            }
            statusTag.frame(width: JobColumn.status, alignment: .leading)
            Text(started).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                .frame(width: JobColumn.started, alignment: .trailing)
            Text(took.isEmpty ? "—" : took).font(Theme.mono(10.5)).foregroundStyle(took.isEmpty ? Theme.faint : Theme.dim).lineLimit(1)
                .frame(width: JobColumn.took, alignment: .trailing)
        }
    }
    @ViewBuilder private var progressText: some View {
        if !value["progress_text"].string.isEmpty {
            Text(value["progress_text"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
    @ViewBuilder private var cancelSlot: some View {
        if live {
            // The glyph, not its 28-point hit area, ends on the content edge.
            IconPress(icon: "x", help: "Cancel job", action: cancel).accessibilityLabel("Cancel \(title)")
                .frame(width: 28, height: 20).padding(.trailing, -7)
        } else if compact { Color.clear.frame(width: 21, height: 1) }
    }
    private var statusTag: some View {
        switch status {
        case "running": return Tag(status, tone: Theme.signal, dot: true)
        case "done": return Tag(status, tone: Theme.okFg)
        case "failed": return Tag(status, tone: Theme.failFg)
        case "cancelled": return Tag(status, tone: Theme.warnFg)
        default: return Tag(status)
        }
    }
    private var details: some View {
        Well(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if failed {
                    MicroLabel("Error")
                    ViewThatFits(in: .vertical) {
                        errorText
                        ScrollView { errorText }.frame(height: 96)
                    }.frame(maxHeight: 96, alignment: .leading)
                }
                ForEach(["params", "log", "result"], id: \.self) { field in
                    if !value[field].isNull && (field != "log" || !value[field].array.isEmpty) {
                        MicroLabel(field).padding(.top, 4)
                        ScrollView {
                            Text(field == "log" ? value[field].array.map(\.string).joined(separator: "\n") : pretty(value[field]))
                                .font(Theme.mono(11)).foregroundStyle(Theme.dim).lineSpacing(2)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }.frame(maxHeight: field == "log" ? 240 : 160)
                    }
                }
            }
        }
        .padding(.leading, JobColumn.lead).padding(.bottom, 12)
    }
    private var errorText: some View {
        Text(value["error"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.failFg)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private func toggle() {
        if reduceMotion { expanded.toggle() } else { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } }
    }
    private func pretty(_ json: JSONValue) -> String { (try? String(decoding: json.encoded(pretty: true), as: UTF8.self)) ?? "" }
}

/// Progress of live work: ink fills a ticked track and the signal tick marks
/// its head. The fill sweeps from the previous value.
private struct NativeJobMeter: View {
    var fraction: Double
    var divisions = 40
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var body: some View {
        let value: Double = NativeMotion.fraction(fraction)
        VStack(spacing: 2) {
            GeometryReader { geometry in
                let head: CGFloat = geometry.size.width * value
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.track).frame(height: 4)
                    Rectangle().fill(Theme.ink).frame(width: head, height: 4)
                    Theme.signal.frame(width: 2, height: 10).offset(x: max(0, head - 2))
                }
                .frame(height: 10)
                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: value)
            }
            .frame(height: 10)
            TickScale(divisions: divisions, major: 5, minorHeight: 2, majorHeight: 4).fill(Theme.faint).frame(height: 4)
        }
        .accessibilityHidden(true)
    }
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
