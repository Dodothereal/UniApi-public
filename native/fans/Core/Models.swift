import Foundation

struct Fan: Codable, Identifiable {
    var id: Int
    var actual: Double
    var target: Double
    var minimum: Double
    var maximum: Double
    var mode: Int
    var name: String { "Fan \(id + 1)" }
    var isAutomatic: Bool { mode == 0 || mode == 3 }
    var validLimits: Bool { minimum.isFinite && maximum.isFinite && minimum >= 0 && maximum > max(minimum, 500) && maximum < 20000 }
}
struct Sensor: Codable, Identifiable {
    var id: String
    var value: Double
    var group: String {
        if id.hasPrefix("HID:") {
            if id.contains("pACC") || id.contains("eACC") { return "CPU" }; if id.contains("GPU") { return "GPU" }; return "System"
        }
        if id.hasPrefix("Tp") || id.hasPrefix("TC") || id.hasPrefix("Te") { return "CPU" }
        if id.hasPrefix("Tg") || id.hasPrefix("TG") { return "GPU" }
        if id.hasPrefix("TB") { return "Battery" }
        if id.hasPrefix("Tm") || id.hasPrefix("TM") || id.hasPrefix("TR") { return "Memory" }
        if id.hasPrefix("TH") { return "Storage" }
        return "System"
    }
    var name: String {
        if id.hasPrefix("HID:") { return id.replacingOccurrences(of:"HID:",with:"").replacingOccurrences(of:"pACC MTR Temp Sensor",with:"Performance core ").replacingOccurrences(of:"eACC MTR Temp Sensor",with:"Efficiency core ").replacingOccurrences(of:"GPU MTR Temp Sensor",with:"GPU core ").replacingOccurrences(of:"SOC MTR Temp Sensor",with:"System core ") }
        switch id {
        case "TCMb": return "CPU die average"
        case "TCMz": return "CPU die maximum"
        case "TB0T": return "Battery"
        case "TH0x": return "SSD"
        case "TA0P", "TAOL": return "Ambient"
        case "TS0P": return "Palm rest"
        default: return "\(group) · \(id)"
        }
    }
}
struct Snapshot: Codable {
    var date: Date = Date()
    var fans: [Fan]
    var sensors: [Sensor]
    var thermal: Int
    var peak: Double? { sensors.filter { $0.group == "CPU" || $0.group == "GPU" }.map(\.value).max() }
    // Curves follow the readings the page shows: the CPU die average (TCMb) and the hottest GPU sensor.
    // The hottest single core (TCMz, part of `peak`) idles near 80°C on Apple Silicon and reaches the
    // mid-90s under macOS's own minimum-RPM automatic control, so a curve keyed to it pins the fans.
    var governing: Double? { [temperature("CPU"), temperature("GPU")].compactMap { $0 }.max() }
    func temperature(_ group: String) -> Double? {
        if group == "CPU", let average = sensors.first(where: { $0.id == "TCMb" }) { return average.value }
        return sensors.filter { $0.group == group }.map(\.value).max()
    }
}
struct CurvePoint: Codable, Equatable {
    var temperature: Double
    var percent: Double
}
struct ControlRequest: Codable {
    var command: String
    var duration: Double? = nil
    var speeds: [Double]? = nil
    var curve: [CurvePoint]? = nil
}
struct ControlReply: Codable {
    var ok: Bool
    var message: String
    var mode: String
    var until: Date?
}
struct FanError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Policy {
    static let cooler = [CurvePoint(temperature: 45, percent: 0), CurvePoint(temperature: 65, percent: 25), CurvePoint(temperature: 80, percent: 65), CurvePoint(temperature: 90, percent: 100)]
    static func validCurve(_ points: [CurvePoint]) -> Bool {
        guard points.count == 4, points.last?.percent == 100, let last = points.last, last.temperature <= 90 else { return false }
        for (i,p) in points.enumerated() {
            guard p.temperature.isFinite, p.percent.isFinite, (30...90).contains(p.temperature), (0...100).contains(p.percent) else { return false }
            if i > 0 && (p.temperature - points[i-1].temperature < 5 || p.percent < points[i-1].percent) { return false }
        }
        return true
    }
    static func percent(at temperature: Double, points: [CurvePoint]) -> Double {
        guard temperature.isFinite, validCurve(points) else { return 100 }
        if temperature <= points[0].temperature { return points[0].percent }
        for i in 1..<points.count where temperature <= points[i].temperature {
            let a = points[i-1], b = points[i]
            return a.percent + (b.percent-a.percent) * (temperature-a.temperature)/(b.temperature-a.temperature)
        }
        return 100
    }
    static func rpm(percent: Double, fan: Fan) -> Double {
        let floor = max(fan.minimum, 1200)
        return min(fan.maximum, floor + (fan.maximum-floor)*max(0,min(100,percent))/100)
    }
    /// Heat never hands the fans back. It is the one moment they are worth holding.
    ///
    /// This released at 105°C, and then - once that proved to be a coin flip on a sensor that
    /// spikes - at a *sustained* 105°C. Both were wrong, and the measurement that settles it was
    /// taken on this machine: in six hours, 31 history buckets recorded a CPU die **average** at or
    /// above 100°C, peaking at 108.3°C, and on every one of them macOS was running the fans between
    /// 2325 and 3181 RPM. Near idle. Against a 7826 RPM ceiling.
    ///
    /// So "it is too hot, let the system take over" hands the hottest moment to a system that does
    /// essentially nothing, and the user watches a 107°C machine with fans at 2348 RPM. Holding is
    /// strictly better: `Policy.floor` already ramps to 100% by 100°C, and full airflow cannot harm
    /// anything. Serious macOS thermal pressure is treated the same way - it means the OS is
    /// throttling, which is a reason to blow harder, not to walk away.
    ///
    /// What still releases is the set of things that mean *this helper cannot do its job*: it has
    /// gone blind (no CPU or GPU reading), nobody is listening (heartbeat), the user's timer
    /// finished, or the fans are not there. Those are about competence, not temperature.
    static func shouldRelease(snapshot: Snapshot, heartbeatAge: Double, expired: Bool) -> Bool {
        guard snapshot.temperature("CPU") != nil, snapshot.temperature("GPU") != nil, let peak = snapshot.peak, peak.isFinite else { return true }
        return expired || heartbeatAge > 10 || heartbeatAge < 0 || snapshot.fans.isEmpty || snapshot.fans.contains { !$0.validLimits }
    }
    static func slew(previous: Double, requested: Double) -> Double {
        // Rise immediately for cooling; release noise gradually to avoid oscillation.
        requested >= previous ? requested : max(requested, previous - 120)
    }
    // Emergency floor from the hottest processor sensor, in every mode: rises linearly from 0% at 95°C
    // to 100% at 100°C. Continuous on purpose: a step at the threshold turned every brief crossing into a
    // jump followed by a slow slew down, and the die maximum crosses 95°C hundreds of times a day under
    // macOS's own fans. The controller feeds it a 2-second smoothed reading; the 105°C release and the
    // guard in setSpeeds use the raw one. App policy, not a silicon limit.
    static func floor(peak: Double) -> Double? { peak > 95 ? min(100, (peak - 95) * 20) : nil }
    /// The floor, including macOS's own distress signal. Serious or critical thermal pressure means
    /// the OS is throttling the machine to cope; the useful response to that is every RPM there is.
    static func floor(peak: Double, thermal: Int) -> Double? {
        if thermal >= 2 { return 100 }
        return floor(peak: peak)
    }
    // A die average still swings several degrees between ticks. Rises are immediate and decreases are
    // slewed, so without this average every spike ratchets the fans up and holds them there. Ticks land
    // 1-2 s apart depending on IPC traffic, hence a time constant (4 s) rather than a per-tick factor.
    static func smooth(previous: Double?, current: Double, dt: Double, tau: Double = 4) -> Double {
        guard let previous, dt.isFinite, dt > 0 else { return current }
        return previous + (current - previous) * (1 - exp(-dt / tau))
    }
}
