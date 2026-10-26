import Foundation

final class FakeHardware: FanHardware {
    var fans = [Fan(id:0,actual:3000,target:3000,minimum:2000,maximum:7000,mode:0),Fan(id:1,actual:3000,target:3000,minimum:2400,maximum:7800,mode:0)]
    var sensors = [Sensor(id:"TCMb",value:60),Sensor(id:"TCMz",value:65),Sensor(id:"Tg0K",value:55)]
    var thermal = 0, restores = 0, writes = 0
    var onWrite: (() -> Void)?, afterSnapshot: (() -> Void)?
    var failRead = false, failWrite = false, failRestore = false, follow = true
    func snapshot() throws -> Snapshot { if failRead { throw FanError("read failed") }; defer { afterSnapshot?() }; return Snapshot(fans:fans,sensors:sensors,thermal:thermal) }
    func setSpeeds(_ speeds:[Double]) throws { onWrite?(); writes += 1; if failWrite { throw FanError("write failed") }; for i in fans.indices { fans[i].mode = 1; fans[i].target = speeds[i]; if follow { fans[i].actual = speeds[i] } } }
    var forcedRestores = 0
    func restore(force: Bool) throws {
        restores += 1; if force { forcedRestores += 1 }
        if failRestore { throw FanError("restore failed") }
        for i in fans.indices { fans[i].mode = 0 }
    }
}
@main struct CoreTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool,_ label:String) { count += 1; if !condition() { fputs("FAIL: \(label)\n",stderr); exit(1) }; print("PASS: \(label)") }
    static func main() throws {
        check(MemoryLayout<SMCParamStruct>.stride == 80,"SMC struct matches kernel ABI")
        check(Hardware.decode([0,0,150,66],type:"flt ") == 75,"Little-endian float decoding")
        check(Hardware.decode([31,64],type:"fpe2") == 2000,"Intel fan fixed-point decoding")
        check(Hardware.decode([42,128],type:"sp78") == 42.5,"Signed temperature decoding")
        check(Hardware.decode([0,0,192,127],type:"flt ") == nil,"NaN is not a temperature")
        check(Hardware.decode([1,2],type:"flt ") == nil,"Malformed sensor data rejected")
        check(Policy.validCurve(Policy.cooler),"Default curve valid")
        check(abs(Policy.percent(at:72.5,points:Policy.cooler)-45) < 0.01,"Curve interpolates between points")
        check(Policy.percent(at:110,points:Policy.cooler) == 100,"Curve saturates at maximum")
        var invalid = Policy.cooler; invalid[1].temperature = 44
        check(!Policy.validCurve(invalid),"Descending temperatures rejected")
        invalid = Policy.cooler; invalid[3].percent = 90
        check(!Policy.validCurve(invalid),"Curve must reach full cooling")
        check(Policy.slew(previous:5000,requested:3000) == 4880,"Fan decreases are gradual")
        check(Policy.slew(previous:3000,requested:6000) == 6000,"Fan increases are immediate")
        check(Policy.floor(peak:95) == nil && Policy.floor(peak:97) == 40 && Policy.floor(peak:100) == 100,"Hottest-sensor floor rises continuously from 95°C to full speed at 100°C")
        check(Policy.smooth(previous:nil,current:64,dt:1) == 64 && abs(Policy.smooth(previous:60,current:70,dt:4)-66.3212) < 0.001 && Policy.smooth(previous:60,current:70,dt:40) > 69.99 && abs(Policy.smooth(previous:90,current:100,dt:2,tau:2)-96.3212) < 0.001,"Temperatures are smoothed with time constants, not per-tick factors")
        let start = Date()
        do {
            let h = FakeHardware(), c = Controller(hardware:FakeHardware())
            let controller = Controller(hardware:h)
            let r = controller.handle(ControlRequest(command:"manual",duration:0,speeds:[3000,3000]),now:start)
            check(r.ok && r.until == nil,"Never accepts manual speeds without a timer")
            _ = controller.handle(ControlRequest(command:"status"),now:start.addingTimeInterval(7200))
            try controller.tick(now:start.addingTimeInterval(7200))
            check(controller.mode == "manual","Never remains manual after two hours with a live heartbeat")
            try controller.tick(now:start.addingTimeInterval(7211))
            check(controller.mode == "automatic","Never still restores automatic when the heartbeat expires")
            let invalid = c.handle(ControlRequest(command:"boost",duration:0),now:start)
            check(!invalid.ok,"Boost cannot disable its timer")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"manual",duration:0,speeds:[3000,3000]),now:start)
            // Serious thermal pressure used to hand the fans back. Measured on this M4 Pro, that is
            // the worst available response: across six hours, 31 buckets recorded a CPU die average
            // at or above 100°C (peak 108.3°C) and macOS ran the fans at 2325-3181 RPM every time,
            // against a 7826 ceiling. The OS throttling is a reason to blow harder, not to leave.
            h.thermal = 2; try c.tick(now:start.addingTimeInterval(1))
            check(c.mode == "manual","Serious thermal pressure keeps the override rather than surrendering")
            check(h.fans[0].target > h.fans[0].maximum-70,"and pins the fans at full speed instead")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            let r = c.handle(ControlRequest(command:"boost",duration:10),now:start)
            check(r.ok && c.mode == "boost", "Timed boost starts")
            check(h.fans[0].target == 7000 && h.fans[1].target == 7800,"Uses each fan’s own maximum")
            _ = c.handle(ControlRequest(command:"status"),now:start.addingTimeInterval(8))
            try c.tick(now:start.addingTimeInterval(11))
            check(c.mode == "automatic" && h.restores == 1,"Expired boost restores automatic")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"cooler"),now:start)
            try c.tick(now:start.addingTimeInterval(11))
            check(c.mode == "automatic" && h.restores == 1,"Missing GUI heartbeat releases fans")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"manual",duration:600,speeds:[2100,2500]),now:start)
            var t = 0.0
            // Fifteen heartbeat-renewed ticks let the 2-second smoothed hottest reading settle on the new value.
            func settle(_ tcmz: Double) throws { h.sensors[1].value = tcmz; for _ in 0..<15 { t += 1; _ = c.handle(ControlRequest(command:"status"),now:start.addingTimeInterval(t)); try c.tick(now:start.addingTimeInterval(t)) } }
            try settle(94)
            check(h.fans[0].target == 2100 && h.fans[1].target == 2500,"A sustained 94°C hottest core does not override manual speeds")
            try settle(97)
            check(abs(h.fans[0].target-Policy.rpm(percent:40,fan:h.fans[0])) < 70,"Hottest core at 97°C raises the manual cooling floor to 40%")
            try settle(100)
            check(h.fans[0].target > h.fans[0].maximum-70,"Hottest core at 100°C forces full speed")
            // A spike past 105 must NOT release. On this hardware TCMz peaked at 115.9°C twenty-six
            // times in one hour while macOS itself drove the fans, so a single-sample release is a
            // coin flip, and it made the mode visibly flap between a curve and Automatic. By 100°C
            // the floor already has the fans at full speed, so releasing on a spike hands the
            // hottest moment back to macOS and cools *less*.
            h.sensors[1].value = 106
            t += 1; try c.tick(now:start.addingTimeInterval(t))
            check(c.mode == "manual","A single spike past 105°C does not hand control back")
            check(h.fans[0].target > h.fans[0].maximum-70,"and the floor keeps the fans at full speed through it")
            h.sensors[1].value = 96
            t += 1; try c.tick(now:start.addingTimeInterval(t))
            check(c.mode == "manual","A spike that passes leaves the override intact")
            // Sustained heat does not release either, and that is the whole point. Measured here:
            // macOS left the fans at 2325-3181 RPM through 31 buckets of a 100°C+ die average,
            // peaking at 108.3°C. Handing it back is the one response guaranteed to cool less.
            h.sensors[1].value = 112
            for _ in 0..<8 { t += 1; _ = c.handle(ControlRequest(command:"status"),now:start.addingTimeInterval(t)); try c.tick(now:start.addingTimeInterval(t)) }
            check(c.mode == "manual","Sustained 105°C+ keeps the override instead of surrendering")
            check(h.fans[0].target > h.fans[0].maximum-70,"and holds the fans at full speed while it lasts")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"cooler"),now:start); h.thermal = 2
            try c.tick(now:start.addingTimeInterval(1))
            check(c.mode == "cooler" && h.fans[0].target > h.fans[0].maximum-70,"Serious thermal pressure pins the fans rather than releasing them")
            // And it is still possible to ACQUIRE while the machine is throttling - declining there
            // left a 107°C Mac with its fans at 2348 RPM, which is what this whole rule is about.
            let hot = FakeHardware(); hot.thermal = 3
            let c2 = Controller(hardware:hot)
            let accepted = c2.handle(ControlRequest(command:"cooler"),now:start)
            check(accepted.ok && c2.mode == "cooler","A throttling machine can still be given its fans")
            check(hot.fans[0].target > hot.fans[0].maximum-70,"and they go straight to full speed")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"cooler"),now:start); h.sensors.removeAll { $0.group == "CPU" }
            try c.tick(now:start.addingTimeInterval(1))
            check(c.mode == "automatic","Losing CPU readings releases fans even if GPU is readable")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            let r = c.handle(ControlRequest(command:"manual",duration:60,speeds:[2200,2200]),now:start)
            check(!r.ok && h.writes == 0,"Every fan minimum validated before writing")
            let invalid = c.handle(ControlRequest(command:"boost",duration:86400),now:start)
            check(!invalid.ok && h.writes == 0,"Unbounded override rejected")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h); h.fans[0].mode = 1
            let r = c.handle(ControlRequest(command:"cooler"),now:start)
            check(!r.ok && h.restores == 0 && h.writes == 0,"Does not take over another utility’s manual session")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h); h.failWrite = true
            let r = c.handle(ControlRequest(command:"cooler"),now:start)
            check(!r.ok && h.restores == 1 && c.mode == "automatic","Partial write failure triggers rollback")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"cooler"),now:start); h.failRead = true
            do { try c.tick(now:start.addingTimeInterval(1)) } catch { }
            check(h.restores == 1 && c.mode == "automatic","Read failure after takeover triggers rollback")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h); h.follow = false
            _ = c.handle(ControlRequest(command:"boost",duration:60),now:start)
            _ = c.handle(ControlRequest(command:"status"),now:start.addingTimeInterval(22))
            try c.tick(now:start.addingTimeInterval(22))
            check(c.mode == "automatic" && h.restores == 1,"Accepted targets with no actual fan response are caught")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"cooler"),now:start); h.failRestore = true
            let r = c.handle(ControlRequest(command:"automatic"),now:start)
            check(!r.ok && c.mode != "automatic","Restore failure is not reported as successful Auto")
            h.failRestore = false; try c.release("retry")
            check(c.mode == "automatic","Restore can be retried after a transient failure")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h); h.follow = false
            h.fans[0].actual = 0; h.fans[1].actual = 0
            _ = c.handle(ControlRequest(command:"cooler"),now:start)
            for i in 1...25 {
                h.sensors[0].value = i % 2 == 0 ? 70 : 80
                _ = c.handle(ControlRequest(command:"status"),now:start.addingTimeInterval(Double(i)))
                try c.tick(now:start.addingTimeInterval(Double(i)))
            }
            check(c.mode == "automatic" && h.restores == 1,"Changing curve targets cannot postpone stalled-fan recovery")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            h.sensors.append(Sensor(id:"Tg1U",value:80))
            _ = c.handle(ControlRequest(command:"cooler"),now:start)
            h.sensors.removeAll { $0.id == "Tg1U" }
            try c.tick(now:start.addingTimeInterval(1))
            check(c.mode == "automatic","Losing one governing sensor releases fans even when its group survives")
        }
        do {
            // The other half of that rule, and the one that was breaking curves in practice: Apple
            // Silicon parks idle cores, a parked core reports a sentinel below 10°C that
            // Hardware.snapshot drops, and releasing on any disappearance flapped the mode to
            // Automatic and back every time a core went to sleep. A cool sensor vanishing cannot
            // lower the reading being steered by, so it must not release.
            let h = FakeHardware(), c = Controller(hardware:h)
            h.sensors.append(Sensor(id:"HID:pACC MTR Temp Sensor7",value:41))
            _ = c.handle(ControlRequest(command:"cooler"),now:start)
            h.sensors.removeAll { $0.id == "HID:pACC MTR Temp Sensor7" }
            try c.tick(now:start.addingTimeInterval(1))
            check(c.mode == "cooler","A parked idle core disappearing does not release the fans")
            // And it is not merely deferred: the same core staying away keeps the override.
            for i in 2...6 { try c.tick(now:start.addingTimeInterval(Double(i))) }
            check(c.mode == "cooler","and it stays released-free while that core remains parked")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"cooler"),now:start)
            h.failRestore = true
            _ = c.handle(ControlRequest(command:"automatic"),now:start)
            let writes = h.writes
            do { try c.tick(now:start.addingTimeInterval(1)) } catch { }
            check(h.writes == writes,"Failed restoration is latched and cannot resume an override")
            h.failRestore = false
            try c.tick(now:start.addingTimeInterval(2))
            check(c.mode == "automatic","Watchdog retries latched restoration without another user request")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"boost",duration:10),now:start)
            h.failRestore = true
            do { try c.tick(now:start.addingTimeInterval(11)) } catch { }
            check(!c.reply.ok && c.reply.mode == "unknown" && c.reply.message.contains("pending"),"Failed watchdog restoration is visible as recovery pending")
        }
        do {
            let h = FakeHardware(); var wall = start
            let c = Controller(hardware:h,clock:{ wall })
            h.onWrite = { wall = wall.addingTimeInterval(11) }
            _ = c.handle(ControlRequest(command:"boost",duration:60),now:start)
            try c.tick(now:start.addingTimeInterval(12))
            check(c.mode == "boost", "Slow acquisition renews the heartbeat when the command finishes")
            try c.tick(now:start.addingTimeInterval(22))
            check(c.mode == "automatic", "Renewed lease still expires when heartbeats stop")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            h.failWrite = true; h.failRestore = true
            let response = c.handle(ControlRequest(command:"boost",duration:60),now:start)
            check(!response.ok && response.mode == "unknown" && h.restores == 1,"Failed command makes one blocking restore attempt then leaves recovery to watchdog")
        }
        do {
            // The 2026-09-06 field failure: die average 64°C, hottest core 78°C, GPU 57°C pinned every profile near full speed.
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            h.sensors = [Sensor(id:"TCMb",value:64),Sensor(id:"TCMz",value:78),Sensor(id:"Tg0K",value:57)]
            _ = c.handle(ControlRequest(command:"cooler"),now:start)
            let average = Policy.rpm(percent:Policy.percent(at:64,points:Policy.cooler),fan:h.fans[0])
            let hottest = Policy.rpm(percent:Policy.percent(at:78,points:Policy.cooler),fan:h.fans[0])
            check(abs(h.fans[0].target-average) < 1 && h.fans[0].target < hottest,"Curves follow the displayed die average, not the hottest core")
            h.sensors[0].value = 84
            try c.tick(now:start.addingTimeInterval(1))
            let spike = Policy.rpm(percent:Policy.percent(at:84,points:Policy.cooler),fan:h.fans[0])
            check(h.fans[0].target > average && h.fans[0].target < spike,"A one-tick spike moves the curve only part of the way")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            h.sensors = [Sensor(id:"TCMb",value:50),Sensor(id:"TCMz",value:80),Sensor(id:"Tg0K",value:75)]
            _ = c.handle(ControlRequest(command:"cooler"),now:start)
            check(abs(h.fans[0].target-Policy.rpm(percent:Policy.percent(at:75,points:Policy.cooler),fan:h.fans[0])) < 1,"The hottest GPU sensor governs when it exceeds the CPU average")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            h.sensors = [Sensor(id:"TCMb",value:60),Sensor(id:"TCMz",value:97),Sensor(id:"Tg0K",value:55)]
            _ = c.handle(ControlRequest(command:"cooler"),now:start)
            check(abs(h.fans[0].target-Policy.rpm(percent:40,fan:h.fans[0])) < 1,"The hottest-sensor floor also lifts a curve that asks for less")
        }
        do {
            let h = FakeHardware(), c: Controller; c = Controller(hardware:h)
            // Triggered by going blind - no GPU reading at all - because that is now the shape of a
            // real release: the helper cannot do its job. Heat no longer releases anything. The
            // point of this check is that the reason survives into the reply.
            h.afterSnapshot = { h.sensors.removeAll { $0.group == "GPU" } }
            let r = c.handle(ControlRequest(command:"cooler"),now:start)
            check(r.mode == "automatic" && r.message.contains("could not continue safely"),"A release during the first tick keeps its reason in the reply")
        }
        let h = FakeHardware(), sample = try h.snapshot()
        check(sample.temperature("CPU") == 60 && sample.peak == 65 && sample.governing == 60,"Display average governs the curve and differs from the safety maximum")
        // cooler/curve take no timer, so an out-of-range duration on them used to sail past every
        // check and land in `until` - infinity there is an override no expiry can ever end.
        do {
            let h = FakeHardware(), c = Controller(hardware:h)
            for bad in [Double.infinity, Double.nan, -1, 86400] {
                let r = c.handle(ControlRequest(command:"cooler",duration:bad),now:start)
                check(!r.ok && r.mode == "automatic","cooler rejects an out-of-range duration (\(bad))")
            }
            let ok = c.handle(ControlRequest(command:"cooler"),now:start)
            check(ok.ok && ok.until == nil,"cooler with no duration still has no timer")
        }
        // A daemon killed mid-override leaves the fans forced and its replacement owns nothing.
        // Only the user's explicit Automatic may reclaim that; every internal release must keep
        // its hands off, or a restart would stomp a third-party utility that legitimately owns
        // the hardware.
        do {
            let h = FakeHardware(); h.fans[0].mode = 1; h.fans[1].mode = 1
            let c = Controller(hardware:h)
            let r = c.handle(ControlRequest(command:"automatic"),now:start)
            check(r.ok && r.mode == "automatic" && h.forcedRestores == 1,"Explicit Automatic reclaims fans this process never forced")
            check(h.fans.allSatisfy { $0.isAutomatic },"Reclaim actually returns the fans to macOS")
        }
        do {
            let h = FakeHardware()
            let c = Controller(hardware:h)
            _ = c.handle(ControlRequest(command:"automatic"),now:start)
            check(h.forcedRestores == 0,"Automatic over already-automatic fans forces no write")
        }
        do {
            // An internal release (heartbeat loss here) must never force.
            let h = FakeHardware(); h.fans[0].mode = 1; h.fans[1].mode = 1
            let c = Controller(hardware:h)
            try? c.release("internal")
            check(h.forcedRestores == 0,"Internal releases never reclaim another utility's fans")
        }
        // The daemon and a temporary session share one root-owned directory and must never share
        // an endpoint: a session names itself after the server process it belongs to, and the
        // daemon's fixed name has to stay outside that namespace whatever pid comes along.
        check(IPC.directory(501) == "/var/run/app.devved.uniapi.fans-501","Socket directory is per uid under root-owned /var/run")
        check(IPC.controlPath(501) == IPC.directory(501)+"/control.sock","The installed daemon has one fixed endpoint")
        check(IPC.controlPath(501) != IPC.path(501,4242) && IPC.controlPath(501) != IPC.path(501,0),"No server pid can collide with the daemon endpoint")
        check(IPC.controlPath(501) != IPC.controlPath(502),"Each uid gets its own daemon endpoint")
        // Startup unlinks a leftover socket only when nothing answers it. `reachable` is what
        // separates a crashed daemon's file from a live one, so a second daemon cannot steal a
        // running session's path - the bind is deliberately not a blind unlink.
        check(!IPC.reachable(IPC.directory(501)+"/definitely-not-listening.sock"),"A socket path nobody listens on is not reachable")
        check(IPC.address("/tmp/x.sock").sun_family == sa_family_t(AF_UNIX),"Socket addresses are AF_UNIX")
        print("\(count) checks passed. No live fan writes performed.")
    }
}
