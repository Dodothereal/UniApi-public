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
    @FocusState private var sourceFocused: Bool
    @Environment(\.nativeReducedMotion) private var reduceMotion
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
    private let languages: [(value: String, label: String)] = [("", "Auto"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"), ("pt", "Português"), ("nl", "Nederlands"), ("tr", "Türkçe"), ("ja", "日本語"), ("zh", "中文")]
    private var service: NativeTranscriptionService? { session.transcription }
    private var reads: NativePageReadScope { mediaReads.scope }
    private var selected: String? {
        get { mediaReads.selection }
        nonmutating set { mediaReads.select(newValue) }
    }
    private var pageError: String? { error ?? mediaReads.detailError }
    private var transcriptText: String { NativeTranscriptPresentation.text(detail, parts: parts) }
    private var modelReady: Bool { status["model"]["available"].bool }
    /// The model asks for attention until it is installed and runnable.
    private var needsSetup: Bool { !status.isNull && (!modelReady || installingModel || !status["localRuntime"].bool) }
    private var pageTitle: String {
        guard selected != nil else { return "Transcribe" }
        return detail["title"].string.isEmpty && detail["source"].string.isEmpty ? "Transcription" : nativeTranscriptName(detail)
    }
    var body: some View {
        NativePage(title: pageTitle, eyebrow: selected == nil ? "Links and files to text" : "Transcript", readiness: pageError != nil ? .failed : status.isNull || selected != nil && detail.isNull ? .pending : .ready, backTitle: "Transcripts", back: selected == nil ? nil : back, actions: {
            if selected == nil {
                Button("Reload", nativeIcon: "rotate-cw") { Task { await reload() } }
            } else { transcriptActions }
        }) {
            if let pageError { Notice(text: pageError, tone: .fail).accessibilityLabel("Error: " + pageError) }
            if selected == nil {
                composer
                if !rows.isEmpty { tally }
                history
                if !status.isNull && !needsSetup { Band("On-device model", spacing: 0) { modelRow } }
            } else { transcript }
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous).strokeBorder(Theme.signal, style: StrokeStyle(lineWidth: 2, dash: [8, 5])).padding(12).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in acceptFiles(providers) }
        .sheet(isPresented: $rename) {
            NativeTranscriptRenameSheet(title: $title, cancel: { rename = false }, save: { Task { await renameTranscript() } })
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

    // MARK: - New transcription

    /// The top of the page is the tool: a source, the one action, and the two
    /// choices that apply to the next transcription. Files can be dropped anywhere.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One surface: the well is the field, so nothing is boxed inside it.
            Well(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { sourceField; sourceActions }
                        VStack(alignment: .leading, spacing: 0) { sourceField; HStack(spacing: 8) { sourceActions }.padding(.bottom, 12) }
                    }.padding(.leading, 16).padding(.trailing, 12)
                    Rule()
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 24) { dropHint; Spacer(minLength: 0); sourceOptions }
                        VStack(alignment: .leading, spacing: 10) { dropHint; HStack(spacing: 24) { sourceOptions } }
                    }.padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 10)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous)
                    .strokeBorder(Theme.signal, style: StrokeStyle(lineWidth: 1, dash: dropTarget ? [4, 3] : []))
                    .opacity(dropTarget || sourceFocused ? 1 : 0).allowsHitTesting(false)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: sourceFocused)
            }
            if needsSetup { modelRow }
            if !status.isNull && !status["ytdlp"].bool {
                Notice(text: "Links need the optional yt-dlp. Local WAV, MP3 and M4A files use the built-in decoder; other formats may need ffmpeg.")
            }
        }
    }
    private var dropHint: some View {
        HStack(spacing: 8) {
            NativeIcon("upload", size: 13, strokeWidth: 1.75).foregroundStyle(dropTarget ? Theme.signal : Theme.muted)
            Text(dropTarget ? "Release to transcribe" : "Drop audio or video anywhere. It stays on this Mac.")
                .font(Theme.ui(12.5)).foregroundStyle(dropTarget ? Theme.ink : Theme.muted).lineLimit(1)
        }
        .help("Several files at once are fine. The local model is released from memory when its job finishes.")
    }
    @ViewBuilder private var sourceOptions: some View {
        HStack(spacing: 8) {
            MicroLabel("Language")
            Pick(title: "Language", selection: $language, options: languages, width: 128)
        }.help("Forced when set; Auto lets the recognizer detect it per chunk.")
        HStack(spacing: 8) {
            MicroLabel("Telegram when done")
            Flip(isOn: $notify).accessibilityLabel("Telegram when done")
        }.help("One ping per transcript. Configure and enable Telegram delivery in Settings first.")
    }
    private var sourceField: some View {
        NativeTranscribeSourceField(source: $source, focused: $sourceFocused) { Task { await submit(source, upload: false) } }
    }
    @ViewBuilder private var sourceActions: some View {
        Button(action: chooseFiles) {
            HStack(spacing: 6) { NativeIcon("folder-open", size: 14, strokeWidth: 1.75); Text("Files") }
        }.buttonStyle(Press(.secondary)).accessibilityLabel("Choose files")
        // One primary at a time: while the model is missing, installing it is the action.
        Button { Task { await submit(source, upload: false) } } label: {
            HStack(spacing: 6) { NativeIcon("mic", size: 14, strokeWidth: 1.75); Text(submitting ? "Starting…" : "Transcribe") }
                .frame(minWidth: 93)
        }.buttonStyle(Press(needsSetup && !modelReady ? .secondary : .primary))
            .disabled(submitting || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !status["localReady"].bool)
    }

    /// The optional model. It sits above the composer while it needs
    /// something, and at the foot of the page once it is installed.
    private var modelRow: some View {
        let detail: String = installingModel ? (modelProgress["message"].string.isEmpty ? "Preparing model download…" : modelProgress["message"].string)
            : modelReady ? (status["localRuntime"].bool ? "Installed. Ready for on-device transcription; it runs only for a transcription job."
                            : "Model installed, but the bundled runtime is missing. Reinstall UniApi.")
            : "Optional 574 MB model. No account or cloud transcription service. Downloads only when you choose Install."
        return VStack(alignment: .leading, spacing: 0) {
            OptionRow(title: "Local Whisper large-v3-turbo", detail: detail, ruled: !installingModel && needsSetup) {
                if installingModel {
                    Button("Cancel") { modelTask?.cancel() }
                } else if modelReady {
                    Button("Remove model") { modelAction("model.remove") }.disabled(status["model"]["inUse"].bool)
                } else {
                    Button("Install model", nativeIcon: "download") { modelAction("model.install") }.buttonStyle(Press(.primary)).disabled(status.isNull)
                }
            }
            if installingModel {
                NativeTranscribeMeter(fraction: modelProgress["progress"].double)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Model download progress").accessibilityValue(String(format: "%.0f percent", modelProgress["progress"].double * 100))
                    .padding(.bottom, 8)
            }
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

    // MARK: - Transcripts

    /// What has been turned into text so far.
    private var tally: some View {
        let done = rows.filter { $0["status"].string == "done" }
        let working: Int = rows.filter { ["queued", "running"].contains($0["status"].string) }.count
        let seconds: Double = done.reduce(0) { $0 + $1["duration_s"].double }
        let words: Double = done.reduce(0) { $0 + $1["wordCount"].double }
        let known: Bool = !status.isNull
        let audio: (String, String) = seconds >= 3600 ? (String(format: "%.1f", seconds / 3600), "h") : (String(format: "%.0f", seconds / 60), "min")
        return ReadoutStrip(minimum: 130) {
            Readout(label: "Transcripts", value: known ? String(rows.count) : "--", size: .medium, color: known ? Theme.ink : Theme.faint)
            Readout(label: "Audio", value: known ? audio.0 : "--", unit: known ? audio.1 : "", size: .medium, color: known ? Theme.ink : Theme.faint)
            Readout(label: "Words", value: known ? NativeNumberFormat.compact(words) : "--", size: .medium, color: known ? Theme.ink : Theme.faint)
            Readout(label: "In progress", value: known ? String(working) : "--", size: .medium, tint: working > 0 ? Theme.signal : nil, color: known ? Theme.ink : Theme.faint)
        }
    }
    private var history: some View {
        Band(title: "Transcripts", spacing: 0) {
            if status["runs"].int > 0 {
                Text("time estimates learned from \(status["runs"].int) earlier runs").font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        } content: {
            NativeTranscriptLedgerHead()
            if rows.isEmpty {
                if status.isNull {
                    if error == nil { Text("Reading transcripts").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).frame(minHeight: 44) }
                } else {
                    Blank(icon: "mic", title: "No transcripts yet", detail: "Paste a link above, choose files, or drop audio or video anywhere on this page.")
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.self["id"]) { row in
                        NativeTranscriptHistoryRow(row: row, progress: progress[row["job_id"].string] ?? .null, onOpen: {
                            selected = row["id"].string; parts = [:]; detail = .null; Task { await loadDetail() }
                        }, onDelete: { deleting = row["id"].string }) { countdown(row["id"].string) }
                    }
                }
            }
        }
    }

    // MARK: - Open transcript

    private var live: Bool { ["queued", "running"].contains(detail["status"].string) }
    /// Copy is what an open transcript is for; while there is nothing to copy
    /// and the work can continue, resuming takes its place.
    private var transcriptActions: some View {
        let resumes: Bool = NativeTranscriptPresentation.canResume(detail)
        return HStack(spacing: 4) {
            IconPress(icon: "pencil", help: "Rename") { title = detail["title"].string; rename = true }
                .disabled(detail.isNull).accessibilityLabel("Rename transcript")
            IconPress(icon: "download", help: "Save text") { Task { await save() } }
                .disabled(detail["text"].string.isEmpty).accessibilityLabel("Save transcript text")
            IconPress(icon: "trash-2", help: "Delete transcript") { deleting = selected }
                .disabled(detail.isNull).accessibilityLabel("Delete transcript")
            if resumes {
                Button("Resume", nativeIcon: "rotate-cw") { Task { await resume() } }
                    .buttonStyle(Press(transcriptText.isEmpty ? .primary : .secondary)).disabled(runtime.paths.readOnly || submitting).padding(.leading, 4)
            }
            Button("Copy", nativeIcon: "copy") { copy(transcriptText) }
                .buttonStyle(Press(resumes && transcriptText.isEmpty ? .secondary : .primary)).disabled(transcriptText.isEmpty).padding(.leading, 4)
        }
    }
    @ViewBuilder private var transcript: some View {
        if detail.isNull {
            if mediaReads.detailError != nil {
                NativeReadFailureState(icon: "mic", title: "Could not load transcript", detail: "Try loading this transcript again.", retryTitle: "Reload transcript") {
                    Task { await loadDetail() }
                }
            } else { Text("Reading the transcript").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20) }
        } else {
            if live {
                let job = progress[detail["job_id"].string] ?? detail["job"]
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            NativeNumberText(text: String(Int((NativeMotion.fraction(job["progress"].double) * 100).rounded())), font: Theme.readout(34), color: Theme.ink)
                            MicroLabel("%")
                        }
                        Text(job["progress_text"].string.isEmpty ? detail["status"].string : job["progress_text"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                        Spacer(minLength: 8)
                        if let selected { countdown(selected) }
                    }
                    NativeTranscribeMeter(fraction: job["progress"].double, divisions: 50)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Transcription progress").accessibilityValue(String(format: "%.0f percent", job["progress"].double * 100))
                }
            }
            if detail["failed_chunks"].int > 0 { Notice(text: "\(detail["failed_chunks"].int) audio chunks are missing from this transcript.", tone: .warn) }
            if !detail["error"].isNull { Notice(text: detail["error"].string, tone: .fail).accessibilityLabel("Error: " + detail["error"].string) }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 40) {
                    reading.frame(minWidth: 520, idealWidth: 520, maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 14) { transcriptFigures; transcriptOrigin }.frame(width: 208, alignment: .topLeading)
                }
                VStack(alignment: .leading, spacing: 20) {
                    ReadoutStrip(minimum: 120) { transcriptFigures }
                    transcriptOrigin
                    reading
                }
            }
        }
    }
    /// The reading column: playback when the media is still on disk, then the text.
    private var reading: some View {
        VStack(alignment: .leading, spacing: 28) {
            Well(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if let path = mediaPath {
                        NativeTranscriptPlayback(path: path).id(path).padding(.horizontal, 24)
                    }
                    Group {
                        if !transcriptText.isEmpty {
                            Text(transcriptText).font(Theme.ui(13)).foregroundStyle(Theme.ink).lineSpacing(7)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
                        }
                        else if detail["status"].string == "cancelled" { Text("Cancelled. Resume to continue from saved chunks.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted) }
                        else if detail["status"].string == "failed" { Text("No transcript was produced.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted) }
                        else {
                            Text(detail["status"].string == "queued" ? "Waiting for a transcription slot…" : "Reading audio and transcribing…")
                                .font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !detail["summary"].string.isEmpty {
                Band(title: "Saved summary", spacing: 12) {
                    if !detail["summary_model"].string.isEmpty { Text(detail["summary_model"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1) }
                } content: {
                    Text(detail["summary"].string).font(Theme.ui(13)).foregroundStyle(Theme.ink).lineSpacing(6).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
                }
            }
        }
    }
    /// The file that was transcribed, when it is still where it was.
    private var mediaPath: String? {
        let path: String = detail["media_path"].isNull ? (detail["source_kind"].string == "file" ? detail["source"].string : "") : detail["media_path"].string
        return path.hasPrefix("/") ? path : nil
    }
    @ViewBuilder private var transcriptFigures: some View {
        let done: Bool = detail["status"].string == "done"
        if !done { Readout(label: "Status", value: detail["status"].string.capitalized, size: .small, tint: live ? Theme.signal : nil, color: statusColor) }
        Readout(label: "Audio", value: detail["duration_s"].isNull ? "--" : duration(detail["duration_s"].double), size: .small,
                color: detail["duration_s"].isNull ? Theme.faint : Theme.ink)
        if done {
            Readout(label: "Words", value: NativeNumberFormat.decimal(detail["wordCount"].double), size: .small)
            Readout(label: "Transcribed in", value: detail["transcribe_ms"].isNull ? "--" : NativeListTimeFormat.duration(detail["transcribe_ms"].double), size: .small,
                    color: detail["transcribe_ms"].isNull ? Theme.faint : Theme.ink)
                .help(detail["transcribe_ms"].isNull ? "Transcription time unavailable" : "Time spent on speech recognition, including retries. Excludes downloading, decoding and queue waits.")
            Readout(label: "Rate", value: detail["wordsPerMinute"].isNull ? "--" : detail["wordsPerMinute"].double.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0))),
                    unit: "words/min", size: .small, color: detail["wordsPerMinute"].isNull ? Theme.faint : Theme.ink)
                .help("Full transcript word count divided by ASR processing minutes. This measures processing throughput, not speaker pace; audio duration is separate.")
        }
        if !detail["lang"].string.isEmpty { Readout(label: "Language", value: detail["lang"].string.uppercased(), size: .small) }
    }
    private var statusColor: Color {
        switch detail["status"].string { case "failed": return Theme.failFg; case "cancelled": return Theme.warnFg; default: return Theme.ink }
    }
    private var transcriptOrigin: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rule()
            HStack(spacing: 6) {
                Tag(detail["source_kind"].string == "url" ? "link" : "file")
                Text(Date(timeIntervalSince1970: detail["created_at"].double / 1000), style: .date).font(Theme.mono(11)).foregroundStyle(Theme.muted)
            }.padding(.top, 6)
            Text(detail["source"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(3).truncationMode(.middle)
                .textSelection(.enabled).help(detail["source"].string)
        }
    }
    @ViewBuilder private func countdown(_ id: String) -> some View {
        if let estimate = eta[id], rows.first(where: { $0["id"].string == id })?["status"].string == "running" {
            if pageActive { TimelineView(.periodic(from: .now, by: 1)) { tick in etaLabel(estimate, at: tick.date) } }
            else { etaLabel(estimate, at: Date()) }
        }
    }
    private func etaLabel(_ estimate: (value: JSONValue, received: Date), at date: Date) -> some View {
        let left = max(0, estimate.value["eta_ms"].double / 1000 - date.timeIntervalSince(estimate.received))
        return Text("About " + duration(left) + " left (" + estimate.value["phase"].string + ")").font(Theme.mono(10.5)).foregroundStyle(Theme.muted).help("Estimated from " + estimate.value["basis"].string)
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

/// Its own view, so Save follows the title as it is typed: state read only
/// inside a sheet closure does not refresh the sheet.
private struct NativeTranscriptRenameSheet: View {
    @Binding var title: String
    let cancel: () -> Void
    let save: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename transcript").font(Theme.display(17)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
            Entry(placeholder: "Title", text: $title, autoFocus: true).accessibilityLabel("Transcript title")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", action: cancel).buttonStyle(Press(.quiet)).keyboardShortcut(.cancelAction)
                Button("Save", action: save).buttonStyle(Press(.primary))
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 440).background(Theme.popover)
    }
}

/// What a transcript is called: its title, else the file's name or the link.
/// The whole source stays in the tooltip and beside an open transcript.
private func nativeTranscriptName(_ row: JSONValue) -> String {
    if !row["title"].string.isEmpty { return row["title"].string }
    let source: String = row["source"].string
    return row["source_kind"].string == "file" && source.contains("/") ? URL(fileURLWithPath: source).lastPathComponent : source
}

/// The page's main input: a bare line of text that takes the composer well
/// as its field. It carries its own accessibility label, which the kit's
/// `Entry` has no slot for.
private struct NativeTranscribeSourceField: View {
    @Binding var source: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            NativeIcon("link", size: 14, strokeWidth: 1.75).foregroundStyle(focused.wrappedValue ? Theme.ink : Theme.muted).accessibilityHidden(true)
            TextField("Paste a link or a file path", text: $source)
                .textFieldStyle(.plain).font(Theme.ui(13)).foregroundStyle(Theme.ink).accessibilityLabel("Transcription source")
                .focused(focused).onSubmit(onSubmit)
        }.frame(minWidth: 180, maxWidth: .infinity).frame(height: 58).contentShape(Rectangle())
            .onTapGesture { focused.wrappedValue = true }
    }
}

/// Fixed columns of the transcript ledger; the head and each row share them.
private enum TranscriptColumn {
    static let audio: CGFloat = 72
    static let words: CGFloat = 64
    static let took: CGFloat = 64
    static let rate: CGFloat = 84
    static let added: CGFloat = 84
    static let action: CGFloat = 21
    /// Below this width the two processing columns give their room to the title.
    static let wide: CGFloat = 260 + audio + words + took + rate + added + action + 72
}

private struct NativeTranscriptLedgerHead: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            head(processing: true).frame(minWidth: TranscriptColumn.wide)
            head(processing: false)
        }
    }
    private func head(processing: Bool) -> some View {
        LedgerHead {
            MicroLabel("Transcript").frame(minWidth: 0, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
            MicroLabel("Audio").frame(width: TranscriptColumn.audio, alignment: .trailing)
            MicroLabel("Words").frame(width: TranscriptColumn.words, alignment: .trailing)
            if processing {
                MicroLabel("Took").frame(width: TranscriptColumn.took, alignment: .trailing)
                    .help("Time spent on speech recognition, including retries. Excludes downloading, decoding and queue waits.")
                MicroLabel("Words/min").frame(width: TranscriptColumn.rate, alignment: .trailing)
                    .help("Full transcript word count divided by ASR processing minutes. This measures processing throughput, not speaker pace; audio duration is separate.")
            }
            MicroLabel("Added").frame(width: TranscriptColumn.added, alignment: .trailing)
            Color.clear.frame(width: TranscriptColumn.action, height: 1)
        }
    }
}

/// One transcript. Finished work reads across as figures; live work shows a
/// ticked meter with the signal tick at its head. The row opens the transcript.
private struct NativeTranscriptHistoryRow<Countdown: View>: View {
    let row: JSONValue
    let progress: JSONValue
    let onOpen: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var countdown: () -> Countdown
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var status: String { row["status"].string }
    private var live: Bool { ["queued", "running"].contains(status) }

    var body: some View {
        Button(action: onOpen) {
            ViewThatFits(in: .horizontal) {
                columns(processing: true).frame(minWidth: TranscriptColumn.wide)
                columns(processing: false)
            }
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(hovering ? Theme.hover : .clear).padding(.horizontal, -8)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand().help(row["source"].string)
        .overlay(alignment: .trailing) {
            // The glyph, not its 28-point hit area, ends on the content edge.
            IconPress(icon: "trash-2", help: "Delete transcript", size: 13, action: onDelete)
                .accessibilityLabel("Delete transcript").opacity(hovering ? 1 : 0.55).padding(.trailing, -7)
        }
        .overlay(alignment: .bottom) { Rule() }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
    private func columns(processing: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(nativeTranscriptName(row))
                        .font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                    Tag(row["source_kind"].string == "url" ? "link" : "file")
                    if row["failed_chunks"].int > 0 { Tag("\(row["failed_chunks"].int) gaps", tone: Theme.warnFg) }
                    statusTag
                }
                if status == "running" || live && !progress["progress_text"].string.isEmpty {
                    HStack(spacing: 10) {
                        if status == "running" { NativeTranscribeMeter(fraction: progress["progress"].double, divisions: 20).frame(width: 180) }
                        if !progress["progress_text"].string.isEmpty {
                            Text(progress["progress_text"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        countdown()
                    }
                }
                if !row["error"].isNull { Text(row["error"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.failFg).lineLimit(2) }
            }
            .frame(minWidth: 0, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
            figure(row["duration_s"].isNull ? "" : NativeListTimeFormat.duration(row["duration_s"].double * 1000), TranscriptColumn.audio)
            figure(status == "done" ? NativeNumberFormat.decimal(row["wordCount"].double) : "", TranscriptColumn.words)
            if processing {
                figure(status != "done" || row["transcribe_ms"].isNull ? "" : NativeListTimeFormat.duration(row["transcribe_ms"].double), TranscriptColumn.took)
                    .help(row["transcribe_ms"].isNull ? "Transcription time unavailable" : "Time spent on speech recognition, including retries. Excludes downloading, decoding and queue waits.")
                figure(status != "done" || row["wordsPerMinute"].isNull ? "" : row["wordsPerMinute"].double.formatted(.number.locale(Locale(identifier: "en_US")).precision(.fractionLength(0))), TranscriptColumn.rate)
                    .help("Full transcript word count divided by ASR processing minutes. This measures processing throughput, not speaker pace; audio duration is separate.")
            }
            Text(NativeListTimeFormat.ago(row["created_at"].double)).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                .frame(width: TranscriptColumn.added, alignment: .trailing)
            Color.clear.frame(width: TranscriptColumn.action, height: 1)
        }
    }
    private func figure(_ text: String, _ width: CGFloat) -> some View {
        Text(text.isEmpty ? "—" : text).font(Theme.mono(11)).foregroundStyle(text.isEmpty ? Theme.faint : Theme.dim).lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }
    @ViewBuilder private var statusTag: some View {
        switch status {
        case "running": Tag(status, tone: Theme.signal, dot: true).accessibilityLabel(status)
        case "queued": Tag(status).accessibilityLabel(status)
        case "failed": Tag(status, tone: Theme.failFg).accessibilityLabel(status)
        case "cancelled": Tag(status, tone: Theme.warnFg).accessibilityLabel(status)
        default: EmptyView()
        }
    }
}

/// Playback of the transcribed file inside the reading column: the thin
/// transport with one rule beneath it, and nothing when the file is gone.
private struct NativeTranscriptPlayback: View {
    let path: String
    @StateObject private var media = NativeMediaPlayer()
    var body: some View {
        // A stack, not a Group: the task below must run before there is a player to show.
        VStack(spacing: 0) {
            if let player = media.player {
                NativeMediaTransport(player: player, ruled: false).frame(height: 48)
                    .overlay(alignment: .bottom) { Rule() }
            }
        }
        .nativePageTask(id: path) {
            if FileManager.default.isReadableFile(atPath: path) { media.load(url: URL(fileURLWithPath: path)) }
        }
        .nativePageActivity(suspended: { media.pause() })
    }
}

/// Progress of live work: ink fills a ticked track and the signal tick marks
/// its head. The fill sweeps from the previous value.
private struct NativeTranscribeMeter: View {
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
