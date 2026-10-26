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
    @State private var reads = NativePageReadScope()
    @State private var subscription: NativePageReadScope.Ticket?
    // CSS ch is the zero-glyph advance; measure the same46ch in the native font.
    private static let emptyDetailWidth = ("0" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12.5)]).width * 46
    private var filtered: [JSONObject] {
        rows.filter { row in let status = row["status"]?.string ?? ""; return scope == "all" || (scope == "active" ? ["queued", "running"].contains(status) : ["failed", "cancelled"].contains(status)) }
    }
    var body: some View {
        NativePage(title: "Jobs", subtitle: "Everything that runs in the background: arena matches, transcriptions, benchmark runs. Jobs keep running with the window closed.", readiness: error != nil ? .failed : loaded ? .ready : .pending, actions: {
            HStack(spacing: 8) {
                Button { Task { await reload() } } label: { HStack(spacing: 6) { NativeIcon("rotate-cw", size: 12); Text("Reload") } }
                T3Segmented(options: [("active", "Active"), ("all", "All"), ("failed", "Failed")], selection: scope) { scope = $0 }
                Button("Prune") { Task { do { let removed = try await runtime.jobs.prune(olderThan: NativeJobQueue.defaultPruneAge); notice = "Removed \(removed) finished jobs older than seven days."; await reload() } catch { self.error = error.localizedDescription } } }.disabled(runtime.paths.readOnly)
            }
        }) {
            if let error {
                VStack(alignment: .leading, spacing: 10) {
                    NativeError(message: error)
                    Button("Retry") { Task { await reload() } }
                }
            }
            if let notice { Text(notice).font(Theme.ui(12)).foregroundStyle(Theme.muted) }
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(text: scope == "active" ? "Running and queued" : scope == "failed" ? "Failed and cancelled" : "All jobs") {
                    if loaded || !rows.isEmpty {
                        NativeNumberText(text: "\(filtered.count) \(filtered.count == 1 ? "job" : "jobs")", font: Theme.ui(12), color: Theme.muted)
                    } else {
                        Text("—").font(Theme.ui(12)).foregroundStyle(Theme.muted).accessibilityLabel("Job count unavailable")
                    }
                }
                if !loaded && rows.isEmpty {
                    if error == nil { ShimmerText(text: "Reading background jobs…").padding(.vertical, 40) }
                } else if filtered.isEmpty {
                    VStack(spacing: 0) {
                        NativeIcon("list-checks", size: 24).foregroundStyle(Theme.muted.opacity(0.8)).padding(.bottom, 10).accessibilityHidden(true)
                        Text(scope == "active" ? "Nothing running" : "No jobs").font(Theme.ui(14, weight: .medium))
                        Text("Start a benchmark, an arena match or a transcription and it shows up here.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: Self.emptyDetailWidth).padding(.top, 4)
                    }.frame(maxWidth: .infinity).padding(.vertical, 48)
                } else {
                    Card(padding: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element["id"]) { index, row in
                                if index > 0 { Rectangle().fill(Theme.border).frame(height: 1) }
                                NativeJobRow(row: row, cancel: { Task { do { _ = try await runtime.jobs.cancel(row["id"]!.string); await reload() } catch { self.error = error.localizedDescription } } }, compact: false)
                            }
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

struct NativeJobRow: View {
    let row: JSONObject
    let cancel: () -> Void
    var compact = true
    @State private var expanded = false
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var value: JSONValue { .object(row) }
    private var live: Bool { ["running", "queued"].contains(value["status"].string) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button { expanded.toggle() } label: { NativeIcon(expanded ? "chevron-down" : "chevron-right", size: 14) }.buttonStyle(.plain).pointingHand().help("Job details").accessibilityLabel("\(expanded ? "Collapse" : "Expand") details for \(value["title"].string)")
                NativeStatusDot(color: color, pulse: value["status"] == "running")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text(value["title"].string).font(Theme.ui(13)).lineLimit(1)
                        Text(value["status"].string).font(Theme.mono(11)).foregroundStyle(statusForeground).frame(minHeight: 14)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(statusBackground, in: RoundedRectangle(cornerRadius: 5))
                        if !compact { Text(value["app"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted) }
                    }
                    if live || !value["progress_text"].string.isEmpty {
                        HStack(spacing: 10) {
                            if value["status"].string == "running" { CapsuleBar(fraction: value["progress"].double, color: Theme.accent).frame(maxWidth: 220) }
                            Text(value["progress_text"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    if value["status"].string != "cancelled", !value["error"].string.isEmpty { Text(value["error"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.failFg).lineLimit(1).help(value["error"].string).textSelection(.enabled) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(NativeListTimeFormat.ago(value["created_at"].double))
                    if !value["started_at"].isNull {
                        Text(NativeListTimeFormat.duration(max(0, (value["finished_at"].isNull ? Date().timeIntervalSince1970 * 1000 : value["finished_at"].double) - value["started_at"].double)))
                    }
                }.font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize()
                if live { Button(action: cancel) { NativeIcon("x", size: 14) }.buttonStyle(T3Button(.ghost)).help("Cancel job").accessibilityLabel("Cancel \(value["title"].string)").frame(width: 28) }
                else { Color.clear.frame(width: 28, height: 1) }
            }.padding(.horizontal, 14).padding(.vertical, 10).background(hovering ? Theme.subtle : .clear).onHover { hovering = $0 }.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
            if expanded {
                Rectangle().fill(Theme.border).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    if !value["error"].string.isEmpty, value["status"].string != "cancelled" {
                        Text("ERROR").font(Theme.mono(10)).tracking(0.5).foregroundStyle(Theme.muted)
                        ViewThatFits(in: .vertical) {
                            errorText
                            ScrollView { errorText }.frame(height: 96)
                        }.frame(maxHeight: 96, alignment: .leading)
                    }
                    ForEach(["params", "log", "result"], id: \.self) { field in
                        if !value[field].isNull && (field != "log" || !value[field].array.isEmpty) {
                            Text(field.uppercased()).font(Theme.mono(10)).tracking(0.5).foregroundStyle(Theme.muted)
                            ScrollView { Text(field == "log" ? value[field].array.map(\.string).joined(separator: "\n") : pretty(value[field])).font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: field == "log" ? 240 : 160)
                        }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10).background(Theme.well)
            }
        }
        .background(compact ? Theme.surface : .clear)
        .clipShape(RoundedRectangle(cornerRadius: compact ? Theme.radiusMd : 0))
        .overlay { if compact { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1) } }
    }
    private var errorText: some View {
        Text(value["error"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.failFg)
            .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    private var statusForeground: Color {
        switch value["status"].string {
        case "done": return Theme.okFg
        case "failed": return Theme.failFg
        case "cancelled": return Theme.warnFg
        default: return Theme.muted
        }
    }
    private var statusBackground: Color {
        switch value["status"].string {
        case "done", "failed", "cancelled": return color.opacity(0.14)
        default: return Theme.subtle
        }
    }
    private var color: Color {
        switch value["status"].string { case "done": return Theme.ok; case "failed": return Theme.fail; case "running": return Theme.accent; case "cancelled": return Theme.warn; default: return Theme.muted }
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
