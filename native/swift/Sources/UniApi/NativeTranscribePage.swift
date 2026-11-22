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
        NativePage(title: selected == nil ? "Transcribe" : (detail["title"].string.isEmpty ? (detail["source"].string.isEmpty ? "Transcription" : detail["source"].string) : detail["title"].string),
                   readiness: pageError != nil ? .failed : status.isNull || selected != nil && detail.isNull ? .pending : .ready,
                   backTitle: "Transcripts", back: selected == nil ? nil : back, actions: {
            if selected == nil { T3IconButton(system: "refresh-cw", help: "Reload") { Task { await reload() } } }
            else { transcriptActions }
        }) {
            if let pageError { NativeError(message: pageError) }
            if selected == nil { input; history } else { transcript }
        }
        .overlay { if dropTarget { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])).padding(12).allowsHitTesting(false) } }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTarget) { providers in acceptFiles(providers) }
        .sheet(isPresented: $rename) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rename").font(Theme.ui(Theme.textBase, weight: .semibold))
                T3Field(placeholder: "Title", text: $title).accessibilityLabel("Transcript title")
                HStack {
                    Button("Cancel") { rename = false }.buttonStyle(T3Button(.ghost)).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Save") { Task { await renameTranscript() } }.buttonStyle(T3Button(.primary)).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 420).background(Theme.bg)
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
    private var modelReady: Bool { status["model"]["available"].bool }
    private var input: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !status.isNull, !modelReady || installingModel || !status["localRuntime"].bool { modelRow }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { sourceField; sourceActions }
                VStack(alignment: .leading, spacing: 8) { sourceField; HStack(spacing: 8) { sourceActions } }
            }
            HStack(spacing: 16) {
                NativeMenuSelect(title: "Language", selection: $language, options: languages.map { ($0.0, $0.0.isEmpty ? "Detect language" : $0.1) }, width: 150)
                HStack(spacing: 8) {
                    T3Switch(isOn: $notify).accessibilityLabel("Telegram when done")
                    Text("Telegram when done").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim)
                }
                Spacer(minLength: 0)
                if !status.isNull && !status["ytdlp"].bool {
                    Text("Links need yt-dlp").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                        .help("Install yt-dlp to transcribe links. WAV, MP3 and M4A files use the built-in decoder; other formats may need ffmpeg.")
                }
            }
        }.padding(.bottom, 8)
    }
    /// Shown above the source while the model is missing; afterwards it lives at the foot of the list.
    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Whisper large-v3-turbo").font(Theme.mono(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(installingModel ? (modelProgress["message"].string.isEmpty ? "Preparing download…" : modelProgress["message"].string)
                         : !modelReady ? "574 MB. Runs on this Mac, no account."
                         : status["localRuntime"].bool ? "574 MB, on this Mac" : "The bundled runtime is missing. Reinstall UniApi.")
                        .font(Theme.ui(Theme.textXs)).foregroundStyle(modelReady && !status["localRuntime"].bool ? Theme.failFg : Theme.muted)
                }
                Spacer(minLength: 12)
                if installingModel { Button("Cancel") { modelTask?.cancel() }.buttonStyle(T3Button(.outline)) }
                else if modelReady { Button("Remove") { modelAction("model.remove") }.buttonStyle(T3Button(.outline)).disabled(status["model"]["inUse"].bool) }
                else { Button("Install model", nativeIcon: "download") { modelAction("model.install") }.buttonStyle(T3Button(.primary)).disabled(status.isNull) }
            }
            if installingModel {
                NativeTickMeter(fraction: modelProgress["progress"].double, color: Theme.accent, height: 8)
                    .accessibilityLabel("Model download").accessibilityValue(String(format: "%.0f percent", modelProgress["progress"].double * 100))
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
        .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
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
            Text(submitting ? "Starting…" : "Transcribe").frame(minWidth: 72)
        }.buttonStyle(T3Button(.primary)).disabled(submitting || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !status["localReady"].bool)
        Button("Files", nativeIcon: "folder-open", action: chooseFiles).buttonStyle(T3Button(.outline)).accessibilityLabel("Choose files")
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                if status.isNull && error == nil { ShimmerText(text: "Loading…") }
                else { Theme.rule.frame(height: 1); NativeEmptyState(title: "No transcripts", detail: "Paste a link, choose files or drop audio here.", icon: "mic") }
            } else {
                Theme.rule.frame(height: 1)
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.self["id"]) { row in
                        NativeTranscriptHistoryRow(row: row, progress: progress[row["job_id"].string] ?? .null,
                            metadata: historyMetadata(row), onOpen: {
                                selected = row["id"].string; parts = [:]; detail = .null; Task { await loadDetail() }
                            }, onDelete: { deleting = row["id"].string }) { countdown(row["id"].string) }
                        Theme.rule.frame(height: 1).accessibilityHidden(true)
                    }
                }
            }
            if !status.isNull, modelReady, !installingModel, status["localRuntime"].bool { modelRow.padding(.top, 32) }
        }
    }
    private func historyMetadata(_ row: JSONValue) -> String {
        var values: [String] = []
        if !row["duration_s"].isNull { values.append(duration(row["duration_s"].double)) }
        if row["status"].string == "done" { values.append("\(row["wordCount"].int) words") }
        if row["status"].string == "done", !row["wordsPerMinute"].isNull { values.append(String(format: "%.0f words/min", row["wordsPerMinute"].double)) }
        if !row["lang"].string.isEmpty { values.append(row["lang"].string) }
        return values.joined(separator: " · ")
    }
    @ViewBuilder private var transcriptActions: some View {
        T3IconButton(system: "pencil", help: "Rename") { title = detail["title"].string; rename = true }.disabled(detail.isNull)
        T3IconButton(system: "download", help: "Save text") { Task { await save() } }.disabled(detail["text"].string.isEmpty)
        T3IconButton(system: "trash-2", help: "Delete transcript") { deleting = selected }.disabled(detail.isNull)
        if NativeTranscriptPresentation.canResume(detail) {
            Button("Resume", nativeIcon: "rotate-cw") { Task { await resume() } }.buttonStyle(T3Button(.outline)).disabled(runtime.paths.readOnly || submitting)
        }
        Button("Copy", nativeIcon: "copy") { copy(transcriptText) }.buttonStyle(T3Button(.primary)).disabled(transcriptText.isEmpty)
    }
    private var transcript: some View {
        VStack(alignment: .leading, spacing: 16) {
            if detail.isNull {
                if mediaReads.detailError != nil {
                    NativeReadFailureState(icon: "mic", title: "Could not load transcript", detail: "", retryTitle: "Retry") { Task { await loadDetail() } }
                } else { ShimmerText(text: "Loading…") }
            } else {
                transcriptMetadata
                if ["queued", "running"].contains(detail["status"].string) {
                    let job = progress[detail["job_id"].string] ?? detail["job"]
                    VStack(alignment: .leading, spacing: 6) {
                        NativeTickMeter(fraction: job["progress"].double, color: Theme.accent, height: 10)
                            .accessibilityLabel("Transcription progress").accessibilityValue(String(format: "%.0f percent", job["progress"].double * 100))
                        HStack(spacing: 10) {
                            Text(job["progress_text"].string.isEmpty ? detail["status"].string : job["progress_text"].string)
                            if let selected { countdown(selected) }
                        }.font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted)
                    }
                }
                if detail["failed_chunks"].int > 0 {
                    Text("\(detail["failed_chunks"].int) audio chunks are missing.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.warnFg)
                }
                if !detail["error"].isNull { NativeError(message: detail["error"].string) }
                Theme.rule.frame(height: 1)
                if !transcriptText.isEmpty {
                    Text(transcriptText).font(Theme.ui(Theme.textBase)).foregroundStyle(Theme.ink).lineSpacing(7)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 680, alignment: .leading)
                }
                else if detail["status"].string == "cancelled" { Text("Cancelled. Resume continues from the saved chunks.").font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.muted) }
                else if detail["status"].string == "failed" { Text("No transcript was produced.").font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.muted) }
                else { ShimmerText(text: detail["status"].string == "queued" ? "Queued…" : "Transcribing…") }
                if !detail["summary"].string.isEmpty {
                    NativeCard(title: "Summary") {
                        Text(detail["summary"].string).font(Theme.ui(Theme.textSm)).lineSpacing(6).textSelection(.enabled).frame(maxWidth: 680, alignment: .leading)
                        if !detail["summary_model"].string.isEmpty { Text(detail["summary_model"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                    }
                }
            }
        }
    }
    /// One line of facts, then where the audio came from.
    private var transcriptMetadata: some View {
        var facts: [String] = []
        if !["done", ""].contains(detail["status"].string) { facts.append(detail["status"].string) }
        if !detail["duration_s"].isNull { facts.append(duration(detail["duration_s"].double)) }
        if detail["status"].string == "done" {
            facts.append("\(detail["wordCount"].int) words")
            if !detail["transcribe_ms"].isNull { facts.append("transcribed in " + NativeListTimeFormat.duration(detail["transcribe_ms"].double)) }
            if !detail["wordsPerMinute"].isNull { facts.append(String(format: "%.0f words/min", detail["wordsPerMinute"].double)) }
        }
        if !detail["lang"].string.isEmpty { facts.append(detail["lang"].string) }
        facts.append(Date(timeIntervalSince1970: detail["created_at"].double / 1000).formatted(date: .abbreviated, time: .omitted))
        return VStack(alignment: .leading, spacing: 4) {
            Text(facts.joined(separator: " · ")).font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.dim)
                .help("Transcription time covers speech recognition and retries, not downloading, decoding or queueing. Words per minute is words divided by that time.")
            HStack(spacing: 6) {
                NativeIcon(detail["source_kind"].string == "url" ? "link" : "file-audio", size: 12).foregroundStyle(Theme.faint)
                Text(detail["source"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).help(detail["source"].string)
            }
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
        return Text(duration(left) + " left, " + estimate.value["phase"].string).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).help("Estimated from " + estimate.value["basis"].string)
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
            NativeIcon("link", size: 13).foregroundStyle(Theme.faint).accessibilityHidden(true)
            TextField("Link or file path", text: $source)
                .textFieldStyle(.plain).font(Theme.ui(Theme.textSm)).accessibilityLabel("Transcription source")
                .focused($focused).onSubmit(onSubmit)
        }.padding(.horizontal, 11).frame(minWidth: 180, maxWidth: .infinity).frame(height: Theme.control)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).strokeBorder(focused ? Theme.accent : Theme.input, lineWidth: 1))
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
        let status = row["status"].string, active = ["queued", "running"].contains(status)
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    NativeIcon(status == "failed" ? "circle-alert" : row["source_kind"].string == "url" ? "link" : "file-audio", size: 14)
                        .foregroundStyle(status == "failed" ? Theme.failFg : Theme.faint).frame(width: 16)
                        .accessibilityLabel(status)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row["title"].string.isEmpty ? row["source"].string : row["title"].string)
                            .font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        HStack(spacing: 5) {
                            if !metadata.isEmpty { Text(metadata + " ·").lineLimit(1) }
                            Text(NativeListTimeFormat.ago(row["created_at"].double)).lineLimit(1)
                            if row["failed_chunks"].int > 0 { Text("· \(row["failed_chunks"].int) gaps").foregroundStyle(Theme.warnFg) }
                            if status == "cancelled" { Text("· cancelled") }
                        }.font(Theme.num(11.5, weight: .regular)).foregroundStyle(Theme.muted)
                        if !row["error"].isNull { Text(row["error"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.failFg).lineLimit(2) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if active {
                        VStack(alignment: .leading, spacing: 4) {
                            NativeTickMeter(fraction: progress["progress"].double, color: Theme.accent, height: 8)
                            HStack(spacing: 6) {
                                Text(progress["progress_text"].string.isEmpty ? status : progress["progress_text"].string).lineLimit(1)
                                countdown()
                            }.font(Theme.num(10.5, weight: .regular)).foregroundStyle(Theme.muted)
                        }.frame(width: 190)
                    }
                    NativeIcon("chevron-right", size: 13).foregroundStyle(hovering ? Theme.ink : Theme.faint).accessibilityHidden(true)
                }.padding(.leading, 4).padding(.trailing, 6).frame(minHeight: 52).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHand()
                .help(row["source"].string)
            T3IconButton(system: "trash-2", help: "Delete transcript", size: 13, action: onDelete).opacity(hovering ? 1 : 0.35)
        }.background(hovering ? Theme.subtle : .clear).onHover { hovering = $0 }
    }
}
