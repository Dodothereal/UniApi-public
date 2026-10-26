import Foundation

final class Controller {
    let hardware: FanHardware
    private(set) var mode = "automatic"
    private(set) var until: Date?
    private(set) var message = "macOS manages your fans."
    private var heartbeat = Date()
    private var points = Policy.cooler
    private var manual: [Double] = []
    private var previous: [Double] = []
    private var owned = false
    private var restoring = false
    private var restoreReason = ""
    private var mismatchSince: Date?
    private var governing: Double?
    private var hottest: Double?
    private var governingAt: Date?
    private var requiredSensors = Set<String>()
    /// Last good reading per frozen sensor. A sensor that vanishes is only a problem if it was as
    /// hot as the one being steered by; this is what tells the two apart.
    private var lastSeen: [String: Double] = [:]
    private let clock: () -> Date
    init(hardware: FanHardware, clock: @escaping () -> Date = Date.init) { self.hardware = hardware; self.clock = clock }
    var reply: ControlReply {
        if restoring { return ControlReply(ok:false,message:"Automatic restoration is pending: " + restoreReason,mode:"unknown",until:nil) }
        return ControlReply(ok:true,message:message,mode:mode,until:until)
    }
    func release(_ reason: String, force: Bool = false) throws {
        restoring = true; restoreReason = reason
        if owned || force { try hardware.restore(force: force) }
        restoring = false
        owned = false; mode = "automatic"; until = nil; previous = []; mismatchSince = nil; governing = nil; hottest = nil; governingAt = nil; requiredSensors = []; lastSeen = [:]; message = reason
    }
    func handle(_ request: ControlRequest, now: Date = Date()) -> ControlReply {
        let started = clock()
        do {
            if request.command == "status" { heartbeat = now; return reply }
            if request.command == "automatic" {
                // An explicit Automatic is the user's own instruction, and it is the only thing
                // allowed to reclaim fans this process never touched. It has to be: a daemon
                // killed mid-override (SIGKILL, a crash, launchd's exit timeout beating the
                // restore retry) leaves F*md set, and its replacement starts with owned=false, so
                // every internal release path correctly declines to write and the fans stay
                // pinned with macOS thermal control disabled until a reboot. Internal releases
                // must keep declining - forcing there would stomp a third-party fan utility that
                // legitimately owns the hardware.
                let orphaned = !owned && ((try? hardware.snapshot())?.fans.contains { !$0.isAutomatic } ?? false)
                try release("macOS manages your fans.", force: orphaned)
                return reply
            }
            guard !restoring else { throw FanError("Automatic restoration is still pending. Retry Restore automatic.") }
            guard ["boost", "manual", "cooler", "curve"].contains(request.command) else { throw FanError("Unknown control request.") }
            let snapshot = try hardware.snapshot()
            guard !Policy.shouldRelease(snapshot:snapshot,heartbeatAge:0,expired:false) else { throw FanError("Valid fan and processor readings are required. macOS retains control.") }
            if !owned && snapshot.fans.contains(where: { !$0.isAutomatic }) { throw FanError("Another utility is controlling the fans. Return it to Auto first.") }
            if request.command == "boost" || request.command == "manual" {
                guard let duration = request.duration, duration.isFinite, ((10...3600).contains(duration) || (request.command == "manual" && duration == 0)) else { throw FanError("Choose 10 seconds to 60 minutes, or Never for manual speeds.") }
            }
            // cooler and curve carry no timer, so a duration on them was previously accepted
            // unchecked and flowed straight into `until` below. An infinite or NaN value there
            // produces an `until` that no comparison can ever make true and that JSONEncoder
            // refuses to encode, which loses the reply the heartbeat is carried on. The helper
            // validates its own inputs; it does not get to assume the Node side already did.
            if let duration = request.duration, !(duration.isFinite && (0...3600).contains(duration)) {
                throw FanError("Choose 10 seconds to 60 minutes, or Never for manual speeds.")
            }
            if request.command == "curve" {
                guard let curve = request.curve, Policy.validCurve(curve) else { throw FanError("Use four rising curve points, at least 5° apart, reaching 100% by 90°C.") }
                points = curve
            } else { points = Policy.cooler }
            if request.command == "manual" {
                guard let speeds = request.speeds, speeds.count == snapshot.fans.count else { throw FanError("Provide a speed for each fan.") }
                for (rpm,fan) in zip(speeds,snapshot.fans) {
                    guard rpm.isFinite, rpm >= max(1200,fan.minimum), rpm <= fan.maximum else { throw FanError("Choose speeds within each fan’s supported range.") }
                }
                manual = speeds
            }
            // Zero explicitly disables only the manual timer; the heartbeat and thermal releases stay active.
            mode = request.command; until = request.command == "manual" && request.duration == 0 ? nil : request.duration.map { now.addingTimeInterval($0) }
            heartbeat = now; previous = []; mismatchSince = nil; governing = nil; hottest = nil; governingAt = nil; requiredSensors = Set(snapshot.sensors.filter { $0.group == "CPU" || $0.group == "GPU" }.map(\.id))
            lastSeen = Dictionary(uniqueKeysWithValues: snapshot.sensors.map { ($0.id, $0.value) }); owned = true
            try tick(now:now)
            if owned && !restoring { heartbeat = now.addingTimeInterval(clock().timeIntervalSince(started)) }
            // The first tick may already have released (a sensor vanished, 105°C, thermal pressure); keep its reason.
            if owned { message = mode == "boost" ? "Boost ends automatically." : mode == "manual" ? "Manual speeds are active. Thermal protection stays on." : "Following the CPU and GPU readings shown on the overview. Thermal protection stays on." }
            return reply
        } catch {
            let original = error.localizedDescription
            if !restoring {
                do { try release(original) } catch { message = original + " " + error.localizedDescription }
            }
            let state = reply
            return ControlReply(ok:false,message:state.message,mode:state.mode,until:state.until)
        }
    }
    func tick(now: Date = Date()) throws {
        guard owned else { return }
        if restoring { try release(restoreReason); return }
        do {
            let snapshot = try hardware.snapshot()
            // Smoothing first, because the release decision below now depends on it. The raw
            // hottest sensor swings far too hard to be tested a single sample at a time.
            let rawPeak = snapshot.peak ?? 0
            let dtHot = governingAt.map { now.timeIntervalSince($0) } ?? 0
            let smoothedPeak = Policy.smooth(previous:hottest,current:rawPeak,dt:dtHot,tau:2)
            if Policy.shouldRelease(snapshot:snapshot,heartbeatAge:now.timeIntervalSince(heartbeat),expired:until.map{ now >= $0 } ?? false) {
                let reason = until.map{ now >= $0 } == true ? "Session finished. macOS manages your fans." : "Fan control could not continue safely. macOS manages your fans."
                try release(reason); return
            }
            // A frozen sensor going missing is not by itself a fault. Apple Silicon parks idle
            // cores, and a parked core reports a low single-digit sentinel that Hardware.snapshot
            // drops as invalid - so on an ordinary machine sensors come and go all day. Releasing
            // on any disappearance made a curve flap to Automatic and back every time a core went
            // to sleep. What the rule is actually protecting against is losing the sensor being
            // steered by and silently under-cooling from a cooler one, so test exactly that: a
            // sensor that was at least as hot as the current governing reading is one whose loss
            // could lower it. Anything cooler is dropped from the set and the override continues.
            let present = Set(snapshot.sensors.map(\.id))
            let missing = requiredSensors.subtracting(present)
            if !missing.isEmpty {
                let steering = snapshot.governing ?? snapshot.peak ?? 0
                if missing.contains(where: { (lastSeen[$0] ?? .infinity) >= steering }) {
                    try release("A processor sensor stopped reporting. Automatic control restored."); return
                }
                requiredSensors.subtract(missing)
            }
            for sensor in snapshot.sensors where requiredSensors.contains(sensor.id) { lastSeen[sensor.id] = sensor.value }
            if mode == "manual" && manual.count != snapshot.fans.count {
                try release("Fan configuration changed. Automatic control restored."); return
            }
            if !previous.isEmpty {
                let mismatch = zip(snapshot.fans,previous).contains { abs($0.actual-$1) > max(500,$1*0.2) }
                if mismatch {
                    if mismatchSince == nil { mismatchSince = now }
                    if now.timeIntervalSince(mismatchSince!) >= 20 {
                        try release("The fans did not reach their requested speeds. Automatic control restored."); return
                    }
                } else { mismatchSince = nil }
            }
            let peak = snapshot.peak!
            // `?? peak` is a belt only: shouldRelease already required both group temperatures, which is what makes `governing` non-nil.
            let smoothed = Policy.smooth(previous:governing,current:snapshot.governing ?? peak,dt:dtHot)
            let hot = smoothedPeak
            governing = smoothed; hottest = hot; governingAt = now
            var speeds = snapshot.fans.enumerated().map { i, fan -> Double in
                if mode == "boost" { return fan.maximum }
                if mode == "manual" { return manual[i] }
                return Policy.rpm(percent:Policy.percent(at:smoothed,points:points),fan:fan)
            }
            // The hottest sensor steers speeds only here, and the floor applies to manual speeds too.
            // Heat raises the floor, it never hands back. Full airflow is the useful answer to a
            // hot machine; surrendering to macOS measurably is not (see Policy.shouldRelease).
            if let floor = Policy.floor(peak:hot,thermal:snapshot.thermal) { speeds = zip(speeds,snapshot.fans).map { max($0,Policy.rpm(percent:floor,fan:$1)) } }
            if previous.count == speeds.count { speeds = zip(previous,speeds).map{ Policy.slew(previous:$0,requested:$1) } }
            if previous.count != speeds.count || zip(previous,speeds).contains(where:{ abs($0-$1) >= 60 }) {
                try hardware.setSpeeds(speeds)
                previous = speeds
                if mismatchSince == nil, zip(snapshot.fans,speeds).contains(where: { abs($0.actual-$1) > max(500,$1*0.2) }) { mismatchSince = now }
            }
        } catch {
            let original = error
            if !restoring { try release("Control interrupted: \(original.localizedDescription)") }
            throw original
        }
    }
}
