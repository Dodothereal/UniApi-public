import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UniApiCore
import UniApiPresentation

struct NativeTranscribePage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @AppStorage("uniapi.transcribe.lang") private var language = ""
    @AppStorage("uniapi.transcribe.notify") private var notify = false
    @State private var source = ""
    @StateObject private var mediaReads = NativeMediaPageReads()
    @Environment(\.nativePageActive) private var pageActive
    @State private var rows: [JSONValue] = []
    @State private var status: JSONValue = .null
    @State private var detail: JSONValue = .null
    @State private var error: String?
    @State private var submitting = false
    @State private var dropTarget = false
    @State private var progress: [String: JSONValue] = [:]
    @State private var eta: [String: (value: JSONValue, received: Date)] = [:]
    @State private var parts: [Int: String] = [:]
    @State private var rename = false
    @State private var title = ""
    @State private var deleting: String?
    @State private var modelTask: Task<Void, Never>?
    @State private var modelProgress: JSONValue = .null
    @State private var installingModel = false
    private let languages = [("", "Auto"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("nl", "Nederlands"), ("tr", "Türkçe"), ("ja", "日本語"), ("zh", "中文")]
    private var service: NativeTranscriptionService? { session.transcription }
    private var reads: NativePageReadScope { mediaReads.scope }
    private var selected: String? {
        get { mediaReads.selection }
        nonmutating set { mediaReads.select(newValue) }
    }
    private var pageError: String? { error ?? mediaReads.detailError }
    private var transcriptText: String { NativeTranscriptPresentation.text(detail, parts: parts) }
    var body: some View {
        NativePage(title: selected == nil ? "Transcribe" : (detail["title"].string.isEmpty ? (detail["source"].string.isEmpty ? "Transcription" : detail["source"].string) : detail["title"].string), subtitle: selected == nil ? "Private, on-device transcription with Whisper large-v3-turbo. Install the optional model once; it runs only for a transcription job." : "", readiness: pageError != nil ? .failed : status.isNull || selected != nil && detail.isNull ? .pending : .ready, backTitle: "Transcripts", back: selected == nil ? nil : back, actions: {
            if selected == nil {
                T3IconButton(icon: "rotate-cw", help: "Reload") { Task { await reload() } }
            } else { transcriptActions }
        }) {
            if let pageError { NativeError(message: pageError) }
            if selected == nil { input; history } else { transcript }
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5])).padding(12).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in acceptFiles(providers) }
        .sheet(isPresented: $rename) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename transcript").font(Theme.ui(18, weight: .semibold))
                T3Field(placeholder: "Title", text: $title).accessibilityLabel("Transcript title")
                HStack {
                    Button("Cancel") { rename = false }.buttonStyle(T3Button(.ghost)).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { Task { await renameTranscript() } }.buttonStyle(T3Button(.primary)).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
                }
            }.padding(22).frame(width: 500).background(Theme.bg)
        }
        .alert("Delete transcript?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) { if let id = deleting { deleting = nil; Task { await remove(id) } } }
        } message: { Text("Running work will be cancelled. The original file you chose is preserved.") }
        .background { Button("Back") { back() }.keyboardShortcut(.escape, modifiers: []).hidden().accessibilityHidden(true) }
        .nativePageTask {
            let events = await runtime.events.stream()
            await reload()
            for await event in events {
                if Task.isCancelled { break }
                switch event.topic {
                case "transcribe.updated", "transcribe.deleted": await reload()
                case "transcribe.model": modelProgress = event.data
                case "job.progress": progress[event.data["id"].string] = event.data
                case "job.updated": if event.data["app"].string == "transcribe" { await reload() }
                case "job.transcribe.eta": eta[event.data["transcriptId"].string] = (event.data, Date())
                case "job.transcribe.chunk": if selected == event.data["transcriptId"].string { parts[event.data["index"].int] = event.data["text"].string }
                case "notify.error": error = "Telegram notification delivery failed."
                default: break
                }
            }
        }
        .nativePageActivity(reads: reads, suspended: { dropTarget = false })
    }
    private var languageMenu: some View {
        Menu {
            ForEach(languages, id: \.0) { id, label in Button(label) { language = id } }
        } label: {
            HStack(spacing: 6) {
                NativeIcon("globe", size: 13)
                Text(languages.first(where: { $0.0 == language })?.1 ?? language)
                NativeIcon("chevron-down", size: 10)
            }.font(Theme.ui(12.5)).foregroundStyle(Theme.dim).frame(height: 28).contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointingHand()
            .help("Language. Auto detects it per chunk.").accessibilityLabel("Language")
    }
    // The source field is the page. Language and delivery sit under it as
    // quiet inline controls; the model line only appears while it needs
    // attention or is doing something.
    private var input: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { sourceField; sourceActions }
                VStack(alignment: .leading, spacing: 8) { sourceField; HStack(spacing: 8) { sourceActions } }
            }
            HStack(spacing: 18) {
                languageMenu
                HStack(spacing: 8) {
                    T3Switch(isOn: $notify).accessibilityLabel("Telegram when done")
                    Text("Telegram when done").font(Theme.ui(12.5)).foregroundStyle(notify ? Theme.ink : Theme.muted)
                }.help("One message per transcript. Set up Telegram in Settings.")
                Spacer(minLength: 0)
                if !status.isNull && !status["ytdlp"].bool {
                    NativeStatusText(text: "Links need yt-dlp", color: Theme.warnFg)
                        .help("Local WAV, MP3 and M4A files use the built-in decoder; other formats may need ffmpeg.")
                }
            }
            localModelSetup
        }.padding(.top, 8)
    }
    @ViewBuilder private var localModelSetup: some View {
        let available = status["model"]["available"].bool
        if !status.isNull && (installingModel || !available || !status["localRuntime"].bool) {
            VStack(alignment: .leading, spacing: 10) {
                NativeRule()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Whisper large-v3-turbo").font(Theme.ui(13.5, weight: .medium))
                        Text(installingModel ? (modelProgress["message"].string.isEmpty ? "Preparing download" : modelProgress["message"].string)
                             : available ? "Bundled runtime missing. Reinstall UniApi." : "574 MB, runs on this Mac")
                            .font(Theme.ui(12)).foregroundStyle(available && !installingModel ? Theme.failFg : Theme.muted)
                    }
                    Spacer(minLength: 12)
                    if installingModel { Button("Cancel") { modelTask?.cancel() }.buttonStyle(T3Button(.outline)) }
                    else if !available { Button("Install") { modelAction("model.install") }.buttonStyle(T3Button(.primary)) }
                }
                if installingModel { NativeGrowBar(fraction: modelProgress["progress"].double, color: Theme.accent, height: 3) }
                NativeRule()
            }.padding(.top, 6)
        }
    }
    private func modelAction(_ operation: String) {
        guard let service, !installingModel else { return }
        installingModel = true; modelProgress = .null; error = nil
        modelTask = Task {
            do { _ = try await service.handle(operation) }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
            installingModel = false; modelTask = nil
            await reload()
        }
    }
    private var sourceField: some View {
        NativeTranscribeSourceField(source: $source) { Task { await submit(source, upload: false) } }
    }
    @ViewBuilder private var sourceActions: some View {
        Button { Task { await submit(source, upload: false) } } label: {
            HStack(spacing: 6) { NativeIcon("mic", size: 14); Text(submitting ? "Starting" : "Transcribe") }
                .frame(minWidth: 93, minHeight: 30)
        }.buttonStyle(T3Button(.primary)).disabled(submitting || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !status["localReady"].bool)
        Button(action: chooseFiles) {
            HStack(spacing: 6) { NativeIcon("folder-open", size: 14); Text("Files") }.frame(minHeight: 30)
        }.buttonStyle(T3Button(.outline)).accessibilityLabel("Choose files")
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            if rows.isEmpty {
                if status.isNull && error == nil { ShimmerText(text: "Loading transcripts") }
                else if status["model"]["available"].bool && status["localRuntime"].bool && !installingModel {
                    Button("Remove model") { modelAction("model.remove") }.buttonStyle(T3Button(.ghost)).disabled(status["model"]["inUse"].bool)
                }
            }
            else {
                NativeSection("Transcripts", count: String(rows.count), trailing: {
                    if status["model"]["available"].bool && !installingModel {
                        Button("Remove model") { modelAction("model.remove") }.buttonStyle(T3Button(.ghost)).disabled(status["model"]["inUse"].bool)
                    }
                }) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element["id"]) { index, row in
                            if index > 0 { NativeRule() }
                            NativeTranscriptHistoryRow(row: row, progress: progress[row["job_id"].string] ?? .null,
                                metadata: historyMetadata(row), onOpen: {
                                    selected = row["id"].string; parts = [:]; detail = .null; Task { await loadDetail() }
                                }, onDelete: { deleting = row["id"].string }) { countdown(row["id"].string) }
                        }
                    }
                }
            }
        }
    }
    private func historyMetadata(_ row: JSONValue) -> String {
        var values: [String] = []
        if !row["duration_s"].isNull { values.append("Audio " + duration(row["duration_s"].double)) }
        if row["status"].string == "done" { values.append("\(row["wordCount"].int) words") }
        if !row["lang"].string.isEmpty { values.append(row["lang"].string) }
        return values.joined(separator: " · ")
    }
    private var transcriptActions: some View {
        HStack(spacing: 4) {
            if NativeTranscriptPresentation.canResume(detail) {
                Button { Task { await resume() } } label: {
                    HStack(spacing: 6) { NativeIcon("rotate-cw", size: 13); Text("Resume") }
                }.buttonStyle(T3Button(.outline)).disabled(runtime.paths.readOnly || submitting)
            }
            Button { copy(transcriptText) } label: {
                HStack(spacing: 6) { NativeIcon("copy", size: 13); Text("Copy") }
            }.buttonStyle(T3Button(.outline)).disabled(transcriptText.isEmpty)
            Button { title = detail["title"].string; rename = true } label: { NativeIcon("pencil", size: 13) }
                .buttonStyle(T3Button(.ghost)).disabled(detail.isNull).help("Rename").accessibilityLabel("Rename transcript")
            Button { Task { await save() } } label: { NativeIcon("download", size: 13) }
                .buttonStyle(T3Button(.ghost)).disabled(detail["text"].string.isEmpty).help("Save text").accessibilityLabel("Save transcript text")
            Button { deleting = selected } label: { NativeIcon("trash-2", size: 13) }
                .buttonStyle(T3Button(.ghost)).disabled(detail.isNull).help("Delete transcript").accessibilityLabel("Delete transcript")
        }
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 20) {
            if detail.isNull {
                if mediaReads.detailError != nil {
                    NativeReadFailureState(icon: "mic", title: "Could not load transcript", detail: "Try loading this transcript again.", retryTitle: "Reload transcript") {
                        Task { await loadDetail() }
                    }
                } else { ShimmerText(text: "Loading the transcript …") }
            }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { transcriptMetadata }
                    VStack(alignment: .leading, spacing: 6) { transcriptMetadata }
                }
                if ["queued", "running"].contains(detail["status"].string) {
                    let job = progress[detail["job_id"].string] ?? detail["job"]
                    VStack(alignment: .leading, spacing: 6) {
                        CapsuleBar(fraction: job["progress"].double)
                            .accessibilityLabel("Transcription progress").accessibilityValue(String(format: "%.0f percent", job["progress"].double * 100))
                        Text(job["progress_text"].string.isEmpty ? detail["status"].string : job["progress_text"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    }
                }
                if detail["status"].string == "done" { NativeTranscriptPerformance(row: detail) }
                if detail["failed_chunks"].int > 0 { Text("\(detail["failed_chunks"].int) audio chunks are missing from this transcript.").font(Theme.ui(12.5)).foregroundStyle(Theme.warnFg) }
                if !detail["error"].isNull { NativeError(message: detail["error"].string) }
                if let selected { countdown(selected) }
                Card(padding: 20) {
                    if !transcriptText.isEmpty {
                        Text(transcriptText).font(Theme.ui(13.5)).foregroundStyle(Theme.ink.opacity(0.9)).lineSpacing(7)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    else if detail["status"].string == "cancelled" { Text("Cancelled. Resume to continue from saved chunks.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted) }
                    else if detail["status"].string == "failed" { Text("No transcript was produced.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted) }
                    else {
                        ShimmerText(text: detail["status"].string == "queued" ? "Waiting for a transcription slot…" : "Reading audio and transcribing…").padding(.vertical, 16)
                    }
                }
                if !detail["summary"].string.isEmpty {
                    NativeCard(title: "Saved summary") {
                        Text(detail["summary"].string).font(Theme.ui(13)).lineSpacing(6).textSelection(.enabled)
                        if !detail["summary_model"].string.isEmpty { Text(detail["summary_model"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                    }
                }
            }
        }
    }
    @ViewBuilder private var transcriptMetadata: some View {
        MonoChip(text: detail["source_kind"].string == "url" ? "link" : "file")
        MonoChip(text: detail["status"].string)
        if !detail["duration_s"].isNull { MonoChip(text: "Audio " + duration(detail["duration_s"].double)) }
        if detail["status"].string == "done" { MonoChip(text: "\(detail["wordCount"].int) words") }
        if !detail["lang"].string.isEmpty { MonoChip(text: detail["lang"].string) }
        Text(Date(timeIntervalSince1970: detail["created_at"].double / 1000), style: .date).font(Theme.mono(11)).foregroundStyle(Theme.muted)
        Text(detail["source"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            .textSelection(.enabled).help(detail["source"].string)
    }
    @ViewBuilder private func countdown(_ id: String) -> some View {
        if let estimate = eta[id], rows.first(where: { $0["id"].string == id })?["status"].string == "running" {
            if pageActive { TimelineView(.periodic(from: .now, by: 1)) { tick in etaLabel(estimate, at: tick.date) } }
            else { etaLabel(estimate, at: Date()) }
        }
    }
    private func etaLabel(_ estimate: (value: JSONValue, received: Date), at date: Date) -> some View {
        let left = max(0, estimate.value["eta_ms"].double / 1000 - date.timeIntervalSince(estimate.received))
        return Text("About " + duration(left) + " left (" + estimate.value["phase"].string + ")").font(Theme.mono(10)).foregroundStyle(Theme.muted).help("Estimated from " + estimate.value["basis"].string)
    }
    private func reload() async {
        guard let service, let ticket = reads.begin("list") else { return }
        do {
            let nextRows = try await service.handle("list").array
            guard reads.accepts(ticket) else { return }
            let nextStatus = try await service.handle("status")
            guard reads.accepts(ticket) else { return }
            rows = nextRows; status = nextStatus; error = nil
            if selected != nil { await loadDetail() }
        } catch { if reads.accepts(ticket) { self.error = error.localizedDescription } }
    }
    private func loadDetail() async {
        guard let service else { return }
        await mediaReads.loadDetail(read: { id in
            try await service.handle("detail", input: ["id": .string(id)])
        }, publish: { result in
            detail = result
            let checkpoint = Dictionary(result["checkpointParts"].array.map { ($0["index"].int, $0["text"].string) }, uniquingKeysWith: { _, new in new })
            parts.merge(checkpoint) { _, new in new }
            if !result["job"].isNull { progress[result["job"]["id"].string] = result["job"] }
        })
    }
    private func resume() async {
        guard let selected, let service else { return }; submitting = true; defer { submitting = false }
        do { _ = try await service.handle("resume", input: ["id": .string(selected), "notify": .bool(notify)]); await reload() } catch { self.error = error.localizedDescription }
    }
    private func submit(_ value: String, upload: Bool) async {
        guard let service else { return }; submitting = true; defer { submitting = false }
        do { let result = try await service.handle(upload ? "upload" : "submit", input: ["source": .string(value), "lang": .string(language), "notify": .bool(notify)]); source = ""; selected = result["id"].string; detail = result; parts = [:]; await reload() }
        catch { self.error = error.localizedDescription }
    }
    private func remove(_ id: String) async {
        do { _ = try await service?.handle("delete", input: ["id": .string(id)]); if selected == id { back() }; await reload() } catch { self.error = error.localizedDescription }
    }
    private func renameTranscript() async {
        guard let selected else { return }
        do { _ = try await service?.handle("rename", input: ["id": .string(selected), "title": .string(title)]); rename = false; await reload() } catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard let selected else { return }
        let panelToken = NativePagePanels.shared.capture()
        do { let result = try await service?.handle("export", input: ["id": .string(selected)]) ?? .null; let panel = NSSavePanel(); panel.nameFieldStringValue = result["filename"].string; panel.nativeBegin(token: panelToken) { response in guard response == .OK, let url = panel.url else { return }; do { try Data(result["text"].string.utf8).write(to: url, options: .atomic) } catch { self.error = error.localizedDescription } } } catch { self.error = error.localizedDescription }
    }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.nativeBegin { response in if response == .OK { Task { for url in panel.urls { await submit(url.path, upload: false) } } } }
    }
    private func acceptFiles(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in guard let url else { return }; Task { @MainActor in await submit(url.path, upload: true) } } }; return true
    }
    private func back() { selected = nil; detail = .null; parts = [:] }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    private func duration(_ seconds: Double) -> String { NativeListTimeFormat.duration(seconds * 1000) }
}

private struct NativeTranscribeSourceField: View {
    @Binding var source: String
    let onSubmit: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            NativeIcon("link", size: 14).foregroundStyle(Theme.muted).accessibilityHidden(true)
            TextField("Link or file path", text: $source)
                .textFieldStyle(.plain).font(Theme.ui(14)).accessibilityLabel("Transcription source")
                .focused($focused).onSubmit(onSubmit)
        }.padding(.horizontal, 14).frame(minWidth: 180, maxWidth: .infinity).frame(height: 44)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.input, lineWidth: 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
    }
}

private struct NativeTranscriptHistoryRow<Countdown: View>: View {
    let row: JSONValue
    let progress: JSONValue
    let metadata: String
    let onOpen: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var countdown: () -> Countdown
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    StatusDot(color: row["status"].string == "done" ? Theme.ok : row["status"].string == "failed" ? Theme.fail : Theme.accent, pulse: row["status"].string == "running")
                        .accessibilityLabel(row["status"].string)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(row["title"].string.isEmpty ? row["source"].string : row["title"].string)
                                .font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            NativeIcon(row["source_kind"].string == "url" ? "link" : "file-audio", size: 11).foregroundStyle(Theme.muted)
                            if row["failed_chunks"].int > 0 { MonoChip(text: "\(row["failed_chunks"].int) gaps", color: Theme.warnFg) }
                        }
                        HStack(spacing: 5) {
                            if !metadata.isEmpty { Text(metadata + " ·").lineLimit(1) }
                            Text(NativeListTimeFormat.ago(row["created_at"].double)).lineLimit(1)
                        }.font(Theme.mono(11.5)).foregroundStyle(Theme.muted)
                        if row["status"].string == "done" { NativeTranscriptPerformance(row: row) }
                        if !row["error"].isNull { Text(row["error"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.failFg).lineLimit(2) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if ["queued", "running"].contains(row["status"].string) {
                        VStack(alignment: .leading, spacing: 4) {
                            CapsuleBar(fraction: progress["progress"].double)
                            Text(progress["progress_text"].string.isEmpty ? row["status"].string : progress["progress_text"].string)
                                .font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                            countdown()
                        }.frame(width: 168)
                    }
                    RowActionLabel(title: "Open", hovering: hovering, width: 50).accessibilityHidden(true)
                }.padding(.trailing, 6).padding(.vertical, 11).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHand()
                .help(row["source"].string)
            Button(action: onDelete) { NativeIcon("trash-2", size: 13) }
                .buttonStyle(T3Button(.ghost)).help("Delete transcript").accessibilityLabel("Delete transcript")
                .padding(.trailing, 4)
        }.background(hovering ? Theme.subtle : .clear).onHover { hovering = $0 }
    }
}

private struct NativeTranscriptPerformance: View {
    let row: JSONValue
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { processingTime; processingRate }
            VStack(alignment: .leading, spacing: 4) { processingTime; processingRate }
        }.font(Theme.mono(11.5)).foregroundStyle(Theme.dim)
    }
    private var processingTime: some View {
        Text(row["transcribe_ms"].isNull ? "Transcription time unavailable" : "Transcribed in " + NativeListTimeFormat.duration(row["transcribe_ms"].double))
            .fixedSize(horizontal: true, vertical: false)
            .help("Time spent on speech recognition, including retries. Excludes downloading, decoding and queue waits.")
    }
    private var processingRate: some View {
        NativeNumberText(text: row["wordsPerMinute"].isNull ? "— words/min" : row["wordsPerMinute"].double.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0))) + " words/min", font: Theme.mono(11.5), color: Theme.dim)
            .help("Full transcript word count divided by ASR processing minutes. This measures processing throughput, not speaker pace; audio duration is separate.")
    }
}
