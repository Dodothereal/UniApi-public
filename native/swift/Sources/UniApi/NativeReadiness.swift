import SwiftUI
import AppKit
import Darwin

enum NativePageReadiness: String {
    case pending, ready, failed
}

enum NativePageVisitTrigger: String {
    case navigation, refresh, rebuild
}

enum NativePageVisitEnd: String {
    case cancelled, incomplete
}

enum NativePageVisitEndReason: String {
    case replacedRead, scopeChanged, inactive, disappeared, taskCancelled, noAcceptedCommit
}

struct NativePageVisit {
    let id: Int
    let page: String
    let started: UInt64
    let userCPU: Double
    let systemCPU: Double
    let initial: Bool
    let trigger: NativePageVisitTrigger
    let parentNavigationVisit: Int?
}

private struct NativePageVisitKey: EnvironmentKey {
    static let defaultValue: NativePageVisit? = nil
}

extension EnvironmentValues {
    var nativePageVisit: NativePageVisit? {
        get { self[NativePageVisitKey.self] }
        set { self[NativePageVisitKey.self] = newValue }
    }
}

/// Passive measurement is opt-in and read-only. Commit callbacks measure the
/// hosting view's state update independently of occluded-window drawing. A
/// display callback proves that view drew; neither measures GPU present time.
@MainActor final class NativeUIReadiness {
    static let shared = NativeUIReadiness()
    private var launch: (time: UInt64, usage: rusage)?
    private var sequence = 0
    private var phases: [Int: Set<String>] = [:]
    private var completed: [Int: NativePageReadiness] = [:]
    private var closed: Set<Int> = []
    private let output: String?
    private init() {
        let env = ProcessInfo.processInfo.environment
        let readOnly = env["UNIAPI_NATIVE_READ_ONLY"] == "1" || CommandLine.arguments.contains("--read-only") || Bundle.main.object(forInfoDictionaryKey: "UniApiReadOnlyPreview") as? Bool == true
        let path = env["UNIAPI_NATIVE_UI_METRICS"] ?? Bundle.main.object(forInfoDictionaryKey: "UniApiUIProfileOutput") as? String
        output = readOnly && path?.hasPrefix("/") == true ? path : nil
    }
    var enabled: Bool { output != nil }
    func launched() {
        guard enabled else { return }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        launch = (DispatchTime.now().uptimeNanoseconds, usage)
    }
    func begin(_ page: NativeDestination, trigger: NativePageVisitTrigger = .navigation,
               parent: NativePageVisit? = nil) -> NativePageVisit? {
        guard enabled else { return nil }
        sequence += 1
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let initial = sequence == 1 && trigger == .navigation
        let start = initial ? launch?.time ?? DispatchTime.now().uptimeNanoseconds : DispatchTime.now().uptimeNanoseconds
        let before = initial ? launch?.usage ?? usage : usage
        let visit = NativePageVisit(id: sequence, page: page.rawValue, started: start,
            userCPU: milliseconds(before.ru_utime), systemCPU: milliseconds(before.ru_stime), initial: initial,
            trigger: trigger, parentNavigationVisit: parent.flatMap { $0.trigger == .navigation ? $0.id : $0.parentNavigationVisit })
        if trigger != .navigation { emit("visitStarted", visit: visit, now: start, usage: usage) }
        return visit
    }
    func complete(_ visit: NativePageVisit, readiness: NativePageReadiness) {
        guard visit.trigger != .navigation, !closed.contains(visit.id) else { return }
        completed[visit.id] = readiness == .pending ? nil : readiness
    }
    func end(_ visit: NativePageVisit, outcome: NativePageVisitEnd, reason: NativePageVisitEndReason) {
        guard visit.trigger != .navigation, !closed.contains(visit.id) else { return }
        // A departure after the accepted view commit cannot retract that commit,
        // but must still prevent a delayed draw callback from extending the visit.
        if !phases[visit.id, default: []].contains("dataViewCommit"), !phases[visit.id, default: []].contains("failureViewCommit") {
            let now = DispatchTime.now().uptimeNanoseconds
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            emit(outcome.rawValue, visit: visit, now: now, usage: usage, reason: reason)
        }
        closed.insert(visit.id); completed[visit.id] = nil
    }
    private func admitted(_ visit: NativePageVisit, readiness: NativePageReadiness) -> NativePageReadiness {
        visit.trigger == .navigation || completed[visit.id] == readiness ? readiness : .pending
    }
    func displayed(_ visit: NativePageVisit, readiness: NativePageReadiness) {
        guard !closed.contains(visit.id) else { return }
        let readiness = admitted(visit, readiness: readiness)
        // Timestamp before encoding/writing so the observer's I/O is excluded.
        let now = DispatchTime.now().uptimeNanoseconds
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        emit("firstDisplayCallback", visit: visit, now: now, usage: usage)
        if readiness != .pending, !phases[visit.id, default: []].contains("dataDisplayCallback"), !phases[visit.id, default: []].contains("failureDisplayCallback") {
            emit(readiness == .ready ? "dataDisplayCallback" : "failureDisplayCallback", visit: visit, now: now, usage: usage)
        }
    }
    func committed(_ visit: NativePageVisit, readiness: NativePageReadiness) {
        guard !closed.contains(visit.id) else { return }
        let readiness = admitted(visit, readiness: readiness)
        let now = DispatchTime.now().uptimeNanoseconds
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        emit("firstViewCommit", visit: visit, now: now, usage: usage)
        if readiness != .pending, !phases[visit.id, default: []].contains("dataViewCommit"), !phases[visit.id, default: []].contains("failureViewCommit") {
            emit(readiness == .ready ? "dataViewCommit" : "failureViewCommit", visit: visit, now: now, usage: usage)
        }
    }
    private func emit(_ phase: String, visit: NativePageVisit, now: UInt64, usage: rusage,
                      reason: NativePageVisitEndReason? = nil) {
        guard phases[visit.id, default: []].insert(phase).inserted, let output else { return }
        var record: [String: Any] = ["schema": 1, "pid": ProcessInfo.processInfo.processIdentifier,
            "visit": visit.id, "page": visit.page, "initial": visit.initial, "phase": phase,
            "trigger": visit.trigger.rawValue,
            "elapsedMs": Double(now - visit.started) / 1e6,
            "userCPUMs": milliseconds(usage.ru_utime) - visit.userCPU,
            "systemCPUMs": milliseconds(usage.ru_stime) - visit.systemCPU,
            "peakResidentBytes": Int64(usage.ru_maxrss), "recordedAt": ISO8601DateFormatter().string(from: Date())]
        if let parent = visit.parentNavigationVisit { record["parentNavigationVisit"] = parent }
        if let reason { record["reason"] = reason.rawValue }
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        data.append(10)
        let fd = open(output, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { return }; defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { return }
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { break }; offset += count
            }
        }
    }
    private func milliseconds(_ value: timeval) -> Double { Double(value.tv_sec) * 1000 + Double(value.tv_usec) / 1000 }
}

struct NativeReadinessProbe: NSViewRepresentable {
    let visit: NativePageVisit
    let readiness: NativePageReadiness
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        view.visit = visit; view.readiness = readiness; view.needsDisplay = true
        NativeUIReadiness.shared.committed(visit, readiness: readiness)
    }
    final class Probe: NSView {
        var visit: NativePageVisit?
        var readiness = NativePageReadiness.pending
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard window?.isVisible == true, let visit else { return }
            NativeUIReadiness.shared.displayed(visit, readiness: readiness)
        }
        override func isAccessibilityElement() -> Bool { false }
    }
}
