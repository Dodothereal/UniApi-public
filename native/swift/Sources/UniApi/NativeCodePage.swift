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
                    if !state.error.isEmpty { NativeError(message: state.error).padding(.horizontal, 24).padding(.vertical, 10) }
                    HStack(spacing: 0) {
                        if !state.loaded || !state.projects.isEmpty {
                            projectRail.frame(width: 264).background(Theme.sunken.opacity(0.55))
                            Rectangle().fill(Theme.border).frame(width: 1).accessibilityHidden(true)
                        }
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
        let current = state.projects.first(where: { $0["id"].string == project })
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Menu {
                    ForEach(Array(state.projects.enumerated()), id: \.offset) { _, p in Button(p["name"].string) { project = p["id"].string } }
                    Divider()
                    Button("Add project folder", nativeIcon: "folder-plus", action: addProject)
                    Button("Remove project", nativeIcon: "trash-2") { Task { if confirm("Remove this project and its thread history?"), await state.call("project.delete", ["id": .string(project)]) != nil { project = ""; selectedThread = ""; await reload() } } }.disabled(project.isEmpty)
                } label: {
                    HStack(spacing: 7) {
                        NativeIcon("folder-open", size: 14).foregroundStyle(Theme.muted)
                        Text(current?["name"].string ?? (state.loaded ? "Choose project" : "Loading…")).font(Theme.ui(Theme.textSm, weight: .semibold)).foregroundStyle(current == nil ? Theme.muted : Theme.ink).lineLimit(1)
                        NativeIcon("chevrons-up-down", size: 11).foregroundStyle(Theme.faint)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 8).frame(height: Theme.control).contentShape(Rectangle())
                }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).pointingHand().accessibilityLabel("Project")
                    .help(current?["path"].string ?? "Project")
                T3IconButton(system: "plus", help: "New thread") { Task { await newThread() } }.disabled(project.isEmpty)
            }.padding(.leading, 8).padding(.trailing, 10).frame(height: Theme.barHeight)
                .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !state.loaded { ShimmerText(text: "Loading…").padding(.horizontal, 16).padding(.vertical, 14) }
                    else if state.threads.isEmpty {
                        Text(project.isEmpty ? "No project chosen" : "No threads").font(Theme.ui(12)).foregroundStyle(Theme.faint).padding(.horizontal, 16).padding(.vertical, 14)
                    }
                    ForEach(Array(state.threads.enumerated()), id: \.offset) { _, t in
                        NativeCodeThreadRow(thread: t, routeName: state.routes.first(where: { $0["id"] == t["route_id"] })?["name"].string ?? t["route_id"].string,
                                            selected: t["id"].string == selectedThread, color: threadStatusColor(t["status"].string)) { selectedThread = t["id"].string }
                    }
                }
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
                VStack(alignment: .leading, spacing: 12) {
                    if state.error.isEmpty { ShimmerText(text: "Loading…", font: Theme.ui(12)) }
                    else { Button("Retry", nativeIcon: "refresh-cw") { Task { await reload() } }.buttonStyle(T3Button(.outline)) }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if selectedThread.isEmpty {
                // What Code needs before there is anything to read: a folder, then a thread in it.
                NativeSetup(steps: [
                    NativeSetupStep(id: "project", title: "Add a project folder",
                                    detail: state.projects.isEmpty ? "The agent works inside this folder." : project.isEmpty ? "Choose one from the menu above the thread list." : (state.projects.first { $0["id"].string == project }?["path"].string ?? ""),
                                    done: !project.isEmpty, actionTitle: "Add folder", actionIcon: "folder-plus", action: addProject),
                    NativeSetupStep(id: "thread", title: "Open a thread, or start one",
                                    detail: "Threads run in parallel and keep running when the window is closed.",
                                    done: false, enabled: !project.isEmpty, actionTitle: "New thread", actionIcon: "plus", action: { Task { await newThread() } })
                ]).frame(maxWidth: 620, alignment: .leading)
                    .padding(.horizontal, 32).padding(.top, 40).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if thread.isNull || state.detailLoading {
                VStack(alignment: .leading, spacing: 12) {
                    if state.error.isEmpty { ShimmerText(text: "Loading…", font: Theme.ui(12)) }
                    else {
                        Text("The saved thread is unchanged.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                        Button("Retry", nativeIcon: "refresh-cw") { Task { await reload() } }.buttonStyle(T3Button(.outline))
                    }
                }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                threadHeader
                if !thread["last_error"].isNull { NativeError(message: thread["last_error"].string).padding(.horizontal, 24).padding(.top, 10) }
                NativeCodeScroll(jump: jump, follows: $follows) {
                    VStack(alignment: .leading, spacing: 14) {
                        NativeCodeTranscript(events: state.events, running: ["running", "starting", "waiting"].contains(thread["status"].string))
                        NativeCodeLiveView(live: state.live, events: state.events)
                        ForEach(Array(state.pending.enumerated()), id: \.element["id"]) { _, p in NativeCodePermission(request: p) { answer in Task { var body = answer; body["id"] = .string(selectedThread); body["requestId"] = p["id"]; _ = await state.call("permission", body); await reload() } } }
                    }.frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.vertical, 16)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1).id(selectedThread)
                    .overlay(alignment: .bottom) {
                        if !follows {
                            Button("Latest", nativeIcon: "arrow-down") { jump += 1 }.buttonStyle(T3Button(.outline))
                                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)).padding(.bottom, 8)
                                .transition(.opacity)
                        }
                    }
                composer
            }
        }
    }
    private var threadHeader: some View {
        HStack(spacing: 10) {
            TextField("Thread title", text: $rename).textFieldStyle(.plain).font(Theme.ui(Theme.textBase, weight: .semibold)).accessibilityLabel("Thread title")
                .onSubmit { Task { _ = await state.call("thread.patch", ["id": .string(selectedThread), "patch": ["title": .string(rename)]]); await reload() } }
            HStack(spacing: 10) {
                HStack(spacing: 3) { NativeIcon("arrow-up", size: 10); Text(NativeNumberFormat.compact(thread["input_tokens"].double)) }.help("\(thread["input_tokens"].int) tokens in")
                HStack(spacing: 3) { NativeIcon("arrow-down", size: 10); Text(NativeNumberFormat.compact(thread["output_tokens"].double)) }.help("\(thread["output_tokens"].int) tokens out")
                if thread["cost_usd"].double > 0 { Text(String(format: "$%.2f", thread["cost_usd"].double)).help("Estimated cost") }
            }.font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).fixedSize()
            T3IconButton(system: "git-branch", help: "Changes", active: showGit) { showGit.toggle() }
            NativeIconMenu(help: "Thread actions") {
                Button("Close session") { Task { _ = await state.call("close", ["id": .string(selectedThread)]); await reload() } }
                Divider()
                Button("Delete thread", role: .destructive) { Task { if confirm("Delete this thread and its history?"), await state.call("thread.delete", ["id": .string(selectedThread)]) != nil { selectedThread = ""; await reload() } } }
            }
        }.padding(.leading, 24).padding(.trailing, 14).frame(height: Theme.barHeight)
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
                TextEditor(text: $text).font(Theme.ui(Theme.textBase)).lineSpacing(2).scrollContentBackground(.hidden).focused($composerFocused).frame(height: 64).padding(.horizontal, 4).accessibilityLabel("Message")
                    .help("Return sends. Shift-Return adds a line. Images can be pasted or dropped.")
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Message").font(Theme.ui(Theme.textBase)).foregroundStyle(Theme.faint)
                                .padding(.horizontal, 9).padding(.top, 0).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .onKeyPress(keys: [.return], phases: .down) { press in if press.modifiers.contains(.shift) { return .ignored }; Task { await send() }; return .handled }
                    .onPasteCommand(of: [.image]) { providers in for p in providers { p.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in if let data { Task { @MainActor in addImage(data, mime: "image/png") } } } } }
                    .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in for p in providers { p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), let bytes = try? Data(contentsOf: url) { let mime = ["jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif", "webp": "image/webp"][url.pathExtension.lowercased()]; if let mime { Task { @MainActor in addImage(bytes, mime: mime) } } } } }; return !providers.isEmpty }
                routeControls
            }.padding(10).nativeFieldChrome(focused: composerFocused, radius: Theme.radius)
                .animation(NativeMotion.hover, value: composerFocused)
        }.frame(maxWidth: 820).frame(maxWidth: .infinity).padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 18)
    }
    /// Where this thread's requests go, left to right, in the order Switcher uses: source, model, effort.
    private var routeStops: some View {
        HStack(spacing: 6) {
            sourceMenu
            NativeRouteArrow()
            modelMenu
            if !efforts.isEmpty || !effort.isEmpty { NativeRouteArrow(); effortMenu }
        }
    }
    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    routeStops
                    permissionRail
                    Spacer(minLength: 0)
                    composerActions
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { routeStops; Spacer(minLength: 0); composerActions }
                    permissionRail
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) { sourceMenu; modelMenu; Spacer(minLength: 0) }
                    HStack(spacing: 6) { if !efforts.isEmpty || !effort.isEmpty { effortMenu }; Spacer(minLength: 0); composerActions }
                    permissionRail
                }
            }
            if let agent = state.routes.first(where: { $0["id"].string == route })?["agent"], !agent.isNull { agentSetup(agent) }
        }
    }
    private var sourceMenu: some View {
        let name = state.routes.first(where: { $0["id"].string == route })?["name"].string ?? route
        return Menu {
            if !state.routes.contains(where: { $0["id"].string == route }) { Text(route + " (unavailable)") }
            ForEach(Array(state.routes.enumerated()), id: \.offset) { _, r in
                Button(r["name"].string) { let value = r["id"].string; route = value; let chosen = state.routes.first { $0["id"].string == value }; model = chosen?["defaultModel"].string ?? ""; Task { await patch(["route_id": .string(value), "model": .string(model)]) } }
            }
        } label: { stopLabel(name, mono: false) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Source").accessibilityValue(name).help("Source: " + name)
    }
    private var modelMenu: some View {
        Menu {
            if !route.hasPrefix("agent:") {
                Button("Use the source's default") { model = ""; Task { await patch(["model": .string("")]) } }
            }
            Button("Search models…", nativeIcon: "search") {
                if let chosen = state.routes.first(where: { $0["id"].string == route }) {
                    modelPicker = NativeCodeModelPickerItem(threadID: selectedThread, route: chosen, options: state.detail["options"], currentModel: model)
                }
            }
        } label: { stopLabel(model.isEmpty ? "default" : model, mono: true) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Model").accessibilityValue(model.isEmpty ? "default" : model).help("Model: " + (model.isEmpty ? "default" : model))
    }
    private func stopLabel(_ value: String, mono: Bool) -> some View {
        HStack(spacing: 6) {
            Text(value).font(mono ? Theme.mono(11) : Theme.ui(11.5, weight: .medium)).foregroundStyle(mono ? Theme.dim : Theme.ink).lineLimit(1).truncationMode(.middle).frame(maxWidth: 190)
                .fixedSize(horizontal: true, vertical: false)
            NativeIcon("chevrons-up-down", size: 11).foregroundStyle(Theme.faint)
        }.padding(.horizontal, 8).frame(height: 28)
            .background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous)).pointingHand()
            .accessibilityElement(children: .ignore)
    }
    private var composerActions: some View {
        HStack(spacing: 4) {
            T3IconButton(system: "paperclip", help: "Attach image") { attach() }
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
                        .foregroundStyle(mode == row["value"].string ? Theme.ink : Theme.muted).padding(.horizontal, 8).frame(height: 24)
                        .background(mode == row["value"].string ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous).strokeBorder(mode == row["value"].string ? Theme.border : .clear, lineWidth: 1) }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).disabled(!row["available"].bool).pointingHand(row["available"].bool)
                    .accessibilityAddTraits(mode == row["value"].string ? [.isSelected] : [])
            }
        }.padding(2).background(Theme.segTrack, in: RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous))
            .disabled(!modes.contains(where: { $0["available"].bool })).accessibilityElement(children: .contain).accessibilityLabel("Permission")
    }
    private var effortMenu: some View {
        Menu {
            Button("Default") { effort = ""; Task { await patch(["effort": .null]) } }
            if !effort.isEmpty && !efforts.contains(where: { $0["value"].string == effort }) { Text(effort + " (not advertised)") }
            ForEach(Array(efforts.filter { !$0["value"].string.isEmpty }.enumerated()), id: \.offset) { _, e in
                Button(e["displayName"].string) { let value = e["value"].string; effort = value; Task { await patch(["effort": value.isEmpty ? .null : .string(value)]) } }
            }
        } label: { stopLabel(effort.isEmpty ? "default effort" : effort, mono: false) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(route.hasPrefix("agent:") && efforts.isEmpty).accessibilityLabel("Effort").accessibilityValue(effort.isEmpty ? "default" : effort)
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

private struct NativeCodeThreadRow: View {
    let thread: JSONValue
    let routeName: String
    let selected: Bool
    let color: Color
    let action: () -> Void
    @State private var hovering = false
    private var active: Bool { ["running", "starting", "waiting"].contains(thread["status"].string) }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(thread["title"].string).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(selected ? Theme.ink : Theme.dim).lineLimit(1)
                    Spacer(minLength: 4)
                    if thread["pending"].int > 0 {
                        HStack(spacing: 3) { NativeIcon("shield-question", size: 11); Text("\(thread["pending"].int)").font(Theme.num(11, weight: .medium)) }
                            .foregroundStyle(Theme.warnFg).accessibilityElement(children: .ignore).accessibilityLabel("\(thread["pending"].int) pending permission requests")
                    } else if active || thread["status"].string == "error" {
                        StatusDot(color: color, pulse: active).accessibilityLabel(thread["status"].string)
                    } else {
                        Text(NativeListTimeFormat.ago(thread["updated_at"].double)).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint).fixedSize()
                    }
                }
                (Text(routeName) + Text("  ") + Text(thread["model"].string.isEmpty ? "default" : thread["model"].string).font(Theme.mono(10.5)))
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }.padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).pointingHand().accessibilityAddTraits(selected ? [.isSelected] : [])
            .background(selected ? Theme.raised : hovering ? Theme.subtle : .clear)
            .overlay(alignment: .leading) { Theme.accent.frame(width: 2).opacity(selected ? 1 : 0) }
            .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
            .onHover { hovering = $0 }
            .help("\(thread["title"].string) · \(thread["status"].string) · \(thread["model"].string)")
    }
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
            else if b["type"].string == "thinking" { NativeDisclosure("Thinking") { NativeMarkdown(text: b["thinking"].string).foregroundStyle(Theme.muted) } }
            else { NativeCodeToolView(block: b, result: results[b["id"].string], pending: running, nested: nested[b["id"].string] ?? 0) }
        }
            if p["aborted"].bool { Text("Stopped").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            if let error = CodeEventPresentation.errorText(p["error"]) { NativeError(message: error) }
        } }
        else if type == "user" { NativeCodeUserBubbleLayout { VStack(alignment: .leading, spacing: 8) { if p["content"].array.isEmpty { Text(p["content"].string).textSelection(.enabled) } else { ForEach(Array(p["content"].array.enumerated()), id: \.offset) { _, b in if b["type"].string == "text" { Text(b["text"].string).textSelection(.enabled) } else if let bytes = Data(base64Encoded: b["source"]["data"].string), let image = NSImage(data: bytes) { Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240) } } } }.font(Theme.ui(13.5)).padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.subtle2, in: UnevenRoundedRectangle(topLeadingRadius: Theme.radius, bottomLeadingRadius: Theme.radius, bottomTrailingRadius: 3, topTrailingRadius: Theme.radius, style: .continuous)) } }
        else if type == "tool_result" { NativeDisclosure("Tool results") { Text(json(p)).font(Theme.mono(11)).textSelection(.enabled) } }
        else if type == "notice" { Text(p["text"].string).font(Theme.ui(12)).foregroundStyle(Theme.muted) }
        else if type == "error" { NativeError(message: p["message"].string) }
        else if type == "blocked" { Text("\(p["tool"].string) refused outside workspace: \(p["path"].string)").font(Theme.ui(11)).foregroundStyle(Theme.warnFg) }
        else if type == "present" { Text("Presented \(p["title"].string)").font(Theme.ui(11)).foregroundStyle(Theme.okFg) }
        else if type == "permission.decision" { Text("\(p["behavior"].string == "allow" ? p["always"].bool ? "Always allowed" : "Allowed" : "Denied")\(p["message"].string.isEmpty ? "" : ": " + p["message"].string)\(p["answers"].isNull ? "" : " · " + json(p["answers"]))").font(Theme.ui(11)).foregroundStyle(p["behavior"].string == "allow" ? Theme.okFg : Theme.warnFg) }
        else if type == "result" { VStack(alignment: .leading, spacing: 4) {
            if let error = CodeEventPresentation.resultError(p) { NativeError(message: error) }
            HStack(spacing: 8) {
                Theme.rule.frame(width: 16, height: 1)
                Text("\(p["num_turns"].int) turns · \(String(format: "%.1f s", Double(p["duration_ms"].int) / 1000)) · \(CodeEventPresentation.inputTokens(p)) in · \(p["usage"]["output_tokens"].int) out").font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint)
                Theme.rule.frame(height: 1)
            }
        } }
        else if type == "compact" { NativeDisclosure("Context compacted", tone: Theme.muted) { Text(json(p)).font(Theme.mono(10)).foregroundStyle(Theme.muted).textSelection(.enabled) } }
        else if type == "init" { Text(["Session \(p["resumed"].bool ? "resumed" : "started")", p["model"].string, p["engine"]["name"].string.isEmpty ? "Claude Code " + p["claude_code_version"].string : p["engine"]["name"].string].filter { !$0.isEmpty }.joined(separator: " · ")).font(Theme.ui(11)).foregroundStyle(Theme.muted) }
        else if !["permission", "permission.decision"].contains(type) { NativeDisclosure(type, tone: Theme.muted) { Text(json(p)).font(Theme.mono(10)).textSelection(.enabled) } }
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
        HStack(spacing: 7) {
            NativeIcon(question ? "circle-help" : "shield-question", size: 14).foregroundStyle(question ? Theme.muted : Theme.warnFg)
            Text(request["title"].string.isEmpty ? request["toolName"].string : request["title"].string).font(Theme.ui(Theme.textSm, weight: .semibold))
        }.accessibilityElement(children: .combine).accessibilityLabel((question ? "Question: " : "Permission needed: ") + (request["title"].string.isEmpty ? request["toolName"].string : request["title"].string))
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
        NativeDisclosure("Tool input") { NativeEditor(text: $edited, mono: true).frame(height: 140) }
        T3Field(placeholder: "Reason for denying (optional)", text: $denial)
        if !error.isEmpty { NativeError(message: error) }
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button("Deny") { decide(["behavior": "deny", "message": .string(denial)]) }.buttonStyle(T3Button(.ghost))
            if !request["suggestions"].array.isEmpty { Button("Always allow") { allow(always: true) }.buttonStyle(T3Button(.outline)) }
            Button(question ? "Answer" : "Allow once") { allow(always: false) }.buttonStyle(T3Button(.primary))
        }
    }.padding(.leading, 16).padding(.trailing, 14).padding(.vertical, 14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1).fill(question ? Theme.accent : Theme.warn).frame(width: 2).padding(.vertical, 12) }
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
