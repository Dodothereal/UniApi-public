import QuartzCore
import XCTest
@testable import UniApiCore

@MainActor final class FanRotationRendererAcceptanceTests: XCTestCase {
    func testConstantRPMUsesOneLinearLayerAnimationAcrossRepeatedTelemetry() throws {
        let clock = FanRotationFixtureClock(100), layer = FanRotationRecordingLayer()
        let renderer = NativeFanRotationRenderer(layer: layer, now: { clock.time })
        renderer.update(rpm: 2500, reduceMotion: false, visible: true)
        let first = try animation(layer)
        XCTAssertEqual(first.keyPath, "transform.rotation.z")
        XCTAssertEqual(try number(first.fromValue), 0)
        XCTAssertEqual(try number(first.toValue), -2 * .pi, accuracy: 1e-12)
        XCTAssertEqual(first.duration, 1); XCTAssertTrue(first.repeatCount.isInfinite)
        XCTAssertEqual(layer.operations, [.remove(NativeFanRotationRenderer.animationKey), .add(NativeFanRotationRenderer.animationKey)])
        let timing = try XCTUnwrap(first.timingFunction)
        var point = [Float](repeating: -1, count: 2)
        point.withUnsafeMutableBufferPointer { timing.getControlPoint(at: 1, values: $0.baseAddress!) }
        XCTAssertEqual(point, [0, 0])
        point.withUnsafeMutableBufferPointer { timing.getControlPoint(at: 2, values: $0.baseAddress!) }
        XCTAssertEqual(point, [1, 1])
        for tick in 1...1000 {
            clock.time = 100 + Double(tick) / 30
            renderer.update(rpm: 2500, reduceMotion: false, visible: true)
        }
        XCTAssertEqual(layer.additions, 1); XCTAssertEqual(layer.removals, 1)
        XCTAssertEqual(try animation(layer).beginTime, first.beginTime)
        XCTAssertEqual(try number(animation(layer).fromValue), 0)
    }

    func testRPMChangesAndZeroResumePreserveClockPhaseAndClockwiseDirection() throws {
        let clock = FanRotationFixtureClock(100), layer = FanRotationRecordingLayer()
        let renderer = NativeFanRotationRenderer(layer: layer, now: { clock.time })
        renderer.update(rpm: 2500, reduceMotion: false, visible: true)
        clock.time = 101.25
        renderer.update(rpm: 1250, reduceMotion: false, visible: true)
        XCTAssertEqual(try number(animation(layer).fromValue), -.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(try animation(layer).duration, 2)
        clock.time = 102.25
        renderer.update(rpm: 0, reduceMotion: false, visible: true)
        assertStopped(layer)
        assertPose(layer, angle: -1.5 * .pi)
        clock.time = 900
        renderer.update(rpm: 1250, reduceMotion: false, visible: true)
        XCTAssertEqual(try number(animation(layer).fromValue), -1.5 * .pi, accuracy: 1e-12)
        clock.time = 901
        renderer.update(rpm: 0, reduceMotion: false, visible: true)
        assertPose(layer, angle: -.pi / 2)
    }

    func testReducedMotionAndVisibilityFreezePhaseWhileTelemetryChanges() throws {
        let clock = FanRotationFixtureClock(10), layer = FanRotationRecordingLayer()
        let renderer = NativeFanRotationRenderer(layer: layer, now: { clock.time })
        renderer.update(rpm: 2500, reduceMotion: false, visible: true)
        clock.time = 10.25
        renderer.update(rpm: 2500, reduceMotion: true, visible: true)
        assertPose(layer, angle: -.pi / 2)
        assertStopped(layer)
        clock.time = 20
        renderer.update(rpm: 9000, reduceMotion: true, visible: true)
        clock.time = 30
        renderer.update(rpm: 1250, reduceMotion: false, visible: false)
        XCTAssertEqual(layer.additions, 1); assertPose(layer, angle: -.pi / 2)
        clock.time = 100
        renderer.update(rpm: 1250, reduceMotion: false, visible: true)
        XCTAssertEqual(try number(animation(layer).fromValue), -.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(try animation(layer).duration, 2)
        clock.time = 101
        renderer.update(rpm: 1250, reduceMotion: true, visible: true)
        assertPose(layer, angle: -1.5 * .pi)
        assertStopped(layer)
    }

    func testDetachStopAndReattachResumeWithoutAdvancingHiddenTime() throws {
        let clock = FanRotationFixtureClock(50), layer = FanRotationRecordingLayer()
        let renderer = NativeFanRotationRenderer(layer: layer, now: { clock.time })
        renderer.update(rpm: 2500, reduceMotion: false, visible: true)
        clock.time = 50.125; renderer.stop()
        assertStopped(layer)
        assertPose(layer, angle: -.pi / 4)
        clock.time = 500; renderer.stop()
        XCTAssertEqual(layer.removals, 2)
        renderer.update(rpm: 9000, reduceMotion: false, visible: true)
        XCTAssertEqual(try number(animation(layer).fromValue), -.pi / 4, accuracy: 1e-12)
        XCTAssertEqual(try animation(layer).duration, 1 / 3.2, accuracy: 1e-12)
        renderer.stop()
        assertStopped(layer)
    }

    func testInvalidRPMAndInvalidClockCannotInstallAnInvalidAnimation() throws {
        let clock = FanRotationFixtureClock(100), layer = FanRotationRecordingLayer()
        let renderer = NativeFanRotationRenderer(layer: layer, now: { clock.time })
        renderer.update(rpm: 2500, reduceMotion: false, visible: true)
        clock.time = 100.25
        renderer.update(rpm: .nan, reduceMotion: false, visible: true)
        for rpm in [Double.infinity, -Double.infinity, -1, 0] {
            clock.time += 1
            renderer.update(rpm: rpm, reduceMotion: false, visible: true)
            assertStopped(layer)
            assertPose(layer, angle: -.pi / 2)
        }
        clock.time = 200
        renderer.update(rpm: 2500, reduceMotion: false, visible: true)
        let resumed = try animation(layer)
        clock.time = .nan
        renderer.update(rpm: 1250, reduceMotion: false, visible: true)
        XCTAssertEqual(layer.additions, 2)
        XCTAssertEqual(try animation(layer).beginTime, resumed.beginTime)
        clock.time = 201
        renderer.update(rpm: 1250, reduceMotion: false, visible: true)
        XCTAssertEqual(try number(animation(layer).fromValue), -.pi / 2, accuracy: 1e-12)
        XCTAssertEqual(try animation(layer).duration, 2)
    }

    func testLayerBoundsScaleAndContentsChangesDoNotRestartPhase() throws {
        let clock = FanRotationFixtureClock(10), layer = FanRotationRecordingLayer()
        let renderer = NativeFanRotationRenderer(layer: layer, now: { clock.time })
        renderer.update(rpm: 1250, reduceMotion: false, visible: true)
        let first = try animation(layer)
        let pixels = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (index, size) in [17, 28, 40].enumerated() {
            clock.time = 10 + Double(index) / 4
            renderer.layout(in: CGRect(x: 0, y: 0, width: CGFloat(size), height: CGFloat(size)), contentsScale: index == 0 ? 1 : 2)
            pixels.setFillColor(CGColor(gray: index == 0 ? 0.25 : 0.75, alpha: 1))
            pixels.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            layer.contents = try XCTUnwrap(pixels.makeImage())
            renderer.update(rpm: 1250, reduceMotion: false, visible: true)
            XCTAssertEqual(try animation(layer).beginTime, first.beginTime)
        }
        XCTAssertEqual(layer.additions, 1)
        clock.time = 10.5; renderer.stop()
        assertPose(layer, angle: -.pi / 2)
    }

    func testFixedMenuRateRetainsCounterclockwiseDirectionAndPausedPhase() throws {
        XCTAssertEqual(NativeVisualClock.fanRate(1000), 0.4)
        let clock = FanRotationFixtureClock(10), layer = FanRotationRecordingLayer()
        let defaultLayer = FanRotationRecordingLayer()
        let defaultRenderer = NativeFanRotationRenderer(layer: defaultLayer) { clock.time }
        defaultRenderer.update(rpm: 1000, reduceMotion: false, visible: true)
        XCTAssertEqual(try number(animation(defaultLayer).toValue), -2 * .pi, accuracy: 1e-12)
        defaultRenderer.stop()
        let renderer = NativeFanRotationRenderer(layer: layer, clockwise: false, now: { clock.time })
        renderer.update(rpm: 1000, reduceMotion: false, visible: true)
        let first = try animation(layer)
        XCTAssertEqual(first.duration, 2.5)
        XCTAssertEqual(try number(first.fromValue), 0)
        XCTAssertEqual(try number(first.toValue), 2 * .pi, accuracy: 1e-12)
        clock.time = 11.25
        renderer.update(rpm: 1000, reduceMotion: false, visible: false)
        assertStopped(layer)
        assertPose(layer, angle: .pi)
        clock.time = 100
        renderer.update(rpm: 1000, reduceMotion: false, visible: true)
        XCTAssertEqual(try number(animation(layer).fromValue), .pi, accuracy: 1e-12)
        XCTAssertEqual(try number(animation(layer).toValue), 3 * .pi, accuracy: 1e-12)
        XCTAssertEqual(try animation(layer).duration, 2.5)
        clock.time = 101
        renderer.update(rpm: 1000, reduceMotion: false, visible: true)
        XCTAssertEqual(layer.additions, 2)
        renderer.stop()
        assertPose(layer, angle: 1.8 * .pi)
    }

    func testIndependentRotorStaysCenteredAcrossPhaseAndBoundsChanges() throws {
        let clock = FanRotationFixtureClock(10), container = CALayer(), rotor = FanRotationRecordingLayer()
        container.anchorPoint = .zero
        container.position = CGPoint(x: 736, y: 742)
        container.bounds = CGRect(x: 7, y: 9, width: 28, height: 28)
        container.addSublayer(rotor)
        let renderer = NativeFanRotationRenderer(layer: rotor, now: { clock.time })
        renderer.layout(in: container.bounds, contentsScale: 2)
        renderer.update(rpm: 2500, reduceMotion: false, visible: true)
        for (time, bounds) in [(10.25, CGRect(x: 7, y: 9, width: 28, height: 28)),
                               (11.0, CGRect(x: -4, y: 2, width: 17, height: 17)),
                               (12.5, CGRect(x: 0, y: 0, width: 18, height: 18))] {
            clock.time = time
            renderer.stop()
            container.bounds = bounds
            renderer.layout(in: bounds, contentsScale: 2)
            XCTAssertTrue(rotor.superlayer === container)
            XCTAssertEqual(rotor.anchorPoint, CGPoint(x: 0.5, y: 0.5))
            XCTAssertEqual(rotor.bounds, CGRect(origin: .zero, size: bounds.size))
            XCTAssertEqual(rotor.position, CGPoint(x: bounds.midX, y: bounds.midY))
            XCTAssertEqual(rotor.contentsScale, 2)
            let center = rotor.convert(CGPoint(x: rotor.bounds.midX, y: rotor.bounds.midY), to: container)
            XCTAssertEqual(center.x, bounds.midX, accuracy: 1e-10)
            XCTAssertEqual(center.y, bounds.midY, accuracy: 1e-10)
            XCTAssertEqual(container.anchorPoint, .zero)
            XCTAssertEqual(container.position, CGPoint(x: 736, y: 742))
            XCTAssertTrue(CATransform3DIsIdentity(container.transform))
            renderer.update(rpm: 2500, reduceMotion: false, visible: true)
        }
        XCTAssertEqual(try animation(rotor).duration, 1)
        renderer.stop(); assertStopped(rotor)
    }

    private func animation(_ layer: FanRotationRecordingLayer) throws -> CABasicAnimation {
        try XCTUnwrap(layer.capturedAnimation(forKey: NativeFanRotationRenderer.animationKey) as? CABasicAnimation)
    }
    private func assertStopped(_ layer: FanRotationRecordingLayer, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(layer.capturedAnimation(forKey: NativeFanRotationRenderer.animationKey), file: file, line: line)
        XCTAssertEqual(layer.operations.last, .remove(NativeFanRotationRenderer.animationKey), file: file, line: line)
    }
    private func number(_ value: Any?) throws -> Double { try XCTUnwrap(value as? NSNumber).doubleValue }
    private func assertPose(_ layer: CALayer, angle: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(layer.transform.m11, cos(angle), accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(layer.transform.m12, sin(angle), accuracy: 1e-12, file: file, line: line)
    }
}

private final class FanRotationFixtureClock {
    var time: Double
    init(_ time: Double) { self.time = time }
}

private final class FanRotationRecordingLayer: CALayer {
    enum Operation: Equatable { case add(String?), remove(String) }
    private(set) var operations: [Operation] = []
    private var captured: [String: CAAnimation] = [:]
    var additions: Int { operations.filter { if case .add = $0 { return true }; return false }.count }
    var removals: Int { operations.filter { if case .remove = $0 { return true }; return false }.count }

    // Record the exact production submission/removal boundary, not attachment to
    // an unhosted layer. Model transforms remain real CALayer properties; render
    // server retention and mounted presentation require parent UI acceptance.
    override func add(_ animation: CAAnimation, forKey key: String?) {
        operations.append(.add(key))
        if let key { captured[key] = animation.copy() as? CAAnimation }
    }
    override func removeAnimation(forKey key: String) {
        operations.append(.remove(key))
        captured.removeValue(forKey: key)
    }
    func capturedAnimation(forKey key: String) -> CAAnimation? { captured[key]?.copy() as? CAAnimation }
}
