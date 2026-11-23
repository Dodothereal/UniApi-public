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
        NativePage(title: "Activity", maxWidth: .infinity, readiness: pageReadiness, scrolls: false, tabs: {
            NativeTabs(options: [("apps", "Apps"), ("all", "All processes")], selection: view) { view = $0 }
        }, actions: {
            searchField.frame(width: 200)
            NativeMenuSelectLabel(title: "\(interval) s") {
                Button("1 s") { interval = 1 }; Button("2 s") { interval = 2 }; Button("5 s") { interval = 5 }
            }.fixedSize().help("Sampling interval").accessibilityLabel("Sampling interval")
            T3IconButton(system: paused ? "play" : "pause", help: paused ? "Resume" : "Pause", active: paused) { paused.toggle() }
            T3IconButton(system: "info", help: "How Activity measures") { information = true }
        }) {
            NativeInspectorSplit(open: selection != nil, width: 340, onClose: { selected = nil }, main: { activityContent }, inspector: {
                if let selection { inspector(selection) }
            })
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
        if status.isNull || snapshot.isNull && status["supported"].bool && status["installed"].bool {
            NativePane(centered: false) {
                if let error { errorFeedback(error) }
                if !status["error"].string.isEmpty { errorFeedback(status["error"].string) }
                if error == nil && status["error"].string.isEmpty { ShimmerText(text: "Loading…") }
            }
        } else if !status["supported"].bool {
            NativePane(centered: false) { NativeEmptyState(title: "Mac only", detail: "Activity reads macOS process telemetry.", icon: "activity") }
        } else if !status["installed"].bool {
            NativePane(centered: false) { NativeEmptyState(title: "Helper not built", detail: "Build the local Activity helper, then reload. No administrator password is needed.", icon: "activity") }
        } else {
            GeometryReader { geometry in
                VStack(alignment: .leading, spacing: 0) {
                    loadStrip(compact: geometry.size.width < 640)
                    if let error { errorFeedback(error).padding(.horizontal, density.pageMargin).padding(.vertical, 8) }
                    if !status["error"].string.isEmpty { errorFeedback(status["error"].string).padding(.horizontal, density.pageMargin).padding(.vertical, 8) }
                    if let notice {
                        HStack(spacing: 12) {
                            Text(notice).font(Theme.ui(12)).foregroundStyle(Theme.dim).textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
                            Spacer(minLength: 0)
                            T3IconButton(system: "x", help: "Dismiss message", size: 12) { self.notice = nil }
                        }.padding(.horizontal, density.pageMargin).frame(height: 36)
                            .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
                    }
                    activityTable
                    HStack(spacing: 12) { tableCaption; Spacer(minLength: 12); sampleStamp }
                        .font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, density.pageMargin).frame(height: 28)
                        .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
                }
                .onChange(of: geometry.size.width, initial: true) { _, width in contentWidth = max(0, width - 2 * density.pageMargin) }
            }
        }
    }
    /// The whole Mac in one band: what the table below adds up to.
    private func loadStrip(compact: Bool) -> some View {
        HStack(spacing: 0) {
            load("CPU", value: snapshot["cpuPercent"], detail: "\(snapshot["logicalCpus"].int) cores", points: history.map { ($0.time, $0.cpu) }, color: Theme.accent,
                 flag: !fresh ? "No readings" : paused ? "Paused" : "")
            Theme.rule.frame(width: 1).padding(.vertical, 12)
            load("Memory", value: snapshot["memoryPercent"], detail: "\(bytes(snapshot["memoryUsed"])) of \(bytes(snapshot["totalMemory"]))", points: history.map { ($0.time, $0.memory) }, color: Theme.ink,
                 flag: ["", "normal", "nominal"].contains(snapshot["pressure"].string) ? "" : snapshot["pressure"].string.capitalized + " pressure")
                .padding(.leading, 20)
            if !compact {
                Theme.rule.frame(width: 1).padding(.vertical, 12)
                VStack(alignment: .leading, spacing: 5) {
                    fact("Processes", "\(snapshot["processCount"].int)")
                    fact("Compressed", bytes(snapshot["compressedBytes"]))
                    fact("Swap", bytes(snapshot["swapUsed"]))
                }.frame(width: 168).padding(.leading, 20)
                    .help("\(snapshot["sampledCount"].int) comparable samples, \(snapshot["omitted"].int) unavailable")
            }
        }
        .padding(.horizontal, density.pageMargin).frame(height: 84)
        .overlay(alignment: .bottom) { Theme.border.frame(height: 1) }
    }
    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.ui(11)).foregroundStyle(Theme.muted)
            Spacer(minLength: 4)
            Text(value).font(Theme.num(11, weight: .medium)).foregroundStyle(Theme.dim)
        }
    }
    private func load(_ title: String, value: JSONValue, detail: String, points: [(Date, Double?)], color: Color, flag: String) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                    if !flag.isEmpty { Text(flag).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.warnFg) }
                }
                NativeNumberText(text: value.isNull || !fresh ? "—" : String(format: "%.1f%%", value.double), font: Theme.num(24), isolateLayout: true)
                Text(detail).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).lineLimit(1)
            }.frame(width: 128, alignment: .leading)
            Chart {
                ForEach([0, 50, 100], id: \.self) { level in RuleMark(y: .value("Grid", level)).foregroundStyle(Theme.rule).lineStyle(StrokeStyle(lineWidth: 0.7)) }
                ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                    if let reading = point.1 {
                        LineMark(x: .value("Time", point.0), y: .value("Percent", reading), series: .value("Segment", segment(points, index)))
                            .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)).interpolationMethod(.monotone)
                    }
                }
            }.chartYScale(domain: 0...100).chartXScale(domain: Date().addingTimeInterval(-120)...Date()).chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .frame(height: 44).padding(.trailing, 20)
                .accessibilityLabel(title + " over the last two minutes")
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var searchField: some View {
        T3Field(placeholder: "Filter", text: $search, leadingIcon: "search").accessibilityLabel("Filter apps or process IDs")
    }
    private var activityTable: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    sortHeading("Name", key: "name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
                    sortHeading("CPU", key: "cpu").frame(width: 110, alignment: .trailing)
                    sortHeading("Memory", key: "memory").frame(width: 142, alignment: .trailing)
                    HStack(spacing: 2) {
                        sortHeading("Disk I/O", key: "disk")
                        Menu { Button("Disk I/O") { sort = "disk" }; Button("Disk read") { sort = "read" }; Button("Disk write") { sort = "write" } } label: { NativeIcon("chevron-down", size: 10) }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().accessibilityLabel("Disk column")
                    }.frame(width: 108, alignment: .trailing)
                    Color.clear.frame(width: 24)
                }.font(Theme.ui(11, weight: .medium)).foregroundStyle(Theme.muted).frame(height: 32)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(displayed, id: \.self["id"]) { group in activityRow(group, individual: false) }
                        if displayed.isEmpty {
                            Theme.rule.frame(height: 1)
                            Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No open apps" : "No match")
                                .font(Theme.ui(12)).foregroundStyle(Theme.faint).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 16)
                        }
                    }.opacity(fresh ? 1 : 0.55).onHover { hover = $0; updateFreeze() }.focusable().focusEffectDisabled().focused($tableFocused)
                        .onChange(of: tableFocused) { _, _ in updateFreeze() }.onChange(of: focusedControl) { _, _ in updateFreeze() }
                }.scrollContentBackground(.hidden)
            }
            .padding(.horizontal, density.pageMargin)
            .frame(width: max(560, contentWidth) + 2 * density.pageMargin)
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
    /// Everything about the selected app or process, and the only place it can be quit.
    private func inspector(_ row: JSONValue) -> some View {
        let group = !row["processes"].isNull
        let parent = group ? nil : snapshot["groups"].array.first { $0["processes"].array.contains { $0["id"].string == row["id"].string } }
        return NativeInspector(title: row["name"].string,
                               caption: group ? (row["bundleId"].string.isEmpty ? "Background" : row["bundleId"].string) : "PID \(row["pid"].int)",
                               icon: group && row["kind"].string == "app" ? "app-window" : "cpu", onClose: { selected = nil }) {
            if let parent {
                Button { selected = parent["id"].string } label: {
                    HStack(spacing: 5) { NativeIcon("arrow-left", size: 12); Text(parent["name"].string) }.font(Theme.ui(Theme.textXs, weight: .medium))
                }.buttonStyle(.plain).foregroundStyle(Theme.link).pointingHand().accessibilityLabel("Back to " + parent["name"].string)
            }
            if !row["protectedReason"].isNull {
                HStack(spacing: 6) { NativeIcon("lock", size: 12); Text(row["protectedReason"].string) }
                    .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.warnFg).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                NativeFact(label: "CPU", value: percent(fresh ? row["cpuPercent"] : .null))
                NativeFact(label: "Memory", value: bytes(fresh ? row["memoryBytes"] : .null) + " · " + percent(fresh ? row["memoryPercent"] : .null))
                NativeFact(label: "Disk read", value: rate(fresh ? row["readPerSecond"] : .null))
                NativeFact(label: "Disk write", value: rate(fresh ? row["writePerSecond"] : .null))
                if !group {
                    NativeFact(label: "Parent", value: "PID \(row["ppid"].int)")
                    NativeFact(label: "Threads", value: row["threads"].isNull ? "—" : row["threads"].string)
                    NativeFact(label: "Memory source", value: row["memoryKind"].string)
                }
            }
            if row["partial"].bool || row["memoryKind"].string == "resident" {
                Text("Some readings are unavailable or fall back to resident memory.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if group {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(row["processes"].array.count) " + (row["processes"].array.count == 1 ? "process" : "processes"))
                        .font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted).padding(.bottom, 6)
                    ForEach(row["processes"].array, id: \.self["id"]) { process in
                        Theme.rule.frame(height: 1)
                        Button { selected = process["id"].string } label: {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(process["name"].string).font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                                    Text(process["pid"].string).font(Theme.num(10.5, weight: .regular)).foregroundStyle(Theme.muted)
                                }
                                Spacer(minLength: 6)
                                Text(percent(fresh ? process["cpuPercent"] : .null)).frame(width: 52, alignment: .trailing)
                                Text(bytes(fresh ? process["memoryBytes"] : .null)).frame(width: 68, alignment: .trailing)
                                NativeIcon("chevron-right", size: 11).foregroundStyle(Theme.faint)
                            }.font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.dim).frame(minHeight: 38).contentShape(Rectangle())
                        }.buttonStyle(.plain).pointingHand().opacity(process["exited"].bool ? 0.45 : 1)
                            .accessibilityLabel(process["name"].string + ", process " + process["pid"].string)
                    }
                    Theme.rule.frame(height: 1)
                }
            } else if !row["path"].string.isEmpty {
                Text(row["path"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Quit") { request(mode: "quit") }.buttonStyle(T3Button(.outline)).disabled(!canAct)
            Button("Force quit") { request(mode: "force") }.buttonStyle(T3Button(.destructive)).disabled(!canAct)
        }
    }
    private var selection: JSONValue? { guard let selected else { return nil }; return snapshot["groups"].array.first { $0["id"].string == selected } ?? snapshot["groups"].array.flatMap { $0["processes"].array }.first { $0["id"].string == selected } }
    private var canAct: Bool { !runtime.paths.readOnly && fresh && !acting && selection != nil && selection!["protectedReason"].isNull }
    private func column(_ text: String, width: CGFloat) -> some View { Text(text).padding(.trailing, 12).frame(width: width, alignment: .trailing) }
    private func activityRow(_ row: JSONValue, individual: Bool) -> some View {
        let exited = row["exited"].bool
        return NativeActivityRowSurface(selected: selected == row["id"].string, individual: individual, exited: exited) {
            Button { selected = selected == row["id"].string ? nil : row["id"].string } label: {
                HStack(spacing: 0) {
                    HStack(spacing: 10) {
                        NativeIcon(row["kind"].string == "app" ? "app-window" : "cpu", size: 15).foregroundStyle(Theme.muted).frame(width: 20).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Text(row["name"].string).lineLimit(1).font(Theme.ui(Theme.textSm, weight: .medium))
                                if !row["protectedReason"].isNull { NativeIcon("lock", size: 10).foregroundStyle(Theme.muted).help(row["protectedReason"].string) }
                                if exited { Text("Exited").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
                            }
                            Text(row["kind"].string == "app" ? "\(row["processes"].array.count) \(row["processes"].array.count == 1 ? "process" : "processes")" : "Background")
                                .font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted)
                        }
                    }.padding(.trailing, 12).frame(maxWidth: .infinity, alignment: .leading)
                    meter(fresh ? row["cpuPercent"] : .null, width: 86, color: Theme.accent).padding(.horizontal, 12).frame(width: 110)
                    VStack(alignment: .trailing, spacing: 2) {
                        meter(fresh ? row["memoryPercent"] : .null, width: 118, color: Theme.ink)
                        Text(bytes(fresh ? row["memoryBytes"] : .null)).font(Theme.num(10, weight: .regular)).foregroundStyle(Theme.muted)
                    }.padding(.horizontal, 12).frame(width: 142)
                    Text(rate(fresh ? diskRate(row) : .null)).font(Theme.num(11, weight: .regular)).foregroundStyle(Theme.muted).padding(.horizontal, 12).frame(width: 108, alignment: .trailing)
                    NativeIcon("chevron-right", size: 12).foregroundStyle(selected == row["id"].string ? Theme.ink : Theme.faint).frame(width: 24).accessibilityHidden(true)
                }.frame(minHeight: 48).contentShape(Rectangle())
            }.buttonStyle(.plain).focused($focusedControl, equals: "select:" + row["id"].string).disabled(exited)
                .accessibilityLabel(row["name"].string).accessibilityAddTraits(selected == row["id"].string ? [.isSelected] : [])
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
