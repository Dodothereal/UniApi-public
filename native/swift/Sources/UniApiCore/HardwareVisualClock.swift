import Foundation

/// Integrate playback time at telemetry boundaries, so a new rate never jumps
/// the existing animation to an unrelated phase. Hidden views freeze it.
public struct NativeVisualClock: Sendable {
    private var accumulated: Double = 0
    private var anchor: Double = 0
    private var rate: Double = 0
    public init() {}
    public func value(at time: Double) -> Double {
        accumulated + max(0, time - anchor) * rate
    }
    public mutating func update(at time: Double, rate: Double) {
        guard time.isFinite, rate.isFinite else { return }
        accumulated = value(at: time)
        anchor = time
        self.rate = max(0, rate)
    }
    public static func fanRate(_ rpm: Double) -> Double {
        guard rpm.isFinite else { return 0 }
        return min(3.2, max(0, rpm) / 2500 + max(0, rpm - 2500) / 2200)
    }
}
