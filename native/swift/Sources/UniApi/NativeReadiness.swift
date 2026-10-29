import SwiftUI
import AppKit
import Darwin
import UniApiCore

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
    let session: UUID
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

/// Automatic output remains read-only-only. Explicit manual recordings describe
/// the current app, never a cold start. A view commit and a display callback are
/// distinct; neither measures GPU present time.
@MainActor final class NativeUIReadiness: ObservableObject {
    static let shared = NativeUIReadiness()
    @Published private(set) var manualRecording = false
    @Published private(set) var lastURL: URL?
    @Published private(set) var recordingError: String?
    private var launch: (time: UInt64, usage: rusage)?
    private var sequence = 0
    private var phases: [Int: Set<String>] = [:]
    private var completed: [Int: NativePageReadiness] = [:]
    private var closed: Set<Int> = []
    private let output: String?
    private var session: UUID?
    private var recordingFile: NativeUIProfileFile?
    private var manualDeadline: ContinuousClock.Instant?
    private var expiry: Task<Void, Never>?
    private var statusTicket = UUID()
    private lazy var timestampFormatter = ISO8601DateFormatter()
    private init() {
        let env = ProcessInfo.processInfo.environment
        let readOnly = env["UNIAPI_NATIVE_READ_ONLY"] == "1" || CommandLine.arguments.contains("--read-only") || Bundle.main.object(forInfoDictionaryKey: "UniApiReadOnlyPreview") as? Bool == true
        let path = env["UNIAPI_NATIVE_UI_METRICS"] ?? Bundle.main.object(forInfoDictionaryKey: "UniApiUIProfileOutput") as? String
        output = readOnly && path?.hasPrefix("/") == true ? path : nil
        session = output == nil ? nil : UUID()
    }
    var automaticRecording: Bool { output != nil }
    var enabled: Bool { automaticRecording || recordingFile != nil }
    func startRecording(runtime: NativeRuntime) {
        guard !runtime.paths.readOnly else { recordingError = "Manual recording is unavailable in read-only mode."; return }
        guard !automaticRecording else { recordingError = "Automatic read-only recording is already active."; return }
        guard !manualRecording else { return }
        statusTicket = UUID()
        recordingError = nil
        do {
            let deadline = ContinuousClock().now.advanced(by: .seconds(300))
            let file = try NativeUIProfileFile(dataRoot: runtime.paths.data)
            let recordingSession = file.sessionID
            phases.removeAll(); completed.removeAll(); closed.removeAll(); launch = nil
            recordingFile = file; session = recordingSession; manualDeadline = deadline
            lastURL = file.url; manualRecording = true
            expiry = Task { [weak self] in
                do { try await Task.sleep(until: deadline, clock: .continuous) }
                catch { return }
                guard let self, self.session == recordingSession, self.manualRecording else { return }
                self.stopRecording()
            }
        } catch { recordingError = "Could not create a protected local recording file." }
    }
    func stopRecording() {
        guard !automaticRecording else { return }
        statusTicket = UUID()
        disconnectRecording()
        manualRecording = false
    }
    private func disconnectRecording() {
        // Invalidate callbacks before closing the sink. A new recording cannot
        // inherit either a prior page visit or an older expiry task.
        session = nil
        manualDeadline = nil
        expiry?.cancel(); expiry = nil
        let file = recordingFile; recordingFile = nil
        phases.removeAll(); completed.removeAll(); closed.removeAll(); launch = nil
        file?.close()
    }
    private func stopFromObservation(error: String? = nil) {
        guard recordingFile != nil else { return }
        let ticket = statusTicket
        disconnectRecording()
        // A probe can detect expiry or failure during updateNSView/draw.
        // Close admission now, but publish Settings state outside that update.
        Task { @MainActor [weak self] in
            guard let self, self.statusTicket == ticket, self.recordingFile == nil else { return }
            self.manualRecording = false
            self.recordingError = error
        }
    }
    private func withinRecordingDeadline() -> Bool {
        if automaticRecording { return true }
        guard recordingFile != nil else { return false }
        guard let manualDeadline, ContinuousClock().now < manualDeadline else {
            stopFromObservation(); return false
        }
        return true
    }
    private func accepts(_ visit: NativePageVisit) -> Bool {
        withinRecordingDeadline() && visit.session == session && !closed.contains(visit.id)
    }
    func launched() {
        guard automaticRecording else { return }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        launch = (DispatchTime.now().uptimeNanoseconds, usage)
    }
    func begin(_ page: NativeDestination, trigger: NativePageVisitTrigger = .navigation,
               parent: NativePageVisit? = nil) -> NativePageVisit? {
        guard enabled, let session else { return nil }
        sequence += 1
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        let initial = automaticRecording && sequence == 1 && trigger == .navigation
        let start = initial ? launch?.time ?? DispatchTime.now().uptimeNanoseconds : DispatchTime.now().uptimeNanoseconds
        let before = initial ? launch?.usage ?? usage : usage
        let currentParent = parent.flatMap { $0.session == session ? $0 : nil }
        let visit = NativePageVisit(id: sequence, session: session, page: page.rawValue, started: start,
            userCPU: milliseconds(before.ru_utime), systemCPU: milliseconds(before.ru_stime), initial: initial,
            trigger: trigger, parentNavigationVisit: currentParent.flatMap { $0.trigger == .navigation ? $0.id : $0.parentNavigationVisit })
        // Preserve the caller's real action if expiry crosses this boundary.
        // Its reserved token is invalid after stop and cannot admit any output.
        guard withinRecordingDeadline() else { return visit }
        if trigger != .navigation || recordingFile != nil {
            emit("visitStarted", visit: visit, now: start, usage: usage)
        }
        return visit
    }
    func complete(_ visit: NativePageVisit, readiness: NativePageReadiness) {
        guard accepts(visit), visit.trigger != .navigation else { return }
        completed[visit.id] = readiness == .pending ? nil : readiness
    }
    func end(_ visit: NativePageVisit, outcome: NativePageVisitEnd, reason: NativePageVisitEndReason) {
        guard accepts(visit), visit.trigger != .navigation else { return }
        // A departure after the accepted view commit cannot retract that commit,
        // but must still prevent a delayed draw callback from extending the visit.
        if !phases[visit.id, default: []].contains("dataViewCommit"), !phases[visit.id, default: []].contains("failureViewCommit") {
            let now = DispatchTime.now().uptimeNanoseconds
            var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
            emit(outcome.rawValue, visit: visit, now: now, usage: usage, reason: reason)
        }
        guard accepts(visit) else { return }
        closed.insert(visit.id); completed[visit.id] = nil
    }
    private func admitted(_ visit: NativePageVisit, readiness: NativePageReadiness) -> NativePageReadiness {
        visit.trigger == .navigation || completed[visit.id] == readiness ? readiness : .pending
    }
    func displayed(_ visit: NativePageVisit, readiness: NativePageReadiness) {
        guard accepts(visit) else { return }
        let readiness = admitted(visit, readiness: readiness)
        // Timestamp before this row's encoding/write. Earlier observation work
        // still contributes to the process-wide CPU interval.
        let now = DispatchTime.now().uptimeNanoseconds
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        emit("firstDisplayCallback", visit: visit, now: now, usage: usage)
        guard accepts(visit) else { return }
        if readiness != .pending, !phases[visit.id, default: []].contains("dataDisplayCallback"), !phases[visit.id, default: []].contains("failureDisplayCallback") {
            emit(readiness == .ready ? "dataDisplayCallback" : "failureDisplayCallback", visit: visit, now: now, usage: usage)
        }
    }
    func committed(_ visit: NativePageVisit, readiness: NativePageReadiness) {
        guard accepts(visit) else { return }
        let readiness = admitted(visit, readiness: readiness)
        let now = DispatchTime.now().uptimeNanoseconds
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        emit("firstViewCommit", visit: visit, now: now, usage: usage)
        guard accepts(visit) else { return }
        if readiness != .pending, !phases[visit.id, default: []].contains("dataViewCommit"), !phases[visit.id, default: []].contains("failureViewCommit") {
            emit(readiness == .ready ? "dataViewCommit" : "failureViewCommit", visit: visit, now: now, usage: usage)
        }
    }
    private func emit(_ phase: String, visit: NativePageVisit, now: UInt64, usage: rusage,
                      reason: NativePageVisitEndReason? = nil) {
        guard accepts(visit), phases[visit.id, default: []].insert(phase).inserted else { return }
        var record: [String: Any] = ["schema": 1, "pid": ProcessInfo.processInfo.processIdentifier,
            "visit": visit.id, "page": visit.page, "initial": visit.initial, "phase": phase,
            "trigger": visit.trigger.rawValue,
            "elapsedMs": Double(now - visit.started) / 1e6,
            "userCPUMs": milliseconds(usage.ru_utime) - visit.userCPU,
            "systemCPUMs": milliseconds(usage.ru_stime) - visit.systemCPU,
            "peakResidentBytes": Int64(usage.ru_maxrss), "recordedAt": timestampFormatter.string(from: Date())]
        if recordingFile != nil { record["session"] = visit.session.uuidString; record["origin"] = "manual" }
        if let parent = visit.parentNavigationVisit { record["parentNavigationVisit"] = parent }
        if let reason { record["reason"] = reason.rawValue }
        guard var data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else {
            if manualRecording { stopFromObservation(error: "Recording stopped because its metadata could not be encoded.") }
            return
        }
        data.append(10)
        guard accepts(visit) else { return }
        if let recordingFile {
            do { try recordingFile.append(data) }
            catch { stopFromObservation(error: "Recording stopped because its local file reached a limit or could not be written.") }
            return
        }
        guard let output else { return }
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
