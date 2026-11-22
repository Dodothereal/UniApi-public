import SwiftUI
import Charts
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
    var body: some View {
        GeometryReader { viewport in
        NativePage(title: "Activity", maxWidth: 1280, readiness: pageReadiness, tabs: {
            NativeTabs(options: [("apps", "Apps"), ("all", "All processes")], selection: view) { view = $0 }
        }, actions: {
            searchField.frame(width: 200)
            NativeMenuSelectLabel(title: "\(interval) s") {
                Button("1 s") { interval = 1 }; Button("2 s") { interval = 2 }; Button("5 s") { interval = 5 }
            }.fixedSize().help("Sampling interval").accessibilityLabel("Sampling interval")
            T3IconButton(system: paused ? "play" : "pause", help: paused ? "Resume" : "Pause", active: paused) { paused.toggle() }
            T3IconButton(system: "refresh-cw", help: "Refresh") { Task { await reload(force: true) } }
            T3IconButton(system: "info", help: "How Activity measures") { information = true }
        }) {
            activityContent
        }
        .onChange(of: max(0, min(1280, viewport.size.width) - 2 * density.pageMargin), initial: true) { _, width in contentWidth = width }
        }
        .nativePageTask(id: "\(interval):\(paused)") {
            guard !paused else { return }
            while !Task.isCancelled { await reload(); do { try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000) } catch { return } }
        }
        .nativePageActivity(reads: reads, suspended: { hover = false; tableFocused = false; focusedControl = nil; resetFreeze() })
        .onChange(of: search) { _, _ in resetFreeze() }.onChange(of: sort) { _, new in descending = new != "name"; resetFreeze() }.onChange(of: descending) { _, _ in resetFreeze() }.onChange(of: view) { _, _ in resetFreeze() }
        .sheet(isPresented: $information) {
            VStack(alignment: .leading, spacing: 12) {
                Text("How Activity measures").font(Theme.ui(Theme.textBase, weight: .semibold))
                Group {
                    Text("CPU is a share of all logical cores, so 100% is the whole Mac. The first sample and gaps have no rate.")
                    Text("Memory is physical footprint where available, otherwise resident memory, marked. Reclaimable file cache and purgeable pages are excluded from the total, and shared memory means rows do not add up to it.")
                    Text("A dash means no comparable or accessible measurement. It never means zero.")
                    Text("Helpers belong to a living app through ancestry or an unambiguous bundle path. Row order holds while the table has the pointer or keyboard focus; exited rows stay disabled until it releases.")
                }.font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.dim).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                HStack { Spacer(); Button("Done") { information = false }.buttonStyle(T3Button(.primary)).keyboardShortcut(.cancelAction) }
            }.padding(20).frame(width: 520).background(Theme.bg)
        }
        .sheet(isPresented: Binding(get: { !action.isNull }, set: { if !$0 { action = .null } })) {
            VStack(alignment: .leading, spacing: 10) {
                Text((action["mode"].string == "force" ? "Force quit " : "Quit ") + action["name"].string + "?").font(Theme.ui(Theme.textBase, weight: .semibold))
                Text("\(action["count"].int) \(action["count"].int == 1 ? "process" : "processes"). " + (action["mode"].string == "force" ? "Unsaved work is discarded." : "The application can ask to save its work.")).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.dim)
                HStack(spacing: 8) { Spacer(); Button("Cancel") { action = .null }.buttonStyle(T3Button(.ghost)).keyboardShortcut(.defaultAction); Button(action["mode"].string == "force" ? "Force quit" : "Quit", role: .destructive) { let pending = action; action = .null; Task { await terminate(pending) } }.buttonStyle(T3Button(.destructive)) }.padding(.top, 8)
            }.padding(20).frame(width: 420).background(Theme.bg)
        }
    }
    @ViewBuilder private var activityContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error { errorFeedback(error) }
            if !status["error"].string.isEmpty { errorFeedback(status["error"].string) }
            if status.isNull {
                if error == nil { ShimmerText(text: "Loading…") }
            } else if !status["supported"].bool {
                NativeEmptyState(title: "Mac only", detail: "Activity reads macOS process telemetry.", icon: "activity")
            } else if !status["installed"].bool {
                NativeEmptyState(title: "Helper not built", detail: "Build the local Activity helper, then reload. No administrator password is needed.", icon: "activity")
            } else if snapshot.isNull {
                if error == nil && status["error"].string.isEmpty { ShimmerText(text: "Loading…") }
            } else {
                Group {
                    if contentWidth >= 620 { HStack(alignment: .top, spacing: 0) { overviewCards } }
                    else { VStack(spacing: 0) { overviewCards } }
                }.background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                if let notice {
                    HStack(spacing: 12) {
                        Text(notice).font(Theme.ui(12)).foregroundStyle(Theme.dim).textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
                        Spacer(minLength: 0)
                        T3IconButton(system: "x", help: "Dismiss message", size: 12) { self.notice = nil }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) { selectionTitle; Spacer(minLength: 8); selectionActions }.frame(height: 44)
                    activityTable
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { tableCaption; Spacer(minLength: 12); contextLabels; sampleStamp }
                        VStack(alignment: .leading, spacing: 4) { tableCaption; contextLabels; sampleStamp }
                    }.font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint).padding(.top, 10)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .sheet(item: $details) { item in activityDetails(item.value) }
    }
    @ViewBuilder private var overviewCards: some View {
        overview("CPU", value: snapshot["cpuPercent"], points: history.map { ($0.time, $0.cpu) }, color: Theme.accent)
        overview("Memory", value: snapshot["memoryPercent"], points: history.map { ($0.time, $0.memory) }, color: Theme.ink)
    }
    private var contextLabels: some View {
        Text("\(snapshot["processCount"].int) processes · compressed \(bytes(snapshot["compressedBytes"])) · swap \(bytes(snapshot["swapUsed"]))")
            .help("\(snapshot["sampledCount"].int) comparable samples, \(snapshot["omitted"].int) unavailable")
    }
    private var searchField: some View {
        T3Field(placeholder: "Filter", text: $search, leadingIcon: "search").accessibilityLabel("Filter apps or process IDs")
    }
    private var selectionTitle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(selection?["name"].string ?? (selected == nil ? "No selection" : "Exited")).font(Theme.ui(Theme.textSm, weight: .medium)).foregroundStyle(selection == nil ? Theme.faint : Theme.ink).lineLimit(1)
            if let selection { Text(!selection["protectedReason"].isNull ? selection["protectedReason"].string : selection["processes"].isNull ? "PID \(selection["pid"].int)" : "\(selection["processes"].array.count) processes").font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var selectionActions: some View {
        HStack(spacing: 6) {
            T3IconButton(system: "info", help: "Selection details") { if let selection { details = NativePresentedValue(value: selection) } }.disabled(selection == nil)
            Button("Quit") { request(mode: "quit") }.disabled(!canAct)
            Button("Force quit") { request(mode: "force") }.buttonStyle(T3Button(.destructive)).disabled(!canAct)
        }.fixedSize()
    }
    private var activityTable: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        sortHeading("Name", key: "name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28)
                        sortHeading("CPU", key: "cpu").frame(width: 110, alignment: .trailing)
                        sortHeading("Memory", key: "memory").frame(width: 142, alignment: .trailing)
                        HStack(spacing: 2) {
                            sortHeading("Disk I/O", key: "disk")
                            Menu { Button("Disk I/O") { sort = "disk" }; Button("Disk read") { sort = "read" }; Button("Disk write") { sort = "write" } } label: { NativeIcon("chevron-down", size: 10) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("Additional disk sort options")
                        }.frame(width: 108, alignment: .trailing)
                        Color.clear.frame(width: 42)
                    }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 30)
                    LazyVStack(spacing: 0) {
                        ForEach(displayed, id: \.self["id"]) { group in
                            activityRow(group, individual: false)
                            if expanded.contains(group["id"].string) { ForEach(group["processes"].array, id: \.self["id"]) { activityRow($0, individual: true) } }
                        }
                        if displayed.isEmpty { Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No open apps" : "No match").font(Theme.ui(12)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 28).padding(.vertical, 16).overlay(alignment: .top) { Theme.rule.frame(height: 1) } }
                    }.opacity(fresh ? 1 : 0.55).onHover { hover = $0; updateFreeze() }.focusable().focused($tableFocused)
                        .onChange(of: tableFocused) { _, _ in updateFreeze() }.onChange(of: focusedControl) { _, _ in updateFreeze() }
                }.frame(width: max(580, contentWidth))
            }
            Theme.rule.frame(height: 1)
        }
    }
    private func sortHeading(_ title: String, key: String) -> some View {
        let active = sort == key || key == "disk" && ["read", "write"].contains(sort)
        return Button { if sort == key { descending.toggle() } else { sort = key } } label: {
            HStack(spacing: 4) { Text(title); if active { NativeIcon(descending ? "arrow-down" : "arrow-up", size: 12) } }
                .foregroundStyle(active ? Theme.ink : Theme.muted)
        }.buttonStyle(.plain).padding(.trailing, key == "name" ? 0 : 12).help("Sort by \(title)").accessibilityLabel("Sort by \(title)").accessibilityValue(active ? descending ? "Descending" : "Ascending" : "Not sorted")
    }
    private var tableCaption: some View { Text(held != nil ? "Row order held" : paused ? "Paused" : "").foregroundStyle(paused ? Theme.warnFg : Theme.muted) }
    private var sampleStamp: some View {
        Text(snapshot["timestamp"].isNull ? "" : Date(timeIntervalSince1970: snapshot["timestamp"].double / 1000).formatted(.dateTime.hour().minute().second()))
    }
    private func errorFeedback(_ message: String) -> some View {
        HStack { NativeError(message: message); Button("Retry") { Task { await reload(force: true) } } }
    }
    private func activityDetails(_ captured: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(captured["name"].string).font(Theme.ui(Theme.textBase, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    detailRow("CPU, whole Mac", percent(captured["cpuPercent"]))
                    detailRow("Memory", bytes(captured["memoryBytes"]) + " / " + percent(captured["memoryPercent"]))
                    detailRow("Disk reads", rate(captured["readPerSecond"]))
                    detailRow("Disk writes", rate(captured["writePerSecond"]))
                    if captured["processes"].isNull {
                        detailRow("Process / parent", "\(captured["pid"].int) / \(captured["ppid"].int)")
                        detailRow("Threads", captured["threads"].isNull ? "—" : captured["threads"].string)
                        detailRow("Memory source", captured["memoryKind"].string)
                    } else {
                        detailRow("Bundle", captured["bundleId"].string.isEmpty ? "Background process" : captured["bundleId"].string)
                        detailRow("Processes", String(captured["processes"].array.count))
                    }
                    if captured["partial"].bool || captured["memoryKind"].string == "resident" { Text("Some readings are unavailable or use resident memory as a fallback. Missing counters remain unavailable.").foregroundStyle(Theme.muted) }
                    if !captured["protectedReason"].isNull { Text(captured["protectedReason"].string).foregroundStyle(Theme.warnFg) }
                    let members = captured["processes"].isNull ? [captured] : captured["processes"].array
                    ForEach(members, id: \.self["id"]) { row in Text("PID \(row["pid"].int) · \(row["memoryKind"].string) · \(row["path"].string)").font(Theme.mono(10)).foregroundStyle(Theme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                }.font(Theme.ui(12)).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 430)
            HStack { Spacer(); Button("Done") { details = nil }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 560).background(Theme.bg)
    }
    private func detailRow(_ title: String, _ value: String) -> some View { HStack(alignment: .top, spacing: 20) { Text(title).foregroundStyle(Theme.muted); Spacer(minLength: 0); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) } }
    private var selection: JSONValue? { guard let selected else { return nil }; return snapshot["groups"].array.first { $0["id"].string == selected } ?? snapshot["groups"].array.flatMap { $0["processes"].array }.first { $0["id"].string == selected } }
    private var canAct: Bool { !runtime.paths.readOnly && fresh && !acting && selection != nil && selection!["protectedReason"].isNull }
    private func column(_ text: String, width: CGFloat) -> some View { Text(text).padding(.trailing, 12).frame(width: width, alignment: .trailing) }
    private func activityRow(_ row: JSONValue, individual: Bool) -> some View {
        let exited = row["exited"].bool
        return NativeActivityRowSurface(selected: selected == row["id"].string, individual: individual, exited: exited) {
            HStack(spacing: 0) {
                HStack(spacing: 9) {
                    if !individual { Button { if !expanded.insert(row["id"].string).inserted { expanded.remove(row["id"].string) } } label: { NativeIcon(expanded.contains(row["id"].string) ? "chevron-down" : "chevron-right", size: 12).frame(width: 22, height: 28) }.buttonStyle(.plain).focused($focusedControl, equals: "expand:" + row["id"].string).accessibilityLabel("\(expanded.contains(row["id"].string) ? "Collapse" : "Expand") \(row["name"].string)") }
                    else { Color.clear.frame(width: 22, height: 1) }
                    if !individual { NativeIcon(row["kind"].string == "app" ? "app-window" : "cpu", size: 15).foregroundStyle(Theme.muted).frame(width: 20, height: 30).background(Color.clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd)).overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Color.clear, lineWidth: 1) } }
                    Button { selected = row["id"].string } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text(row["name"].string).lineLimit(1).font(Theme.ui(individual ? Theme.textXs : Theme.textSm, weight: individual ? .regular : .medium))
                                if !row["protectedReason"].isNull { NativeIcon("lock", size: 10).help(row["protectedReason"].string) }
                                if row["partial"].bool || row["memoryKind"].string == "resident" { NativeIcon("info", size: 10).help("Partial or resident-memory fallback") }
                                if exited { Text("Exited").foregroundStyle(Theme.muted) }
                            }
                            Text(individual ? row["pid"].string : row["kind"].string == "app" ? "\(row["processes"].array.count) \(row["processes"].array.count == 1 ? "process" : "processes")" : "Background").font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).focused($focusedControl, equals: "select:" + row["id"].string).disabled(exited)
                }.padding(.leading, individual ? 14 : 0).padding(.trailing, 12).frame(maxWidth: .infinity, alignment: .leading)
                meter(fresh ? row["cpuPercent"] : .null, width: 86, color: Theme.accent).padding(.horizontal, 12).frame(width: 110)
                VStack(alignment: .trailing, spacing: 2) { meter(fresh ? row["memoryPercent"] : .null, width: 118, color: Theme.ink); Text(bytes(fresh ? row["memoryBytes"] : .null)).font(Theme.num(10, weight: .regular)).foregroundStyle(Theme.muted) }.padding(.horizontal, 12).frame(width: 142)
                Text(rate(fresh ? diskRate(row) : .null)).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).padding(.horizontal, 12).frame(width: 108, alignment: .trailing)
                Button { selected = row["id"].string; action = confirmation(row, mode: "force", individual: individual) } label: { NativeIcon("x", size: 10) }.buttonStyle(.plain).frame(width: 42, height: 28).focused($focusedControl, equals: "force:" + row["id"].string).disabled(runtime.paths.readOnly || !fresh || acting || exited || !row["protectedReason"].isNull).accessibilityLabel("Force quit \(row["name"].string)").help(row["protectedReason"].isNull ? "Force quit" : row["protectedReason"].string)
            }.frame(minHeight: individual ? 36 : 48)
        }
    }
    private func meter(_ value: JSONValue, width: CGFloat, color: Color) -> some View {
        ZStack(alignment: .trailing) { GeometryReader { geometry in if !value.isNull { HStack(spacing: 0) { Spacer(minLength: 0); RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color.opacity(0.12)).frame(width: geometry.size.width * max(0, min(1, value.double / 100))) } } }; Text(value.isNull ? "—" : percent(value)).font(Theme.mono(12)).padding(.horizontal, 7) }.frame(width: width, height: 35)
    }
    private func overview(_ title: String, value: JSONValue, points: [(Date, Double?)], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    NativeIcon(title == "CPU" ? "cpu" : "memory-stick", size: 13).foregroundStyle(Theme.faint)
                    Text(title).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                    Spacer(minLength: 8)
                    if title == "CPU" { if !fresh || paused { Text(!fresh ? "No readings" : "Paused").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.warnFg) } }
                    else if !["", "normal", "nominal"].contains(snapshot["pressure"].string) { Text(snapshot["pressure"].string.capitalized + " pressure").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(snapshot["pressure"].string == "critical" ? Theme.failFg : Theme.warnFg) }
                }
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        NativeNumberText(text: value.isNull || !fresh ? "—" : String(format: "%.1f%%", value.double), font: Theme.num(30), isolateLayout: true)
                        Text(title == "CPU" ? "\(snapshot["logicalCpus"].int) cores" : "\(bytes(snapshot["memoryUsed"])) of \(bytes(snapshot["totalMemory"]))").font(Theme.ui(11)).foregroundStyle(Theme.muted).lineSpacing(3)
                    }.frame(minWidth: 110, alignment: .leading)
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Chart {
                                ForEach([0, 50, 100], id: \.self) { level in RuleMark(y: .value("Grid", level)).foregroundStyle(Theme.border).lineStyle(StrokeStyle(lineWidth: 0.7)) }
                                ForEach(Array(points.enumerated()), id: \.offset) { index, point in if let reading = point.1 { LineMark(x: .value("Time", point.0), y: .value("Percent", reading), series: .value("Segment", segment(points, index))).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.65)) } }
                            }.chartYScale(domain: 0...100).chartXScale(domain: Date().addingTimeInterval(-120)...Date()).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                            VStack { Text("100"); Spacer(minLength: 0); Text("0") }.font(Theme.num(9, weight: .regular)).foregroundStyle(Theme.faint)
                        }
                        HStack { Text("2 min"); Spacer(); Text("now") }.font(Theme.num(9, weight: .regular)).foregroundStyle(Theme.faint)
                    }.frame(height: 78)
                }
            }.padding(16)
        }.frame(maxWidth: .infinity, alignment: .topLeading)
            .overlay(alignment: title == "CPU" ? .trailing : .leading) { if title == "CPU" { Theme.rule.frame(width: 1) } }
            .overlay(alignment: .top) { if title != "CPU" { Theme.rule.frame(height: 1).opacity(contentWidth >= 620 ? 0 : 1) } }
    }
    private func segment(_ points: [(Date, Double?)], _ index: Int) -> Int { NativeHardwareDisplayPolicies.activityHistorySegments(points.map { (time: $0.0.timeIntervalSince1970 * 1000, value: $0.1) })[index] }
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
    private func request(mode: String) { guard canAct, let selection else { return }; action = confirmation(selection, mode: mode, individual: selection["processes"].isNull) }
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

private struct NativeActivityRowSurface<Content: View>: View {
    let selected: Bool, individual: Bool, exited: Bool
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 0) {
            Theme.rule.frame(height: 1)
            content()
        }.background(selected ? Theme.raised : hovering ? Theme.subtle : .clear)
            .overlay(alignment: .leading) { Theme.accent.frame(width: 2).opacity(selected ? 1 : 0) }
            .opacity(exited ? 0.45 : 1).onHover { hovering = $0 }
    }
}
