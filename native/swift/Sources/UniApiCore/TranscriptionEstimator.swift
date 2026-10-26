import Foundation

public enum NativeTranscriptionPhase: String, Sendable { case download, decode, transcribe }

public struct NativeTranscriptionEstimator: Sendable {
    private let db: NativeDatabase
    public init(db: NativeDatabase) { self.db = db }
    public func rate(kind: String, key: String?, phase: NativeTranscriptionPhase) throws -> JSONValue {
        func rates(_ key: String?) throws -> [Double] {
            let filter = key == nil ? "" : " AND \(kind == "url" ? "host" : "ext")=?"
            let params: [JSONValue] = [.string(kind)] + (key.map { [JSONValue.string($0)] } ?? [])
            let rows = try db.query("SELECT \(phase.rawValue)_ms AS v,duration_s AS d,bytes AS b FROM transcribe_runs WHERE \(phase.rawValue)_ms IS NOT NULL AND \(phase.rawValue)_ms>0 AND kind=?\(filter) ORDER BY ts DESC LIMIT 12", params)
            return rows.compactMap { row in
                let value = (row["v"] ?? .null).double
                let denominator = phase == .download ? (row["b"] ?? .null).double : max(1, (row["d"] ?? .null).double)
                let rate = value / denominator
                return rate.isFinite && rate > 0 ? rate : nil
            }
        }
        let specific = try rates(key).sorted()
        if !specific.isEmpty { return ["value": .number(specific[specific.count / 2]), "basis": .string(key.map { "\($0) (\(specific.count) runs)" } ?? kind)] }
        let generic = try rates(nil).sorted()
        if !generic.isEmpty { return ["value": .number(generic[generic.count / 2]), "basis": .string(kind == "url" ? "links so far" : "files so far")] }
        return ["value": .number(phase == .download ? 0.0004 : phase == .decode ? 4 : 32), "basis": "built-in default"]
    }
    public func estimate(kind: String, key: String?, duration: Double, bytes: Int?, from phase: NativeTranscriptionPhase) throws -> JSONValue {
        let phases: [NativeTranscriptionPhase] = phase == .download ? [.download, .decode, .transcribe] : phase == .decode ? [.decode, .transcribe] : [.transcribe]
        var ms: Double = 0, basis = ""
        for p in phases {
            let rate = try rate(kind: kind, key: key, phase: p)
            ms += rate["value"].double * (p == .download ? Double(bytes ?? 0) : max(0, duration))
            if p == .transcribe { basis = rate["basis"].string }
        }
        return ["ms": .number(ms), "basis": .string(basis)]
    }
}
