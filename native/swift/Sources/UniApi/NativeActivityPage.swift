import SwiftUI
import UniApiCore
import UniApiPresentation

private struct NativeActivityHistory: Identifiable {
    let id = UUID()
    var time: Date
    var cpu: Double?
    var memory: Double?
}

struct NativeActivityPage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @Environment(\.nativeInterfaceDensity) private var density
    @State private var status: JSONValue = .null
    @State private var reads = NativePageReadScope()
    @State private var history: [NativeActivityHistory] = []
    @State private var view = "apps"
    @State private var search = ""
    @State private var sort = "cpu"
    @State private var descending = true
    @State private var interval = 2
    @State private var paused = false
    @State private var selected: String?
    @State private var expanded = Set<String>()
    @State private var held: [JSONValue]?
    @State private var hover = false
    @FocusState private var tableFocused: Bool
    @FocusState private var focusedControl: String?
    @State private var action: JSONValue = .null
    @State private var acting = false
    @State private var error: String?
    @State private var notice: String?
    @State private var information = false
    @State private var contentWidth: CGFloat = 820
    @State private var details: NativePresentedValue?
    private var snapshot: JSONValue { status["snapshot"] }
    private var fresh: Bool { !snapshot.isNull && status["error"].isNull && error == nil }
    private var groups: [JSONValue] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = snapshot["groups"].array.filter { group in
            (view == "all" || group["kind"].string == "app") && (query.isEmpty || (group["name"].string + " " + group["bundleId"].string + " " + group["processes"].array.map { $0["pid"].string + " " + $0["name"].string }.joined(separator: " ")).localizedCaseInsensitiveContains(query))
        }
        return NativeHardwareDisplayPolicies.sortActivity(filtered, by: sort, descending: descending)
    }
    private var displayed: [JSONValue] {
        guard let held else { return groups }
        return NativeHardwareDisplayPolicies.holdActivityRows(current: groups, held: held)
    }
    private var pageReadiness: NativePageReadiness {
        if error != nil || !status["error"].string.isEmpty { return .failed }
        if status.isNull { return .pending }
        if !status["supported"].bool || !status["installed"].bool { return .ready }
        return snapshot.isNull ? .pending : .ready
    }
    private var eyebrow: String {
        if status.isNull && error == nil { return "Reading activity" }
        if !fresh { return "Readings unavailable" }
        return paused ? "Paused" : "Live · every \(interval) s"
    }
    private var live: Bool { fresh && !paused }
    // Columns the ledger can afford at this width.
    private var showsBars: Bool { contentWidth >= 660 }
    private var showsDisk: Bool { contentWidth >= 440 }
    private var cpuWidth: CGFloat { showsBars ? 112 : 64 }
    private var memoryWidth: CGFloat { showsBars ? 140 : 76 }

    var body: some View {
        GeometryReader { viewport in
        NativePage(title: "Activity", eyebrow: eyebrow, readiness: pageReadiness, actions: {
            Pick(title: "Refresh frequency", selection: $interval, options: [(1, "Every 1 s"), (2, "Every 2 s"), (5, "Every 5 s")])
            IconPress(icon: "refresh-cw", help: "Refresh") { Task { await reload(force: true) } }
            IconPress(icon: "info", help: "How Activity measurements work", active: information) { information = true }
            Button { paused.toggle() } label: {
                HStack(spacing: 6) {
                    NativeIcon(paused ? "play" : "pause", size: 13, strokeWidth: 1.75)
                    ZStack { Text("Resume").hidden(); Text(paused ? "Resume" : "Pause") }
                }
            }
            .buttonStyle(Press(.primary))
            .accessibilityLabel(paused ? "Resume" : "Pause")
        }) {
            activityContent
        }
        .onChange(of: max(0, min(960, viewport.size.width) - 2 * density.pageMargin), initial: true) { _, width in contentWidth = width }
        }
        .nativePageTask(id: "\(interval):\(paused)") {
            guard !paused else { return }
            while !Task.isCancelled { await reload(); do { try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000) } catch { return } }
        }
        .nativePageActivity(reads: reads, suspended: { hover = false; tableFocused = false; focusedControl = nil; resetFreeze() })
        .onChange(of: search) { _, _ in resetFreeze() }.onChange(of: sort) { _, new in descending = new != "name"; resetFreeze() }.onChange(of: descending) { _, _ in resetFreeze() }.onChange(of: view) { _, _ in resetFreeze() }
        .sheet(isPresented: $information) { informationSheet }
        .sheet(isPresented: Binding(get: { !action.isNull }, set: { if !$0 { action = .null } })) { confirmationSheet }
    }

    // MARK: - Page

    @ViewBuilder private var activityContent: some View {
        Group {
            if let error { errorFeedback(error) }
            if !status["error"].string.isEmpty { errorFeedback(status["error"].string) }
            if !status.isNull && !status["supported"].bool {
                Blank(icon: "activity", title: "Made for Mac", detail: "Activity uses macOS process telemetry and is available on Mac only.")
            } else if !status.isNull && !status["installed"].bool {
                Blank(icon: "activity", title: "Activity needs its local helper", detail: "Build the local Activity helper, then reload this page. No administrator password is needed.")
            } else {
                // The same structure before the first sample, so nothing
                // moves when the readings arrive.
                ColumnFlow(minimum: 300, spacing: 32, rowSpacing: 28, maxColumns: 2) {
                    cpuMeter
                    memoryMeter
                }
                processLedger
            }
        }
        .sheet(item: $details) { item in activityDetails(item.value) }
    }

    private func errorFeedback(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Notice(text: message, tone: .fail).accessibilityLabel("Error: " + message)
            Button("Retry") { Task { await reload(force: true) } }
        }
    }

    // MARK: - Readings

    private var cpuMeter: some View {
        ActivityMeter(title: "CPU", reading: reading(snapshot["cpuPercent"]), live: live,
                      lines: snapshot.isNull ? [] : ["\(snapshot["logicalCpus"].int) logical cores", "100% is the whole Mac"],
                      points: history.map { ($0.time, $0.cpu) }) { EmptyView() }
    }

    private var memoryMeter: some View {
        let pressure = snapshot["pressure"].string
        let tone = pressure == "critical" ? Theme.failFg : ["warning", "warn"].contains(pressure) ? Theme.warnFg : Theme.okFg
        return ActivityMeter(title: "Memory", reading: reading(snapshot["memoryPercent"]), live: live,
                             lines: snapshot.isNull ? [] : ["\(bytes(snapshot["memoryUsed"])) of \(bytes(snapshot["totalMemory"]))",
                                                           "\(bytes(snapshot["compressedBytes"])) compressed · \(bytes(snapshot["swapUsed"])) swap"],
                             points: history.map { ($0.time, $0.memory) }) {
            if !pressure.isEmpty { Tag("pressure " + pressure, tone: tone, dot: true) }
        }
    }

    private func reading(_ value: JSONValue) -> String? {
        value.isNull || !fresh ? nil : String(format: "%.1f", locale: Locale(identifier: "en_US"), value.double)
    }

    // MARK: - Ledger

    private var processLedger: some View {
        Band(title: "Processes", spacing: 0) {
            scopePicker
            if contentWidth >= 520 { searchField.frame(width: 232) }
        } content: {
            if contentWidth < 520 { searchField.padding(.bottom, 10) }
            if let notice {
                HStack(alignment: .center, spacing: 6) {
                    Notice(text: notice).accessibilityAddTraits(.updatesFrequently)
                    IconPress(icon: "x", help: "Dismiss message") { self.notice = nil }
                }
                .padding(.bottom, 10)
            }
            LedgerHead {
                sortHeading("Name", key: "name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 18)
                sortHeading("CPU %", key: "cpu", trailing: true).frame(width: cpuWidth, alignment: .trailing)
                sortHeading("Memory", key: "memory", trailing: true).frame(width: memoryWidth, alignment: .trailing)
                if showsDisk {
                    HStack(spacing: 2) {
                        sortHeading("Disk I/O", key: "disk", trailing: true)
                        Menu {
                            ForEach([("disk", "Disk I/O"), ("read", "Disk read"), ("write", "Disk write")], id: \.0) { key, title in
                                Button { sort = key } label: {
                                    if sort == key { Label { Text(title) } icon: { NativeIcon("check", size: 14) } } else { Text(title) }
                                }
                            }
                        } label: {
                            NativeIcon("chevron-down", size: 10, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                                .frame(width: 14, height: 24).contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Additional disk sort options")
                    }
                    .frame(width: 92, alignment: .trailing)
                }
                Color.clear.frame(width: 28, height: 1)
            }
            LazyVStack(spacing: 0) {
                ForEach(displayed, id: \.self["id"]) { group in
                    activityRow(group, individual: false)
                    if expanded.contains(group["id"].string) { ForEach(group["processes"].array, id: \.self["id"]) { activityRow($0, individual: true) } }
                }
                if displayed.isEmpty { emptyRows }
            }
            .opacity(fresh || snapshot.isNull ? 1 : 0.55).onHover { hover = $0; updateFreeze() }.focusable().focused($tableFocused).focusEffectDisabled()
            .onChange(of: tableFocused) { _, _ in updateFreeze() }.onChange(of: focusedControl) { _, _ in updateFreeze() }
            if !snapshot.isNull {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { tableCaption; Spacer(minLength: 12); sampleStamp }
                    VStack(alignment: .leading, spacing: 4) { tableCaption; sampleStamp }
                }
                .font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1).padding(.top, 12)
            }
        }
    }

    @ViewBuilder private var emptyRows: some View {
        if snapshot.isNull {
            if error == nil && status["error"].string.isEmpty {
                Text("Reading processes").font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
            }
        } else if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Blank(icon: "search", title: "No apps or processes match your search")
        } else if view == "apps" {
            Blank(icon: "app-window", title: "No open apps were found", detail: "Background processes are listed under All activity.",
                  actionTitle: "Show all activity", actionIcon: "activity", primary: false) { view = "all" }
        } else {
            Blank(icon: "activity", title: "No processes were found")
        }
    }

    private var scopePicker: some View {
        Stops(options: [("apps", "Apps"), ("all", "All activity")], selection: view) { view = $0 }
            .accessibilityLabel("Scope")
    }

    private var searchField: some View {
        Entry(placeholder: "Search apps or process IDs", text: $search, icon: "search")
            .accessibilityLabel("Search apps or process IDs")
            .overlay(alignment: .trailing) {
                if !search.isEmpty {
                    Button { search = "" } label: {
                        NativeIcon("x", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                            .frame(width: 26, height: 28).background(Theme.field).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointingHand().padding(.trailing, 2).accessibilityLabel("Clear search")
                }
            }
    }

    private func sortHeading(_ title: String, key: String, trailing: Bool = false) -> some View {
        let active = sort == key || key == "disk" && ["read", "write"].contains(sort)
        let arrow = NativeIcon(descending ? "arrow-down" : "arrow-up", size: 10, strokeWidth: 2).foregroundStyle(Theme.signal)
        return Button { if sort == key { descending.toggle() } else { sort = key } } label: {
            HStack(spacing: 3) {
                if active && trailing { arrow }
                MicroLabel(title, color: active ? Theme.ink : Theme.muted)
                if active && !trailing { arrow }
            }
            .frame(height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHand()
        .help("Sort by \(title)").accessibilityLabel("Sort by \(title)").accessibilityValue(active ? descending ? "Descending" : "Ascending" : "Not sorted")
    }

    private var tableCaption: some View { Text(held != nil ? "Row positions held while you use the list." : paused ? "Readings paused. Resume to see changes." : "Expand an app to see its processes. Right-click a row to quit it.") }
    private var sampleStamp: some View {
        Text("\(snapshot["processCount"].int) processes · \(snapshot["sampledCount"].int) comparable · \(snapshot["omitted"].int) unavailable · " + (snapshot["timestamp"].isNull ? "sample time unavailable" : "sampled " + Date(timeIntervalSince1970: snapshot["timestamp"].double / 1000).formatted(.dateTime.hour().minute().second())))
    }

    private func activityRow(_ row: JSONValue, individual: Bool) -> some View {
        let id = row["id"].string, name = row["name"].string
        let exited = row["exited"].bool, open = expanded.contains(id)
        let cpu = fresh ? row["cpuPercent"] : JSONValue.null
        let memoryShare = fresh ? row["memoryPercent"] : JSONValue.null
        let app = row["kind"].string == "app"
        let members = row["processes"].array.count
        // Apps always state their size; a background group only when it is more than its one process.
        let caption = individual ? "pid " + row["pid"].string : app || members > 1 ? "\(members) \(members == 1 ? "process" : "processes")" : ""
        return ActivityRowSurface(selected: selected == id, exited: exited) { hovering in
            HStack(spacing: 0) {
                if individual {
                    Color.clear.frame(width: 34, height: 1)
                } else {
                    Button { if !expanded.insert(id).inserted { expanded.remove(id) } } label: {
                        NativeIcon(open ? "chevron-down" : "chevron-right", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                            .frame(width: 18, height: 28, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).pointingHand().focused($focusedControl, equals: "expand:" + id)
                    .accessibilityLabel("\(open ? "Collapse" : "Expand") \(name)")
                }
                Button { selected = id } label: {
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text(name).font(Theme.ui(12.5, weight: individual || !app ? .regular : .medium))
                                .foregroundStyle(individual ? Theme.dim : Theme.ink).lineLimit(1)
                            if !row["protectedReason"].isNull {
                                NativeIcon("lock", size: 10, strokeWidth: 1.75).foregroundStyle(Theme.muted).help(row["protectedReason"].string)
                            }
                            if row["partial"].bool || row["memoryKind"].string == "resident" {
                                NativeIcon("info", size: 10, strokeWidth: 1.75).foregroundStyle(Theme.muted).help("Partial or resident-memory fallback")
                            }
                            if exited { Tag("exited") }
                            if !caption.isEmpty { Text(caption).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).layoutPriority(-1) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 8) {
                            if showsBars { Scale(fraction: cpu.isNull ? 0 : cpu.double / 100, height: 3).frame(width: 56) }
                            Text(cpu.isNull ? "—" : percent(cpu).replacingOccurrences(of: "%", with: "")).font(Theme.readout(17))
                                .foregroundStyle(cpu.isNull ? Theme.faint : cpu.double >= 0.1 ? Theme.ink : Theme.muted)
                                .lineLimit(1).frame(width: 48, alignment: .trailing)
                        }
                        .frame(width: cpuWidth, alignment: .trailing)
                        HStack(spacing: 8) {
                            if showsBars { Scale(fraction: memoryShare.isNull ? 0 : memoryShare.double / 100, height: 3).frame(width: 56) }
                            ActivityQuantity(text: bytes(fresh ? row["memoryBytes"] : .null), unitWidth: 20).frame(width: 76, alignment: .trailing)
                        }
                        .frame(width: memoryWidth, alignment: .trailing)
                        .help(memoryShare.isNull ? "" : percent(memoryShare) + " of installed memory")
                        if showsDisk {
                            let disk = fresh ? diskRate(row) : JSONValue.null
                            ActivityQuantity(text: rate(disk), unitWidth: 36, color: disk.double > 0 ? Theme.ink : Theme.muted).frame(width: 92, alignment: .trailing)
                        }
                    }
                    .frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).focused($focusedControl, equals: "select:" + id).disabled(exited)
                .accessibilityAddTraits(selected == id ? .isSelected : [])
                Menu { rowActions(row, individual: individual) } label: {
                    NativeIcon("ellipsis", size: 14, strokeWidth: 1.75).foregroundStyle(Theme.muted)
                        .frame(width: 28, height: 28, alignment: .trailing).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .opacity(hovering || selected == id || focusedControl == "menu:" + id ? 1 : 0)
                .focused($focusedControl, equals: "menu:" + id)
                .accessibilityLabel("Actions for \(name)").help("Details, quit or force quit")
            }
        }
        .contextMenu { rowActions(row, individual: individual) }
    }

    /// Quit and force quit live here, never as a bare button in the row, and
    /// both still pass through the confirmation sheet.
    @ViewBuilder private func rowActions(_ row: JSONValue, individual: Bool) -> some View {
        let name = row["name"].string
        let blocked = runtime.paths.readOnly || !fresh || acting || row["exited"].bool || !row["protectedReason"].isNull
        Button("Details") { selected = row["id"].string; details = NativePresentedValue(value: row) }
            .accessibilityLabel("Selection details")
        Divider()
        Button("Quit \(name)…") { selected = row["id"].string; action = confirmation(row, mode: "quit", individual: individual) }.disabled(blocked)
        Button("Force quit \(name)…") { selected = row["id"].string; action = confirmation(row, mode: "force", individual: individual) }.disabled(blocked)
        if !row["protectedReason"].isNull {
            Divider()
            Text(row["protectedReason"].string)
        }
    }

    // MARK: - Sheets

    private var informationSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How Activity measures").font(Theme.display(17)).accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                informationRow("CPU", "A share of all logical cores, so 100% is the whole Mac. Counters are converted from Mach ticks before comparing elapsed time. The first sample and gaps have no rate.")
                informationRow("Memory", "Physical footprint where available, then resident memory with a visible fallback marker. Reclaimable file cache and purgeable pages are excluded from the whole-Mac total, and shared and system memory mean app rows do not add up to it.")
                informationRow("Grouping", "Helpers belong to a living app through ancestry or an unambiguous bundle path. Shared system hosts stay separate.")
                informationRow("Held rows", "Row order holds while the list has pointer or keyboard focus. Exited rows remain, disabled, until it releases.")
                informationRow("Dashes", "A dash means no comparable or accessible measurement, never zero usage.", ruled: false)
            }
            .padding(.top, 12)
            HStack {
                Spacer(minLength: 0)
                Button("Done") { information = false }.buttonStyle(Press(.primary)).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 16)
        }
        .padding(24).frame(width: 560).sheetGround()
    }

    private func informationRow(_ title: String, _ text: String, ruled: Bool = true) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            MicroLabel(title).frame(width: 96, alignment: .leading)
            Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.dim).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) { if ruled { Rule() } }
        .accessibilityElement(children: .combine)
    }

    private var confirmationSheet: some View {
        let force = action["mode"].string == "force"
        return VStack(alignment: .leading, spacing: 0) {
            Text((force ? "Force quit " : "Quit ") + action["name"].string + "?").font(Theme.display(17))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text("\(action["count"].int) \(action["count"].int == 1 ? "process" : "processes")")
                .font(Theme.mono(11.5)).foregroundStyle(Theme.muted).padding(.top, 8)
            Text(force ? "Force quit can discard unsaved work." : "A normal quit lets the application ask to save its work.")
                .font(Theme.ui(13)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel") { action = .null }.buttonStyle(Press(.secondary)).keyboardShortcut(.defaultAction)
                Button(force ? "Force quit" : "Quit", role: .destructive) { let pending = action; action = .null; Task { await terminate(pending) } }
                    .buttonStyle(Press(force ? .danger : .primary))
            }
            .padding(.top, 22)
        }
        .padding(24).frame(width: 440).sheetGround()
    }

    private func activityDetails(_ captured: JSONValue) -> some View {
        let single = captured["processes"].isNull
        let members = single ? [captured] : captured["processes"].array
        let memory = ActivityQuantity.parts(bytes(captured["memoryBytes"]))
        let read = ActivityQuantity.parts(rate(captured["readPerSecond"])), write = ActivityQuantity.parts(rate(captured["writePerSecond"]))
        return VStack(alignment: .leading, spacing: 0) {
            MicroLabel((single ? "Process" : captured["kind"].string == "app" ? "App" : "Background group") + " · selected sample")
            Text(captured["name"].string).font(Theme.display(17)).lineLimit(1).accessibilityAddTraits(.isHeader).padding(.top, 6)
            ReadoutStrip(minimum: 104) {
                Readout(label: "CPU", value: percent(captured["cpuPercent"]).replacingOccurrences(of: "%", with: ""), unit: captured["cpuPercent"].isNull ? "" : "%", detail: "of the whole Mac", size: .medium)
                Readout(label: "Memory", value: memory.0, unit: memory.1, detail: captured["memoryPercent"].isNull ? "" : percent(captured["memoryPercent"]) + " of installed", size: .medium)
                Readout(label: "Disk reads", value: read.0, unit: read.1, size: .medium)
                Readout(label: "Disk writes", value: write.0, unit: write.1, size: .medium)
            }
            .padding(.top, 18)
            VStack(spacing: 0) {
                if single {
                    detailRow("Process / parent", "\(captured["pid"].int) / \(captured["ppid"].int)")
                    detailRow("Threads", captured["threads"].isNull ? "—" : captured["threads"].string)
                    detailRow("Memory source", captured["memoryKind"].string)
                } else {
                    detailRow("Bundle", captured["bundleId"].string.isEmpty ? "Background process" : captured["bundleId"].string)
                    detailRow("Processes", String(captured["processes"].array.count))
                }
            }
            .padding(.top, 18)
            if captured["partial"].bool || captured["memoryKind"].string == "resident" {
                Notice(text: "Some readings are unavailable or use resident memory as a fallback. Missing counters remain unavailable.").padding(.top, 12)
            }
            if !captured["protectedReason"].isNull { Notice(text: captured["protectedReason"].string, tone: .warn).padding(.top, 12) }
            MicroLabel("Executables").padding(.top, 18).padding(.bottom, 8)
            ViewThatFits(in: .vertical) {
                memberList(members)
                ScrollView { memberList(members) }
            }
            .frame(maxHeight: 190, alignment: .top)
            HStack {
                Spacer(minLength: 0)
                Button("Done") { details = nil }.buttonStyle(Press(.primary)).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 18)
        }
        .padding(24).frame(width: 560).sheetGround()
    }

    private func memberList(_ members: [JSONValue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(members, id: \.self["id"]) { row in
                Text(verbatim: "PID \(row["pid"].int) · \(row["memoryKind"].string) · \(row["path"].string)").font(Theme.mono(10.5)).foregroundStyle(Theme.muted)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        LedgerRow(minHeight: 28) {
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(title).font(Theme.ui(12.5)).foregroundStyle(Theme.muted)
                Spacer(minLength: 0)
                Text(value).font(Theme.mono(11.5)).foregroundStyle(Theme.ink).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
        }
    }

    // MARK: - Formatting and operations

    private func percent(_ value: JSONValue) -> String { value.isNull ? "—" : value.double > 0 && value.double < 0.1 ? "<0.1%" : String(format: "%.1f%%", locale: Locale(identifier: "en_US"), value.double) }
    private func bytes(_ value: JSONValue) -> String {
        guard !value.isNull, value.double.isFinite else { return "—" }
        let amount = max(0, value.double), unit = amount < 1024 ? "B" : amount < 1_048_576 ? "KB" : amount < 1_073_741_824 ? "MB" : "GB"
        let divisor = unit == "B" ? 1.0 : unit == "KB" ? 1024.0 : unit == "MB" ? 1_048_576.0 : 1_073_741_824.0
        return String(format: unit == "B" ? "%.0f %@" : unit == "GB" ? "%.2f %@" : "%.1f %@", locale: Locale(identifier: "en_US"), amount / divisor, unit)
    }
    private func rate(_ value: JSONValue) -> String { value.isNull ? "—" : bytes(value) + "/s" }
    private func diskRate(_ row: JSONValue) -> JSONValue { row["readPerSecond"].isNull && row["writePerSecond"].isNull ? .null : .number(row["readPerSecond"].double + row["writePerSecond"].double) }

    private func updateFreeze() { if hover || tableFocused || focusedControl != nil { if held == nil { held = groups } } else { held = nil } }
    private func resetFreeze() { held = nil; updateFreeze() }
    private func confirmation(_ row: JSONValue, mode: String, individual: Bool) -> JSONValue { ["id": row["id"], "mode": .string(mode), "process": .bool(individual), "name": row["name"], "count": .number(Double(individual ? 1 : row["processes"].array.count))] }
    private func reload(force: Bool = false) async {
        guard let service = session.activity, let ticket = reads.begin("status") else { return }
        do {
            let next = try await service.handle("status", input: ["force": .bool(force)])
            guard reads.accepts(ticket) else { return }
            status = next; error = nil
            let time = fresh ? NativeHardwareDisplayPolicies.number(snapshot["timestamp"]).map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date() : Date()
            if history.last?.time != time { history.append(.init(time: time, cpu: fresh ? NativeHardwareDisplayPolicies.number(snapshot["cpuPercent"]) : nil, memory: fresh ? NativeHardwareDisplayPolicies.number(snapshot["memoryPercent"]) : nil)) }
            history.removeAll { time.timeIntervalSince($0.time) > 120 }
        }
        catch { if reads.accepts(ticket) { self.error = error.localizedDescription } }
    }
    private func terminate(_ input: JSONValue) async {
        guard let service = session.activity, !acting else { return }; acting = true; defer { acting = false }
        do {
            let command: JSONObject = ["id": input["id"], "mode": input["mode"], "process": input["process"]]
            let result = try await service.handle("terminate", input: command)
            notice = result["ok"].bool ? result["requested"].double > 0 ? "Quit request sent to \(input["name"].string)." : "\(input["name"].string) has already exited." : "\(result["requested"].int) requests sent. " + result["failed"].array.map { "PID \($0["pid"].int): \($0["reason"].string)" }.joined(separator: " ")
            await reload(force: true)
        } catch { notice = error.localizedDescription }
    }
}

private extension View {
    /// Sheets do not sit inside a `NativePage`, so they restate its ground,
    /// ink and control defaults.
    func sheetGround() -> some View {
        background(Theme.canvas).foregroundStyle(Theme.ink).font(Theme.ui(13)).tint(Theme.signal)
    }
}

/// One whole-Mac reading with the last two minutes beside it: the label hangs
/// from a ticked rule as a `Readout` does, the trace is a strip-chart on the
/// canvas rather than a boxed plot.
private struct ActivityMeter<Accessory: View>: View {
    let title: String
    let reading: String?
    let live: Bool
    let lines: [String]
    let points: [(Date, Double?)]
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                Rule()
                Theme.ink.frame(width: 2, height: 7)
            }
            .frame(height: 7, alignment: .top).padding(.bottom, 9)
            HStack(alignment: .center, spacing: 8) {
                if live { NativeStatusDot(color: Theme.signal, size: 5, pulse: true) }
                MicroLabel(title)
                Spacer(minLength: 8)
                accessory()
            }
            .frame(height: 18)
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        NativeNumberText(text: reading ?? "--", font: Theme.readout(54), color: reading == nil ? Theme.faint : Theme.ink, isolateLayout: true)
                        MicroLabel("%", size: 11)
                    }
                    ForEach(lines, id: \.self) { line in
                        Text(line).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                .frame(minWidth: 150, alignment: .leading).fixedSize()
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(title)
                .accessibilityValue(([reading.map { $0 + " percent" } ?? "Unavailable"] + lines).joined(separator: ", "))
                ActivityTrace(points: points, live: live).frame(maxWidth: .infinity)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The last two minutes of one percentage, drawn to the same gap rule as the
/// readings: a missing sample breaks the line instead of bridging it.
private struct ActivityTrace: View {
    let points: [(Date, Double?)]
    let live: Bool
    private static let span: TimeInterval = 120

    private var samples: [(x: Double, y: Double, segment: Int)] {
        let segments = NativeHardwareDisplayPolicies.activityHistorySegments(points.map { (time: $0.0.timeIntervalSince1970 * 1000, value: $0.1) })
        let now = Date()
        return points.enumerated().compactMap { index, point in
            guard let value = point.1, value.isFinite else { return nil }
            let x = 1 - now.timeIntervalSince(point.0) / Self.span
            guard x >= 0 else { return nil }
            return (min(1, x), max(0, min(1, value / 100)), segments[index])
        }
    }

    var body: some View {
        let samples = samples
        VStack(spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                GeometryReader { geometry in
                    let size = geometry.size
                    ZStack(alignment: .topLeading) {
                        Theme.grid.frame(height: 1)
                        Theme.grid.frame(height: 1).offset(y: size.height / 2)
                        Theme.baseline.frame(height: 1).offset(y: size.height - 1)
                        ActivityTraceShape(samples: samples).stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        if let last = samples.last {
                            Circle().fill(live ? Theme.signal : Theme.muted).frame(width: 5, height: 5)
                                .position(x: last.x * size.width, y: (1 - last.y) * (size.height - 1))
                        }
                    }
                }
                .frame(height: 64)
                VStack(alignment: .trailing) {
                    Text("100"); Spacer(minLength: 0); Text("0")
                }
                .font(Theme.mono(10.5)).foregroundStyle(Theme.faint).frame(width: 22, height: 64, alignment: .trailing)
            }
            HStack(spacing: 6) {
                VStack(spacing: 4) {
                    TickScale(divisions: 24, major: 6, minorHeight: 2, majorHeight: 4).fill(Theme.faint).frame(height: 4)
                    HStack { MicroLabel("2 min ago", color: Theme.faint); Spacer(minLength: 0); MicroLabel("Now", color: Theme.faint) }
                }
                Color.clear.frame(width: 22, height: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ActivityTraceShape: Shape {
    var samples: [(x: Double, y: Double, segment: Int)]
    func path(in rect: CGRect) -> Path {
        var path = Path(), segment: Int?
        for sample in samples {
            let point = CGPoint(x: rect.minX + sample.x * rect.width, y: rect.minY + (1 - sample.y) * (rect.height - 1))
            if segment == sample.segment { path.addLine(to: point) } else { path.move(to: point); segment = sample.segment }
        }
        return path
    }
}

/// A formatted amount such as "22.5 MB": condensed numerals, then the unit as
/// an engraved label in a fixed slot so the digits of a column share an edge.
private struct ActivityQuantity: View {
    var text: String
    var unitWidth: CGFloat
    var color: Color = Theme.ink
    static func parts(_ text: String) -> (String, String) {
        let pieces = text.split(separator: " ", maxSplits: 1).map(String.init)
        return (pieces.first ?? text, pieces.count > 1 ? pieces[1] : "")
    }
    var body: some View {
        let parts = Self.parts(text)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.0).font(Theme.readout(17)).foregroundStyle(parts.0 == "—" ? Theme.faint : color)
            MicroLabel(parts.1).frame(width: unitWidth, alignment: .leading)
        }
        .lineLimit(1)
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

/// A ledger line that hosts its own controls. It draws as `LedgerRow` does
/// (hover and selection bleed into the margin, selected rows carry the signal
/// tick) and tells its content when the pointer is over it.
private struct ActivityRowSurface<Content: View>: View {
    let selected: Bool, exited: Bool
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        content(hovering)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusControl, style: .continuous)
                    .fill(selected ? Theme.pressed : hovering ? Theme.hover : .clear)
                    .padding(.horizontal, -8)
            }
            .overlay(alignment: .leading) { if selected { Theme.signal.frame(width: 2, height: 14).offset(x: -8) } }
            .overlay(alignment: .bottom) { Rule() }
            .opacity(exited ? 0.45 : 1)
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
    }
}
