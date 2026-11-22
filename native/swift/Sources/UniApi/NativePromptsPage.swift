import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UniApiCore
import UniApiPresentation

struct NativePromptsPage: View {
    let runtime: NativeRuntime
    @State private var service: NativePromptsService?
    @StateObject private var mediaReads = NativeMediaPageReads()
    private var reads: NativePageReadScope { mediaReads.scope }
    @State private var prompts: [JSONValue] = []
    private var selected: String? {
        get { mediaReads.selection }
        nonmutating set {
            if newValue != mediaReads.selection { preview = nil }
            mediaReads.select(newValue)
        }
    }
    @State private var detail: JSONValue = .null
    @State private var catalog: JSONValue = .null
    @State private var error: String?
    @State private var promptEditor: NativePresentedValue?
    @State private var resultEditor: NativePresentedValue?
    @State private var title = ""
    @State private var text = ""
    @State private var model = ""
    @State private var providerID = ""
    @State private var link = ""
    @State private var files: [URL] = []
    @State private var dropContext = NativePromptsDropContext()
    @State private var dropLoads: [Progress] = []
    @State private var pendingDrops = 0
    @State private var useLink = false
    @State private var saving = false
    @State private var ordering = false
    @State private var cleanupPending = false
    @State private var dragTarget = false
    @State private var resultDragTarget = false
    @State private var preview: NativePresentedValue?
    @State private var deleteAction: JSONValue = .null
    @State private var initializedPromptDialog: UUID?
    @State private var initializedResultDialog: UUID?
    @State private var filter = ""
    @State private var expandedPrompt: String?
    @Environment(\.nativeInterfaceDensity) private var density
    @Environment(\.nativeReducedMotion) private var reduceMotion
    private var editingPrompt: JSONValue { promptEditor?.value ?? .null }
    private var editingResult: JSONValue { resultEditor?.value ?? .null }
    private var pageError: String? { error ?? mediaReads.detailError ?? mediaReads.previewError }
    /// The list already holds the title and text, so a newly chosen prompt
    /// reads at once; only its results wait for the detail read.
    private var current: JSONValue {
        if !detail.isNull, detail["prompt"]["id"].string == selected { return detail["prompt"] }
        return prompts.first { $0["id"].string == selected } ?? .null
    }
    private var shownPrompts: [JSONValue] {
        let terms = filter.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return prompts }
        return prompts.filter { prompt in
            let haystack = (prompt["title"].string + " " + prompt["text"].string).lowercased()
            return terms.allSatisfy { haystack.contains($0) }
        }
    }
    private var resultTotal: Int { prompts.reduce(0) { $0 + $1["resultCount"].int } }
    private var waiting: Int { prompts.filter { $0["resultCount"].int == 0 }.count }

    var body: some View {
        GeometryReader { geometry in
        let contentWidth = min(960, geometry.size.width) - 2 * density.pageMargin
        NativePage(title: "Prompts", eyebrow: "Benchmark library", readiness: pageError != nil ? .failed : catalog.isNull || selected != nil && detail.isNull ? .pending : .ready, actions: {
            IconPress(icon: "rotate-cw", help: "Reload") { Task { await reload() } }
            Button("New prompt", nativeIcon: "plus") { error = nil; promptEditor = NativePresentedValue(value: .null) }
                .buttonStyle(Press(.primary))
        }) {
            if let pageError { BenchFailure(message: pageError) }
            if cleanupPending { Notice(text: "Removed. Managed file cleanup will retry in the background.", tone: .warn) }
            reading(split: contentWidth >= 700)
            if prompts.isEmpty { emptyLibrary }
            else if contentWidth >= 700 {
                HStack(alignment: .top, spacing: 32) {
                    promptIndex.frame(width: 272)
                    promptDetail.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                Pick(title: "Prompt", selection: Binding(get: { selected ?? "" }, set: { choose($0) }),
                     options: prompts.map { (value: $0["id"].string, label: $0["title"].string) }, width: max(120, contentWidth))
                promptDetail
            }
        }
        .overlay {
            if dragTarget {
                RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous)
                    .strokeBorder(Theme.signal, style: StrokeStyle(lineWidth: 2, dash: [8, 5])).padding(12).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dragTarget) { providers in acceptFiles(providers) }
        .sheet(item: $promptEditor) { item in promptForm(item) }
        .sheet(item: $resultEditor, onDismiss: cancelPendingDrops) { item in resultForm(item) }
        .sheet(item: $preview) { item in NativeArtifactPreview(preview: item.value) }
        .alert("Delete \(deleteAction["kind"].string)?", isPresented: Binding(get: { !deleteAction.isNull }, set: { if !$0 { deleteAction = .null } })) {
            Button("Cancel", role: .cancel) { deleteAction = .null }
            Button("Delete", role: .destructive) { let action = deleteAction; deleteAction = .null; Task { await remove(action) } }
        } message: { Text("The saved item and its managed files will be removed.") }
        .onChange(of: selected) { _, _ in cancelPendingDrops(); resultEditor = nil }
        .onChange(of: resultEditor?.id) { _, id in if id == nil { cancelPendingDrops() } }
        .nativePageTask {
            if service == nil { service = NativePromptsService(runtime: runtime) }
            let events = await runtime.events.stream()
            await reload()
            for await event in events {
                if Task.isCancelled { break }
                if event.topic == "prompts.changed" { await reload() }
            }
        }
        }
        .nativePageActivity(reads: reads, suspended: { cancelPendingDrops(); dragTarget = false })
    }

    // ---- reading ---------------------------------------------------------
    @ViewBuilder private func reading(split: Bool) -> some View {
        if catalog.isNull && prompts.isEmpty {
            if error == nil { Text("Reading saved prompts").font(Theme.ui(12.5)).foregroundStyle(Theme.muted) }
        } else {
            let library = Readout(label: "Library", value: String(prompts.count), unit: prompts.count == 1 ? "prompt" : "prompts", size: .hero)
            let collected = Readout(label: "Results collected", value: String(resultTotal), unit: resultTotal == 1 ? "file or link" : "files and links",
                                    detail: prompts.isEmpty ? "" : "Across " + PromptsText.count(prompts.count - waiting, "prompt"))
            let empty = Readout(label: "Still empty", value: String(waiting), unit: waiting == 1 ? "prompt" : "prompts",
                                detail: prompts.isEmpty ? "" : waiting == 0 ? "Every prompt has a result" : "Drop files on one to fill it",
                                color: waiting == 0 ? Theme.faint : Theme.ink)
            if split {
                // The readings sit on the same two columns as the index and the detail below.
                HStack(alignment: .top, spacing: 32) {
                    library.frame(width: 272)
                    ReadoutStrip(minimum: 170) { collected; empty }
                }
            } else {
                ReadoutStrip(minimum: 170) { library; collected; empty }
            }
        }
    }
    @ViewBuilder private var emptyLibrary: some View {
        if !catalog.isNull || error != nil {
            Band("Library", spacing: 0) {
                LedgerHead {
                    MicroLabel("Prompt"); Spacer(minLength: 0); MicroLabel("Results")
                }
                if error == nil {
                    Blank(icon: "file-text", title: "No prompts yet", detail: "Keep the full task text here, then collect what each model made for it.",
                          actionTitle: "New prompt", primary: false) { error = nil; promptEditor = NativePresentedValue(value: .null) }
                } else {
                    Blank(icon: "file-text", title: "Could not load prompts", detail: "Try reloading your saved prompts.",
                          actionTitle: "Reload", actionIcon: "rotate-cw", primary: false) { Task { await reload() } }
                }
            }
        }
    }

    // ---- index -----------------------------------------------------------
    private func choose(_ id: String) {
        selected = id; detail = .null
        Task { await loadDetail() }
    }
    private var promptIndex: some View {
        VStack(alignment: .leading, spacing: 0) {
            if prompts.count > 7 {
                Entry(placeholder: "Filter prompts", text: $filter, icon: "search").accessibilityLabel("Filter prompts")
                    .padding(.bottom, 10)
            }
            LedgerHead {
                MicroLabel("Prompt"); Spacer(minLength: 0); MicroLabel("Results")
            }
            LazyVStack(spacing: 0) {
                ForEach(shownPrompts, id: \.self["id"]) { prompt in
                    PromptIndexRow(prompt: prompt, selected: selected == prompt["id"].string,
                                   onSelect: { choose(prompt["id"].string) }, onCopy: { copy(prompt["text"].string) })
                }
            }
            if shownPrompts.isEmpty {
                Text("No prompt matches the filter").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 16)
            }
        }
    }

    // ---- detail ----------------------------------------------------------
    @ViewBuilder private var promptDetail: some View {
        let prompt = current
        if prompt.isNull {
            if mediaReads.detailError != nil {
                NativeReadFailureState(icon: "file-text", title: "Could not load results", detail: "Try loading this prompt again.", retryTitle: "Reload results") {
                    Task { await loadDetail() }
                }
            } else { Text("Reading prompt").font(Theme.ui(12.5)).foregroundStyle(Theme.muted) }
        } else {
            VStack(alignment: .leading, spacing: 24) {
                promptText(prompt)
                Band(title: "Results") {
                    if !detail.isNull, !resultsHint.isEmpty {
                        Text(resultsHint).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
                    }
                    Button("Add result", nativeIcon: "plus") { beginResult() }.fixedSize()
                } content: { results }
            }
        }
    }
    private var resultsHint: String {
        let count = detail["results"].array.count
        return count == 0 ? "" : count == 1 ? "1 collected" : "\(count) · best first"
    }
    private func promptText(_ prompt: JSONValue) -> some View {
        let body = prompt["text"].string
        let long = body.count > 620 || body.filter { $0 == "\n" }.count > 9
        let open = expandedPrompt == prompt["id"].string
        return VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    promptTitle(prompt).frame(maxWidth: .infinity, alignment: .leading)
                    promptActions(prompt)
                }
                VStack(alignment: .leading, spacing: 10) { promptTitle(prompt); promptActions(prompt).padding(.leading, -1) }
            }
            Rule().padding(.top, 14)
            Text(body).font(Theme.ui(13)).foregroundStyle(Theme.dim).lineSpacing(5)
                .lineLimit(long && !open ? 10 : nil)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
            if long {
                Button {
                    let next = open ? nil : prompt["id"].string
                    if reduceMotion { expandedPrompt = next } else { withAnimation(NativeMotion.toggle) { expandedPrompt = next } }
                } label: {
                    HStack(spacing: 6) {
                        NativeIcon(open ? "chevron-up" : "chevron-down", size: 13, strokeWidth: 1.75)
                        Text(open ? "Show less" : "Show the whole prompt")
                    }
                }.buttonStyle(Press(.quiet)).padding(.leading, -8).padding(.top, 6)
                    .accessibilityValue(open ? "Expanded" : "Collapsed")
            }
        }
    }
    private func promptTitle(_ prompt: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prompt["title"].string).font(Theme.display(17)).foregroundStyle(Theme.ink).accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
            Text("created " + PromptsText.day(prompt["createdAt"].double) + " · " + PromptsText.count(prompt["text"].string.count, "character"))
                .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }
    private func promptActions(_ prompt: JSONValue) -> some View {
        HStack(spacing: 2) {
            Button("Copy prompt", nativeIcon: "clipboard") { copy(prompt["text"].string) }.padding(.trailing, 4)
            IconPress(icon: "pencil", help: "Edit prompt") { error = nil; promptEditor = NativePresentedValue(value: prompt) }
            IconPress(icon: "trash-2", help: "Delete prompt") { deleteAction = ["kind": "prompt", "id": prompt["id"]] }
        }.fixedSize()
    }
    @ViewBuilder private var results: some View {
        if detail.isNull {
            if mediaReads.detailError != nil {
                NativeReadFailureState(icon: "file-text", title: "Could not load results", detail: "Try loading this prompt again.", retryTitle: "Reload results") {
                    Task { await loadDetail() }
                }
            } else { Text("Reading results").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 8) }
        } else if detail["results"].array.isEmpty {
            Well(padding: 4) {
                Blank(icon: "upload", title: "No results yet", detail: "Drop files here, or add a link to a model response. Any file type, 50 MiB per file.")
                    .padding(.horizontal, 16)
            }
        } else {
            let rows = detail["results"].array
            VStack(alignment: .leading, spacing: 0) {
                LedgerHead {
                    MicroLabel("Rank").frame(width: 44, alignment: .leading)
                    MicroLabel("Model")
                    Spacer(minLength: 0)
                    MicroLabel("Size").frame(width: 64, alignment: .trailing)
                    Color.clear.frame(width: 88, height: 1)
                }
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element["id"]) { index, result in
                        PromptResultRow(result: result, rank: index + 1, source: resultSource(result),
                                        open: { activate(result) }) { resultActions(result, index: index, last: index == rows.count - 1) }
                    }
                }
                Text("Drop files anywhere on this page to add results. Any file type, 50 MiB per file.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
        }
    }
    private func resultSource(_ result: JSONValue) -> String {
        let provider = !result["providerName"].string.isEmpty ? result["providerName"].string : !result["providerId"].string.isEmpty ? result["providerId"].string : "Unspecified provider"
        let source = result["kind"].string == "url" ? result["url"].string.isEmpty ? "URL" : result["url"].string : result["fileName"].string.isEmpty ? "File" : result["fileName"].string
        return provider + " · " + source
    }
    /// A row opens what it holds: an upload in the preview, a link in the browser.
    private func activate(_ result: JSONValue) {
        let owner = mediaReads.beginPreview()
        if result["kind"].string == "upload" {
            guard let owner else { return }
            Task { await previewResult(result, owner: owner) }
        } else { Task { await openResult(result, owner: owner) } }
    }
    private func resultActions(_ result: JSONValue, index: Int, last: Bool) -> some View {
        HStack(spacing: 2) {
            IconPress(icon: "arrow-up", help: "Rank higher") { Task { await reorder(index, -1) } }.disabled(ordering || index == 0)
            IconPress(icon: "arrow-down", help: "Rank lower") { Task { await reorder(index, 1) } }.disabled(ordering || last)
            Menu {
                if result["kind"].string == "upload" {
                    Button("Preview result") {
                        guard let owner = mediaReads.beginPreview() else { return }
                        Task { await previewResult(result, owner: owner) }
                    }
                    Button("Save result…") { Task { await saveResult(result) } }
                }
                Button("Open result") {
                    let owner = mediaReads.beginPreview()
                    Task { await openResult(result, owner: owner) }
                }
                Button("Edit result…") { beginResult(result) }
                Divider()
                Button("Delete result…", role: .destructive) { deleteAction = ["kind": "result", "id": result["id"]] }
            } label: {
                NativeIcon("ellipsis", size: 14, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointingHand()
            .accessibilityLabel("More for " + result["model"].string).help("Preview, save, open, edit or delete")
        }.fixedSize()
    }

    // ---- sheets ----------------------------------------------------------
    private func promptForm(_ item: NativePresentedValue) -> some View {
        BenchSheet(eyebrow: item.value.isNull ? "New prompt" : "Edit prompt", title: title, editing: $title,
                   placeholder: "Name this task", titleLabel: "Prompt title", focusTitle: item.value.isNull, width: 680) {
            VStack(alignment: .leading, spacing: 12) {
                BenchEditor(text: $text, placeholder: "The full task text, exactly as every model should receive it", label: "Prompt text", height: 320)
                if let error { BenchFailure(message: error) }
            }
        } note: {
            Text(PromptsText.count(text.count, "character")).font(Theme.mono(10.5))
        } actions: {
            Button("Cancel") { promptEditor = nil }.buttonStyle(Press(.quiet)).keyboardShortcut(.cancelAction)
            Button(saving ? "Saving…" : item.value.isNull ? "Create prompt" : "Save changes") { Task { await savePrompt() } }
                .buttonStyle(Press(.primary)).disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
        }
        .disabled(saving).interactiveDismissDisabled(saving)
        .onAppear { if initializedPromptDialog != item.id { title = item.value["title"].string; text = item.value["text"].string; initializedPromptDialog = item.id } }
    }
    private func resultForm(_ item: NativePresentedValue) -> some View {
        BenchSheet(eyebrow: current["title"].string, title: item.value.isNull ? "Add result" : "Edit result", width: 620) {
            VStack(alignment: .leading, spacing: 20) {
                if editingResult.isNull {
                    VStack(alignment: .leading, spacing: 12) {
                        Stops(options: [(value: false, label: "Files"), (value: true, label: "Link")], selection: useLink,
                              icons: [false: "upload", true: "link-2"]) { choice in
                            guard choice != useLink else { return }
                            cancelPendingDrops(); useLink = choice
                        }.accessibilityLabel("Result source")
                        if useLink { linkField } else { fileWell }
                    }
                } else if useLink {
                    linkField
                } else {
                    Text(editingResult["fileName"].string + " stays attached to this result.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                }
                HStack(alignment: .top, spacing: 16) {
                    BenchField(label: "Model") {
                        Entry(placeholder: "Choose a suggestion or type a model ID", text: $model, mono: true).accessibilityLabel("Model label or custom ID")
                    }.frame(maxWidth: .infinity)
                    BenchField(label: "Provider") { providerMenu(item.value) }
                }
                modelSuggestions
                if let error { BenchFailure(message: error) }
            }
        } note: {
            if pendingDrops > 0 { Text("Reading \(pendingDrops) dropped files") }
        } actions: {
            Button("Cancel") { cancelPendingDrops(); resultEditor = nil }.buttonStyle(Press(.quiet)).disabled(saving).keyboardShortcut(.cancelAction)
            Button(saving ? "Saving…" : item.value.isNull ? (files.count > 1 && !useLink ? "Add \(files.count) results" : "Add result") : "Save changes") { Task { await saveResults() } }
                .buttonStyle(Press(.primary)).disabled(saving || pendingDrops > 0 || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (editingResult.isNull && (useLink ? link.isEmpty : files.isEmpty))).keyboardShortcut(.defaultAction)
        }
        .disabled(saving).interactiveDismissDisabled(saving)
        .overlay {
            if resultDragTarget && !saving && editingResult.isNull {
                RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous).fill(Theme.canvas.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous).strokeBorder(Theme.signal, style: StrokeStyle(lineWidth: 2, dash: [8, 5])))
                    .overlay { Text("Drop files to add results").font(Theme.display(17)).foregroundStyle(Theme.ink) }
                    .padding(12).allowsHitTesting(false)
            }
        }
        .onAppear { if initializedResultDialog != item.id { model = item.value["model"].string; providerID = item.value["providerId"].string; link = item.value["url"].string; useLink = item.value["kind"].string == "url"; initializedResultDialog = item.id } }
        .onDisappear { resultDragTarget = false }
        .onDrop(of: [UTType.fileURL], isTargeted: $resultDragTarget) { acceptFiles($0) }
    }
    private var linkField: some View {
        Entry(placeholder: "https://example.com/result", text: $link, mono: true, icon: "link-2").accessibilityLabel("HTTP or HTTPS URL")
    }
    private var fileWell: some View {
        Well(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Button("Choose files", nativeIcon: "upload", action: chooseFiles)
                    Text(files.isEmpty ? "or drop them here. Any type, 50 MiB per file." : "Each file becomes a result with the model below.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    Spacer(minLength: 0)
                }.padding(14)
                ForEach(files, id: \.self) { url in
                    HStack(spacing: 10) {
                        NativeIcon("file", size: 13, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                        Text(url.lastPathComponent).font(Theme.mono(11.5)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        NativePendingPromptFileSize(url: url).fixedSize()
                        IconPress(icon: "x", help: "Remove " + url.lastPathComponent, size: 13) { cancelPendingDrops(); files.removeAll { $0 == url } }
                    }
                    .padding(.leading, 14).padding(.trailing, 8).frame(minHeight: 34)
                    .overlay(alignment: .top) { Rule() }
                }
            }
        }
    }
    @ViewBuilder private var modelSuggestions: some View {
        let suggestions = catalog["providers"].array.filter { providerID.isEmpty || $0["id"].string == providerID }.map { p -> JSONValue in
            var p = p
            let query = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            p["models"] = .array(Array(p["models"].array.filter { query.isEmpty || $0["id"].string.lowercased().contains(query) || $0["name"].string.lowercased().contains(query) }.prefix(query.isEmpty ? 3 : 8)))
            return p
        }.filter { !$0["models"].array.isEmpty }
        if !suggestions.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self["id"]) { p in
                        MicroLabel(p["name"].string).frame(height: 24).padding(.top, 4)
                        ForEach(p["models"].array, id: \.self["id"]) { m in
                            LedgerRow(selected: model == m["id"].string && providerID == p["id"].string, minHeight: 28, ruled: false,
                                      action: { providerID = p["id"].string; model = m["id"].string }) {
                                HStack(spacing: 8) {
                                    Text(m["name"].string.isEmpty ? m["id"].string : m["name"].string).font(Theme.mono(12)).foregroundStyle(Theme.ink).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if !m["name"].string.isEmpty && m["name"].string != m["id"].string {
                                        Text(m["id"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                }.padding(.horizontal, 8)
            }
            .frame(height: 150).padding(.horizontal, -8)
            .overlay(alignment: .top) { Rule().padding(.horizontal, 0) }
            .overlay(alignment: .bottom) { Rule() }
            .padding(.top, -8)
            .accessibilityLabel("Model suggestions")
        }
    }
    private func providerMenu(_ result: JSONValue) -> some View {
        var options: [(value: String, label: String)] = [(value: "", label: "Unspecified provider")]
        options += catalog["providers"].array.map { (value: $0["id"].string, label: $0["name"].string) }
        if !result["providerId"].string.isEmpty, !catalog["providers"].array.contains(where: { $0["id"] == result["providerId"] }) {
            options.append((value: result["providerId"].string, label: result["providerName"].string.isEmpty ? result["providerId"].string : result["providerName"].string))
        }
        if !options.contains(where: { $0.value == providerID }) { options.append((value: providerID, label: providerID)) }
        return Pick(title: "Provider for this model", selection: $providerID, options: options, width: 210)
    }
    private func reload() async {
        guard let service, let ticket = reads.begin("list") else { return }
        do {
            let nextPrompts = try await service.handle("list")["prompts"].array
            guard reads.accepts(ticket) else { return }
            let nextCatalog = try await service.handle("models")
            guard reads.accepts(ticket) else { return }
            prompts = nextPrompts; catalog = nextCatalog
            if let selected, !prompts.contains(where: { $0["id"].string == selected }) { self.selected = nil; detail = .null }
            // The list stays beside its detail, so retain a visible selection.
            if selected == nil { selected = prompts.first?["id"].string }
            error = nil
            if selected != nil { await loadDetail() }
        } catch { if reads.accepts(ticket) { self.error = error.localizedDescription } }
    }
    private func loadDetail() async {
        guard let service else { return }
        await mediaReads.loadDetail(read: { id in
            try await service.handle("detail", input: ["id": .string(id)])
        }, publish: { detail = $0 }, failed: { detail = .null })
    }
    private func beginResult(_ result: JSONValue = .null) {
        cancelPendingDrops()
        files = []; error = nil; resultEditor = NativePresentedValue(value: result)
        if let selected, let dialog = resultEditor?.id { dropContext.begin(prompt: selected, dialog: dialog) }
    }
    private func savePrompt() async {
        saving = true; defer { saving = false }
        do {
            var input: JSONObject = ["title": .string(title), "text": .string(text)]
            if !editingPrompt.isNull { input["id"] = editingPrompt["id"] }
            let creating = editingPrompt.isNull
            let saved = try await service?.handle(creating ? "create" : "update", input: input)
            if creating, let id = saved?["prompt"]["id"].string, !id.isEmpty { selected = id; detail = .null }
            promptEditor = nil; await reload()
        } catch { self.error = error.localizedDescription }
    }
    private func saveResults() async {
        guard let selected, let service else { return }
        cancelPendingDrops()
        saving = true; defer { saving = false }
        do {
            var input: JSONObject = ["id": .string(selected), "model": .string(model)]
            if editingResult.isNull || providerID != editingResult["providerId"].string { input["providerId"] = providerID.isEmpty ? .null : .string(providerID) }
            if !editingResult.isNull {
                input["resultId"] = editingResult["id"]; if useLink { input["url"] = .string(link) }
                _ = try await service.handle("updateResult", input: input)
            } else if useLink {
                input["url"] = .string(link); _ = try await service.handle("addURL", input: input)
            } else {
                while let url = files.first {
                    input["filePath"] = .string(url.path); _ = try await service.handle("upload", input: input)
                    files.removeFirst() // Retrying preserves successful uploads.
                }
            }
            resultEditor = nil; await reload()
        } catch { self.error = error.localizedDescription; await loadDetail() }
    }
    private func reorder(_ index: Int, _ delta: Int) async {
        guard let selected, !ordering else { return }
        ordering = true; defer { ordering = false }
        var ids = detail["results"].array.map { $0["id"] }
        let next = index + delta
        guard ids.indices.contains(next) else { return }
        ids.swapAt(index, next)
        do { _ = try await service?.handle("order", input: ["id": .string(selected), "resultIds": .array(ids)]); await loadDetail() }
        catch { self.error = error.localizedDescription }
    }
    private func remove(_ action: JSONValue) async {
        do {
            if action["kind"].string == "prompt" {
                let removed = try await service?.handle("delete", input: ["id": action["id"]]); cleanupPending = removed?["cleanupPending"].bool ?? false; if selected == action["id"].string { selected = nil; detail = .null }
            } else if let selected { let removed = try await service?.handle("deleteResult", input: ["id": .string(selected), "resultId": action["id"]]); cleanupPending = removed?["cleanupPending"].bool ?? false }
            await reload()
        } catch { self.error = error.localizedDescription }
    }
    private func previewResult(_ result: JSONValue, owner: NativeMediaPageReads.PreviewOwner) async {
        guard let service else { return }
        await mediaReads.preview(owner: owner, read: {
            try await service.handle("preview", input: ["resultId": result["id"]])
        }, publish: { preview = NativePresentedValue(value: $0) })
    }
    private func saveResult(_ result: JSONValue) async {
        let panelToken = NativePagePanels.shared.capture()
        do {
            let record = try await service?.handle("resolveFile", input: ["resultId": result["id"]]) ?? .null
            let panel = NSSavePanel(); panel.nameFieldStringValue = result["fileName"].string
            panel.nativeBegin(token: panelToken) { response in
                guard response == .OK, let url = panel.url else { return }
                do { let bytes = try NativePromptFiles.read(URL(fileURLWithPath: record["path"].string)); try bytes.data.write(to: url, options: .atomic) }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func openResult(_ result: JSONValue, owner: NativeMediaPageReads.PreviewOwner?) async {
        if result["kind"].string == "url", let url = URL(string: result["url"].string) { NSWorkspace.shared.open(url); return }
        guard let service else { return }
        await mediaReads.open(fileName: result["fileName"].string, owner: owner, read: {
            try await service.handle("resolveFile", input: ["resultId": result["id"]])
        }, present: { preview = NativePresentedValue(value: $0) },
        external: { NSWorkspace.shared.open(URL(fileURLWithPath: $0["path"].string)) }, commandFailure: { error = $0 })
    }
    private func chooseFiles() {
        cancelPendingDrops()
        guard let ticket = currentDropTicket() else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.nativeBegin { response in if response == .OK { for url in panel.urls { appendDropped(url, ticket: ticket) } } }
    }
    private func acceptFiles(_ providers: [NSItemProvider]) -> Bool {
        guard !saving, promptEditor == nil, preview == nil, editingResult.isNull else { return false }
        guard selected != nil else { error = "Select a prompt before adding result files"; return false }
        if resultEditor == nil { beginResult() }; useLink = false
        guard let ticket = currentDropTicket() else { return false }
        pendingDrops += providers.count
        for provider in providers {
            let progress = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    guard dropContext.accepts(ticket, prompt: selected, dialog: resultEditor?.id, saving: saving) else { return }
                    pendingDrops = max(0, pendingDrops - 1)
                    if let url { appendDropped(url, ticket: ticket) }
                }
            }
            dropLoads.append(progress)
        }
        return true
    }
    private func currentDropTicket() -> NativePromptsDropContext.Ticket? {
        guard !saving, let selected, let dialog = resultEditor?.id, editingResult.isNull else { return nil }
        if let ticket = dropContext.ticket, dropContext.accepts(ticket, prompt: selected, dialog: dialog, saving: saving) { return ticket }
        return dropContext.begin(prompt: selected, dialog: dialog)
    }
    private func appendDropped(_ url: URL, ticket: NativePromptsDropContext.Ticket) {
        guard dropContext.accepts(ticket, prompt: selected, dialog: resultEditor?.id, saving: saving), !useLink, promptEditor == nil, preview == nil, editingResult.isNull else { return }
        if !files.contains(url) { files.append(url) }
    }
    private func cancelPendingDrops() {
        dropContext.invalidate()
        pendingDrops = 0
        dropLoads.forEach { $0.cancel() }; dropLoads = []
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

private struct NativePendingPromptFileSize: View {
    let url: URL
    @State private var bytes: Int?
    private var label: String {
        bytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "-"
    }
    var body: some View {
        Text(label).font(Theme.mono(12)).foregroundStyle(Theme.muted)
            .accessibilityLabel("File size").accessibilityValue(bytes == nil ? "Unavailable" : label)
            .task(id: url) {
                let fileURL = url
                // Read metadata once per row, without opening the file or blocking field edits.
                let size = await Task.detached(priority: .utility) {
                    (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                }.value
                guard !Task.isCancelled else { return }
                bytes = size
            }
    }
}

private enum PromptsText {
    static func count(_ value: Int, _ noun: String) -> String {
        value.formatted(.number.locale(Locale(identifier: "en_US"))) + " " + (value == 1 ? noun : noun + "s")
    }
    static func day(_ milliseconds: Double) -> String {
        Date(timeIntervalSince1970: milliseconds / 1000).formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// One prompt in the index: its name, the first line of the task and how many
/// results it holds. Hovering trades the count for a copy button.
private struct PromptIndexRow: View {
    let prompt: JSONValue
    let selected: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        let count = prompt["resultCount"].int
        LedgerRow(selected: selected, minHeight: 50, action: onSelect) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt["title"].string).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(prompt["text"].string.replacingOccurrences(of: "\n", with: " ")).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(String(count)).font(Theme.readout(17)).foregroundStyle(count == 0 ? Theme.faint : Theme.ink)
                    .frame(width: 28, alignment: .trailing).opacity(hovering ? 0 : 1)
                    .accessibilityLabel("\(count) \(count == 1 ? "result" : "results")")
            }
        }
        .overlay(alignment: .trailing) {
            IconPress(icon: "clipboard", help: "Copy prompt: " + prompt["title"].string, action: onCopy)
                .opacity(hovering ? 1 : 0).offset(x: 6)
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}

/// One collected result. The row itself opens the result; ranking and the
/// rarely used commands sit on the right, outside the row's button.
private struct PromptResultRow<Actions: View>: View {
    let result: JSONValue
    let rank: Int
    let source: String
    let open: () -> Void
    @ViewBuilder var actions: () -> Actions
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Text(String(rank)).font(Theme.readout(17)).foregroundStyle(rank == 1 ? Theme.ink : Theme.muted)
                        .frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result["model"].string).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        HStack(spacing: 6) {
                            NativeIcon(result["kind"].string == "url" ? "link-2" : "file", size: 11, strokeWidth: 1.75)
                            Text(source).lineLimit(1).truncationMode(.middle)
                        }.font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Text(result["fileSize"].isNull ? "" : ByteCountFormatter.string(fromByteCount: Int64(result["fileSize"].double), countStyle: .file))
                        .font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 64, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).pointingHand()
            .accessibilityLabel((result["kind"].string == "url" ? "Open " : "Preview ") + result["model"].string)
            .accessibilityValue("Rank \(rank). " + source)
            .help(result["kind"].string == "url" ? result["url"].string : result["fileName"].string)
            actions().frame(width: 88, alignment: .trailing)
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                .fill(hovering ? Theme.hover : .clear).padding(.horizontal, -8)
        }
        .overlay(alignment: .bottom) { Rule() }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}
