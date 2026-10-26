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
        NativePage(title: "Activity", subtitle: "A clearer view of what your Mac is using.", maxWidth: 1500, readiness: pageReadiness, actions: {
            HStack(spacing: 8) {
                Menu {
                    Button("1 s") { interval = 1 }; Button("2 s") { interval = 2 }; Button("5 s") { interval = 5 }
                } label: { HStack(spacing: 6) { Text("\(interval) s"); NativeIcon("chevron-down", size: 12) }.font(Theme.ui(12)).padding(.horizontal, 10).frame(height: 30).background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd)).overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1) } }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("Refresh frequency")
                Button { paused.toggle() } label: { HStack(spacing: 6) { NativeIcon(paused ? "play" : "pause", size: 12); Text(paused ? "Resume" : "Pause") }.frame(width: 66) }
                Button { Task { await reload(force: true) } } label: { NativeIcon("refresh-cw", size: 13) }.help("Refresh").accessibilityLabel("Refresh")
                Button { information = true } label: { NativeIcon("info", size: 14) }.buttonStyle(T3Button(.ghost)).help("How Activity measurements work").accessibilityLabel("How Activity measurements work")
            }
        }) {
            activityContent
        }
        .onChange(of: max(0, min(1500, viewport.size.width) - 2 * density.pageMargin), initial: true) { _, width in contentWidth = width }
        }
        .nativePageTask(id: "\(interval):\(paused)") {
            guard !paused else { return }
            while !Task.isCancelled { await reload(); do { try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000) } catch { return } }
        }
        .nativePageActivity(reads: reads, suspended: { hover = false; tableFocused = false; focusedControl = nil; resetFreeze() })
        .onChange(of: search) { _, _ in resetFreeze() }.onChange(of: sort) { _, new in descending = new != "name"; resetFreeze() }.onChange(of: descending) { _, _ in resetFreeze() }.onChange(of: view) { _, _ in resetFreeze() }
        .sheet(isPresented: $information) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Activity measurements").font(Theme.ui(18, weight: .semibold))
                Text("CPU is a share of all logical cores. Counters are converted from Mach ticks before comparing elapsed time. The first sample and gaps have no rate.")
                Text("Memory uses physical footprint where available, then resident memory with a visible fallback marker. Reclaimable file cache and purgeable pages are excluded from the whole-Mac memory total.")
                Text("Helpers belong to a living app through ancestry or an unambiguous bundle path. Shared system hosts stay separate. Row order holds while the table has pointer or keyboard focus; exited rows remain disabled until it releases.")
                Button("Done") { information = false }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 580).background(Theme.bg)
        }
        .sheet(isPresented: Binding(get: { !action.isNull }, set: { if !$0 { action = .null } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text(action["mode"].string == "force" ? "Force quit selected activity?" : "Quit selected activity?").font(Theme.ui(18, weight: .semibold))
                Text("\(action["name"].string) · \(action["count"].int) \(action["count"].int == 1 ? "process" : "processes")").font(Theme.ui(13, weight: .medium))
                Text(action["mode"].string == "force" ? "Force quit can discard unsaved work." : "A normal quit lets the application ask to save its work.")
                HStack { Button("Cancel") { action = .null }.keyboardShortcut(.defaultAction); Spacer(); Button(action["mode"].string == "force" ? "Force quit" : "Quit", role: .destructive) { let pending = action; action = .null; Task { await terminate(pending) } } }
            }.padding(24).frame(width: 500).background(Theme.bg)
        }
    }
    @ViewBuilder private var activityContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let error { errorFeedback(error) }
            if !status["error"].string.isEmpty { errorFeedback(status["error"].string) }
            if status.isNull {
                if error == nil { ShimmerText(text: "Reading your Mac's activity…").padding(.vertical, 48) }
            } else if !status["supported"].bool {
                NativeEmptyState(title: "Made for Mac", detail: "Activity uses macOS process telemetry and is available on Mac only.", icon: "activity")
            } else if !status["installed"].bool {
                NativeEmptyState(title: "Activity needs its local helper", detail: "Build the local Activity helper, then reload this page. No administrator password is needed.", icon: "activity")
            } else if snapshot.isNull {
                if error == nil && status["error"].string.isEmpty {
                    ShimmerText(text: "Reading your Mac's activity…").padding(.vertical, 48)
                }
            } else {
                if contentWidth >= 620 {
                    HStack(alignment: .top, spacing: 14) { overviewCards }
                } else { VStack(spacing: 14) { overviewCards } }
                Group {
                    if contentWidth >= 620 { HStack(spacing: 12) { contextLabels } }
                    else { VStack(alignment: .leading, spacing: 8) { contextLabels } }
                }.font(Theme.ui(11)).foregroundStyle(Theme.dim).padding(.top, -8)
                if contentWidth >= 620 {
                    HStack(spacing: 12) { scopePicker; Spacer(minLength: 12); searchField.frame(width: 300) }
                } else { VStack(alignment: .leading, spacing: 12) { scopePicker; searchField } }
                VStack(alignment: .leading, spacing: 12) {
                    if contentWidth >= 620 { HStack(spacing: 12) { selectionTitle; Spacer(minLength: 8); selectionActions } }
                    else { VStack(alignment: .leading, spacing: 10) { selectionTitle; HStack { Spacer(minLength: 0); selectionActions } } }
                }.padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 62).background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd)).padding(.top, -6)
                if let notice {
                    HStack(spacing: 12) {
                        Text(notice).font(Theme.ui(12)).foregroundStyle(Theme.dim).textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
                        Spacer(minLength: 0)
                        Button { self.notice = nil } label: { NativeIcon("x", size: 12) }.buttonStyle(T3Button(.ghost)).accessibilityLabel("Dismiss message")
                    }.padding(12).background(Theme.subtle, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
                }
                activityTable
                if contentWidth < 580 {
                    Text("Scroll horizontally for memory, disk and actions.").font(Theme.ui(11)).foregroundStyle(Theme.muted)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { tableCaption; Spacer(minLength: 12); sampleStamp }
                    VStack(alignment: .leading, spacing: 4) { tableCaption; sampleStamp }
                }.font(Theme.ui(10.5)).foregroundStyle(Theme.muted).padding(.top, -10)
                Text("Percentages use the whole Mac. Memory uses physical footprint when available; shared and system memory mean app rows do not add up to the total. A dash means no comparable or accessible measurement, never zero usage.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true).padding(.top, -8)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .sheet(item: $details) { item in activityDetails(item.value) }
    }
    @ViewBuilder private var overviewCards: some View {
        overview("CPU", value: snapshot["cpuPercent"], points: history.map { ($0.time, $0.cpu) }, color: Theme.accent)
        overview("Memory", value: snapshot["memoryPercent"], points: history.map { ($0.time, $0.memory) }, color: Theme.ok)
    }
    @ViewBuilder private var contextLabels: some View {
        Text("\(snapshot["processCount"].int) processes · \(snapshot["sampledCount"].int) comparable samples · \(snapshot["omitted"].int) unavailable")
        if contentWidth >= 620 { Spacer(minLength: 8) }
        Text("Compressed \(bytes(snapshot["compressedBytes"])) · Swap \(bytes(snapshot["swapUsed"]))")
    }
    private var scopePicker: some View { T3Segmented(options: [("apps", "Apps"), ("all", "All activity")], selection: view) { view = $0 } }
    private var searchField: some View {
        HStack(spacing: 8) {
            NativeIcon("search", size: 14).foregroundStyle(Theme.muted)
            TextField("Search apps or process IDs", text: $search).textFieldStyle(.plain).font(Theme.ui(12)).accessibilityLabel("Search apps or process IDs")
            if !search.isEmpty { Button { search = "" } label: { NativeIcon("x", size: 12) }.buttonStyle(.plain).accessibilityLabel("Clear search") }
        }.padding(.horizontal, 10).frame(height: 34).background(Theme.field, in: RoundedRectangle(cornerRadius: Theme.radiusMd)).overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.input, lineWidth: 1) }
    }
    private var selectionTitle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection?["name"].string ?? (selected == nil ? "Select an app to manage it" : "This selection has exited")).font(Theme.ui(12.5, weight: .medium)).lineLimit(1)
            Text(selection.map { !$0["protectedReason"].isNull ? $0["protectedReason"].string : $0["processes"].isNull ? "PID \($0["pid"].int)" : "\($0["processes"].array.count) processes grouped together" } ?? "Or use the × on any row to force quit").font(Theme.ui(11)).foregroundStyle(Theme.muted).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var selectionActions: some View {
        HStack(spacing: 6) {
            Button { if let selection { details = NativePresentedValue(value: selection) } } label: { NativeIcon("info", size: 14) }.buttonStyle(T3Button(.ghost)).disabled(selection == nil).help("Selection details").accessibilityLabel("Selection details")
            Button("Quit") { request(mode: "quit") }.disabled(!canAct)
            Button("Force quit") { request(mode: "force") }.buttonStyle(T3Button(.destructive)).disabled(!canAct)
        }.fixedSize()
    }
    private var activityTable: some View {
        Card(padding: 0) {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        sortHeading("Name", key: "name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 20)
                        sortHeading("CPU", key: "cpu").frame(width: 110, alignment: .trailing)
                        sortHeading("Memory", key: "memory").frame(width: 142, alignment: .trailing)
                        HStack(spacing: 2) {
                            sortHeading("Disk I/O", key: "disk")
                            Menu { Button("Disk I/O") { sort = "disk" }; Button("Disk read") { sort = "read" }; Button("Disk write") { sort = "write" } } label: { NativeIcon("chevron-down", size: 10) }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("Additional disk sort options")
                        }.frame(width: 108, alignment: .trailing)
                        Color.clear.frame(width: 42)
                    }.font(Theme.ui(11.5, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 38).background(Theme.surface)
                    LazyVStack(spacing: 0) {
                        ForEach(displayed, id: \.self["id"]) { group in
                            activityRow(group, individual: false)
                            if expanded.contains(group["id"].string) { ForEach(group["processes"].array, id: \.self["id"]) { activityRow($0, individual: true) } }
                        }
                        if displayed.isEmpty { Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No open apps were found." : "No apps or processes match your search.").font(Theme.ui(12)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.vertical, 44) }
                    }.opacity(fresh ? 1 : 0.55).onHover { hover = $0; updateFreeze() }.focusable().focused($tableFocused)
                        .onChange(of: tableFocused) { _, _ in updateFreeze() }.onChange(of: focusedControl) { _, _ in updateFreeze() }
                }.frame(width: max(580, contentWidth))
            }
        }.padding(.top, -8)
    }
    private func sortHeading(_ title: String, key: String) -> some View {
        let active = sort == key || key == "disk" && ["read", "write"].contains(sort)
        return Button { if sort == key { descending.toggle() } else { sort = key } } label: {
            HStack(spacing: 4) { Text(title); if active { NativeIcon(descending ? "arrow-down" : "arrow-up", size: 12) } }
                .foregroundStyle(active ? Theme.ink : Theme.muted)
        }.buttonStyle(.plain).padding(.trailing, key == "name" ? 0 : 12).help("Sort by \(title)").accessibilityLabel("Sort by \(title)").accessibilityValue(active ? descending ? "Descending" : "Ascending" : "Not sorted")
    }
    private var tableCaption: some View { Text(held != nil ? "Row positions held while you use the list." : paused ? "Readings paused. Resume to see changes." : "Live readings. Expand an app to see its processes.") }
    private var sampleStamp: some View {
        Text(snapshot["timestamp"].isNull ? "Sample time unavailable" : "Sampled " + Date(timeIntervalSince1970: snapshot["timestamp"].double / 1000).formatted(.dateTime.hour().minute().second()))
    }
    private func errorFeedback(_ message: String) -> some View {
        HStack { NativeError(message: message); Button("Retry") { Task { await reload(force: true) } } }
    }
    private func activityDetails(_ captured: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(captured["name"].string).font(Theme.ui(18, weight: .semibold))
            Text("Details from the selected sample.").font(Theme.ui(12)).foregroundStyle(Theme.muted)
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
                    if !individual { NativeIcon(row["kind"].string == "app" ? "app-window" : "cpu", size: 15).foregroundStyle(Theme.dim).frame(width: 30, height: 30).background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radiusMd)).overlay { RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border, lineWidth: 1) } }
                    Button { selected = row["id"].string } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text(row["name"].string).lineLimit(1).font(Theme.ui(individual ? 11.5 : 12.5, weight: individual ? .regular : .medium))
                                if !row["protectedReason"].isNull { NativeIcon("lock", size: 10).help(row["protectedReason"].string) }
                                if row["partial"].bool || row["memoryKind"].string == "resident" { NativeIcon("info", size: 10).help("Partial or resident-memory fallback") }
                                if exited { Text("Exited").foregroundStyle(Theme.muted) }
                            }
                            Text(individual ? row["pid"].string : row["kind"].string == "app" ? "\(row["processes"].array.count) \(row["processes"].array.count == 1 ? "process" : "processes")" : "Background").font(Theme.ui(10.5)).foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading).focused($focusedControl, equals: "select:" + row["id"].string).disabled(exited)
                }.padding(.leading, individual ? 18 : 6).padding(.trailing, 12).frame(maxWidth: .infinity, alignment: .leading)
                meter(fresh ? row["cpuPercent"] : .null, width: 86, color: Theme.accent).padding(.horizontal, 12).frame(width: 110)
                VStack(alignment: .trailing, spacing: 2) { meter(fresh ? row["memoryPercent"] : .null, width: 118, color: Theme.ok); Text(bytes(fresh ? row["memoryBytes"] : .null)).font(Theme.mono(10)).foregroundStyle(Theme.muted) }.padding(.horizontal, 12).frame(width: 142)
                Text(rate(fresh ? diskRate(row) : .null)).font(Theme.mono(11)).foregroundStyle(Theme.muted).padding(.horizontal, 12).frame(width: 108, alignment: .trailing)
                Button { selected = row["id"].string; action = confirmation(row, mode: "force", individual: individual) } label: { NativeIcon("x", size: 10) }.buttonStyle(.plain).frame(width: 42, height: 28).focused($focusedControl, equals: "force:" + row["id"].string).disabled(runtime.paths.readOnly || !fresh || acting || exited || !row["protectedReason"].isNull).accessibilityLabel("Force quit \(row["name"].string)").help(row["protectedReason"].isNull ? "Force quit" : row["protectedReason"].string)
            }.frame(minHeight: individual ? 40 : 56)
        }
    }
    private func meter(_ value: JSONValue, width: CGFloat, color: Color) -> some View {
        ZStack(alignment: .trailing) { GeometryReader { geometry in if !value.isNull { HStack(spacing: 0) { Spacer(minLength: 0); RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.1)).frame(width: geometry.size.width * max(0, min(1, value.double / 100))) } } }; Text(value.isNull ? "—" : percent(value)).font(Theme.mono(12)).padding(.horizontal, 7) }.frame(width: width, height: 35)
    }
    private func overview(_ title: String, value: JSONValue, points: [(Date, Double?)], color: Color) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    NativeIcon(title == "CPU" ? "cpu" : "memory-stick", size: 16)
                    Text(title).font(Theme.ui(13, weight: .medium))
                    Spacer(minLength: 8)
                    if title == "CPU" { HStack(spacing: 6) { if fresh && !paused { NativeStatusDot(color: Theme.okFg, size: 5) }; Text(!fresh ? "Readings unavailable" : paused ? "Paused" : "Live") }.font(Theme.ui(11)).foregroundStyle(Theme.muted) }
                    else { Text("Pressure: " + snapshot["pressure"].string).font(Theme.ui(11)).foregroundStyle(snapshot["pressure"].string == "critical" ? Theme.failFg : ["warning", "warn"].contains(snapshot["pressure"].string) ? Theme.warnFg : Theme.muted) }
                }
                HStack(spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        NativeNumberText(text: value.isNull || !fresh ? "—" : String(format: "%.1f%%", value.double), font: Theme.ui(32, weight: .semibold), isolateLayout: true)
                        Text(title == "CPU" ? "\(snapshot["logicalCpus"].int) logical cores\n100% = the whole Mac" : "\(bytes(snapshot["memoryUsed"])) used\nof \(bytes(snapshot["totalMemory"])) installed").font(Theme.ui(11)).foregroundStyle(Theme.muted).lineSpacing(3)
                    }.frame(minWidth: 110, alignment: .leading)
                    VStack(spacing: 3) {
                        HStack(spacing: 3) {
                            Chart {
                                ForEach([0, 50, 100], id: \.self) { level in RuleMark(y: .value("Grid", level)).foregroundStyle(Theme.border).lineStyle(StrokeStyle(lineWidth: 0.7)) }
                                ForEach(Array(points.enumerated()), id: \.offset) { index, point in if let reading = point.1 { LineMark(x: .value("Time", point.0), y: .value("Percent", reading), series: .value("Segment", segment(points, index))).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.65)) } }
                            }.chartYScale(domain: 0...100).chartXScale(domain: Date().addingTimeInterval(-120)...Date()).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                            VStack { Text("100"); Spacer(minLength: 0); Text("0") }.font(Theme.ui(8)).foregroundStyle(Theme.muted)
                        }
                        HStack { Text("2 min ago"); Spacer(); Text("Now") }.font(Theme.ui(8)).foregroundStyle(Theme.muted)
                    }.frame(height: 94)
                }
            }
        }
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
            Rectangle().fill(Theme.border).frame(height: 1)
            content()
        }.background(selected ? Theme.accent.opacity(0.09) : hovering ? Theme.subtle : individual ? Theme.well : .clear)
            .opacity(exited ? 0.45 : 1).onHover { hovering = $0 }
    }
}
