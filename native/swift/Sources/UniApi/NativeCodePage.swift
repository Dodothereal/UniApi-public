import SwiftUI
import AppKit
import UniformTypeIdentifiers
import UniApiCore
import UniApiPresentation

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
    @State private var jump = 0
    @FocusState private var composerFocused: Bool
    init(runtime: NativeRuntime) { self.runtime = runtime; _state = StateObject(wrappedValue: NativeCodeModel(runtime: runtime)) }
    private var thread: JSONValue { state.hasHistory(for: selectedThread) && state.detail["thread"]["id"].string == selectedThread ? state.detail["thread"] : .null }
    private var scope: String { project + ":" + selectedThread }
    var body: some View {
        NativeCodeWorkbenchFrame(readiness: !state.error.isEmpty ? .failed : !selectedThread.isEmpty && (state.detailLoading || thread.isNull) ? .pending : state.loaded ? .ready : .pending) {
            GeometryReader { geometry in
                let inlineInspector = geometry.size.width >= 1050
                VStack(spacing: 0) {
                    if !state.error.isEmpty { NativeError(message: state.error).padding(12) }
                    HStack(spacing: 0) {
                        projectRail.frame(width: 268)
                        Rectangle().fill(Theme.border).frame(width: 1).accessibilityHidden(true)
                        threadPane.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityHidden(showGit && !project.isEmpty && !inlineInspector)
                        if showGit, !project.isEmpty, inlineInspector {
                            Rectangle().fill(Theme.border).frame(width: 1).accessibilityHidden(true)
                            gitInspector.frame(width: 380)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: .trailing) {
                    if showGit, !project.isEmpty, !inlineInspector {
                        gitInspector.frame(width: min(380, geometry.size.width - 24))
                            .background(Theme.surface)
                            .overlay(alignment: .leading) { Theme.border.frame(width: 1) }
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
    private var projectRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Menu {
                    Button("Choose project") { project = "" }
                    ForEach(Array(state.projects.enumerated()), id: \.offset) { _, p in Button(p["name"].string) { project = p["id"].string } }
                    Divider()
                    Button("Add project folder", nativeIcon: "folder-plus", action: addProject)
                    Button("Remove project", nativeIcon: "trash-2") { Task { if confirm("Remove this project and its thread history?"), await state.call("project.delete", ["id": .string(project)]) != nil { project = ""; selectedThread = ""; await reload() } } }.disabled(project.isEmpty)
                } label: {
                    HStack(spacing: 8) {
                        NativeIcon("folder-open", size: 14).foregroundStyle(Theme.muted)
                        Text(state.projects.first(where: { $0["id"].string == project })?["name"].string ?? (state.loaded ? "No project yet" : "Reading projects…")).lineLimit(1)
                        Spacer(minLength: 0)
                        NativeIcon("chevron-down", size: 12).foregroundStyle(Theme.muted)
                    }.font(Theme.ui(12.5, weight: .medium)).padding(.horizontal, 10).frame(height: 30)
                        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1))
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).pointingHand().accessibilityLabel("Project")
                Button { Task { await newThread() } } label: { NativeIcon("plus", size: 16) }
                    .buttonStyle(T3Button(.ghost)).disabled(project.isEmpty).help("New thread").accessibilityLabel("New thread")
            }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
            if let path = state.projects.first(where: { $0["id"].string == project })?["path"] {
                Text(path.string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).help(path.string).padding(.horizontal, 18).padding(.bottom, 8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if !state.loaded { ShimmerText(text: "Loading threads …").padding(.vertical, 28) }
                    else if state.threads.isEmpty {
                        Text(project.isEmpty ? "Pick or add a project" : "No threads yet").font(Theme.ui(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                    ForEach(Array(state.threads.enumerated()), id: \.offset) { _, t in
                        Button { selectedThread = t["id"].string } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 8) {
                                    StatusDot(color: threadStatusColor(t["status"].string), pulse: ["running", "starting", "waiting"].contains(t["status"].string))
                                    Text(t["title"].string).font(Theme.ui(13, weight: t["id"].string == selectedThread ? .medium : .regular)).lineLimit(1)
                                        .foregroundStyle(t["id"].string == selectedThread ? Theme.ink : Theme.dim)
                                    Spacer(minLength: 0)
                                    if t["pending"].int > 0 {
                                        Text("\(t["pending"].int)").font(Theme.mono(10.5, weight: .medium))
                                            .foregroundStyle(Theme.warn).padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(Theme.warn.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                                            .accessibilityLabel("\(t["pending"].int) pending permission requests")
                                    }
                                }
                                HStack(spacing: 5) {
                                    Text(state.routes.first(where: { $0["id"] == t["route_id"] })?["name"].string ?? t["route_id"].string).lineLimit(1)
                                    Text("·").accessibilityHidden(true)
                                    Text(t["model"].string.isEmpty ? "default" : t["model"].string).font(Theme.mono(10.5)).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Text(NativeListTimeFormat.ago(t["updated_at"].double)).fixedSize()
                                }.font(Theme.ui(11)).foregroundStyle(Theme.muted).padding(.leading, 14)
                            }.padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                .background(t["id"].string == selectedThread ? Theme.subtle2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                        }.buttonStyle(.plain).pointingHand().accessibilityAddTraits(t["id"].string == selectedThread ? [.isSelected] : [])
                            .help("\(t["title"].string) · \(t["status"].string) · \(t["model"].string)")
                    }
                }.padding(.horizontal, 8).padding(.bottom, 8)
            }.frame(maxHeight: .infinity)
        }.frame(maxHeight: .infinity, alignment: .top)
    }
    private func threadStatusColor(_ status: String) -> Color {
        switch status {
        case "error": return Theme.fail
        case "waiting": return Theme.warn
        case "running": return Theme.ok
        case "starting": return Theme.accent
        default: return Theme.muted
        }
    }
    private var threadPane: some View {
        VStack(spacing: 0) {
            if !state.loaded {
                VStack(spacing: 12) {
                    if state.error.isEmpty { ShimmerText(text: "Reading projects and threads…", font: Theme.ui(12)) }
                    else {
                        Text("Could not read projects and threads").font(Theme.ui(14, weight: .medium))
                        Button("Retry", nativeIcon: "rotate-cw") { Task { await reload() } }.buttonStyle(T3Button(.outline))
                    }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if selectedThread.isEmpty {
                VStack(spacing: 14) {
                    NativeIcon("bot", size: 24).foregroundStyle(Theme.muted)
                    Text(state.projects.isEmpty ? "Add a project folder to start" : "Pick a thread or start a new one").font(Theme.ui(14, weight: .medium))
                    Text("Each thread keeps its own route, settings, transcript and resumable session. Threads run in parallel and survive closing the window.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).frame(maxWidth: 460)
                    if state.projects.isEmpty { Button("Add project", nativeIcon: "folder-plus", action: addProject).buttonStyle(T3Button(.primary)) }
                    else { Button("New thread", nativeIcon: "plus") { Task { await newThread() } }.buttonStyle(T3Button(.primary)).disabled(project.isEmpty) }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if thread.isNull || state.detailLoading {
                VStack(spacing: 12) {
                    if state.error.isEmpty { ShimmerText(text: "Loading the thread …", font: Theme.ui(12)) }
                    else {
                        Text("Could not load this thread").font(Theme.ui(14, weight: .medium))
                        Text("Your saved thread is unchanged. Reload to try reading it again.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        Button("Retry", nativeIcon: "rotate-cw") { Task { await reload() } }.buttonStyle(T3Button(.outline))
                    }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                threadHeader
                if !thread["last_error"].isNull { NativeError(message: thread["last_error"].string).padding(12) }
                NativeCodeScroll(jump: jump, follows: $follows) {
                    VStack(alignment: .leading, spacing: 12) {
                        NativeCodeTranscript(events: state.events, running: ["running", "starting", "waiting"].contains(thread["status"].string))
                        NativeCodeLiveView(live: state.live, events: state.events)
                        ForEach(Array(state.pending.enumerated()), id: \.element["id"]) { _, p in NativeCodePermission(request: p) { answer in Task { var body = answer; body["id"] = .string(selectedThread); body["requestId"] = p["id"]; _ = await state.call("permission", body); await reload() } } }
                    }.frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 8)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1).id(selectedThread)
                if !follows {
                    HStack { Spacer(); Button("Jump to latest", nativeIcon: "arrow-down") { jump += 1 }.buttonStyle(T3Button(.outline)) }.padding(.horizontal, 24).padding(.bottom, 6)
                }
                composer
            }
        }
    }
    private var threadHeader: some View {
        HStack(spacing: 8) {
            TextField("Thread title", text: $rename).textFieldStyle(.plain).font(Theme.ui(13.5, weight: .medium)).accessibilityLabel("Thread title")
                .onSubmit { Task { _ = await state.call("thread.patch", ["id": .string(selectedThread), "patch": ["title": .string(rename)]]); await reload() } }
            Text("\(thread["input_tokens"].int) / \(thread["output_tokens"].int)").font(Theme.mono(11)).foregroundStyle(Theme.muted).fixedSize().help("Tokens in / out")
            if thread["cost_usd"].double > 0 { Text(String(format: "~$%.2f", thread["cost_usd"].double)).font(Theme.mono(11)).foregroundStyle(Theme.muted) }
            Button("Changes", nativeIcon: "git-branch") { showGit.toggle() }.buttonStyle(T3Button(.ghost)).fixedSize()
            Menu {
                Button("Close session") { Task { _ = await state.call("close", ["id": .string(selectedThread)]); await reload() } }
                Divider()
                Button("Delete thread", role: .destructive) { Task { if confirm("Delete this thread and its history?"), await state.call("thread.delete", ["id": .string(selectedThread)]) != nil { selectedThread = ""; await reload() } } }
            } label: { NativeIcon("ellipsis", size: 14) }
                .menuStyle(.button).buttonStyle(T3Button(.ghost)).menuIndicator(.hidden).help("Thread actions").accessibilityLabel("Thread actions")
        }.padding(.horizontal, 20).frame(height: 48)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) { ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                            if let bytes = Data(base64Encoded: image["data"].string), let picture = NSImage(data: bytes) {
                                Image(nsImage: picture).resizable().scaledToFit().frame(width: 56, height: 56)
                                    .overlay(alignment: .topTrailing) { Button { images.remove(at: index) } label: { NativeIcon("x", size: 12) }.buttonStyle(T3Button(.ghost)).help("Remove image").accessibilityLabel("Remove image") }
                            }
                        } }
                    }
                }
                TextEditor(text: $text).font(Theme.ui(13.5)).scrollContentBackground(.hidden).focused($composerFocused).frame(height: 64).padding(.horizontal, 4).accessibilityLabel("Message")
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Message…").font(Theme.ui(13.5)).foregroundStyle(Theme.muted)
                                .padding(.horizontal, 8).padding(.top, 8).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .onKeyPress(keys: [.return], phases: .down) { press in if press.modifiers.contains(.shift) { return .ignored }; Task { await send() }; return .handled }
                    .onPasteCommand(of: [.image]) { providers in for p in providers { p.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in if let data { Task { @MainActor in addImage(data, mime: "image/png") } } } } }
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in for p in providers { p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), let bytes = try? Data(contentsOf: url) { let mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()]; if let mime { Task { @MainActor in addImage(bytes, mime: mime) } } } } }; return !providers.isEmpty }
                routeControls
            }.padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1))
            Text("Enter sends, Shift+Enter breaks a line, paste or drop images.").font(Theme.ui(10.5)).foregroundStyle(Theme.muted).padding(.horizontal, 4)
        }.frame(maxWidth: 860).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 20)
    }
    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    routeModelMenu(width: 250)
                    permissionRail
                    if !efforts.isEmpty || !effort.isEmpty { effortMenu }
                    Spacer(minLength: 0)
                    composerActions
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { routeModelMenu(); composerActions }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { permissionRail; if !efforts.isEmpty || !effort.isEmpty { effortMenu } }
                        VStack(alignment: .leading, spacing: 6) { permissionRail; if !efforts.isEmpty || !effort.isEmpty { effortMenu } }
                    }
                }
            }
            if let agent = state.routes.first(where: { $0["id"].string == route })?["agent"], !agent.isNull { agentSetup(agent) }
        }
    }
    private func routeModelMenu(width: CGFloat? = nil) -> some View {
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
            HStack(spacing: 6) {
                (Text(name).foregroundColor(Theme.ink) + Text(" · ").foregroundColor(Theme.muted)
                    + Text(model.isEmpty ? "default" : model).font(Theme.mono(11)).foregroundColor(Theme.dim))
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                NativeIcon("chevron-down", size: 12).foregroundStyle(Theme.muted)
            }.font(Theme.ui(11.5)).padding(.horizontal, 8).frame(width: width, height: 28)
                .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd)).pointingHand()
                .accessibilityElement(children: .ignore)
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .accessibilityLabel("Route and model").accessibilityValue(name + " · " + (model.isEmpty ? "default" : model))
            .help(name + " · " + (model.isEmpty ? "default" : model))
    }
    private var composerActions: some View {
        HStack(spacing: 4) {
            Button { attach() } label: { NativeIcon("paperclip", size: 14) }
                .buttonStyle(T3Button(.ghost)).help("Attach image").accessibilityLabel("Attach image")
            // Keep this slot stable when the session starts or finishes.
            ZStack(alignment: .trailing) {
                if ["running", "starting", "waiting"].contains(thread["status"].string) {
                    Button("Stop", nativeIcon: "square") { Task { _ = await state.call("interrupt", ["id": .string(selectedThread)]) } }
                        .buttonStyle(T3Button(.outline)).fixedSize()
                }
            }.frame(width: 66, height: 28)
            Button { Task { await send() } } label: { NativeIcon("arrow-up", size: 15) }
                .buttonStyle(T3Button(.primary)).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty)
                .keyboardShortcut(.return, modifiers: [.command]).help(thread["status"].string == "running" ? "Send queues a follow-up" : "Send").accessibilityLabel("Send")
        }.fixedSize()
    }
    private var permissionRail: some View {
        HStack(spacing: 2) {
            ForEach(Array(modes.enumerated()), id: \.offset) { _, row in
                Button { let value = row["value"].string; mode = value; Task { await patch(["permission_mode": .string(value)]) } } label: {
                    Text(row["displayName"].string).font(Theme.ui(11.5)).lineLimit(1).fixedSize()
                        .foregroundStyle(mode == row["value"].string ? Theme.ink : Theme.muted).padding(.horizontal, 8).padding(.vertical, 5)
                        .background(mode == row["value"].string ? Theme.subtle2 : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                }.buttonStyle(.plain).disabled(!row["available"].bool).pointingHand(row["available"].bool)
                    .accessibilityAddTraits(mode == row["value"].string ? [.isSelected] : [])
            }
        }.padding(2).background(Theme.segTrack, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1))
            .disabled(!modes.contains(where: { $0["available"].bool })).accessibilityElement(children: .contain).accessibilityLabel("Permission")
    }
    private var effortMenu: some View {
        Menu {
            Button("Default") { effort = ""; Task { await patch(["effort": .null]) } }
            if !effort.isEmpty && !efforts.contains(where: { $0["value"].string == effort }) { Text(effort + " (not advertised)") }
            ForEach(Array(efforts.filter { !$0["value"].string.isEmpty }.enumerated()), id: \.offset) { _, e in
                Button(e["displayName"].string) { let value = e["value"].string; effort = value; Task { await patch(["effort": value.isEmpty ? .null : .string(value)]) } }
            }
        } label: { controlLabel("effort " + (effort.isEmpty ? "default" : effort), width: 112) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).disabled(route.hasPrefix("agent:") && efforts.isEmpty).accessibilityLabel("Effort").accessibilityValue(effort.isEmpty ? "default" : effort)
    }
    private func controlLabel(_ value: String, width: CGFloat) -> some View {
        HStack(spacing: 6) { Text(value).lineLimit(1); Spacer(minLength: 0); NativeIcon("chevron-down", size: 12) }
            .font(Theme.ui(11.5)).foregroundStyle(Theme.dim).padding(.horizontal, 8).frame(width: width, height: 28)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1)).pointingHand().help(value).accessibilityElement(children: .ignore)
    }
    private func agentSetup(_ agent: JSONValue) -> some View {
        let setup = CodeAgentSetup(agent)
        return VStack(alignment: .leading, spacing: 5) {
            if !setup.installHint.isEmpty { Text(setup.installHint).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled) }
            if !setup.authHint.isEmpty { Text(setup.authHint).font(Theme.ui(11)).foregroundStyle(Theme.warnFg).textSelection(.enabled) }
            HStack {
                if setup.canDownload { Button("Install " + agent["name"].string) { agentOperation("agent.install", agent: agent) } }
                if setup.canSignIn { Button(setup.signInLabel) { agentOperation("agent.login", agent: agent) } }
                if setup.canDiscover { Button("Refresh models") { agentOperation("agent.models", agent: agent) } }
                if agentAction != nil { ProgressView().controlSize(.small); Text(agentAction == "agent.login" ? "Waiting for sign-in…" : "Working…").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            }.disabled(agentAction != nil)
        }
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

/// Code owns the viewport; only its thread rail, transcript and inspector scroll.
private struct NativeCodeWorkbenchFrame<Content: View>: View {
    let readiness: NativePageReadiness
    @ViewBuilder var content: () -> Content
    @Environment(\.nativePageVisit) private var visit
    var body: some View {
        content().frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg).foregroundStyle(Theme.ink).font(Theme.ui(13))
            .buttonStyle(T3Button(.outline)).tint(Theme.accent).nativeMotionVisibility()
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
    var body: some View { let type = event["type"].string, p = event["payload"]
        if type == "assistant" { VStack(alignment: .leading, spacing: 8) { ForEach(Array(p["content"].array.enumerated()), id: \.offset) { _, b in
            if b["type"].string == "text" { NativeCodeMarkdown(text: b["text"].string) }
            else if b["type"].string == "thinking" { DisclosureGroup("Thinking") { NativeMarkdown(text: b["thinking"].string).foregroundStyle(Theme.muted) } }
            else { NativeCodeToolView(block: b, result: results[b["id"].string], pending: running, nested: nested[b["id"].string] ?? 0) }
        }
            if p["aborted"].bool { Text("Stopped").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            if let error = CodeEventPresentation.errorText(p["error"]) { NativeError(message: error) }
        } }
        else if type == "user" { NativeCodeUserBubbleLayout { VStack(alignment: .leading, spacing: 8) { if p["content"].array.isEmpty { Text(p["content"].string).textSelection(.enabled) } else { ForEach(Array(p["content"].array.enumerated()), id: \.offset) { _, b in if b["type"].string == "text" { Text(b["text"].string).textSelection(.enabled) } else if let bytes = Data(base64Encoded: b["source"]["data"].string), let image = NSImage(data: bytes) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240) } } } }.font(Theme.ui(13.5)).padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.subtle2, in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 3, topTrailingRadius: 12)) } }
        else if type == "tool_result" { DisclosureGroup("Tool results") { Text(json(p)).font(Theme.mono(11)).textSelection(.enabled) } }
        else if type == "notice" { Text(p["text"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted) }
        else if type == "error" { NativeError(message: p["message"].string) }
        else if type == "blocked" { Text("\(p["tool"].string) refused outside workspace: \(p["path"].string)").font(Theme.ui(11)).foregroundStyle(Theme.warnFg) }
        else if type == "present" { Text("Presented \(p["title"].string)").font(Theme.ui(11)).foregroundStyle(Theme.okFg) }
        else if type == "permission.decision" { Text("\(p["behavior"].string == "allow" ? p["always"].bool ? "Always allowed" : "Allowed" : "Denied")\(p["message"].string.isEmpty ? "" : ": " + p["message"].string)\(p["answers"].isNull ? "" : " · " + json(p["answers"]))").font(Theme.ui(11)).foregroundStyle(p["behavior"].string == "allow" ? Theme.okFg : Theme.warnFg) }
        else if type == "result" { VStack(alignment: .leading, spacing: 4) {
            if let error = CodeEventPresentation.resultError(p) { NativeError(message: error) } else { Text("Done").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            Text("\(p["num_turns"].int) turns · \(p["duration_ms"].int) ms · \(CodeEventPresentation.inputTokens(p)) in · \(p["usage"]["output_tokens"].int) out").font(Theme.mono(11)).foregroundStyle(Theme.muted)
        } }
        else if type == "compact" { DisclosureGroup("Context compacted") { Text(json(p)).font(Theme.mono(10)).textSelection(.enabled) }.font(Theme.ui(11)).foregroundStyle(Theme.muted) }
        else if type == "init" { Text("Session \(p["resumed"].bool ? "resumed" : "started") · \(p["model"].string) · \(p["engine"]["name"].string.isEmpty ? "Claude Code " + p["claude_code_version"].string : p["engine"]["name"].string)").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
        else if !["permission", "permission.decision"].contains(type) { DisclosureGroup(type) { Text(json(p)).font(Theme.mono(10)).textSelection(.enabled) } }
    }
    private func json(_ value: JSONValue) -> String { String(decoding: (try? value.encoded(pretty: true)) ?? Data(), as: UTF8.self) }
}

struct NativeCodePermission: View {
    let request: JSONValue
    let decide: (JSONObject) -> Void
    @State private var denial = ""
    @State private var edited: String
    @State private var choices: [String: String] = [:]
    @State private var multiple: [String: Set<String>] = [:]
    @State private var other: [String: String] = [:]
    @State private var error = ""
    init(request: JSONValue, decide: @escaping (JSONObject) -> Void) {
        self.request = request; self.decide = decide
        _edited = State(initialValue: String(decoding: (try? request["input"].encoded(pretty: true)) ?? Data(), as: UTF8.self))
    }
    private var question: Bool { !request["input"]["questions"].array.isEmpty }
    private var previewInput: JSONValue? {
        guard let input = try? JSONValue.decode(Data(edited.utf8)), case .object = input else { return nil }
        return input
    }
    var body: some View { VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 6) { NativeIcon(question ? "circle-help" : "shield-question", size: 14); Text(question ? "Question" : "Permission needed").font(Theme.ui(12)) }
            .foregroundStyle(question ? Theme.muted : Theme.warnFg)
        Text(request["title"].string.isEmpty ? request["toolName"].string : request["title"].string).font(Theme.ui(13.5, weight: .medium))
        if !request["description"].string.isEmpty { Text(request["description"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted) }
        if !request["decisionReason"].string.isEmpty { Text(request["decisionReason"].string).font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
        if !question {
            if let input = previewInput { NativeCodeToolView(block: ["name": request["toolName"], "input": input], result: nil, pending: false, nested: 0, permissionSummary: true) }
            else if error.isEmpty { NativeError(message: "Tool input must be a JSON object") }
        }
        if !request["blockedPath"].string.isEmpty { Text("Path outside the project: " + request["blockedPath"].string).font(Theme.mono(11)).foregroundStyle(Theme.muted).textSelection(.enabled) }
        ForEach(Array(request["input"]["questions"].array.enumerated()), id: \.offset) { _, q in
            Text(q["question"].string)
            if q["multiSelect"].bool { ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, option in Toggle(option["label"].string, isOn: Binding(get: { multiple[q["question"].string]?.contains(option["label"].string) == true }, set: { yes in if yes { multiple[q["question"].string, default: []].insert(option["label"].string) } else { multiple[q["question"].string]?.remove(option["label"].string) } })) } }
            else { Picker("Answer", selection: Binding(get: { choices[q["question"].string] ?? "" }, set: { choices[q["question"].string] = $0 })) { Text("Choose").tag(""); ForEach(Array(q["options"].array.enumerated()), id: \.offset) { _, o in Text(o["label"].string).tag(o["label"].string) } } }
            TextField("Other answer", text: Binding(get: { other[q["question"].string] ?? "" }, set: { other[q["question"].string] = $0 }))
        }
        DisclosureGroup("Inspect or edit tool input") { TextEditor(text: $edited).font(Theme.mono(11)).scrollContentBackground(.hidden).padding(8).frame(height: 140)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1)) }
        TextField("Denial explanation (optional)", text: $denial)
        if !error.isEmpty { NativeError(message: error) }
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Deny") { decide(["behavior": "deny", "message": .string(denial)]) }.buttonStyle(T3Button(.ghost))
            if !request["suggestions"].array.isEmpty { Button("Always allow") { allow(always: true) }.buttonStyle(T3Button(.outline)) }
            Button(question ? "Answer" : "Allow once") { allow(always: false) }.buttonStyle(T3Button(.primary))
        }
    }.padding(14).background(question ? Theme.surface : Theme.warn.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(question ? Theme.border : Theme.warn.opacity(0.4), lineWidth: 1))
        .onChange(of: edited) { _, _ in error = "" }
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

/// Preserve the web transcript's right-aligned 85-percent user-bubble limit
/// without a GeometryReader that would claim an arbitrary message height.
private struct NativeCodeUserBubbleLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        let width = proposal.width ?? bubble.sizeThatFits(.unspecified).width
        let size = bubble.sizeThatFits(ProposedViewSize(width: width * 0.85, height: nil))
        return CGSize(width: width, height: size.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let bubble = subviews.first else { return }
        let size = bubble.sizeThatFits(ProposedViewSize(width: bounds.width * 0.85, height: nil))
        bubble.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: ProposedViewSize(size))
    }
}
