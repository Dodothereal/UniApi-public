import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UniApiCore
import UniApiPresentation

enum NativeCodeMetrics {
    /// Every pane opens with a band of this height, so one hairline runs
    /// across the whole workbench.
    static let head: CGFloat = 52
    /// The reading column shared by the thread heading, transcript and composer.
    static let column: CGFloat = 760
}

struct NativeCodePage: View {
    let runtime: NativeRuntime
    @StateObject private var state: NativeCodeModel
    @AppStorage("uniapi.code.project") private var project = ""
    @State private var selectedThread = ""
    @State private var text = ""
    @State private var images: [JSONValue] = []
    @State private var route = "subscription"
    @State private var model = "opus[1m]"
    @State private var mode = "acceptEdits"
    @State private var effort = ""
    @State private var rename = ""
    @State private var showGit = false
    @State private var modelPicker: NativeCodeModelPickerItem?
    @State private var agentAction: String?
    @State private var follows = true
    @State private var headWidth: CGFloat = 800
    @State private var jump = 0
    @FocusState private var composerFocused: Bool
    @Namespace private var modeMarker
    @Environment(\.nativeReducedMotion) private var reduceMotion
    init(runtime: NativeRuntime) { self.runtime = runtime; _state = StateObject(wrappedValue: NativeCodeModel(runtime: runtime)) }
    private var thread: JSONValue { state.hasHistory(for: selectedThread) && state.detail["thread"]["id"].string == selectedThread ? state.detail["thread"] : .null }
    private var scope: String { project + ":" + selectedThread }
    private var working: Bool { ["running", "starting", "waiting"].contains(thread["status"].string) }
    private var currentProject: JSONValue? { state.projects.first(where: { $0["id"].string == project }) }
    var body: some View {
        NativeCodeWorkbenchFrame(readiness: !state.error.isEmpty ? .failed : !selectedThread.isEmpty && (state.detailLoading || thread.isNull) ? .pending : state.loaded ? .ready : .pending) {
            GeometryReader { geometry in
                let inlineInspector = geometry.size.width >= 1050
                VStack(spacing: 0) {
                    if !state.error.isEmpty { Notice(text: state.error, tone: .fail).accessibilityLabel("Error: " + state.error).padding(12) }
                    HStack(spacing: 0) {
                        if !state.loaded || !state.projects.isEmpty {
                            projectRail.frame(width: geometry.size.width < 760 ? 224 : 268)
                            Rule(vertical: true)
                        }
                        threadPane.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(showGit && !project.isEmpty && !inlineInspector)
                        if showGit, !project.isEmpty, inlineInspector {
                            Rule(vertical: true)
                            gitInspector.frame(width: 380)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: .trailing) {
                    if showGit, !project.isEmpty, !inlineInspector {
                        gitInspector.frame(width: min(380, geometry.size.width - 24))
                            .overlay(alignment: .leading) { Rule(strong: true, vertical: true) }
                            .shadow(color: Theme.shadow, radius: 12, x: -4)
                    }
                }
            }
        }
        .nativePageTask(id: scope) { await state.listen(runtime: runtime, project: { project }, thread: { selectedThread }); if !Task.isCancelled { await reload() } }
        .onChange(of: project) { _, _ in selectedThread = "" }
        .onChange(of: state.projects) { _, projects in let valid = CodeProjectSelection.resolve(project, projects: projects); if valid != project { project = valid; selectedThread = "" } }
        .onChange(of: state.threads) { _, threads in if !selectedThread.isEmpty && !threads.contains(where: { $0["id"].string == selectedThread }) { selectedThread = "" } }
        .onChange(of: thread["model"]) { _, value in if !thread.isNull { model = value.string } }
        .onChange(of: thread["permission_mode"]) { _, value in if !thread.isNull { mode = value.string } }
        .onChange(of: thread["effort"]) { _, value in if !thread.isNull { effort = value.string } }
        .nativePageActivity(suspended: { state.stop(); composerFocused = false })
        .sheet(item: $modelPicker) { item in NativeCodeModelPicker(item: item) { chosen in
            guard await state.call("thread.patch", ["id": .string(item.threadID), "patch": ["model": .string(chosen)]]) != nil else { return false }
            if item.threadID == selectedThread { await reload() }; return true
        } }
    }
    private var gitInspector: some View {
        NativeCodeGitPanel(service: NativeCodeService.shared(runtime: runtime), projectID: project, threadID: selectedThread,
                           revision: state.gitRevision) { showGit = false }
            .id(project).frame(maxHeight: .infinity, alignment: .top)
    }

    // ------------------------------------------------------------------
    // Rail: the project, then its threads as a ledger
    // ------------------------------------------------------------------

    private var projectRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    Button("Choose project") { project = "" }
                    ForEach(Array(state.projects.enumerated()), id: \.offset) { _, p in Button(p["name"].string) { project = p["id"].string } }
                    Divider()
                    Button("Add project folder", nativeIcon: "folder-plus", action: addProject)
                    Button("Remove project", nativeIcon: "trash-2") { Task { if confirm("Remove this project and its thread history?"), await state.call("project.delete", ["id": .string(project)]) != nil { project = ""; selectedThread = ""; await reload() } } }.disabled(project.isEmpty)
                } label: {
                    NativeCodeTrigger(icon: "folder-open", outlined: true, fill: true) {
                        Text(currentProject?["name"].string ?? (state.loaded ? "No project yet" : "Reading projects"))
                            .font(Theme.ui(12.5, weight: .medium)).foregroundStyle(currentProject == nil ? Theme.muted : Theme.ink)
                    }
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).pointingHand().accessibilityLabel("Project")
                IconPress(icon: "plus", help: "New thread", size: 15) { Task { await newThread() } }.disabled(project.isEmpty)
            }
            .padding(.leading, 16).padding(.trailing, 10).frame(height: NativeCodeMetrics.head)
            Rule()
            LedgerHead {
                MicroLabel("Threads")
                Spacer(minLength: 0)
                if state.loaded && !project.isEmpty { MicroLabel(String(state.threads.count)) }
            }
            .padding(.horizontal, 16).padding(.top, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !state.loaded { railNote("Reading threads") }
                    else if state.threads.isEmpty { railNote(project.isEmpty ? "Pick or add a project" : "No threads yet") }
                    ForEach(Array(state.threads.enumerated()), id: \.offset) { _, t in threadRow(t) }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity)
            if let path = currentProject?["path"] {
                Rule()
                Text(path.string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).help(path.string)
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: 34).padding(.horizontal, 16)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
    private func railNote(_ text: String) -> some View {
        Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
    }
    private func threadRow(_ t: JSONValue) -> some View {
        let selected = t["id"].string == selectedThread, status = t["status"].string
        let routeName = state.routes.first(where: { $0["id"] == t["route_id"] })?["name"].string ?? t["route_id"].string
        return LedgerRow(selected: selected, minHeight: 50, action: { selectedThread = t["id"].string }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(t["title"].string).font(Theme.ui(13, weight: selected ? .medium : .regular)).lineLimit(1)
                        .foregroundStyle(selected ? Theme.ink : Theme.dim)
                    Spacer(minLength: 0)
                    if t["pending"].int > 0 {
                        Tag("\(t["pending"].int) to answer", tone: Theme.signal, dot: true)
                            .accessibilityLabel("\(t["pending"].int) pending permission requests")
                    }
                }
                HStack(spacing: 6) {
                    if ["running", "starting", "waiting", "error"].contains(status) {
                        NativeStatusDot(color: threadStatusColor(status), size: 5, pulse: status != "error")
                        Text(status).foregroundStyle(threadStatusColor(status)).fixedSize()
                    }
                    Text((t["model"].string.isEmpty ? "default" : t["model"].string) + " · " + routeName).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(NativeListTimeFormat.ago(t["updated_at"].double)).fixedSize()
                }
                .font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 8)
        }
        .help("\(t["title"].string) · \(t["status"].string) · \(t["model"].string)")
    }
    private func threadStatusColor(_ status: String) -> Color {
        switch status {
        case "error": return Theme.failFg
        case "waiting": return Theme.warnFg
        case "running": return Theme.okFg
        case "starting": return Theme.signal
        default: return Theme.muted
        }
    }

    // ------------------------------------------------------------------
    // Thread: heading, transcript, composer on one reading column
    // ------------------------------------------------------------------

    private var threadPane: some View {
        VStack(spacing: 0) {
            if !state.loaded {
                paneHead(currentProject?["name"].string ?? "Code")
                paneBody {
                    if state.error.isEmpty { paneNote("Reading projects and threads") }
                    else {
                        Blank(icon: "circle-alert", title: "Could not read projects and threads",
                              actionTitle: "Retry", actionIcon: "rotate-cw", primary: false) { Task { await reload() } }
                    }
                }
            } else if selectedThread.isEmpty {
                paneHead(currentProject?["name"].string ?? "Code")
                paneBody {
                    if state.projects.isEmpty {
                        Blank(icon: "folder-plus", title: "Add a project folder to start",
                              detail: "Each thread keeps its own route, settings, transcript and resumable session. Threads run in parallel and survive closing the window.",
                              actionTitle: "Add project", actionIcon: "folder-plus", action: addProject)
                    } else {
                        Blank(icon: "bot", title: "Pick a thread or start a new one",
                              detail: "Each thread keeps its own route, settings, transcript and resumable session. Threads run in parallel and survive closing the window.",
                              actionTitle: "New thread", actionIcon: "plus") { Task { await newThread() } }
                            .disabled(project.isEmpty)
                    }
                }
            } else if thread.isNull || state.detailLoading {
                paneHead(state.threads.first(where: { $0["id"].string == selectedThread })?["title"].string ?? "Thread")
                paneBody {
                    if state.error.isEmpty { paneNote("Loading the thread") }
                    else {
                        Blank(icon: "circle-alert", title: "Could not load this thread", detail: "Your saved thread is unchanged. Reload to try reading it again.",
                              actionTitle: "Retry", actionIcon: "rotate-cw", primary: false) { Task { await reload() } }
                    }
                }
            } else {
                threadHeader
                if !thread["last_error"].isNull {
                    Notice(text: thread["last_error"].string, tone: .fail).accessibilityLabel("Error: " + thread["last_error"].string)
                        .codeColumn().padding(.horizontal, 24).padding(.top, 12)
                }
                NativeCodeScroll(jump: jump, follows: $follows) {
                    VStack(alignment: .leading, spacing: 12) {
                        if state.events.isEmpty && state.pending.isEmpty && !working { paneNote("Nothing said yet. The first message starts the session.") }
                        NativeCodeTranscript(events: state.events, running: working)
                        NativeCodeLiveView(live: state.live, events: state.events)
                        ForEach(Array(state.pending.enumerated()), id: \.element["id"]) { index, p in
                            NativeCodePermission(request: p, primary: index == 0) { answer in Task { var body = answer; body["id"] = .string(selectedThread); body["requestId"] = p["id"]; _ = await state.call("permission", body); await reload() } }
                        }
                    }
                    .font(Theme.ui(13)).foregroundStyle(Theme.ink).tint(Theme.signal)
                    .codeColumn().padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1).id(selectedThread)
                .overlay(alignment: .bottom) {
                    if !follows {
                        Button("Jump to latest", nativeIcon: "arrow-down") { jump += 1 }.buttonStyle(Press(.secondary))
                            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .codeColumn().padding(.horizontal, 24).padding(.bottom, 8)
                    }
                }
                composer
            }
        }
    }
    private func paneHead(_ title: String) -> some View {
        Text(title).font(Theme.display(17)).foregroundStyle(Theme.muted).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .codeColumn().padding(.horizontal, 24).frame(height: NativeCodeMetrics.head)
            .overlay(alignment: .bottom) { Rule() }
    }
    private func paneBody<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .codeColumn().padding(.horizontal, 24).padding(.top, 12)
            .frame(maxHeight: .infinity, alignment: .top)
    }
    private func paneNote(_ text: String) -> some View {
        Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 12)
    }
    private var threadHeader: some View {
        HStack(spacing: 12) {
            TextField("Thread title", text: $rename).textFieldStyle(.plain).font(Theme.display(17)).foregroundStyle(Theme.ink).accessibilityLabel("Thread title")
                .onSubmit { Task { _ = await state.call("thread.patch", ["id": .string(selectedThread), "patch": ["title": .string(rename)]]); await reload() } }
            if ["running", "starting", "waiting", "error"].contains(thread["status"].string) {
                Tag(thread["status"].string, tone: threadStatusColor(thread["status"].string), dot: true)
            }
            if headWidth >= 640 { HStack(alignment: .firstTextBaseline, spacing: 4) {
                NativeNumberText(text: NativeNumberFormat.compact(Double(thread["input_tokens"].int)), font: Theme.readout(17), color: Theme.ink)
                MicroLabel("in").padding(.trailing, 6)
                NativeNumberText(text: NativeNumberFormat.compact(Double(thread["output_tokens"].int)), font: Theme.readout(17), color: Theme.ink)
                MicroLabel("out")
                if thread["cost_usd"].double > 0, headWidth >= 700 {
                    NativeNumberText(text: String(format: "~$%.2f", thread["cost_usd"].double), font: Theme.readout(17), color: Theme.dim).padding(.leading, 6)
                }
            }
            .fixedSize().help("Tokens in / out: \(thread["input_tokens"].int) / \(thread["output_tokens"].int)")
            .accessibilityElement(children: .ignore).accessibilityLabel("Tokens in / out")
            .accessibilityValue("\(thread["input_tokens"].int) / \(thread["output_tokens"].int)") }
            HStack(spacing: 2) {
                Button("Changes", nativeIcon: "git-branch") { showGit.toggle() }.buttonStyle(Press(.quiet)).fixedSize()
                    .background(showGit ? Theme.pressed : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    .accessibilityAddTraits(showGit ? .isSelected : [])
                Menu {
                    Button("Close session") { Task { _ = await state.call("close", ["id": .string(selectedThread)]); await reload() } }
                    Divider()
                    Button("Delete thread", role: .destructive) { Task { if confirm("Delete this thread and its history?"), await state.call("thread.delete", ["id": .string(selectedThread)]) != nil { selectedThread = ""; await reload() } } }
                } label: { NativeIcon("ellipsis", size: 14, strokeWidth: 1.75) }
                    .menuStyle(.button).buttonStyle(Press(.quiet)).menuIndicator(.hidden).fixedSize().help("Thread actions").accessibilityLabel("Thread actions")
            }
            .padding(.trailing, -8)
        }
        .codeColumn().padding(.horizontal, 24).frame(height: NativeCodeMetrics.head)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { headWidth = $0 }
        .overlay(alignment: .bottom) { Rule() }
    }

    // ------------------------------------------------------------------
    // Composer: the message, then how it is sent, then the one action
    // ------------------------------------------------------------------

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 10) { ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                        if let bytes = Data(base64Encoded: image["data"].string), let picture = NSImage(data: bytes) {
                            Image(nsImage: picture).resizable().scaledToFill().frame(width: 56, height: 56)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    Button { images.remove(at: index) } label: {
                                        NativeIcon("x", size: 10, strokeWidth: 2.25).foregroundStyle(Theme.onInk)
                                            .frame(width: 16, height: 16).background(Theme.ink, in: Circle())
                                    }
                                    .buttonStyle(.plain).pointingHand().offset(x: 5, y: -5).help("Remove image").accessibilityLabel("Remove image")
                                }
                        }
                    } }.padding(.top, 5).padding(.trailing, 5)
                }
            }
            TextEditor(text: $text).font(Theme.ui(13)).foregroundStyle(Theme.ink).scrollContentBackground(.hidden).focused($composerFocused).frame(height: 64).accessibilityLabel("Message")
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Message. Enter sends, Shift+Enter breaks a line, paste or drop images.").font(Theme.ui(13)).foregroundStyle(Theme.muted)
                            .padding(.horizontal, 5).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .onKeyPress(keys: [.return], phases: .down) { press in if press.modifiers.contains(.shift) { return .ignored }; Task { await send() }; return .handled }
                .onPasteCommand(of: [.image]) { providers in for p in providers { p.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in if let data { Task { @MainActor in addImage(data, mime: "image/png") } } } } }
                .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in for p in providers { p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), let bytes = try? Data(contentsOf: url) { let mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()]; if let mime { Task { @MainActor in addImage(bytes, mime: mime) } } } } }; return !providers.isEmpty }
            routeControls
        }
        .padding(.leading, 9).padding(.trailing, 10).padding(.top, 12).padding(.bottom, 10)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous).strokeBorder(composerFocused ? Theme.signal : Theme.rule, lineWidth: 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: composerFocused)
        .codeColumn().padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 20)
    }
    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    routeModelMenu.frame(maxWidth: 230, alignment: .leading)
                    permissionRail
                    if !efforts.isEmpty || !effort.isEmpty { effortMenu }
                    Spacer(minLength: 0)
                    composerActions
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) { routeModelMenu; Spacer(minLength: 0); composerActions }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) { permissionRail; if !efforts.isEmpty || !effort.isEmpty { effortMenu } }
                        VStack(alignment: .leading, spacing: 6) { permissionRail; if !efforts.isEmpty || !effort.isEmpty { effortMenu } }
                    }.padding(.leading, 3)
                }
            }
            if let agent = state.routes.first(where: { $0["id"].string == route })?["agent"], !agent.isNull { agentSetup(agent) }
        }
    }
    private var routeModelMenu: some View {
        let name = state.routes.first(where: { $0["id"].string == route })?["name"].string ?? route
        return Menu {
            Section("Route") {
                if !state.routes.contains(where: { $0["id"].string == route }) { Text(route + " (unavailable)") }
                ForEach(Array(state.routes.enumerated()), id: \.offset) { _, r in
                    Button(r["name"].string) { let value = r["id"].string; route = value; let chosen = state.routes.first { $0["id"].string == value }; model = chosen?["defaultModel"].string ?? ""; Task { await patch(["route_id": .string(value), "model": .string(model)]) } }
                }
            }
            Divider()
            if !route.hasPrefix("agent:") {
                Button("Use route default") { model = ""; Task { await patch(["model": .string("")]) } }
            }
            Button("Search models…", nativeIcon: "search") {
                if let chosen = state.routes.first(where: { $0["id"].string == route }) {
                    modelPicker = NativeCodeModelPickerItem(threadID: selectedThread, route: chosen, options: state.detail["options"], currentModel: model)
                }
            }
        } label: {
            NativeCodeTrigger(icon: "route") {
                (Text(name).font(Theme.ui(12.5, weight: .medium)).foregroundColor(Theme.ink) + Text("  ")
                    + Text(model.isEmpty ? "default" : model).font(Theme.mono(11)).foregroundColor(Theme.muted))
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .ignore)
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Route and model").accessibilityValue(name + " · " + (model.isEmpty ? "default" : model))
            .help(name + " · " + (model.isEmpty ? "default" : model))
    }
    private var composerActions: some View {
        HStack(spacing: 4) {
            // Keep this slot stable when the session starts or finishes.
            ZStack(alignment: .trailing) {
                if working {
                    Button("Stop", nativeIcon: "square") { Task { _ = await state.call("interrupt", ["id": .string(selectedThread)]) } }
                        .buttonStyle(Press(.secondary)).fixedSize()
                }
            }.frame(width: 74, height: 28)
            IconPress(icon: "paperclip", help: "Attach image") { attach() }
            // The page has one primary. While the agent waits on an answer,
            // that answer is the primary and sending steps back.
            Button { Task { await send() } } label: { NativeIcon("arrow-up", size: 15, strokeWidth: 2) }
                .buttonStyle(Press(state.pending.isEmpty ? .primary : .secondary)).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
                .keyboardShortcut(.return, modifiers: [.command]).help(thread["status"].string == "running" ? "Send queues a follow-up" : "Send").accessibilityLabel("Send")
        }.fixedSize()
    }
    /// Permission modes on a hairline, as `Stops`, with unavailable modes dimmed.
    private var permissionRail: some View {
        HStack(spacing: 14) {
            ForEach(Array(modes.enumerated()), id: \.offset) { _, row in
                let chosen = mode == row["value"].string, available = row["available"].bool
                Button { let value = row["value"].string; mode = value; Task { await patch(["permission_mode": .string(value)]) } } label: {
                    ZStack {
                        Text(row["displayName"].string).font(Theme.ui(12.5, weight: .semibold)).hidden()
                        Text(row["displayName"].string).font(Theme.ui(12.5, weight: chosen ? .semibold : .regular))
                    }
                    .lineLimit(1).fixedSize().foregroundStyle(chosen ? Theme.ink : Theme.muted)
                    .frame(height: 28).opacity(available ? 1 : 0.4)
                    .overlay(alignment: .bottom) {
                        if chosen { Theme.signal.frame(height: 2).matchedGeometryEffect(id: "mode", in: modeMarker) }
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!available).pointingHand(available)
                    .accessibilityLabel(row["displayName"].string)
                    .accessibilityAddTraits(chosen ? [.isSelected] : [])
            }
        }
        .background(alignment: .bottom) { Rule() }
        .animation(reduceMotion ? nil : NativeMotion.segmented, value: mode)
        .disabled(!modes.contains(where: { $0["available"].bool })).accessibilityElement(children: .contain).accessibilityLabel("Permission")
    }
    private var effortMenu: some View {
        Menu {
            Button("Default") { effort = ""; Task { await patch(["effort": .null]) } }
            if !effort.isEmpty && !efforts.contains(where: { $0["value"].string == effort }) { Text(effort + " (not advertised)") }
            ForEach(Array(efforts.filter { !$0["value"].string.isEmpty }.enumerated()), id: \.offset) { _, e in
                Button(e["displayName"].string) { let value = e["value"].string; effort = value; Task { await patch(["effort": value.isEmpty ? .null : .string(value)]) } }
            }
        } label: {
            NativeCodeTrigger {
                (Text("effort ").foregroundColor(Theme.muted) + Text(effort.isEmpty ? "default" : effort).foregroundColor(Theme.ink)).font(Theme.ui(12.5))
            }
            .help("effort " + (effort.isEmpty ? "default" : effort)).accessibilityElement(children: .ignore)
        }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(route.hasPrefix("agent:") && efforts.isEmpty).accessibilityLabel("Effort").accessibilityValue(effort.isEmpty ? "default" : effort)
    }
    private func agentSetup(_ agent: JSONValue) -> some View {
        let setup = CodeAgentSetup(agent)
        return VStack(alignment: .leading, spacing: 6) {
            if !setup.installHint.isEmpty { Text(setup.installHint).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled) }
            if !setup.authHint.isEmpty { Text(setup.authHint).font(Theme.ui(11.5)).foregroundStyle(Theme.warnFg).textSelection(.enabled) }
            HStack(spacing: 8) {
                if setup.canDownload { Button("Install " + agent["name"].string) { agentOperation("agent.install", agent: agent) } }
                if setup.canSignIn { Button(setup.signInLabel) { agentOperation("agent.login", agent: agent) } }
                if setup.canDiscover { Button("Refresh models") { agentOperation("agent.models", agent: agent) } }
                if agentAction != nil {
                    NativeStatusDot(color: Theme.signal, size: 5, pulse: true)
                    Text(agentAction == "agent.login" ? "Waiting for sign-in" : "Working").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
                }
            }.disabled(agentAction != nil)
        }
        .padding(.leading, 3)
    }
    private func agentOperation(_ operation: String, agent: JSONValue) {
        guard agentAction == nil else { return }; agentAction = operation
        Task { defer { agentAction = nil }; let result = await state.call(operation, ["agentId": agent["id"]]); let failure = state.error; await reload(); if result == nil { state.error = failure } }
    }
    private var chosenRoute: JSONValue { state.routes.first { $0["id"].string == route } ?? ["id": .string(route), "kind": .string(route.hasPrefix("agent:") ? "agent" : "provider")] }
    private var modes: [JSONValue] { CodeSessionChoices.modes(route: chosenRoute, options: state.detail["options"], current: mode) }
    private var efforts: [JSONValue] { route.hasPrefix("agent:") ? CodeSessionChoices.effective(route: chosenRoute, options: state.detail["options"])["efforts"].array : ["low", "medium", "high", "xhigh", "max"].map { ["value": .string($0), "displayName": .string($0)] } }
    private func reload() async { guard await state.load(project: project, thread: selectedThread) else { return }; let valid = CodeProjectSelection.resolve(project, projects: state.projects); if valid != project { project = valid; selectedThread = ""; return }; if !thread.isNull { rename = thread["title"].string; route = thread["route_id"].string; model = thread["model"].string; mode = thread["permission_mode"].string; effort = thread["effort"].string } }
    private func patch(_ body: JSONObject) async {
        guard await state.call("thread.patch", ["id": .string(selectedThread), "patch": .object(body)]) != nil else {
            if body["route_id"] != nil { route = thread["route_id"].string }
            return
        }
        await reload()
    }
    private func newThread() async { if let t = await state.call("thread.create", ["projectId": .string(project), "routeId": .string(route), "model": .string(model), "effort": effort.isEmpty ? .null : .string(effort), "permissionMode": .string(mode)]) { selectedThread = t["id"].string; await reload(); composerFocused = true } }
    private func send() async { if await state.call("send", ["id": .string(selectedThread), "text": .string(text), "images": .array(images)]) != nil { text = ""; images = []; jump += 1; await reload(); composerFocused = true } }
    private func addProject() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; if panel.nativeRunModal() == .OK, let path = panel.url?.path { Task { if let p = await state.call("project.add", ["path": .string(path)]) { project = p["id"].string; await reload() } } } }
    private func confirm(_ message: String) -> Bool { let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel"); return alert.nativeRunModal() == .alertFirstButtonReturn }
    private func addImage(_ data: Data, mime: String) { guard images.count < 6, data.count <= 10 * 1024 * 1024 else { state.error = "At most six images, 10 MiB each"; return }; images.append(["media_type": .string(mime), "data": .string(data.base64EncodedString())]) }
    private func attach() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .webP, .gif]; panel.allowsMultipleSelection = true; if panel.nativeRunModal() == .OK { for url in panel.urls { if let data = try? Data(contentsOf: url) { addImage(data, mime: ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()] ?? "image/png") } } } }
}

private extension View {
    /// Centers content on the workbench's reading column.
    func codeColumn() -> some View {
        frame(maxWidth: NativeCodeMetrics.column, alignment: .leading).frame(maxWidth: .infinity)
    }
}

/// A value that opens a menu. Outlined on the canvas, bare inside a well.
private struct NativeCodeTrigger<Label: View>: View {
    var icon: String? = nil
    var outlined = false
    var fill = false
    @ViewBuilder var label: () -> Label
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        HStack(spacing: 7) {
            if let icon { NativeIcon(icon, size: 13, strokeWidth: 1.75).foregroundStyle(Theme.muted) }
            label().lineLimit(1)
            if fill { Spacer(minLength: 0) }
            NativeIcon("chevrons-up-down", size: 11, strokeWidth: 1.75).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, outlined ? 10 : 6).frame(maxWidth: fill ? .infinity : nil).frame(height: 28)
        .background(hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
        .overlay { if outlined { RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1) } }
        .contentShape(Rectangle()).opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 && enabled }.pointingHand(enabled)
    }
}

/// Code owns the viewport; only its thread rail, transcript and inspector scroll.
private struct NativeCodeWorkbenchFrame<Content: View>: View {
    let readiness: NativePageReadiness
    @ViewBuilder var content: () -> Content
    @Environment(\.nativePageVisit) private var visit
    var body: some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas).foregroundStyle(Theme.ink).font(Theme.ui(13))
            .buttonStyle(Press(.secondary)).tint(Theme.signal).nativeMotionVisibility()
            .background(alignment: .topLeading) {
                if let visit, NativeUIReadiness.shared.enabled {
                    NativeReadinessProbe(visit: visit, readiness: readiness)
                        .frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

struct NativeCodeEvent: View {
    let event: JSONValue
    var results: [String: JSONValue] = [:]
    var nested: [String: Int] = [:]
    var running = false
    /// Whether this event opens a new speaker's turn and so carries a heading.
    var leads = true
    var body: some View {
        let type = event["type"].string, p = event["payload"]
        if type == "assistant" { assistant(p) }
        else if type == "user" { user(p) }
        else if type == "tool_result" { NativeCodeFold("Tool results") { raw(p) } }
        else if type == "notice" { Text(p["text"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
        else if type == "error" { failure(p["message"].string) }
        else if type == "blocked" { NativeCodeLine(icon: "shield", text: "\(p["tool"].string) refused outside workspace: \(p["path"].string)", tone: Theme.warnFg) }
        else if type == "present" { NativeCodeLine(icon: "eye", text: "Presented \(p["title"].string)", tone: Theme.okFg) }
        else if type == "permission.decision" {
            NativeCodeLine(icon: p["behavior"].string == "allow" ? "check" : "x",
                           text: "\(p["behavior"].string == "allow" ? p["always"].bool ? "Always allowed" : "Allowed" : "Denied")\(p["message"].string.isEmpty ? "" : ": " + p["message"].string)\(p["answers"].isNull ? "" : " · " + json(p["answers"]))",
                           tone: p["behavior"].string == "allow" ? Theme.okFg : Theme.warnFg)
        }
        else if type == "result" {
            VStack(alignment: .leading, spacing: 8) {
                if let error = CodeEventPresentation.resultError(p) { failure(error) }
                NativeCodeLine(icon: CodeEventPresentation.resultError(p) == nil ? "check" : nil,
                               text: (CodeEventPresentation.resultError(p) == nil ? "Done · " : "") + "\(p["num_turns"].int) turns · \(NativeListTimeFormat.duration(Double(p["duration_ms"].int))) · \(NativeNumberFormat.compact(Double(CodeEventPresentation.inputTokens(p)))) in · \(NativeNumberFormat.compact(Double(p["usage"]["output_tokens"].int))) out")
                    .help("\(p["duration_ms"].int) ms · \(CodeEventPresentation.inputTokens(p)) in · \(p["usage"]["output_tokens"].int) out")
            }
        }
        else if type == "compact" { NativeCodeFold("Context compacted") { raw(p) } }
        else if type == "init" { NativeCodeLine(icon: "play", text: "Session \(p["resumed"].bool ? "resumed" : "started") · \(p["model"].string) · \(p["engine"]["name"].string.isEmpty ? "Claude Code " + p["claude_code_version"].string : p["engine"]["name"].string)") }
        else if !["permission", "permission.decision"].contains(type) { NativeCodeFold(type) { raw(p) } }
    }
    private func assistant(_ p: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if leads { NativeCodeTurnHead(speaker: "Agent") }
            ForEach(Array(p["content"].array.enumerated()), id: \.offset) { _, b in
                if b["type"].string == "text" { NativeCodeMarkdown(text: b["text"].string) }
                else if b["type"].string == "thinking" { NativeCodeFold("Thinking") { NativeMarkdown(text: b["thinking"].string).foregroundStyle(Theme.muted) } }
                else { NativeCodeToolView(block: b, result: results[b["id"].string], pending: running, nested: nested[b["id"].string] ?? 0) }
            }
            if p["aborted"].bool { NativeCodeLine(icon: "square", text: "Stopped") }
            if let error = CodeEventPresentation.errorText(p["error"]) { failure(error) }
        }
    }
    // The person's words: heavier than the reply, under a stronger rule, so a
    // long thread can be scanned prompt by prompt. No bubble.
    private func user(_ p: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NativeCodeTurnHead(speaker: "You", own: true)
            if p["content"].array.isEmpty { said(p["content"].string) }
            else {
                ForEach(Array(p["content"].array.enumerated()), id: \.offset) { _, b in
                    if b["type"].string == "text" { said(b["text"].string) }
                    else if let bytes = Data(base64Encoded: b["source"]["data"].string), let image = NSImage(data: bytes) {
                        Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    }
                }
            }
        }
    }
    private func said(_ text: String) -> some View {
        Text(text).font(Theme.ui(13, weight: .medium)).lineSpacing(5).foregroundStyle(Theme.ink).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func failure(_ message: String) -> some View {
        Notice(text: message, tone: .fail).accessibilityLabel("Error: " + message)
    }
    private func raw(_ value: JSONValue) -> some View {
        Text(json(value)).font(Theme.mono(10.5)).foregroundStyle(Theme.dim).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10).background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
    }
    private func json(_ value: JSONValue) -> String { String(decoding: (try? value.encoded(pretty: true)) ?? Data(), as: UTF8.self) }
}

/// The agent is waiting on the person. The block carries the signal color
/// down its edge and holds the page's primary action until it is answered.
struct NativeCodePermission: View {
    let request: JSONValue
    var primary = true
    let decide: (JSONObject) -> Void
    @State private var denial = ""
    @State private var edited: String
    @State private var choices: [String: String] = [:]
    @State private var multiple: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @State private var error = ""
    init(request: JSONValue, primary: Bool = true, decide: @escaping (JSONObject) -> Void) {
        self.request = request; self.primary = primary; self.decide = decide
        _edited = State(initialValue: String(decoding: (try? request["input"].encoded(pretty: true)) ?? Data(), as: UTF8.self))
    }
    private var question: Bool { !request["input"]["questions"].array.isEmpty }
    private var previewInput: JSONValue? {
        guard let input = try? JSONValue.decode(Data(edited.utf8)), case .object = input else { return nil }
        return input
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                NativeStatusDot(color: Theme.signal, size: 6, pulse: true)
                MicroLabel(question ? "Question" : "Permission needed", color: Theme.signal)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(request["title"].string.isEmpty ? request["toolName"].string : request["title"].string)
                    .font(Theme.display(17)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                if !request["description"].string.isEmpty { Text(request["description"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                if !request["decisionReason"].string.isEmpty { Text(request["decisionReason"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            if !question {
                if let input = previewInput { NativeCodeToolView(block: ["name": request["toolName"], "input": input], result: nil, pending: false, nested: 0, permissionSummary: true) }
                else if error.isEmpty { Notice(text: "Tool input must be a JSON object", tone: .fail).accessibilityLabel("Error: Tool input must be a JSON object") }
            }
            if !request["blockedPath"].string.isEmpty { NativeCodeLine(icon: "shield", text: "Path outside the project: " + request["blockedPath"].string, tone: Theme.warnFg).textSelection(.enabled) }
            ForEach(Array(request["input"]["questions"].array.enumerated()), id: \.offset) { _, q in questionBlock(q) }
            NativeCodeFold("Inspect or edit tool input") {
                TextEditor(text: $edited).font(Theme.mono(11)).foregroundStyle(Theme.ink).scrollContentBackground(.hidden).padding(8).frame(height: 140)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous).strokeBorder(Theme.ruleStrong, lineWidth: 1))
            }
            Entry(placeholder: "Denial explanation (optional)", text: $denial)
            if !error.isEmpty { Notice(text: error, tone: .fail).accessibilityLabel("Error: " + error) }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Deny") { decide(["behavior": "deny", "message": .string(denial)]) }.buttonStyle(Press(.quiet))
                if !request["suggestions"].array.isEmpty { Button("Always allow") { allow(always: true) }.buttonStyle(Press(.secondary)) }
                Button(question ? "Answer" : "Allow once") { allow(always: false) }.buttonStyle(Press(primary ? .primary : .secondary))
            }
        }
        .padding(.leading, 18).padding(.vertical, 6)
        .overlay(alignment: .leading) { Theme.signal.frame(width: 2) }
        .padding(.top, 12)
        .onChange(of: edited) { _, _ in error = "" }
    }
    private func questionBlock(_ q: JSONValue) -> some View {
        let key = q["question"].string
        return VStack(alignment: .leading, spacing: 0) {
            Text(key).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            Rule(strong: true)
            ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, option in
                let label = option["label"].string
                if q["multiSelect"].bool {
                    NativeSwitcherChoiceRow(selected: false, checked: multiple[key]?.contains(label) == true) {
                        if multiple[key]?.contains(label) == true { multiple[key]?.remove(label) } else { multiple[key, default: []].insert(label) }
                    } content: { optionLabel(option) }.accessibilityLabel(label)
                } else {
                    NativeSwitcherChoiceRow(selected: choices[key] == label) { choices[key] = choices[key] == label ? "" : label } content: { optionLabel(option) }
                        .accessibilityLabel(label)
                }
            }
            Entry(placeholder: "Other answer", text: Binding(get: { other[key] ?? "" }, set: { other[key] = $0 })).padding(.top, 10)
        }
    }
    private func optionLabel(_ option: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(option["label"].string).font(Theme.ui(12.5)).foregroundStyle(Theme.ink)
            if !option["description"].string.isEmpty {
                Text(option["description"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }
    private func allow(always: Bool) {
        guard var input = try? JSONValue.decode(Data(edited.utf8)), case .object = input else { error = "Tool input must be a JSON object"; return }
        if !request["input"]["questions"].array.isEmpty {
            do { input["answers"] = .object(try CodeQuestionAnswers.build(questions: request["input"]["questions"].array, single: choices, multiple: multiple, other: other)) }
            catch { self.error = error.localizedDescription; return }
        }
        decide(["behavior": "allow", "always": .bool(always), "updatedInput": input])
    }
}
