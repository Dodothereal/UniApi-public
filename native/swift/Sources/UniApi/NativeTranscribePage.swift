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
    @State private var wide = true
    @Environment(\.nativeInterfaceDensity) private var density
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
        NativePage(title: "Transcribe", maxWidth: .infinity, readiness: pageError != nil ? .failed : status.isNull ? .pending : .ready, scrolls: false, actions: {
            NativeMenuSelect(title: "Language", selection: $language, options: languages.map { ($0.0, $0.0.isEmpty ? "Detect language" : $0.1) }, width: 150)
            NativeIconMenu {
                Toggle("Telegram when done", isOn: $notify)
                Divider()
                Button("Reload") { Task { await reload() } }
                Button("Remove Whisper model (574 MB)") { modelAction("model.remove") }
                    .disabled(!modelReady || installingModel || status["model"]["inUse"].bool)
            }
        }) {
            VStack(alignment: .leading, spacing: 0) {
                composer
                if let pageError { NativeError(message: pageError).padding(.horizontal, density.pageMargin).padding(.vertical, 10) }
                if !setup.isEmpty {
                    NativeSetup(steps: setup).padding(.horizontal, density.pageMargin).padding(.top, 16).padding(.bottom, 8)
                }
                GeometryReader { geometry in
                    Group {
                        if rows.isEmpty {
                            NativePane(centered: false) {
                                if status.isNull && error == nil { ShimmerText(text: "Loading…") }
                                else if setup.isEmpty { NativeEmptyState(title: "No transcripts", detail: "Paste a link, choose files or drop audio here.", icon: "mic") }
                            }
                        } else if geometry.size.width >= 720 {
                            HStack(spacing: 0) {
                                list.frame(width: 320)
                                Theme.border.frame(width: 1)
                                transcript
                            }
                        } else if selected == nil { list } else { transcript }
                    }
                    .onChange(of: geometry.size.width >= 720, initial: true) { _, next in wide = next; selectFirstIfNeeded() }
                }
            }
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
        .background { Button("Back") { if !wide { back() } }.keyboardShortcut(.escape, modifiers: []).hidden().accessibilityHidden(true) }
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
    /// What must exist before a transcription can start. Empty once it does.
    private var setup: [NativeSetupStep] {
        guard !status.isNull else { return [] }
        var steps: [NativeSetupStep] = []
        if !modelReady || installingModel {
            steps.append(NativeSetupStep(id: "model", title: "Install Whisper large-v3-turbo", detail: "574 MB. Runs on this Mac, no account.", done: modelReady && !installingModel,
                busy: installingModel, busyText: modelProgress["message"].string.isEmpty ? "Preparing download…" : modelProgress["message"].string,
                progress: installingModel && !modelProgress["progress"].isNull ? modelProgress["progress"].double : nil, cancel: { modelTask?.cancel() },
                actionTitle: "Install", actionIcon: "download", action: { modelAction("model.install") }))
        }
        if modelReady && !status["localRuntime"].bool {
            steps.append(NativeSetupStep(id: "runtime", title: "Reinstall UniApi", detail: "The bundled speech runtime is missing.", done: false))
        }
        return steps
    }
    /// The one input of the page: a source, and the action that starts it.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                NativeTranscribeSourceField(source: $source) { Task { await submit(source, upload: false) } }
                Button("Files", nativeIcon: "folder-open", action: chooseFiles).buttonStyle(T3Button(.outline)).accessibilityLabel("Choose files")
                Button { Task { await submit(source, upload: false) } } label: {
                    Text(submitting ? "Starting…" : "Transcribe").frame(minWidth: 72)
                }.buttonStyle(T3Button(.primary)).disabled(submitting || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !status["localReady"].bool)
            }
            if !status.isNull, !status["ytdlp"].bool, source.lowercased().hasPrefix("http") {
                Text("Links need yt-dlp. Files work without it.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.warnFg)
            }
        }
        .padding(.horizontal, density.pageMargin).padding(.vertical, 12)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
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
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows, id: \.self["id"]) { row in
                    NativeTranscriptRow(row: row, selected: selected == row["id"].string, progress: progress[row["job_id"].string] ?? .null,
                                        metadata: historyMetadata(row), onOpen: { open(row) }) { countdown(row["id"].string) }
                        .contextMenu { Button("Delete", role: .destructive) { deleting = row["id"].string } }
                    Theme.rule.frame(height: 1).accessibilityHidden(true)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .focusable().focusEffectDisabled()
        .onMoveCommand { direction in
            guard let index = rows.firstIndex(where: { $0["id"].string == selected }) else { return }
            let next = direction == .down ? index + 1 : direction == .up ? index - 1 : index
            if next != index, rows.indices.contains(next) { open(rows[next]) }
        }
        .accessibilityLabel("Transcripts")
    }
    private func open(_ row: JSONValue) {
        guard selected != row["id"].string else { return }
        selected = row["id"].string; parts = [:]; detail = row; Task { await loadDetail() }
    }
    private func selectFirstIfNeeded() {
        if wide, selected == nil, let first = rows.first { open(first) }
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
        if NativeTranscriptPresentation.canResume(detail) {
            Button("Resume", nativeIcon: "rotate-cw") { Task { await resume() } }.buttonStyle(T3Button(.outline)).disabled(runtime.paths.readOnly || submitting)
        }
        T3IconButton(system: "pencil", help: "Rename") { title = detail["title"].string; rename = true }.disabled(detail.isNull)
        T3IconButton(system: "download", help: "Save text") { Task { await save() } }.disabled(transcriptText.isEmpty)
        T3IconButton(system: "trash-2", help: "Delete transcript") { deleting = selected }.disabled(detail.isNull)
        Button("Copy", nativeIcon: "copy") { copy(transcriptText) }.buttonStyle(T3Button(.outline)).disabled(transcriptText.isEmpty)
    }
    private var transcript: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !wide {
                    Button { back() } label: { HStack(spacing: 5) { NativeIcon("arrow-left", size: 12); Text("Transcripts") }.font(Theme.ui(Theme.textXs, weight: .medium)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.link).pointingHand()
                }
                if detail.isNull {
                    if mediaReads.detailError != nil {
                        NativeReadFailureState(icon: "mic", title: "Could not load transcript", detail: "", retryTitle: "Retry") { Task { await loadDetail() } }
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) { transcriptHeading; Spacer(minLength: 0); HStack(spacing: 4) { transcriptActions }.fixedSize() }
                        VStack(alignment: .leading, spacing: 12) { transcriptHeading; HStack(spacing: 4) { transcriptActions } }
                    }
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
                    else if ["queued", "running"].contains(detail["status"].string) { ShimmerText(text: detail["status"].string == "queued" ? "Queued…" : "Transcribing…") }
                    if !detail["summary"].string.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Theme.rule.frame(height: 1)
                            Text("Summary").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted).padding(.top, 8)
                            Text(detail["summary"].string).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.dim).lineSpacing(6).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 680, alignment: .leading)
                            if !detail["summary_model"].string.isEmpty { Text(detail["summary_model"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted) }
                        }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.surface)
    }
    private var transcriptHeading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail["title"].string.isEmpty ? (detail["source"].string.isEmpty ? "Transcription" : detail["source"].string) : detail["title"].string)
                .font(Theme.ui(Theme.textLg, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(2).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            transcriptMetadata
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
            if selected != nil { await loadDetail() } else { selectFirstIfNeeded() }
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

private struct NativeTranscriptRow<Countdown: View>: View {
    let row: JSONValue
    let selected: Bool
    let progress: JSONValue
    let metadata: String
    let onOpen: () -> Void
    @ViewBuilder var countdown: () -> Countdown
    @State private var hovering = false

    var body: some View {
        let status = row["status"].string, active = ["queued", "running"].contains(status)
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if status == "failed" { NativeIcon("circle-alert", size: 12).foregroundStyle(Theme.failFg).accessibilityLabel("Failed") }
                    Text(row["title"].string.isEmpty ? row["source"].string : row["title"].string)
                        .font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 5) {
                    if !metadata.isEmpty { Text(metadata + " ·").lineLimit(1) }
                    Text(NativeListTimeFormat.ago(row["created_at"].double)).lineLimit(1)
                    if row["failed_chunks"].int > 0 { Text("· \(row["failed_chunks"].int) gaps").foregroundStyle(Theme.warnFg) }
                    if status == "cancelled" { Text("· cancelled") }
                }.font(Theme.num(11.5, weight: .regular)).foregroundStyle(Theme.muted)
                if active {
                    NativeTickMeter(fraction: progress["progress"].double, color: Theme.accent, height: 6).padding(.top, 3)
                    HStack(spacing: 6) {
                        Text(progress["progress_text"].string.isEmpty ? status : progress["progress_text"].string).lineLimit(1)
                        countdown()
                    }.font(Theme.num(10.5, weight: .regular)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.leading, 24).padding(.trailing, 16).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Theme.raised : hovering ? Theme.subtle : .clear)
        .overlay(alignment: .leading) { Theme.accent.frame(width: 2).opacity(selected ? 1 : 0) }
        .onHover { hovering = $0 }
        .help(row["source"].string)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
