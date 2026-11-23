import SwiftUI
import Charts
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
    @Environment(\.nativeInterfaceDensity) private var density
    @AppStorage("uniapi.keyboard.range") private var range = "7d"
    @AppStorage("uniapi.keyboard.view") private var view = "keys"
    @State private var reads = NativePageReadScope()
    @State private var state: JSONValue = .null
    @State private var live: JSONValue = .null
    @State private var legends: [Int: String] = [:]
    @State private var shifted: [Int: String] = [:]
    @State private var error: String?
    @State private var pending = false
    @State private var confirmingReset = false
    @State private var information = false
    @State private var hovered: Int?
    @State private var contentWidth: CGFloat = 900

    private static let ranges: [(value: String, label: String)] = [("today", "Today"), ("7d", "7 days"), ("30d", "30 days"), ("all", "All time")]
    private var totals: JSONValue { state["totals"] }
    private var enabled: Bool { state["enabled"].bool }
    private var recording: Bool { live.isNull ? state["recording"].bool : live["recording"].bool }
    private var hasKeys: Bool { totals["keys"].double > 0 }
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

    var body: some View {
        GeometryReader { viewport in
            NativePage(title: "Keyboard Stats", maxWidth: 1240, readiness: readiness, tabs: {
                if started { NativeTabs(options: [("keys", "Keys"), ("typing", "Typing"), ("rhythm", "Rhythm")], selection: ["typing", "rhythm"].contains(view) ? view : "keys") { view = $0 } }
            }, actions: {
                if started { barActions }
            }) {
                if let error { NativeError(message: error) }
                if !state["error"].string.isEmpty { NativeError(message: state["error"].string) }
                if state.isNull {
                    if error == nil { ShimmerText(text: "Loading…") }
                } else if !started {
                    welcome
                } else {
                    if enabled && !state["permitted"].bool { permissionNotice }
                    if !hasKeys {
                        NativeEmptyState(title: "No keys \(rangeTitle)", detail: enabled ? "" : "Recording is off.", icon: "keyboard")
                    } else {
                        switch view {
                        case "typing":
                            tiles
                            columns { corrections } _: { balance }
                        case "rhythm":
                            rhythm
                        default:
                            heatmap
                            columns { topKeys } _: { VStack(spacing: 24) { categories; shortcuts } }
                        }
                    }
                }
            }
            .onChange(of: max(0, min(1240, viewport.size.width) - 2 * density.pageMargin), initial: true) { _, width in contentWidth = width }
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

    private var started: Bool { !state.isNull && (enabled || state["hasData"].bool) }

    @ViewBuilder private var barActions: some View {
        if confirmingReset {
            Text("Delete every counter?").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.failFg)
            Button("Cancel") { confirmingReset = false }.buttonStyle(T3Button(.outline))
            Button("Delete") { confirmingReset = false; Task { await operation("reset") } }.buttonStyle(T3Button(.destructive))
        } else {
            NativeMenuSelect(title: "Range", selection: $range, options: Self.ranges, width: 112)
            T3IconButton(system: "info", help: "What is recorded", active: information) { information.toggle() }
                .popover(isPresented: $information, arrowEdge: .bottom) { informationSheet }
            T3IconButton(system: "trash-2", help: "Delete all counters") { confirmingReset = true }
                .disabled(pending || state["readOnly"].bool || !state["hasData"].bool)
            HStack(spacing: 8) {
                Text("Record").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.dim)
                T3Switch(isOn: Binding(get: { enabled }, set: { value in Task { await operation("set-enabled", ["enabled": .bool(value)]) } }),
                         enabled: !pending && !state["readOnly"].bool)
                    .accessibilityLabel("Record keyboard statistics")
            }.padding(.leading, 4)
        }
    }

    private static let recorded = [
        "Only a count per key per day is stored. Text and key order are never saved.",
        "Counters stay in UniApi's database on this Mac.",
        "macOS withholds keys typed into password fields."
    ]
    private var informationSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.recorded, id: \.self) { line in
                Text(line).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
            }
            Theme.rule.frame(height: 1)
            Text("A correction is one run of Delete presses. The rate compares Delete presses, repeats included, with characters typed, so it is an upper estimate. Fingers follow standard touch typing.")
                .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }.padding(16).frame(width: 320, alignment: .leading)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeIcon("keyboard", size: 22, strokeWidth: 1.5).foregroundStyle(Theme.faint)
            Text("Count the keys you press").font(Theme.ui(Theme.textLg, weight: .semibold)).foregroundStyle(Theme.ink).padding(.top, 14)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.recorded + ["Needs the Input Monitoring permission."], id: \.self) { line in
                    Text(line).font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.dim).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .overlay(alignment: .top) { Theme.rule.frame(height: 1) }
                }
            }.padding(.top, 16)
            Button("Start recording") { Task { await operation("set-enabled", ["enabled": true]) } }
                .buttonStyle(T3Button(.primary)).disabled(pending || state["readOnly"].bool).padding(.top, 16)
            if state["readOnly"].bool { Text("Unavailable in read-only mode.").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).padding(.top, 8) }
        }.frame(maxWidth: 520, alignment: .leading).padding(.top, 24)
    }

    private var permissionNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            NativeIcon("triangle-alert", size: 14).foregroundStyle(Theme.warnFg).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            Text("Allow UniApi under Privacy & Security, Input Monitoring. Reopen UniApi if recording does not start.")
                .font(Theme.ui(Theme.textSm)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Ask again") { Task { await operation("request-permission") } }.buttonStyle(T3Button(.outline)).disabled(pending)
            Button("Open settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
            }.buttonStyle(T3Button(.primary))
        }
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Theme.warnFg.opacity(0.5).frame(height: 1) }
        .overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }
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

    private var tiles: some View {
        let time = duration(totals["activeMs"].double), liveWpm = live["wpm"].double
        let peak = totals["peakWpm"].double
        var facts: [NativeHeroFact] = []
        if recording && liveWpm > 0 { facts.append(NativeHeroFact(label: "Now", value: String(format: "%.0f WPM", liveWpm), tone: Theme.accent)) }
        if peak > 0 { facts.append(NativeHeroFact(label: "Peak", value: String(format: "%.0f WPM", peak))) }
        facts.append(NativeHeroFact(label: "Keys", value: NativeNumberFormat.compact(totals["keys"].double),
                                    help: NativeNumberFormat.compact(totals["words"].double) + " words, " + NativeNumberFormat.compact(totals["keysPerDay"].double.rounded()) + " a day"))
        facts.append(NativeHeroFact(label: "Corrected", value: percent(totals["correctionRate"].double) + "%",
                                    help: NativeNumberFormat.compact(totals["corrections"].double) + (totals["corrections"].int == 1 ? " correction" : " corrections")))
        facts.append(NativeHeroFact(label: "Typing time", value: time.0 + " " + time.1, help: NativeNumberFormat.compact(totals["bursts"].double) + (totals["bursts"].int == 1 ? " burst" : " bursts")))
        facts.append(NativeHeroFact(label: "Streak", value: "\(totals["streak"].int) " + (totals["streak"].int == 1 ? "day" : "days"),
                                    help: "Longest \(totals["longestStreak"].int), \(totals["days"].int) active"))
        return NativeHero(value: String(format: "%.0f", totals["wpm"].double), numeric: totals["wpm"].double, unit: "WPM", facts: facts,
                          maxFacts: contentWidth >= 900 ? 6 : contentWidth >= 640 ? 4 : contentWidth >= 480 ? 2 : 0) {
            Text("Average speed")
        } trailing: { EmptyView() }
    }

    private func heat(_ count: Double, _ peak: Double) -> Double { peak > 0 && count > 0 ? (count / peak).squareRoot() : 0 }
    private var model: NativeKeyboardLayout.Model {
        let layout = state["layout"]
        return .init(standard: .init(rawValue: layout["standard"].string) ?? .ansi, form: .init(rawValue: layout["form"].string) ?? .compact,
                     apple: layout["apple"].bool, name: layout["name"].string)
    }
    /// The legend printed on a key, and the shifted character above it.
    private func legend(_ code: Int, width: CGFloat, symbols: Bool) -> (main: String, upper: String) {
        if let cap = NativeKeyboardLayout.caps[code] {
            let fits: Bool = width >= CGFloat(cap.word.count) * 6 + 8
            return (symbols || !fits ? cap.symbol : cap.word, "")
        }
        if let glyph = legends[code] {
            let upper: String = shifted[code] ?? ""
            return (glyph, upper == glyph ? "" : upper)
        }
        return (NativeKeyboardLayout.named[code] ?? NativeKeyboardLayout.labels[code] ?? "", "")
    }
    private func keycap(_ key: NativeKeyboardLayout.Key, pitch: CGFloat, gap: CGFloat, symbols: Bool, counts: [Int: Double], peak: Double, pressed: Double) -> some View {
        let width: CGFloat = CGFloat(key.width) * pitch - gap
        let height: CGFloat = CGFloat(key.height) * pitch - gap
        let upper: CGFloat = key.notch > 0 ? pitch - gap : height
        let shape = NativeKeycapShape(notch: CGFloat(key.notch) * pitch, upper: upper, radius: min(6, pitch * 0.14))
        let count: Double = counts[key.code] ?? 0
        let level: Double = heat(count, peak)
        let name: String = NativeKeyboardLegends.label(key.code, legends)
        let tint: Color = level == 0 ? Color.clear : Theme.accent.opacity(0.14 + 0.82 * level)
        let stroke: Color = hovered == key.code ? Theme.ink.opacity(0.7) : Theme.border
        let ink: Color = level > 0.5 ? Theme.onAccent : Theme.dim
        let text = legend(key.code, width: width, symbols: symbols)
        let stacked: Bool = !text.upper.isEmpty && upper >= 30
        let size: CGFloat = min(text.main.count > 2 ? 10 : 13, pitch * (text.main.count > 2 ? 0.2 : 0.28)) * (stacked ? 0.88 : 1)
        let share: String = percent(pressed > 0 ? count / pressed : 0)
        let value: String = "\(Int(count)) presses, " + share + " percent"
        let caption = VStack(spacing: 0) {
            if stacked { Text(text.upper).font(Theme.ui(size * 0.86)).opacity(0.75) }
            Text(text.main).font(Theme.ui(size, weight: .medium))
        }.foregroundStyle(ink).lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 2).frame(width: width, height: upper)
        return shape.fill(Theme.track).overlay(shape.fill(tint)).overlay(shape.stroke(stroke, lineWidth: 1)).overlay(alignment: .top) { caption }
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
        let shape = NativeKeycapShape(radius: min(6, pitch * 0.14))
        return shape.fill(Theme.track).overlay(shape.stroke(Theme.border, lineWidth: 1))
            .overlay(Circle().strokeBorder(Theme.border, lineWidth: 1).frame(width: min(width, height) * 0.5, height: min(width, height) * 0.5))
            .frame(width: width, height: height)
            .accessibilityHidden(true)
            .offset(x: CGFloat(key.x) * pitch, y: CGFloat(key.y) * pitch)
    }
    private func layoutChoice(_ title: String, _ field: String, _ value: String) -> some View {
        let selected: Bool = state["layoutChoice"][field].string == value
        return Button(selected ? "\u{2713} " + title : title) { Task { await operation("set-layout", [field: .string(value)]) } }
    }
    private var layoutLine: some View {
        let model = model, choice = state["layoutChoice"]
        let chosen: Bool = ["form", "standard", "style"].contains { choice[$0].string != "auto" }
        let name: String = model.name.isEmpty ? "Keyboard" : model.name
        let title: String = [name, model.standard.title, model.form.title, model.apple ? "Apple keys" : "Third-party keys"].joined(separator: " \u{00B7} ")
        return HStack(spacing: 10) {
            Text(title).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted).lineLimit(1)
            Spacer(minLength: 8)
            NativeMenuSelectLabel(title: chosen ? "Layout, chosen" : "Layout") {
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
            }
            .disabled(pending || state["readOnly"].bool)
            .accessibilityLabel("Keyboard layout")
        }
    }
    private var heatmap: some View {
        let counts = counts, model = model
        let keys = NativeKeyboardLayout.keys(model), size = NativeKeyboardLayout.size(model)
        let board = Set(keys.map(\.code))
        let peak = counts.filter { board.contains($0.key) }.values.max() ?? 0
        let pressed = counts.values.reduce(0, +)
        let available: CGFloat = max(120, contentWidth - 34)
        let pitch: CGFloat = min(62, available / CGFloat(size.width))
        let gap: CGFloat = pitch < 36 ? 2 : 4
        let symbols = model.standard != .ansi
        return NativeCard {
            VStack(alignment: .leading, spacing: 14) {
                layoutLine
                ZStack(alignment: .topLeading) {
                    ForEach(keys) { key in
                        if key.code < 0 { inertCap(key, pitch: pitch, gap: gap) }
                        else { keycap(key, pitch: pitch, gap: gap, symbols: symbols, counts: counts, peak: peak, pressed: pressed) }
                    }
                }
                .frame(width: CGFloat(size.width) * pitch - gap, height: CGFloat(size.height) * pitch - gap, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .center)
                HStack(spacing: 10) {
                    if let hovered {
                        let count = counts[hovered] ?? 0
                        Text(NativeKeyboardLegends.label(hovered, legends)).font(Theme.ui(Theme.textXs, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text(NativeNumberFormat.decimal(count)).font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink)
                        Text(percent(pressed > 0 ? count / pressed : 0) + "%").font(Theme.num(Theme.textXs, weight: .regular)).foregroundStyle(Theme.muted)
                        if let finger = NativeKeyboardLayout.finger(hovered) { Text(finger.title).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted) }
                    } else {
                        Text("\(totals["uniqueKeys"].int) keys used").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 2) {
                        ForEach(0..<6, id: \.self) { step in
                            Rectangle().fill(step == 0 ? Theme.track : Theme.accent.opacity(0.14 + 0.82 * Double(step) / 5)).frame(width: 3, height: 10)
                        }
                    }.accessibilityHidden(true)
                }.frame(minHeight: 18)
            }
        }
    }

    private func bar(_ title: String, _ count: Double, share: Double, peak: Double, color: Color = Theme.ink, mono: Bool = false, titleWidth: CGFloat = 96) -> some View {
        HStack(spacing: 10) {
            Text(title).font(mono ? Theme.mono(11.5, weight: .medium) : Theme.ui(Theme.textXs)).foregroundStyle(Theme.ink).lineLimit(1)
                .frame(width: titleWidth, alignment: .leading)
            NativeTickMeter(fraction: peak > 0 ? count / peak : 0, color: color, height: 9)
            Text(NativeNumberFormat.compact(count)).font(Theme.num(11.5, weight: .regular)).foregroundStyle(Theme.dim).frame(width: 52, alignment: .trailing)
            Text(percent(share) + "%").font(Theme.num(11.5, weight: .regular)).foregroundStyle(Theme.muted).frame(width: 44, alignment: .trailing)
        }.frame(height: 22)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityValue("\(Int(count)), " + percent(share) + " percent")
    }
    private func bars(_ items: [JSONValue], title: (JSONValue) -> String, color: Color = Theme.ink, mono: Bool = false, titleWidth: CGFloat = 96) -> some View {
        let peak = items.map { $0["count"].double }.max() ?? 0
        let titles = items.map(title)
        return VStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                bar(titles[index], item["count"].double, share: item["share"].double, peak: peak, color: color, mono: mono, titleWidth: titleWidth)
            }
        }
    }

    private var topKeys: some View {
        NativeCard(title: "Most pressed") {
            bars(Array(state["keys"].array.prefix(12)), title: { NativeKeyboardLegends.label($0["code"].int, legends) }, titleWidth: 70)
        }
    }
    private func fact(_ title: String, _ value: String, _ detail: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.dim)
            Spacer(minLength: 8)
            Text(value).font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink)
            if !detail.isEmpty { Text(detail).font(Theme.ui(11)).foregroundStyle(Theme.muted) }
        }.frame(height: 30).overlay(alignment: .bottom) { Theme.rule.frame(height: 1) }.accessibilityElement(children: .combine)
    }
    private var corrections: some View {
        let accuracy = totals["accuracy"].double
        let backspace = counts[NativeKeyboardKeys.delete] ?? 0, forward = counts[NativeKeyboardKeys.forwardDelete] ?? 0
        return NativeCard(title: "Corrections") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(percent(accuracy)).font(Theme.num(26)).foregroundStyle(Theme.ink)
                    Text("% kept").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted)
                }
                NativeTickMeter(fraction: max(0, min(1, accuracy)), color: Theme.ink).padding(.top, 8).padding(.bottom, 10)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Estimated share of characters kept").accessibilityValue(percent(accuracy) + " percent")
                Theme.rule.frame(height: 1)
                fact("Corrections", NativeNumberFormat.decimal(totals["corrections"].double))
                fact("Delete presses", NativeNumberFormat.decimal(totals["deleted"].double), "with repeats")
                fact("Presses per correction", String(format: "%.1f", totals["deletedPerCorrection"].double))
                fact("Typed between corrections", String(format: "%.0f", totals["charactersPerCorrection"].double), "characters")
                fact("Delete", NativeNumberFormat.decimal(backspace))
                fact("Forward delete", NativeNumberFormat.decimal(forward))
                fact("Speed after corrections", String(format: "%.0f", totals["netWpm"].double), "WPM")
            }
        }
    }

    private struct Point: Identifiable { let id: Int; let label: String; let keys: Double; let wpm: Double; let rate: Double }
    private func points(_ items: [JSONValue], label: (Int, JSONValue) -> String) -> [Point] {
        items.enumerated().map { .init(id: $0.offset, label: label($0.offset, $0.element), keys: $0.element["keys"].double, wpm: $0.element["wpm"].double, rate: $0.element["correctionRate"].double) }
    }
    private func chart(_ data: [Point], stride step: Int, speed: Bool) -> some View {
        Chart(data) { point in
            BarMark(x: .value("Time", point.label), y: .value("Keys", point.keys), width: .ratio(0.72))
                .foregroundStyle(Theme.ink.opacity(0.82)).cornerRadius(1)
                .accessibilityLabel(point.label).accessibilityValue("\(Int(point.keys)) keys, \(Int(point.wpm)) words per minute")
        }
        .chartXScale(domain: data.map(\.label))
        .chartXAxis {
            AxisMarks(values: data.enumerated().filter { $0.offset % max(1, step) == 0 }.map(\.element.label)) { _ in
                AxisValueLabel().font(Theme.num(10, weight: .regular)).foregroundStyle(Theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.grid)
                AxisValueLabel { if let number = value.as(Double.self) { Text(NativeNumberFormat.compact(number)).font(Theme.num(10, weight: .regular)).foregroundStyle(Theme.muted) } }
            }
        }
        .frame(height: 150)
    }
    private func speedChart(_ data: [Point], stride step: Int) -> some View {
        Chart(data.filter { $0.wpm > 0 }) { point in
            LineMark(x: .value("Time", point.label), y: .value("WPM", point.wpm)).foregroundStyle(Theme.accent).interpolationMethod(.monotone)
            PointMark(x: .value("Time", point.label), y: .value("WPM", point.wpm)).foregroundStyle(Theme.accent).symbolSize(14)
                .accessibilityLabel(point.label).accessibilityValue("\(Int(point.wpm)) words per minute")
        }
        .chartXScale(domain: data.map(\.label))
        .chartXAxis {
            AxisMarks(values: data.enumerated().filter { $0.offset % max(1, step) == 0 }.map(\.element.label)) { _ in
                AxisValueLabel().font(Theme.num(10, weight: .regular)).foregroundStyle(Theme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Theme.grid)
                AxisValueLabel { if let number = value.as(Double.self) { Text(String(format: "%.0f", number)).font(Theme.num(10, weight: .regular)).foregroundStyle(Theme.muted) } }
            }
        }
        .frame(height: 110)
    }
    private var rhythm: some View {
        let hours = points(state["hours"].array) { index, _ in String(format: "%02d", index) }
        let names = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
        let weekdays = points(state["weekdays"].array) { index, _ in names[min(index, 6)] }
        let recorded: Int = state["daily"].array.count
        let daily = points(Array(state["daily"].array.suffix(120))) { _, item in dayTitle(item["day"].string) }
        let busiest = totals["busiestHour"].isNull ? "" : "busiest " + hourTitle(totals["busiestHour"].int)
        let best = totals["bestDay"]["day"].string
        return VStack(spacing: 24) {
            columns {
                NativeCard(title: "By hour") {
                    if !busiest.isEmpty { Text(busiest).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted) }
                    chart(hours, stride: contentWidth < 620 ? 4 : 3, speed: false)
                }
            } _: {
                NativeCard(title: "By weekday") {
                    if let top = weekdays.max(by: { $0.keys < $1.keys }), top.keys > 0 {
                        Text("most on " + top.label).font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    }
                    chart(weekdays, stride: 1, speed: false)
                }
            }
            if daily.count > 1 {
                // The callouts below describe the whole range; the chart holds 120 days.
                NativeCard(title: recorded > 120 ? "By day, latest 120 of \(recorded)" : "By day") {
                    if !best.isEmpty {
                        Text("most " + dayTitle(best) + ", " + NativeNumberFormat.compact(totals["bestDay"]["keys"].double) + " keys"
                             + (totals["fastestDay"].isNull ? "" : String(format: " · fastest %@, %.0f WPM", dayTitle(totals["fastestDay"]["day"].string), totals["fastestDay"]["wpm"].double)))
                            .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                    }
                    chart(daily, stride: max(1, daily.count / (contentWidth < 620 ? 4 : 8)), speed: false)
                    Text("Speed").font(Theme.ui(Theme.textXs, weight: .medium)).foregroundStyle(Theme.muted).padding(.top, 4)
                    speedChart(daily, stride: max(1, daily.count / (contentWidth < 620 ? 4 : 8)))
                }
            }
        }
    }

    private var balance: some View {
        let left = state["hands"]["leftShare"].double, travel = totals["travelMeters"].double
        return NativeCard(title: "Hands and fingers") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Left " + percent(left) + "%").font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("Right " + percent(1 - left) + "%").font(Theme.num(Theme.textXs, weight: .medium)).foregroundStyle(Theme.dim)
                    }
                    GeometryReader { proxy in
                        HStack(spacing: 3) {
                            Rectangle().fill(Theme.ink).frame(width: max(4, (proxy.size.width - 3) * left))
                            Rectangle().fill(Theme.faint)
                        }
                    }.frame(height: 6)
                }.accessibilityElement(children: .ignore).accessibilityLabel("Hand balance")
                    .accessibilityValue("Left " + percent(left) + " percent, right " + percent(1 - left) + " percent")
                bars(state["fingers"].array, title: { $0["name"].string })
                Theme.rule.frame(height: 1)
                bars(state["rows"].array.filter { $0["count"].double > 0 }, title: { $0["name"].string })
                if travel > 0 {
                    Text(String(format: travel >= 1000 ? "About %.1f km of finger travel" : "About %.0f m of finger travel", travel >= 1000 ? travel / 1000 : travel))
                        .font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
                }
            }
        }
    }
    private var categories: some View {
        NativeCard(title: "Key types") { bars(state["categories"].array, title: { $0["name"].string }) }
    }
    private var shortcuts: some View {
        let items = state["shortcuts"].array, total = max(1, totals["shortcuts"].double)
        return NativeCard(title: "Shortcuts") {
            if items.isEmpty {
                Text("None \(rangeTitle)").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.faint)
            } else {
                let peak = items.map { $0["count"].double }.max() ?? 0
                VStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        bar(NativeKeyboardLegends.combination(item["combo"].string, legends), item["count"].double,
                            share: item["count"].double / total, peak: peak, mono: true)
                    }
                }
                Text(NativeNumberFormat.decimal(totals["shortcuts"].double) + " in total").font(Theme.ui(Theme.textXs)).foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder private func columns<Left: View, Right: View>(@ViewBuilder _ left: () -> Left, @ViewBuilder _ right: () -> Right) -> some View {
        if contentWidth >= 860 {
            HStack(alignment: .top, spacing: 32) { left().frame(maxWidth: .infinity, alignment: .top); right().frame(maxWidth: .infinity, alignment: .top) }
        } else { VStack(spacing: 24) { left(); right() } }
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
