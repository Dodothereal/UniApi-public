import SwiftUI
import AppKit
import Carbon.HIToolbox
import UniApiCore
import UniApiPresentation

/// Key legends for the input source in use, so the heatmap matches the keys
/// the user sees. Positions come from key codes and never change.
enum NativeKeyboardLegends {
    /// `shift` gives the characters printed in the upper half of a key.
    @MainActor static func current(shift: Bool = false) -> [Int: String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        var result: [Int: String] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in NativeKeyboardKeys.glyphs {
                var dead: UInt32 = 0, length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), shift ? 2 : 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &characters)
                guard status == noErr, length > 0 else { continue }
                let text = String(utf16CodeUnits: characters, count: length).uppercased()
                if !text.isEmpty, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespaces.contains($0) }) {
                    result[code] = text
                }
            }
        }
        return result
    }
    static func label(_ code: Int, _ legends: [Int: String]) -> String {
        NativeKeyboardLayout.named[code] ?? legends[code].map { (65...92).contains(code) ? "Num " + $0 : $0 } ?? NativeKeyboardLayout.label(code)
    }
    static func combination(_ combo: String, _ legends: [Int: String]) -> String {
        let parts = combo.split(separator: "+").map(String.init)
        guard let code = parts.last.flatMap({ Int($0) }) else { return combo }
        let symbols = ["ctrl": "\u{2303}", "opt": "\u{2325}", "shift": "\u{21E7}", "cmd": "\u{2318}"]
        return parts.dropLast().compactMap { symbols[$0] }.joined() + " " + label(code, legends)
    }
}

/// A key cap outline. `notch` cuts the lower left away below `upper`, which
/// gives the two-row Return key of ISO and JIS boards.
struct NativeKeycapShape: Shape {
    var notch: CGFloat = 0, upper: CGFloat = 0
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        guard notch > 0 else { return Path(roundedRect: box, cornerRadius: radius, style: .continuous) }
        let points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY),
                      CGPoint(x: box.minX + notch, y: box.maxY), CGPoint(x: box.minX + notch, y: box.minY + upper), CGPoint(x: box.minX, y: box.minY + upper)]
        var path = Path()
        path.move(to: CGPoint(x: box.midX, y: box.minY))
        for index in 1...points.count {
            path.addArc(tangent1End: points[index % points.count], tangent2End: points[(index + 1) % points.count], radius: radius)
        }
        path.closeSubpath()
        return path
    }
}

struct NativeKeyboardPage: View {
    let runtime: NativeRuntime
    @EnvironmentObject private var session: NativeAppSession
    @AppStorage("uniapi.keyboard.range") private var range = "7d"
    @State private var reads = NativePageReadScope()
    @State private var state: JSONValue = .null
    @State private var live: JSONValue = .null
    @State private var legends: [Int: String] = [:]
    @State private var shifted: [Int: String] = [:]
    @State private var error: String?
    @State private var pending = false
    @State private var confirmingReset = false
    @State private var hovered: Int?

    private static let ranges: [(value: String, label: String)] = [("today", "Today"), ("7d", "7 days"), ("30d", "30 days"), ("all", "All time")]
    private var totals: JSONValue { state["totals"] }
    private var enabled: Bool { state["enabled"].bool }
    private var recording: Bool { live.isNull ? state["recording"].bool : live["recording"].bool }
    private var hasKeys: Bool { totals["keys"].double > 0 }
    private var locked: Bool { pending || state["readOnly"].bool }
    private var counts: [Int: Double] { Dictionary(uniqueKeysWithValues: state["keys"].array.map { ($0["code"].int, $0["count"].double) }) }
    private var rangeTitle: String {
        switch state["range"].string {
        case "today": return "today"
        case "7d": return "in the last 7 days"
        case "30d": return "in the last 30 days"
        default: return "since recording began"
        }
    }
    private var readiness: NativePageReadiness {
        if error != nil { return .failed }
        return state.isNull ? .pending : .ready
    }
    private var eyebrow: String {
        if state.isNull { return "This Mac" }
        if recording { return "Recording on this Mac" }
        if state["readOnly"].bool { return "Read-only session" }
        return enabled ? "Waiting for Input Monitoring" : state["hasData"].bool ? "Recording paused" : "Recording off"
    }

    var body: some View {
        NativePage(title: "Keyboard Stats", eyebrow: eyebrow, readiness: readiness) {
            actions
        } content: {
            if let error { Notice(text: error, tone: .fail).accessibilityLabel("Error: " + error) }
            if !state["error"].string.isEmpty { Notice(text: state["error"].string, tone: .fail).accessibilityLabel("Error: " + state["error"].string) }
            if state.isNull {
                if error == nil { Text("Reading keyboard statistics").font(Theme.ui(12.5)).foregroundStyle(Theme.muted).padding(.vertical, 20) }
            } else if !enabled && !state["hasData"].bool {
                welcome
            } else {
                if enabled && !state["permitted"].bool { permissionNotice }
                lead
                heatmap
                if hasKeys {
                    ColumnFlow(minimum: 340, spacing: 40, rowSpacing: 28, maxColumns: 2) { topKeys; shortcuts }
                    pace
                    corrections
                    balance
                    ColumnFlow(minimum: 340, spacing: 40, rowSpacing: 28, maxColumns: 2) { rowLoad; categories }
                }
                controls
            }
        }
        .nativePageTask {
            readLegends()
            let events = await runtime.events.stream()
            await reload()
            var refreshed = Date.distantPast
            for await event in events {
                if Task.isCancelled { break }
                guard event.topic == "keyboard.state" else { continue }
                live = event.data
                // Follow live typing without rebuilding every chart per key press.
                if Date().timeIntervalSince(refreshed) >= 2 { refreshed = Date(); await reload() }
            }
        }
        .nativePageTask(id: range) { await reload() }
        .nativePageTask {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                await reload()
            }
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String))) { _ in readLegends() }
        .nativePageActivity(reads: reads)
    }

    // MARK: - Header and states

    /// The range governs everything below the lead. The one primary action
    /// is whatever recording still needs: turning it on, or the permission.
    @ViewBuilder private var actions: some View {
        if !state.isNull {
            if enabled || state["hasData"].bool { Stops(options: Self.ranges, selection: range) { range = $0 } }
            if !enabled {
                Button(state["hasData"].bool ? "Resume recording" : "Turn on keyboard statistics", nativeIcon: "play") {
                    Task { await operation("set-enabled", ["enabled": true]) }
                }.buttonStyle(Press(.primary)).disabled(locked)
            } else if !state["permitted"].bool {
                Button("Open Input Monitoring settings", nativeIcon: "external-link") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
                }.buttonStyle(Press(.primary))
            }
        }
    }

    private var welcome: some View {
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing is recorded").font(Theme.display()).foregroundStyle(Theme.ink)
                Text("Turn recording on to see where your fingers go, how fast you type and how often you correct.")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                if state["readOnly"].bool { Text("Unavailable in read-only mode.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
            }
            heatmap
            Band("What is stored", spacing: 0) {
                ColumnFlow(minimum: 340, spacing: 40, rowSpacing: 0, maxColumns: 2) {
                    promise("Counters only", "How often each key was pressed per day. Never what you typed, nor the order of keys.")
                    promise("Stays on this Mac", "Kept in UniApi's local database. Nothing is sent anywhere.")
                    promise("No password fields", "macOS does not report keys typed into password fields, so they are not counted.")
                    promise("Off until you turn it on", "Recording needs the macOS Input Monitoring permission.")
                }
            }
        }
    }
    private func promise(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            NativeIcon("check", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.okFg).offset(y: 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(13, weight: .medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) { Rule() }
        .accessibilityElement(children: .combine)
    }

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Notice(text: "Input Monitoring permission is needed. Allow UniApi under System Settings > Privacy & Security > Input Monitoring. Recording starts by itself once allowed; if it does not, quit and reopen UniApi. macOS can ask again after an update, because the app's signature changes.", tone: .warn)
            Button("Ask again") { Task { await operation("request-permission") } }.disabled(pending)
        }
    }

    // MARK: - Figures

    private func percent(_ value: Double) -> String { String(format: value < 0.1 ? "%.1f" : "%.0f", value * 100) }
    private func duration(_ milliseconds: Double) -> (String, String) {
        let seconds = milliseconds / 1000
        if seconds >= 3600 { return (String(format: "%.1f", seconds / 3600), "h") }
        if seconds >= 60 { return (String(format: "%.0f", seconds / 60), "min") }
        return (String(format: "%.0f", seconds), "s")
    }
    private func hourTitle(_ hour: Int) -> String { String(format: "%02d:00", hour) }
    private func dayTitle(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// Today, large, whatever range is chosen below; beside it what is
    /// happening now and the three figures people ask about first.
    private var lead: some View {
        let today: JSONValue = state["daily"].array.first { $0["day"].string == state["today"].string } ?? .null
        let time = duration(today["activeMs"].double), liveWpm: Double = live["wpm"].double
        let top: JSONValue = state["keys"].array.first ?? .null
        let span: String = state["range"].string == "today" ? "today" : rangeTitle.replacingOccurrences(of: "in the ", with: "")
        let todayDetail: String = today["keys"].double > 0
            ? NativeNumberFormat.decimal(today["words"].double) + " words in " + time.0 + " " + time.1 + " of typing"
            : recording ? "Start typing anywhere on this Mac" : "Nothing recorded today"
        return KeyboardLead {
            KeyboardReading(label: "Keystrokes today", value: NativeNumberFormat.decimal(today["keys"].double), unit: "keys",
                            detail: todayDetail, hero: true, tint: recording ? Theme.signal : nil)
        } rest: {
            KeyboardReading(label: "Now", value: recording ? String(format: "%.0f", liveWpm) : "--", unit: "WPM",
                            detail: liveWpm > 0 ? "typing now" : recording ? "waiting for typing" : "recording is paused", known: recording)
            KeyboardReading(label: "Streak", value: String(totals["streak"].int), unit: totals["streak"].int == 1 ? "day" : "days",
                            detail: "longest \(totals["longestStreak"].int), \(totals["days"].int) active " + span)
            KeyboardReading(label: "Peak rate", value: totals["peakWpm"].double > 0 ? String(format: "%.0f", totals["peakWpm"].double) : "--", unit: "WPM",
                            detail: "best burst " + span, known: totals["peakWpm"].double > 0)
            KeyboardReading(label: "Top key", value: top.isNull ? "--" : NativeKeyboardLegends.label(top["code"].int, legends),
                            detail: top.isNull ? span : percent(top["share"].double) + "% of all keys", known: !top.isNull)
        }
    }

    private func heat(_ count: Double, _ peak: Double) -> Double { peak > 0 && count > 0 ? (count / peak).squareRoot() : 0 }
    /// Ink density for a heat level; the legend steps use the same curve.
    private func density(_ level: Double) -> Color { level <= 0 ? .clear : Theme.ink.opacity(0.07 + 0.88 * level) }
    private var model: NativeKeyboardLayout.Model {
        let layout = state["layout"]
        return .init(standard: .init(rawValue: layout["standard"].string) ?? .ansi, form: .init(rawValue: layout["form"].string) ?? .compact,
                     apple: layout["apple"].bool, name: layout["name"].string)
    }
    /// The legend printed on a key, and the shifted character above it.
    private func legend(_ code: Int, width: CGFloat, symbols: Bool) -> (main: String, upper: String) {
        if let cap = NativeKeyboardLayout.caps[code] {
            let fits: Bool = width >= CGFloat(cap.word.count) * 7.5 + 10
            return (symbols || !fits ? cap.symbol : cap.word, "")
        }
        if let glyph = legends[code] {
            let upper: String = shifted[code] ?? ""
            return (glyph, upper == glyph ? "" : upper)
        }
        return (NativeKeyboardLayout.named[code] ?? NativeKeyboardLayout.labels[code] ?? "", "")
    }
    /// A square key on the grid. An unused key is an outline; use fills it
    /// with ink, and only the hottest key takes the signal color.
    private func keycap(_ key: NativeKeyboardLayout.Key, pitch: CGFloat, gap: CGFloat, symbols: Bool, counts: [Int: Double], peak: Double, hottest: Int?, pressed: Double) -> some View {
        let width: CGFloat = CGFloat(key.width) * pitch - gap
        let height: CGFloat = CGFloat(key.height) * pitch - gap
        let upper: CGFloat = key.notch > 0 ? pitch - gap : height
        let shape = NativeKeycapShape(notch: CGFloat(key.notch) * pitch, upper: upper, radius: 2)
        let count: Double = counts[key.code] ?? 0
        let level: Double = heat(count, peak)
        let hot: Bool = key.code == hottest
        let name: String = NativeKeyboardLegends.label(key.code, legends)
        let fill: Color = hot ? Theme.signal : density(level)
        let stroke: Color = hovered == key.code ? Theme.ink : level == 0 ? Theme.rule : Color.clear
        let ink: Color = hot ? Theme.onAccent : level > 0.45 ? Theme.onInk : level > 0 ? Theme.ink : Theme.muted
        let text = legend(key.code, width: width, symbols: symbols)
        let stacked: Bool = !text.upper.isEmpty && upper >= 34
        let word: Bool = text.main.count > 1 && text.main.unicodeScalars.allSatisfy { $0.isASCII }
        let share: String = percent(pressed > 0 ? count / pressed : 0)
        let value: String = "\(Int(count)) presses, " + share + " percent"
        let caption = VStack(spacing: 1) {
            if stacked { Text(text.upper).font(Theme.mono(10.5)).opacity(0.65) }
            if word { Text(text.main.uppercased()).font(Theme.label(9.5)).tracking(0.8) }
            else { Text(text.main).font(Theme.mono(12, weight: .medium)) }
        }.foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 3).frame(width: width, height: upper)
        return shape.fill(fill).overlay(shape.stroke(stroke, lineWidth: 1)).overlay(alignment: .top) { caption }
            .frame(width: width, height: height)
            .contentShape(shape)
            .onHover { inside in
                if inside { hovered = key.code } else if hovered == key.code { hovered = nil }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name + " key")
            .accessibilityValue(value)
            .offset(x: CGFloat(key.x) * pitch, y: CGFloat(key.y) * pitch)
    }
    /// A cap that sends no key code, drawn so the board keeps its shape.
    private func inertCap(_ key: NativeKeyboardLayout.Key, pitch: CGFloat, gap: CGFloat) -> some View {
        let width: CGFloat = CGFloat(key.width) * pitch - gap
        let height: CGFloat = CGFloat(key.height) * pitch - gap
        let shape = NativeKeycapShape(radius: 2)
        return shape.stroke(Theme.rule, lineWidth: 1)
            .overlay(Circle().strokeBorder(Theme.rule, lineWidth: 1).frame(width: min(width, height) * 0.4, height: min(width, height) * 0.4))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
            .offset(x: CGFloat(key.x) * pitch, y: CGFloat(key.y) * pitch)
    }
    private func layoutChoice(_ title: String, _ field: String, _ value: String) -> some View {
        let selected: Bool = state["layoutChoice"][field].string == value
        return Button(selected ? "\u{2713} " + title : title) { Task { await operation("set-layout", [field: .string(value)]) } }
    }
    private var layoutTitle: String {
        let model = model, choice = state["layoutChoice"]
        let chosen: Bool = ["form", "standard", "style"].contains { choice[$0].string != "auto" }
        let name: String = model.name.isEmpty ? "Keyboard" : model.name
        return [name, model.standard.title, model.form.title, model.apple ? "Apple keys" : "Third-party keys", chosen ? "chosen by you" : "detected"]
            .joined(separator: " \u{00B7} ")
    }
    private var layoutMenu: some View {
        Menu {
            Section("Size") {
                layoutChoice("Automatic", "form", "auto")
                ForEach(NativeKeyboardLayout.Form.allCases, id: \.self) { layoutChoice($0.title, "form", $0.rawValue) }
            }
            Section("Standard") {
                layoutChoice("Automatic", "standard", "auto")
                ForEach(NativeKeyboardLayout.Standard.allCases, id: \.self) { layoutChoice($0.title, "standard", $0.rawValue) }
            }
            Section("Key arrangement") {
                layoutChoice("Automatic", "style", "auto")
                layoutChoice("Apple", "style", "apple")
                layoutChoice("Third-party", "style", "other")
            }
        } label: {
            HStack(spacing: 6) {
                Text("Layout")
                NativeIcon("chevrons-up-down", size: 12, strokeWidth: 1.75).foregroundStyle(Theme.muted)
            }
            .font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.dim)
            .padding(.leading, 8).frame(height: 28).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(locked).opacity(locked ? 0.4 : 1).pointingHand(!locked)
        .accessibilityLabel("Keyboard layout")
    }
    private var heatmap: some View {
        let counts = counts, model = model
        let keys = NativeKeyboardLayout.keys(model), size = NativeKeyboardLayout.size(model)
        let board = Set(keys.map(\.code))
        let onBoard = counts.filter { board.contains($0.key) }
        let peak: Double = onBoard.values.max() ?? 0
        let hottest: Int? = peak > 0 ? onBoard.filter { $0.value == peak }.keys.min() : nil
        let pressed: Double = counts.values.reduce(0, +)
        let symbols: Bool = model.standard != .ansi
        let units: CGFloat = CGFloat(size.width), rows: CGFloat = CGFloat(size.height)
        return Band(title: "Heat map", spacing: 16) { KeyboardNote(text: layoutTitle); layoutMenu } content: {
            // The board spans the content column, so its keys end on the page's two edges.
            GeometryReader { proxy in
                let gap: CGFloat = proxy.size.width / units < 36 ? 2 : 4
                let pitch: CGFloat = (proxy.size.width + gap) / units
                ZStack(alignment: .topLeading) {
                    ForEach(keys) { key in
                        if key.code < 0 { inertCap(key, pitch: pitch, gap: gap) }
                        else { keycap(key, pitch: pitch, gap: gap, symbols: symbols, counts: counts, peak: peak, hottest: hottest, pressed: pressed) }
                    }
                }
                .frame(width: proxy.size.width, height: rows * pitch - gap, alignment: .topLeading)
            }
            .aspectRatio(units / rows, contentMode: .fit)
            heatLegend(counts: counts, pressed: pressed)
        }
    }
    private func heatLegend(counts: [Int: Double], pressed: Double) -> some View {
        HStack(spacing: 10) {
            if let hovered {
                let count: Double = counts[hovered] ?? 0
                Text(NativeKeyboardLegends.label(hovered, legends)).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.ink)
                Text(NativeNumberFormat.decimal(count) + " presses").font(Theme.mono(11)).foregroundStyle(Theme.dim)
                Text(percent(pressed > 0 ? count / pressed : 0) + "% of all keys").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                if let finger = NativeKeyboardLayout.finger(hovered) { Text(finger.title).font(Theme.ui(11.5)).foregroundStyle(Theme.muted) }
            } else if hasKeys {
                Text("Point at a key for its count. \(totals["uniqueKeys"].int) different keys used \(rangeTitle).").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
            } else if enabled || state["hasData"].bool {
                Text(recording ? "Nothing typed \(rangeTitle) yet. Start typing anywhere on this Mac; figures appear within a second."
                     : "No keys recorded \(rangeTitle). Choose a longer range, or turn recording on.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
            } else {
                Text("Every key starts as an outline and fills with ink as you use it.").font(Theme.ui(11.5)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                MicroLabel("Less")
                HStack(spacing: 2) {
                    ForEach(0..<6, id: \.self) { step in
                        Rectangle().fill(density(Double(step) / 5)).frame(width: 12, height: 12)
                            .overlay { if step == 0 { Rectangle().strokeBorder(Theme.rule, lineWidth: 1) } }
                    }
                }
                MicroLabel("More")
                Rectangle().fill(Theme.signal).frame(width: 12, height: 12).padding(.leading, 10)
                MicroLabel("Most pressed")
            }.fixedSize().accessibilityHidden(true)
        }.lineLimit(1).frame(minHeight: 18)
    }

    // MARK: - Ledgers

    private func items(_ values: [JSONValue], title: (JSONValue) -> String) -> [KeyboardRanking.Item] {
        values.enumerated().map { .init(id: $0.offset, title: title($0.element), count: $0.element["count"].double, share: $0.element["share"].double) }
    }
    private var topKeys: some View {
        Band(title: "Keys", spacing: 0) { KeyboardNote(text: "most pressed " + rangeTitle) } content: {
            KeyboardRanking(head: "Key", items: items(Array(state["keys"].array.prefix(12))) { NativeKeyboardLegends.label($0["code"].int, legends) },
                            ranked: true, mono: true, titleWidth: 64)
        }
    }
    private var shortcuts: some View {
        let values = state["shortcuts"].array, total: Double = max(1, totals["shortcuts"].double)
        let list: [KeyboardRanking.Item] = values.enumerated().map {
            .init(id: $0.offset, title: NativeKeyboardLegends.combination($0.element["combo"].string, legends),
                  count: $0.element["count"].double, share: $0.element["count"].double / total)
        }
        return Band(title: "Shortcuts", spacing: 0) { KeyboardNote(text: NativeNumberFormat.decimal(totals["shortcuts"].double) + " in total") } content: {
            KeyboardRanking(head: "Combination", items: list, ranked: true, mono: true, titleWidth: 96,
                            empty: "No Command or Control shortcuts \(rangeTitle).")
        }
    }
    private var rowLoad: some View {
        Band("Rows", spacing: 0) {
            KeyboardRanking(head: "Row", items: items(state["rows"].array.filter { $0["count"].double > 0 }) { $0["name"].string }, titleWidth: 96)
        }
    }
    private var categories: some View {
        Band("Key types", spacing: 0) {
            KeyboardRanking(head: "Type", items: items(state["categories"].array) { $0["name"].string }, titleWidth: 96)
        }
    }

    // MARK: - Pace

    private func bars(_ values: [JSONValue], label: (Int, JSONValue) -> String) -> [KeyboardBars.Bar] {
        values.enumerated().map { index, item in
            let wpm: Double = item["wpm"].double
            return .init(id: index, label: label(index, item), value: item["keys"].double, trace: wpm,
                         detail: "\(Int(item["keys"].double)) keys, \(Int(wpm)) words per minute")
        }
    }
    private var pace: some View {
        let time = duration(totals["activeMs"].double), travel: Double = totals["travelMeters"].double
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let hours = bars(state["hours"].array) { index, _ in String(format: "%02d", index) }
        let weekdays = bars(state["weekdays"].array) { index, _ in names[min(index, 6)] }
        let recorded: Int = state["daily"].array.count
        let daily = bars(Array(state["daily"].array.suffix(120))) { _, item in dayTitle(item["day"].string) }
        let calendar = Calendar.current
        let hourNow: Int = calendar.component(.hour, from: Date()), weekdayNow: Int = (calendar.component(.weekday, from: Date()) + 5) % 7
        let busiest: String = totals["busiestHour"].isNull ? "" : "busiest at " + hourTitle(totals["busiestHour"].int)
        let topDay: String = weekdays.max(by: { $0.value < $1.value }).flatMap { $0.value > 0 ? "most keys on " + $0.label : nil } ?? ""
        let best: String = totals["bestDay"]["day"].string
        let bestText: String = best.isEmpty ? "" : "best day " + dayTitle(best) + " with " + NativeNumberFormat.compact(totals["bestDay"]["keys"].double) + " keys"
        let fastText: String = totals["fastestDay"].isNull ? "" : String(format: "fastest day %@ at %.0f WPM", dayTitle(totals["fastestDay"]["day"].string), totals["fastestDay"]["wpm"].double)
        let today: Int? = daily.last.flatMap { _ in state["daily"].array.last?["day"].string == state["today"].string ? daily.count - 1 : nil }
        return Band(title: "Pace", spacing: 24) { KeyboardNote(text: rangeTitle) } content: {
            ReadoutStrip(minimum: 150) {
                Readout(label: "Keys pressed", value: NativeNumberFormat.compact(totals["keys"].double),
                        detail: NativeNumberFormat.compact(totals["keysPerDay"].double.rounded()) + " per active day", size: .medium)
                Readout(label: "Words", value: NativeNumberFormat.compact(totals["words"].double),
                        detail: String(format: "%.1f characters per word", totals["charactersPerWord"].double), size: .medium)
                Readout(label: "Average speed", value: String(format: "%.0f", totals["wpm"].double), unit: "WPM",
                        detail: String(format: "%.0f WPM after corrections", totals["netWpm"].double), size: .medium)
                Readout(label: "Typing time", value: time.0, unit: time.1,
                        detail: NativeNumberFormat.compact(totals["bursts"].double) + " bursts", size: .medium)
                    .help("Time inside typing bursts; pauses are excluded.")
                Readout(label: "Finger travel", value: String(format: (travel >= 1000 ? travel / 1000 : travel) >= 100 ? "%.0f" : "%.1f", travel >= 1000 ? travel / 1000 : travel),
                        unit: travel >= 1000 ? "km" : "m", detail: "Estimate for touch typing", size: .medium)
            }
            ColumnFlow(minimum: 340, spacing: 40, rowSpacing: 28, maxColumns: 2) {
                KeyboardPlot(title: "By hour of day", note: busiest) {
                    KeyboardBars(bars: hours, every: 3, major: 6, now: state["range"].string == "all" ? nil : hourNow)
                }
                KeyboardPlot(title: "By weekday", note: topDay) {
                    KeyboardBars(bars: weekdays, every: 1, major: 7, now: weekdayNow)
                }
            }
            if daily.count > 1 {
                // The notes describe the whole range; the plot holds 120 days.
                KeyboardPlot(title: recorded > 120 ? "Day by day, latest 120 of \(recorded) days" : "Day by day", note: bestText) {
                    KeyboardBars(bars: daily, every: max(1, daily.count / 8), major: 7, now: today, axis: false)
                }
                KeyboardPlot(title: "Typing speed", note: fastText) {
                    KeyboardBars(bars: daily, every: max(1, daily.count / 8), major: 7, now: today, height: 56, traced: true)
                }.padding(.top, -8)
            }
        }
    }

    // MARK: - Corrections and hands

    private func fact(_ title: String, _ value: String, _ unit: String = "") -> some View {
        LedgerRow(minHeight: 28) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(Theme.ui(12.5)).foregroundStyle(Theme.dim)
                Spacer(minLength: 8)
                Text(value).font(Theme.mono(12, weight: .medium)).foregroundStyle(Theme.ink)
                Text(unit).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).lineLimit(1).frame(width: 88, alignment: .leading)
            }
        }.accessibilityElement(children: .combine)
    }
    private var corrections: some View {
        let accuracy: Double = totals["accuracy"].double
        let backspace: Double = counts[NativeKeyboardKeys.delete] ?? 0, forward: Double = counts[NativeKeyboardKeys.forwardDelete] ?? 0
        let dial = Dial(fraction: accuracy, size: 148) {
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    NativeNumberText(text: percent(accuracy), font: Theme.readout(34), color: Theme.ink)
                    MicroLabel("%")
                }
                MicroLabel("kept")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated share of characters kept").accessibilityValue(percent(accuracy) + " percent")
        .help("A correction is one run of Delete presses. The rate compares Delete presses, including repeats while the key is held, with characters typed. A press that removed nothing still counts, so it is an upper estimate.")
        let facts = VStack(spacing: 0) {
            LedgerHead { MicroLabel("Measure"); Spacer(minLength: 0); MicroLabel(rangeTitle) }
            fact("Correction rate", percent(totals["correctionRate"].double), "% of typed")
            fact("Corrections", NativeNumberFormat.decimal(totals["corrections"].double), "runs")
            fact("Delete presses", NativeNumberFormat.decimal(totals["deleted"].double), "with repeats")
            fact("Presses per correction", String(format: "%.1f", totals["deletedPerCorrection"].double))
            fact("Typed between corrections", String(format: "%.0f", totals["charactersPerCorrection"].double), "characters")
            fact("Delete", NativeNumberFormat.decimal(backspace), "presses")
            fact("Forward delete", NativeNumberFormat.decimal(forward), "presses")
            fact("Speed after corrections", String(format: "%.0f", totals["netWpm"].double), "WPM")
        }
        return Band(title: "Corrections", spacing: 16) { KeyboardNote(text: "an upper estimate: every Delete press counts") } content: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 56) { dial; facts.frame(minWidth: 380) }
                VStack(alignment: .leading, spacing: 20) { dial; facts }
            }
        }
    }
    private var balance: some View {
        let left: Double = state["hands"]["leftShare"].double
        let names = ["Pinky", "Ring", "Middle", "Index", "Thumbs", "Index", "Middle", "Ring", "Pinky"]
        let fingers: [KeyboardBars.Bar] = state["fingers"].array.enumerated().map { index, item in
            .init(id: index, label: names[min(index, 8)], value: item["count"].double, trace: 0,
                  detail: item["name"].string + ": \(Int(item["count"].double)), " + percent(item["share"].double) + " percent",
                  caption: percent(item["share"].double) + "%")
        }
        return Band(title: "Hands and fingers", spacing: 20) { KeyboardNote(text: "standard touch typing; thumbs are left out of the balance") } content: {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    MicroLabel("Left")
                    NativeNumberText(text: percent(left), font: Theme.readout(24), color: Theme.ink)
                    MicroLabel("%")
                }.fixedSize()
                KeyboardSplit(left: left).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 4 }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    NativeNumberText(text: percent(1 - left), font: Theme.readout(24), color: Theme.ink)
                    MicroLabel("%")
                    MicroLabel("Right")
                }.fixedSize()
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("Hand balance")
            .accessibilityValue("Left " + percent(left) + " percent, right " + percent(1 - left) + " percent")
            KeyboardBars(bars: fingers, every: 1, major: 9, now: nil, height: 88, divided: 4)
        }
    }

    private var controls: some View {
        Band("Recording", spacing: 0) {
            OptionRow(title: "Record keyboard statistics",
                      detail: "Counts key presses across this Mac while UniApi runs. Only per-day counters are stored locally; typed text and key order are never saved, and macOS withholds password fields.") {
                Flip(isOn: Binding(get: { enabled }, set: { value in Task { await operation("set-enabled", ["enabled": .bool(value)]) } }), enabled: !locked)
                    .accessibilityLabel("Record keyboard statistics")
            }
            OptionRow(title: confirmingReset ? "Delete every recorded keyboard counter?" : "Recorded counters",
                      detail: confirmingReset ? "This cannot be undone." : "Kept on this Mac until you delete them.", ruled: false) {
                if confirmingReset {
                    HStack(spacing: 8) {
                        Button("Cancel") { confirmingReset = false }
                        Button("Delete statistics") { confirmingReset = false; Task { await operation("reset") } }.buttonStyle(Press(.danger))
                    }
                } else {
                    Button("Reset statistics") { confirmingReset = true }
                        .disabled(locked || !state["hasData"].bool)
                }
            }
        }
    }

    // MARK: - Data

    private func readLegends() {
        legends = NativeKeyboardLegends.current(); shifted = NativeKeyboardLegends.current(shift: true)
    }
    private func reload() async {
        guard let service = session.keyboard, let ticket = reads.begin("status") else { return }
        do {
            let next = try await service.handle("status", input: ["range": .string(range)])
            guard reads.accepts(ticket) else { return }
            state = next; live = next["live"]; error = nil
        } catch {
            if reads.accepts(ticket) { self.error = error.localizedDescription }
        }
    }
    private func operation(_ name: String, _ input: JSONObject = [:]) async {
        guard let service = session.keyboard, !pending else { return }
        pending = true; defer { pending = false }
        var payload = input; payload["range"] = .string(range)
        do {
            reads.invalidate("status")
            let next = try await service.handle(name, input: payload)
            state = next; live = next["live"]; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Local components

/// A note beside a section name. It rides in the Band's trailing slot,
/// because the Band's own hint collapses next to its rule.
private struct KeyboardNote: View {
    let text: String
    var body: some View { Text(text).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1) }
}

/// One large reading and the smaller ones that qualify it, all standing on
/// the same numeral baseline. On a narrow page the smaller ones drop below.
private struct KeyboardLead<Hero: View, Rest: View>: View {
    @ViewBuilder var hero: () -> Hero
    @ViewBuilder var rest: () -> Rest
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 40) {
                hero().frame(width: 300, alignment: .leading)
                HStack(alignment: .firstTextBaseline, spacing: 24) { rest() }.frame(minWidth: 500)
            }
            VStack(alignment: .leading, spacing: 20) {
                hero()
                HStack(alignment: .firstTextBaseline, spacing: 20) { rest() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A reading whose numerals carry the first baseline, so readings of
/// different sizes line up in a row. The label hangs above its numerals.
private struct KeyboardReading: View {
    var label: String
    var value: String
    var unit: String = ""
    var detail: String = ""
    var hero = false
    var tint: Color? = nil
    var known = true
    var body: some View {
        VStack(alignment: .leading, spacing: hero ? 2 : 4) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                NativeNumberText(text: value, font: Theme.readout(hero ? 54 : 24), color: known ? Theme.ink : Theme.faint)
                if !unit.isEmpty { MicroLabel(unit, size: hero ? 11 : 9.5) }
            }
            .padding(.top, 18)
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    if let tint { tint.frame(width: 2, height: 9) }
                    MicroLabel(label)
                }.fixedSize()
            }
            Text(detail.isEmpty ? " " : detail).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
        .frame(maxWidth: hero ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue([value, unit, detail].filter { !$0.isEmpty }.joined(separator: " "))
    }
}

/// A ranking as a ledger. The head of the bar column is a ruler graduated to
/// the largest row, so each bar can be read against it.
private struct KeyboardRanking: View {
    struct Item: Identifiable { let id: Int; let title: String; let count: Double; let share: Double }
    var head: String
    var items: [Item]
    var ranked = false
    var mono = false
    var titleWidth: CGFloat = 96
    var empty = ""
    private func percent(_ value: Double) -> String { String(format: value < 0.1 ? "%.1f" : "%.0f", value * 100) }
    var body: some View {
        let peak: Double = items.map(\.count).max() ?? 0
        VStack(spacing: 0) {
            LedgerHead {
                if ranked { MicroLabel("#").frame(width: 18, alignment: .leading) }
                MicroLabel(head).frame(width: titleWidth, alignment: .leading)
                TickScale(divisions: 20, major: 5, minorHeight: 3, majorHeight: 6).fill(Theme.faint)
                    .frame(height: 6).scaleEffect(y: -1).frame(maxWidth: .infinity).frame(height: 24, alignment: .bottom)
                    .accessibilityHidden(true)
                MicroLabel("Presses").frame(width: 64, alignment: .trailing)
                MicroLabel("Share").frame(width: 52, alignment: .trailing)
            }
            if items.isEmpty, !empty.isEmpty {
                Text(empty).font(Theme.ui(12.5)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            ForEach(items) { item in
                LedgerRow(minHeight: 28) {
                    HStack(spacing: 12) {
                        if ranked { Text("\(item.id + 1)").font(Theme.mono(10.5)).foregroundStyle(Theme.faint).frame(width: 18, alignment: .leading) }
                        Text(item.title).font(mono ? Theme.mono(12, weight: .medium) : Theme.ui(12.5)).foregroundStyle(Theme.ink).lineLimit(1)
                            .frame(width: titleWidth, alignment: .leading)
                        Scale(fraction: peak > 0 ? item.count / peak : 0, height: 4)
                        Text(NativeNumberFormat.compact(item.count)).font(Theme.mono(11)).foregroundStyle(Theme.dim).frame(width: 64, alignment: .trailing)
                        Text(percent(item.share) + "%").font(Theme.mono(11)).foregroundStyle(Theme.muted).frame(width: 52, alignment: .trailing)
                    }
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(item.title)
                .accessibilityValue("\(Int(item.count)), " + percent(item.share) + " percent")
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A plot with its engraved name on the left and one finding on the right.
private struct KeyboardPlot<Content: View>: View {
    var title: String
    var note: String = ""
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                MicroLabel(title)
                Spacer(minLength: 8)
                if !note.isEmpty { Text(note).font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(1) }
            }
            content()
        }
    }
}

/// Ink bars standing on a ruled baseline, one slot per value. The ruler
/// beneath marks the slots and the signal tick marks now. `traced` draws the
/// second value as a line instead, on the same slots.
private struct KeyboardBars: View {
    struct Bar: Identifiable { let id: Int; let label: String; let value: Double; let trace: Double; let detail: String; var caption: String = "" }
    var bars: [Bar]
    /// Print every nth axis label.
    var every: Int
    var major: Int
    var now: Int?
    var height: CGFloat = 96
    var axis = true
    var traced = false
    /// Slot after which the baseline pauses, parting two groups.
    var divided: Int? = nil
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible

    var body: some View {
        let values: [Double] = bars.map { traced ? $0.trace : $0.value }
        let peak: Double = max(values.max() ?? 0, 0.000_001)
        VStack(spacing: 0) {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) { Theme.grid.frame(height: 1); Spacer(minLength: 0); Theme.grid.frame(height: 1); Spacer(minLength: 0) }
                if traced {
                    KeyboardTrace(values: values, peak: peak).stroke(Theme.ink, style: StrokeStyle(lineWidth: 1.25, lineJoin: .round))
                    KeyboardTrace(values: values, peak: peak, dots: true).fill(Theme.ink)
                }
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(bars) { bar in
                        let level: CGFloat = CGFloat((traced ? bar.trace : bar.value) / peak)
                        VStack(spacing: 4) {
                            Spacer(minLength: 0)
                            if !bar.caption.isEmpty { Text(bar.caption).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).fixedSize() }
                            if !traced {
                                Rectangle().fill(Theme.ink.opacity(bar.id == now ? 1 : 0.82))
                                    .frame(height: level > 0 ? max(1, (height - (bar.caption.isEmpty ? 0 : 18)) * level) : 0)
                                    .frame(maxWidth: 28)
                            }
                        }
                        .padding(.horizontal, bars.count > 60 ? 0.5 : bars.count > 12 ? 2 : 6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .contentShape(Rectangle())
                        .help(bar.label + ": " + bar.detail)
                        .accessibilityElement(children: .ignore).accessibilityLabel(bar.label).accessibilityValue(bar.detail)
                    }
                }
                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: values)
            }
            .frame(height: height)
            Rule(strong: true)
            if axis {
                HStack(spacing: 0) {
                    ForEach(bars) { bar in
                        VStack(spacing: 3) {
                            (bar.id == now ? Theme.signal : Theme.faint)
                                .frame(width: bar.id == now ? 2 : 1, height: bar.id == now ? 7 : bar.id % max(1, major) == 0 ? 6 : 3)
                                .frame(height: 7, alignment: .top)
                            Color.clear.frame(height: 12).overlay {
                                if bar.id % max(1, every) == 0 || bar.id == now {
                                    Text(bar.label).font(Theme.mono(10.5)).foregroundStyle(bar.id == now ? Theme.ink : Theme.muted).fixedSize()
                                }
                            }
                        }.frame(maxWidth: .infinity)
                    }
                }.accessibilityHidden(true)
            }
        }
    }
}

/// The second value of each slot joined as a line; gaps in the data break it.
private struct KeyboardTrace: Shape {
    var values: [Double]
    var peak: Double
    var dots = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !values.isEmpty, peak > 0 else { return path }
        let slot: CGFloat = rect.width / CGFloat(values.count)
        var drawing = false
        for (index, value) in values.enumerated() {
            guard value > 0 else { drawing = false; continue }
            let point = CGPoint(x: rect.minX + slot * (CGFloat(index) + 0.5), y: rect.maxY - 2 - (rect.height - 4) * CGFloat(value / peak))
            if dots { path.addEllipse(in: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)) }
            else if drawing { path.addLine(to: point) } else { path.move(to: point); drawing = true }
        }
        return path
    }
}

/// Left against right on one ruled track. The centre tick shows how far the
/// split is from even.
private struct KeyboardSplit: View {
    var left: Double
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    var body: some View {
        let value: Double = NativeMotion.fraction(left)
        VStack(spacing: 3) {
            GeometryReader { geometry in
                HStack(spacing: 2) {
                    Rectangle().fill(Theme.ink).frame(width: max(0, (geometry.size.width - 2) * value))
                    Rectangle().fill(Theme.ink.opacity(0.38))
                }
                .animation(reduceMotion || !visible ? nil : NativeMotion.barUpdate, value: value)
            }.frame(height: 6)
            TickScale(divisions: 20, major: 10, minorHeight: 3, majorHeight: 7).fill(Theme.faint).frame(height: 7)
        }
        .accessibilityHidden(true)
    }
}
