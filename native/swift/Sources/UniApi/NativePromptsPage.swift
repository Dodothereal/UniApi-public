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
    @Environment(\.nativeInterfaceDensity) private var density
    private var editingPrompt: JSONValue { promptEditor?.value ?? .null }
    private var editingResult: JSONValue { resultEditor?.value ?? .null }
    private var pageError: String? { error ?? mediaReads.detailError ?? mediaReads.previewError }
    var body: some View {
        GeometryReader { geometry in
        let contentWidth = min(1500, geometry.size.width) - 2 * density.pageMargin
        NativePage(title: "Prompts & Results", subtitle: "Keep full prompts and compare the files models made for them.", maxWidth: 1500, readiness: pageError != nil ? .failed : catalog.isNull || selected != nil && detail.isNull ? .pending : .ready, actions: {
            Button { Task { await reload() } } label: {
                HStack(spacing: 6) { NativeIcon("rotate-cw", size: 14); Text("Reload") }
            }.buttonStyle(T3Button(.outline))
            Button { error = nil; promptEditor = NativePresentedValue(value: .null) } label: {
                HStack(spacing: 6) { NativeIcon("plus", size: 14); Text("New prompt") }
            }.buttonStyle(T3Button(.primary))
        }) {
            if let pageError { NativeError(message: pageError) }
            if cleanupPending { Text("Removed. Managed file cleanup will retry in the background.").font(Theme.ui(12)).foregroundStyle(Theme.warnFg) }
            if prompts.isEmpty { promptList }
            else {
                VStack(alignment: .leading, spacing: 24) {
                    if contentWidth >= 760 {
                        HStack(alignment: .top, spacing: 24) {
                            promptList.frame(width: 280)
                            promptDetail.frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    } else {
                        promptList
                        promptDetail
                    }
                }.frame(maxWidth: .infinity)
            }
        }
        .overlay { if dragTarget { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 5])).padding(12).allowsHitTesting(false) } }
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
    private var promptList: some View {
        VStack(alignment: .leading, spacing: 12) {
            if prompts.isEmpty {
                if catalog.isNull && error == nil { ShimmerText(text: "Loading prompts …") }
                else {
                    NativePromptEmptyState(icon: "file-text", title: error == nil ? "No prompts yet" : "Could not load prompts", detail: error == nil ? "Create a prompt to start collecting results." : "Try reloading your saved prompts.")
                }
            }
            else {
                SectionLabel(text: "Prompts") {
                    NativeNumberText(text: "\(prompts.count) \(prompts.count == 1 ? "prompt" : "prompts")", font: Theme.ui(12), color: Theme.muted)
                }
                LazyVStack(spacing: 8) {
                    ForEach(prompts, id: \.self["id"]) { prompt in
                        NativePromptListRow(prompt: prompt, selected: selected == prompt["id"].string, onSelect: {
                            selected = prompt["id"].string; detail = .null
                            Task { await loadDetail() }
                        }, onCopy: { copy(prompt["text"].string) })
                    }
                }
            }
        }
    }
    private var promptDetail: some View {
        VStack(alignment: .leading, spacing: 20) {
            if detail.isNull {
                if mediaReads.detailError != nil {
                    NativeReadFailureState(icon: "file-text", title: "Could not load results", detail: "Try loading this prompt again.", retryTitle: "Reload results") {
                        Task { await loadDetail() }
                    }
                } else { ShimmerText(text: "Loading prompt and results …") }
            }
            else {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(detail["prompt"]["title"].string).font(Theme.ui(18, weight: .semibold)).accessibilityAddTraits(.isHeader)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 4) {
                            Text("Created")
                            Text(Date(timeIntervalSince1970: detail["prompt"]["createdAt"].double / 1000), style: .date)
                        }.font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    promptActions(detail["prompt"])
                }
                Card {
                    Text(detail["prompt"]["text"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.dim).lineSpacing(6)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    SectionLabel(text: "Results") {
                        NativeNumberText(text: "\(detail["results"].array.count) \(detail["results"].array.count == 1 ? "result" : "results")", font: Theme.ui(12), color: Theme.muted)
                    }
                    Button { beginResult() } label: {
                        HStack(spacing: 6) { NativeIcon("plus", size: 14); Text("Add result") }
                    }.buttonStyle(T3Button(.primary)).fixedSize()
                }
                Text("Drop files anywhere on this page to add them to \(detail["prompt"]["title"].string). All file types · 50 MiB per file.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if detail["results"].array.isEmpty {
                    NativePromptEmptyState(icon: "file-code-2", title: "No results yet", detail: "Drop files here or add a URL for a model response.")
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(detail["results"].array.enumerated()), id: \.element["id"]) { index, result in
                            Card(padding: 12) {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 12) { resultMetadata(result, index: index); resultActions(result, index: index) }
                                    VStack(alignment: .leading, spacing: 8) {
                                        resultMetadata(result, index: index)
                                        HStack { Spacer(minLength: 0); resultActions(result, index: index) }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    private func promptActions(_ prompt: JSONValue) -> some View {
        HStack(spacing: 1) {
            promptIcon("clipboard", help: "Copy prompt") { copy(prompt["text"].string) }
            promptIcon("pencil", help: "Edit prompt") { error = nil; promptEditor = NativePresentedValue(value: prompt) }
            promptIcon("trash-2", help: "Delete prompt") { deleteAction = ["kind": "prompt", "id": prompt["id"]] }
        }
    }
    private func resultMetadata(_ result: JSONValue, index: Int) -> some View {
        HStack(spacing: 12) {
            Text(String(index + 1)).font(Theme.mono(12)).foregroundStyle(Theme.muted).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(result["model"].string).font(Theme.mono(12.5, weight: .medium)).lineLimit(1).textSelection(.enabled).help(result["model"].string)
                Text(resultDescription(result)).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).textSelection(.enabled)
                    .help(result["kind"].string == "url" ? result["url"].string : result["fileName"].string)
            }.frame(minWidth: 150, maxWidth: .infinity, alignment: .leading)
        }
    }
    private func resultDescription(_ result: JSONValue) -> String {
        let provider = !result["providerName"].string.isEmpty ? result["providerName"].string : !result["providerId"].string.isEmpty ? result["providerId"].string : "Unspecified provider"
        let source = result["kind"].string == "url" ? "URL" : result["fileName"].string.isEmpty ? "File" : result["fileName"].string
        let size = result["fileSize"].isNull ? "" : " · " + ByteCountFormatter.string(fromByteCount: Int64(result["fileSize"].double), countStyle: .file)
        return provider + " · " + source + size
    }
    private func resultActions(_ result: JSONValue, index: Int) -> some View {
        HStack(spacing: 1) {
            promptIcon("arrow-up", help: "Rank higher") { Task { await reorder(index, -1) } }.disabled(ordering || index == 0)
            promptIcon("arrow-down", help: "Rank lower") { Task { await reorder(index, 1) } }.disabled(ordering || index == detail["results"].array.count - 1)
            if result["kind"].string == "upload" {
                promptIcon("eye", help: "Preview result") {
                    guard let owner = mediaReads.beginPreview() else { return }
                    Task { await previewResult(result, owner: owner) }
                }
                promptIcon("download", help: "Save result") { Task { await saveResult(result) } }
            }
            promptIcon("external-link", help: "Open result") {
                let owner = mediaReads.beginPreview()
                Task { await openResult(result, owner: owner) }
            }
            promptIcon("pencil", help: "Edit result") { beginResult(result) }
            promptIcon("trash-2", help: "Delete result") { deleteAction = ["kind": "result", "id": result["id"]] }
        }.fixedSize()
    }
    private func promptIcon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        NativePromptIconButton(name: name, title: help, action: action)
    }
    private func promptForm(_ item: NativePresentedValue) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.value.isNull ? "New prompt" : "Edit prompt").font(Theme.ui(18, weight: .semibold))
                Text("Keep the full task text here so you can reuse it across models.").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Title").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                T3Field(placeholder: "A short name for this task", text: $title).accessibilityLabel("Prompt title")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Prompt text").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                TextEditor(text: $text).font(Theme.ui(12.5)).scrollContentBackground(.hidden)
                    .padding(8).frame(height: 250).background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1)).accessibilityLabel("Prompt text")
            }
            if let error { NativeError(message: error) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { promptEditor = nil }.buttonStyle(T3Button(.ghost)).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : item.value.isNull ? "Create prompt" : "Save changes") { Task { await savePrompt() } }
                    .buttonStyle(T3Button(.primary)).disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 680).background(Theme.bg).foregroundStyle(Theme.ink).disabled(saving).interactiveDismissDisabled(saving)
            .onAppear { if initializedPromptDialog != item.id { title = item.value["title"].string; text = item.value["text"].string; initializedPromptDialog = item.id } }
    }
    private func resultForm(_ item: NativePresentedValue) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.value.isNull ? "Add result" : "Edit result").font(Theme.ui(18, weight: .semibold))
                Text(item.value.isNull ? "Add files of any type or a web page for this prompt." : "Update the model and source details.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Model").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                        T3Field(placeholder: "Choose a suggestion or type a model ID", text: $model, mono: true).accessibilityLabel("Model label or custom ID")
                        modelSuggestions
                        Text("You can type a model that is not in the catalog.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                    }
                    HStack {
                        Text("Provider").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                        Spacer()
                        providerMenu(item.value)
                    }
                    if useLink {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("HTTP or HTTPS URL").font(Theme.ui(12, weight: .medium)).foregroundStyle(Theme.dim)
                            T3Field(placeholder: "https://example.com/result", text: $link, mono: true).accessibilityLabel("HTTP or HTTPS URL")
                        }
                    } else if editingResult.isNull {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                Button(action: chooseFiles) {
                                    HStack(spacing: 6) { NativeIcon("upload", size: 14); Text("Choose files") }
                                }.buttonStyle(T3Button(.outline))
                                Text("or drag and drop here").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                            }
                            Text("All file types · 50 MiB per file. Each file becomes a result with this model label.")
                                .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                            ForEach(files, id: \.self) { url in
                                HStack(spacing: 8) {
                                    Text(url.lastPathComponent).font(Theme.ui(12)).foregroundStyle(Theme.dim).lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    NativePendingPromptFileSize(url: url).fixedSize()
                                    promptIcon("trash-2", help: "Remove " + url.lastPathComponent) { cancelPendingDrops(); files.removeAll { $0 == url } }
                                }
                            }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                    } else {
                        Text(editingResult["fileName"].string + " stays attached to this result.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                    }
                    if pendingDrops > 0 { ShimmerText(text: "Reading \(pendingDrops) dropped files …") }
                    if editingResult.isNull {
                        Button { cancelPendingDrops(); useLink.toggle() } label: {
                            HStack(spacing: 6) {
                                NativeIcon(useLink ? "upload" : "link-2", size: 14)
                                Text(useLink ? "Use files instead" : "Use a URL instead")
                            }
                        }.buttonStyle(T3Button(.ghost))
                    }
                }
            }.frame(maxHeight: 430)
            if let error { NativeError(message: error) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { cancelPendingDrops(); resultEditor = nil }.buttonStyle(T3Button(.ghost)).disabled(saving).keyboardShortcut(.cancelAction)
                Button(saving ? "Saving…" : item.value.isNull ? (files.count > 1 && !useLink ? "Add \(files.count) results" : "Add result") : "Save changes") { Task { await saveResults() } }
                    .buttonStyle(T3Button(.primary)).disabled(saving || pendingDrops > 0 || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (editingResult.isNull && (useLink ? link.isEmpty : files.isEmpty))).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 610).background(Theme.bg).foregroundStyle(Theme.ink).disabled(saving).interactiveDismissDisabled(saving)
            .overlay {
                if resultDragTarget && !saving && editingResult.isNull {
                    RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.bg.opacity(0.9))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
                        .overlay {
                            Text("Drop files to add results").font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.accent).padding(24)
                        }.allowsHitTesting(false)
                }
            }
            .onAppear { if initializedResultDialog != item.id { model = item.value["model"].string; providerID = item.value["providerId"].string; link = item.value["url"].string; useLink = item.value["kind"].string == "url"; initializedResultDialog = item.id } }
            .onDisappear { resultDragTarget = false }
            .onDrop(of: [UTType.fileURL], isTargeted: $resultDragTarget) { acceptFiles($0) }
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
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(suggestions, id: \.self["id"]) { p in
                        Text(p["name"].string).font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).padding(.horizontal, 8).padding(.vertical, 4)
                        ForEach(p["models"].array, id: \.self["id"]) { m in
                            Button { providerID = p["id"].string; model = m["id"].string } label: {
                                HStack(spacing: 8) {
                                    Text(m["name"].string.isEmpty ? m["id"].string : m["name"].string).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if !m["name"].string.isEmpty && m["name"].string != m["id"].string {
                                        Text(m["id"].string).font(Theme.mono(10)).foregroundStyle(Theme.muted).lineLimit(1)
                                    }
                                }.font(Theme.mono(12)).frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(T3Button(.ghost, full: true))
                                .background(model == m["id"].string && providerID == p["id"].string ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                        }
                    }
                }.padding(4)
            }.frame(height: 150).background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.input, lineWidth: 1)).accessibilityLabel("Model suggestions")
        }
    }
    private func providerMenu(_ result: JSONValue) -> some View {
        Menu {
            Button("Unspecified provider") { providerID = "" }
            ForEach(catalog["providers"].array, id: \.self["id"]) { p in Button(p["name"].string) { providerID = p["id"].string } }
            if !result["providerId"].string.isEmpty, !catalog["providers"].array.contains(where: { $0["id"] == result["providerId"] }) {
                Button(result["providerName"].string.isEmpty ? result["providerId"].string : result["providerName"].string) { providerID = result["providerId"].string }
            }
        } label: {
            HStack(spacing: 8) {
                Text(providerID.isEmpty ? "Unspecified provider" : catalog["providers"].array.first(where: { $0["id"].string == providerID })?["name"].string ?? (result["providerName"].string.isEmpty ? providerID : result["providerName"].string)).lineLimit(1)
                Spacer(minLength: 0)
                NativeIcon("chevron-down", size: 12)
            }.font(Theme.ui(12)).foregroundStyle(Theme.dim).padding(.horizontal, 11).frame(width: 220, height: 30)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.input, lineWidth: 1))
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().pointingHand().accessibilityLabel("Provider for this model")
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

private struct NativePromptListRow: View {
    let prompt: JSONValue
    let selected: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 1) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(prompt["title"].string).font(Theme.ui(14, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(prompt["text"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineSpacing(3).lineLimit(2)
                    HStack(spacing: 4) {
                        Text("\(prompt["resultCount"].int) \(prompt["resultCount"].int == 1 ? "result" : "results") ·")
                        Text(Date(timeIntervalSince1970: prompt["updatedAt"].double / 1000), style: .date)
                    }.font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 4)
                }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).pointingHand().accessibilityAddTraits(selected ? [.isSelected] : [])
            NativePromptIconButton(name: "clipboard", title: "Copy prompt: " + prompt["title"].string, action: onCopy)
                .padding(.top, 4)
        }.padding(4)
            .background(selected ? Theme.accent.opacity(0.09) : hovering ? Theme.subtle : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(selected ? Theme.accent.opacity(0.35) : Theme.border, lineWidth: 1))
            .onHover { hovering = $0 }
    }
}

private struct NativePromptIconButton: View {
    let name: String
    let title: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.nativeReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            NativeIcon(name, size: 14)
                .foregroundStyle(hovering && name == "trash-2" ? Theme.failFg : hovering ? Theme.ink : Theme.muted)
                .frame(width: 28, height: 28)
                .background(hovering ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.45).pointingHand(enabled)
            .onHover { hovering = $0 && enabled }.animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
            .help(title).accessibilityLabel(title)
    }
}

private struct NativePromptEmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 8) {
            NativeIcon(icon, size: 24).foregroundStyle(Theme.muted).accessibilityHidden(true)
            Text(title).font(Theme.ui(14, weight: .medium))
            Text(detail).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.vertical, 48).accessibilityElement(children: .combine)
    }
}
