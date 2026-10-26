import QuartzCore
import XCTest
@testable import UniApiCore

@MainActor final class FanWindRendererAcceptanceTests: XCTestCase {
    func testAllEighteenParticlesMatchCanvasGeometryGradientCapsAndDots() throws {
        let fixture = WindFixture()
        fixture.renderer.layout(in: CGRect(x: 0, y: 0, width: 400, height: 150), contentsScale: 2, color: fixture.tint)
        fixture.renderer.update(rpm: 4500, reduceMotion: false, visible: true)
        XCTAssertEqual(fixture.container.sublayers?.count, 18)
        XCTAssertTrue(fixture.container.masksToBounds)
        XCTAssertTrue(fixture.container.isGeometryFlipped)
        for index in 0..<18 {
            let layer = fixture.layers[index], expected = canvas(index, elapsed: 0, rpm: 4500, size: CGSize(width: 400, height: 150))
            assertPosition(layer.position, expected.point)
            let trail = try XCTUnwrap(layer.sublayers?.first as? CAGradientLayer)
            let mask = try XCTUnwrap(trail.mask as? CAShapeLayer)
            let dot = try XCTUnwrap(layer.sublayers?.last as? CAShapeLayer)
            XCTAssertLessThan(trail.frame.minX, -expected.length - 0.6)
            XCTAssertGreaterThan(trail.frame.maxX, 0.6)
            XCTAssertLessThan(trail.frame.minY, -0.6)
            XCTAssertGreaterThan(trail.frame.maxY, 0.6)
            XCTAssertEqual(mask.lineWidth, 1.2); XCTAssertEqual(mask.lineCap, .round)
            XCTAssertEqual(try XCTUnwrap(mask.path).boundingBoxOfPath.width, expected.length, accuracy: 1e-10)
            try assertPhysicalArtwork(trail, length: expected.length)
            let colors = try XCTUnwrap(trail.colors as? [CGColor])
            XCTAssertEqual(colors.count, 2); XCTAssertEqual(colors[0].alpha, 0)
            XCTAssertEqual(colors[1].alpha, expected.alpha * fixture.tint.alpha, accuracy: 1e-10)
            XCTAssertEqual(try XCTUnwrap(dot.fillColor).alpha, expected.alpha * fixture.tint.alpha, accuracy: 1e-10)
            XCTAssertEqual(try XCTUnwrap(dot.path).boundingBoxOfPath, CGRect(x: -expected.radius, y: -expected.radius, width: expected.radius * 2, height: expected.radius * 2))
            XCTAssertEqual(dot.bounds, try XCTUnwrap(dot.path).boundingBoxOfPath)
            assertPosition(dot.position, .zero)
            XCTAssertEqual(layer.contentsScale, 2); XCTAssertEqual(trail.contentsScale, 2)
            XCTAssertEqual(dot.contentsScale, 2); XCTAssertEqual(mask.contentsScale, 2)
        }
        fixture.renderer.update(rpm: 12000, reduceMotion: false, visible: true)
        try assertModel(fixture, elapsed: 0, rpm: 12000)
        fixture.renderer.update(rpm: 1, reduceMotion: false, visible: true)
        try assertModel(fixture, elapsed: 0, rpm: 1)
    }

    func testActualSubmittedAnimationsMatchCanvasOffsetsWrapAndBoundedSineError() throws {
        let fixture = WindFixture()
        for size in [CGSize(width: 400, height: 150), CGSize(width: 231, height: 450), CGSize(width: 1200, height: 2160)] {
            fixture.renderer.layout(in: CGRect(origin: .zero, size: size), contentsScale: 2, color: fixture.tint)
            fixture.renderer.update(rpm: 3000, reduceMotion: false, visible: true)
            for index in 0..<18 {
                let group = try animation(fixture.layers[index])
                let x = try XCTUnwrap(group.animations?.first as? CABasicAnimation)
                let y = try XCTUnwrap(group.animations?.last as? CAKeyframeAnimation)
                let duration = 7.2 + Double(index % 3) * 0.45
                let offset = Double(index * 1733 % 8000) / 1000
                XCTAssertEqual(group.duration, duration, accuracy: 1e-12)
                XCTAssertEqual(group.timeOffset, offset.truncatingRemainder(dividingBy: duration), accuracy: 1e-12)
                XCTAssertTrue(group.repeatCount.isInfinite)
                XCTAssertEqual(x.keyPath, "position.x"); XCTAssertEqual(y.keyPath, "position.y")
                XCTAssertEqual(try number(x.fromValue), -0.2 * size.width, accuracy: 1e-12)
                XCTAssertEqual(try number(x.toValue), 1.2 * size.width, accuracy: 1e-12)
                XCTAssertEqual(x.duration, duration); XCTAssertEqual(y.duration, duration)
                XCTAssertEqual(y.calculationMode, .linear)
                try assertLinear(try XCTUnwrap(group.timingFunction))
                try assertLinear(try XCTUnwrap(x.timingFunction))
                try assertLinear(try XCTUnwrap(y.timingFunction))
                let values = try XCTUnwrap(y.values as? [NSNumber])
                let times = try XCTUnwrap(y.keyTimes)
                XCTAssertEqual(values.count, times.count); XCTAssertGreaterThanOrEqual(values.count, 129)
                XCTAssertEqual(times.first?.doubleValue, 0); XCTAssertEqual(times.last?.doubleValue, 1)
                for step in 1..<times.count {
                    XCTAssertGreaterThan(times[step].doubleValue, times[step - 1].doubleValue)
                    // Compare the submitted interpolation itself with the old
                    // Canvas sine, rather than another renderer projection.
                    for fraction in [0.25, 0.5, 0.75] {
                        let phase = times[step - 1].doubleValue + (times[step].doubleValue - times[step - 1].doubleValue) * fraction
                        let actual = values[step - 1].doubleValue + (values[step].doubleValue - values[step - 1].doubleValue) * fraction
                        let expected = canvas(index, elapsed: phase * duration - offset + duration * 2, rpm: 3000, size: size)
                        XCTAssertLessThanOrEqual(abs(actual - expected.point.y), 0.005000001)
                    }
                }
                for elapsed in [0.0, 0.125, duration - offset - 0.000001, duration - offset + 0.000001, duration * 3 + 0.33] where elapsed >= 0 {
                    let actual = try sampled(group, after: elapsed)
                    let expected = canvas(index, elapsed: elapsed, rpm: 3000, size: size)
                    XCTAssertEqual(actual.x, expected.point.x, accuracy: 1e-9)
                    XCTAssertEqual(actual.y, expected.point.y, accuracy: 0.005000001)
                }
            }
        }
    }

    func testRateLengthChangesAndZeroResumeKeepIntegratedCanvasPhase() throws {
        let fixture = WindFixture()
        fixture.prepare(rpm: 3000)
        fixture.time.value = 101.25
        fixture.renderer.update(rpm: 6000, reduceMotion: false, visible: true)
        try assertModel(fixture, elapsed: 1.25, rpm: 6000)
        XCTAssertEqual(try animation(fixture.layers[0]).duration, 3.6, accuracy: 1e-12)
        fixture.time.value = 102.75
        fixture.renderer.update(rpm: 0, reduceMotion: false, visible: true)
        try assertModel(fixture, elapsed: 4.25, rpm: 0)
        XCTAssertEqual(fixture.container.opacity, 0)
        assertStopped(fixture)
        fixture.time.value = 202.75
        fixture.renderer.update(rpm: 1500, reduceMotion: false, visible: true)
        try assertModel(fixture, elapsed: 4.25, rpm: 1500)
        XCTAssertEqual(try animation(fixture.layers[0]).duration, 14.4, accuracy: 1e-12)
        fixture.time.value = 204.25; fixture.renderer.stop()
        try assertModel(fixture, elapsed: 5, rpm: 1500)
        assertStopped(fixture)
    }

    func testReducedMotionVisibilityAndDetachFreezeThenResumeLatestRPM() throws {
        let fixture = WindFixture(); fixture.prepare(rpm: 3000)
        fixture.time.value = 101
        fixture.renderer.update(rpm: 3000, reduceMotion: true, visible: true)
        try assertModel(fixture, elapsed: 1, rpm: 3000); assertStopped(fixture)
        XCTAssertEqual(fixture.container.opacity, 0)
        fixture.time.value = 150
        fixture.renderer.update(rpm: 6000, reduceMotion: true, visible: false)
        try assertModel(fixture, elapsed: 1, rpm: 6000); assertStopped(fixture)
        fixture.time.value = 160
        fixture.renderer.update(rpm: 4500, reduceMotion: false, visible: false)
        XCTAssertEqual(fixture.container.opacity, 1)
        try assertModel(fixture, elapsed: 1, rpm: 4500); assertStopped(fixture)
        fixture.time.value = 200
        fixture.renderer.update(rpm: 4500, reduceMotion: false, visible: true)
        try assertModel(fixture, elapsed: 1, rpm: 4500)
        fixture.time.value = 202; fixture.renderer.stop()
        try assertModel(fixture, elapsed: 4, rpm: 4500); assertStopped(fixture)
        fixture.time.value = 300
        fixture.renderer.update(rpm: 4500, reduceMotion: false, visible: true)
        try assertModel(fixture, elapsed: 4, rpm: 4500)
    }

    func testThousandUnchangedTelemetryAndLayoutUpdatesDoNotResubmit() throws {
        let fixture = WindFixture(); fixture.prepare(rpm: 4500)
        let starts = try fixture.layers.map { try animation($0).beginTime }
        for tick in 1...1000 {
            fixture.time.value = 100 + Double(tick) / 30
            fixture.renderer.layout(in: CGRect(x: 0, y: 0, width: 400, height: 150), contentsScale: 2, color: fixture.tint)
            fixture.renderer.update(rpm: 4500, reduceMotion: false, visible: true)
        }
        for (index, layer) in fixture.layers.enumerated() {
            XCTAssertEqual(layer.additions, 1)
            XCTAssertEqual(try animation(layer).beginTime, starts[index])
            XCTAssertEqual(layer.sublayers?.count, 2)
        }
    }

    func testBoundsTintAndBackingChangesPreservePhaseAndAppKitRootGeometry() throws {
        let fixture = WindFixture()
        let root = CALayer(); root.bounds = CGRect(x: 7, y: 9, width: 400, height: 150)
        root.anchorPoint = .zero; root.position = CGPoint(x: 736, y: 742)
        root.addSublayer(fixture.container); fixture.prepare(rpm: 3000)
        fixture.time.value = 102.5
        let bounds = CGRect(x: 7, y: 9, width: 231, height: 450)
        let tint = CGColor(red: 0.2, green: 0.4, blue: 1, alpha: 0.8)
        fixture.renderer.layout(in: bounds, contentsScale: 1, color: tint)
        for index in 0..<18 {
            let expected = canvas(index, elapsed: 2.5, rpm: 3000, size: bounds.size)
            assertPosition(fixture.layers[index].position, expected.point)
            try assertPhysicalArtwork(try XCTUnwrap(fixture.layers[index].sublayers?.first as? CAGradientLayer), length: expected.length)
            XCTAssertEqual(try sampled(animation(fixture.layers[index]), after: 0).y, fixture.layers[index].position.y, accuracy: 0.005000001)
        }
        XCTAssertEqual(fixture.container.bounds, CGRect(origin: .zero, size: bounds.size))
        XCTAssertEqual(fixture.container.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(fixture.container.position, CGPoint(x: bounds.midX, y: bounds.midY))
        XCTAssertTrue(CATransform3DIsIdentity(root.transform)); XCTAssertTrue(CATransform3DIsIdentity(fixture.container.transform))
        XCTAssertEqual(root.bounds, CGRect(x: 7, y: 9, width: 400, height: 150))
        XCTAssertEqual(root.anchorPoint, .zero); XCTAssertEqual(root.position, CGPoint(x: 736, y: 742))
        XCTAssertEqual(fixture.layers[0].contentsScale, 1)
        let dot = try XCTUnwrap(fixture.layers[0].sublayers?.last as? CAShapeLayer)
        XCTAssertEqual(try XCTUnwrap(dot.fillColor).alpha, 0.8 * 0.35, accuracy: 1e-10)
    }

    func testInvalidRPMClockAndBoundsCannotSubmitNonfiniteAnimations() throws {
        let fixture = WindFixture(); fixture.prepare(rpm: 3000)
        fixture.time.value = 101
        for rpm in [Double.nan, .infinity, -.infinity, -1, 0] {
            fixture.renderer.update(rpm: rpm, reduceMotion: false, visible: true)
            assertStopped(fixture)
            XCTAssertEqual(fixture.container.opacity, rpm > 0 ? 1 : 0)
            for layer in fixture.layers { XCTAssertTrue(layer.position.x.isFinite && layer.position.y.isFinite) }
        }
        let operations = fixture.layers.map(\.operations)
        fixture.time.value = .nan
        fixture.renderer.update(rpm: 6000, reduceMotion: false, visible: true)
        fixture.renderer.layout(in: CGRect(x: 0, y: 0, width: 700, height: 300), contentsScale: 2, color: fixture.tint)
        XCTAssertEqual(fixture.layers.map(\.operations), operations)
        fixture.time.value = 102
        for bounds in [CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 150), CGRect(x: 0, y: 0, width: 400, height: CGFloat.nan)] {
            fixture.renderer.layout(in: bounds, contentsScale: 2, color: fixture.tint)
        }
        fixture.renderer.layout(in: CGRect(x: 0, y: 0, width: 700, height: 300), contentsScale: CGFloat.leastNonzeroMagnitude, color: fixture.tint)
        XCTAssertEqual(fixture.layers.map(\.operations), operations)
        fixture.renderer.update(rpm: 3000, reduceMotion: false, visible: true)
        try assertModel(fixture, elapsed: 1, rpm: 3000)
        fixture.renderer.layout(in: .zero, contentsScale: 2, color: fixture.tint)
        assertStopped(fixture)
    }

    func testStopRemovesExactProductionKeyAndRetainsFinalCanvasModelPose() throws {
        let fixture = WindFixture(); fixture.prepare(rpm: 3000)
        for layer in fixture.layers {
            XCTAssertEqual(Array(layer.operations.suffix(2)), [.remove(NativeFanWindRenderer.animationKey), .add(NativeFanWindRenderer.animationKey)])
        }
        fixture.time.value = 103.75; fixture.renderer.stop()
        try assertModel(fixture, elapsed: 3.75, rpm: 3000)
        assertStopped(fixture)
        let operations = fixture.layers.map(\.operations)
        fixture.time.value = 200; fixture.renderer.stop()
        XCTAssertEqual(fixture.layers.map(\.operations), operations)
        fixture.renderer.update(rpm: 3000, reduceMotion: false, visible: true)
        try assertModel(fixture, elapsed: 3.75, rpm: 3000)
    }

    // Independent literal oracle retained from the removed Canvas closure.
    private func canvas(_ i: Int, elapsed: Double, rpm: Double, size: CGSize) -> (point: CGPoint, length: CGFloat, radius: CGFloat, alpha: CGFloat) {
        let duration = 7.2 + Double(i % 3) * 0.45
        let p = (elapsed + Double(i * 1733 % 8000) / 1000).truncatingRemainder(dividingBy: duration) / duration
        return (CGPoint(x: (-80 + p * 560) / 400 * size.width,
                        y: (Double(16 + i % 6 * 23) + sin(p * .pi * 2 + Double(i % 3) * 0.4) * 9) / 150 * size.height),
                46 * max(0.35, min(1.8, rpm / 4500)) / 400 * size.width,
                i % 3 == 0 ? 1.25 : 0.8, 0.35 + Double(i % 4) * 0.2)
    }
    private func assertModel(_ fixture: WindFixture, elapsed: Double, rpm: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        for index in 0..<18 {
            let expected = canvas(index, elapsed: elapsed, rpm: rpm, size: CGSize(width: 400, height: 150))
            assertPosition(fixture.layers[index].position, expected.point, file: file, line: line)
            let trail = try XCTUnwrap(fixture.layers[index].sublayers?.first as? CAGradientLayer, file: file, line: line)
            try assertPhysicalArtwork(trail, length: expected.length, file: file, line: line)
            if let group = fixture.layers[index].captured[NativeFanWindRenderer.animationKey] as? CAAnimationGroup {
                let start = try sampled(group, after: 0)
                XCTAssertEqual(start.x, expected.point.x, accuracy: 1e-9, file: file, line: line)
                XCTAssertEqual(start.y, expected.point.y, accuracy: 0.005000001, file: file, line: line)
                let later = try sampled(group, after: 0.37)
                let oracle = canvas(index, elapsed: elapsed + 0.37 * rpm / 3000, rpm: rpm, size: CGSize(width: 400, height: 150))
                XCTAssertEqual(later.x, oracle.point.x, accuracy: 1e-8, file: file, line: line)
                XCTAssertEqual(later.y, oracle.point.y, accuracy: 0.005000001, file: file, line: line)
            }
        }
    }
    private func assertPhysicalArtwork(_ trail: CAGradientLayer, length: CGFloat, file: StaticString = #filePath, line: UInt = #line) throws {
        let mask = try XCTUnwrap(trail.mask as? CAShapeLayer, file: file, line: line)
        let path = try XCTUnwrap(mask.path, file: file, line: line).boundingBoxOfPath
        XCTAssertEqual(path.minX + mask.frame.minX + trail.frame.minX, -length, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(path.maxX + mask.frame.minX + trail.frame.minX, 0, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(path.midY + mask.frame.minY + trail.frame.minY, 0, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(path.width, length, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(mask.lineWidth, 1.2, file: file, line: line)
        XCTAssertEqual(mask.lineCap, .round, file: file, line: line)
        XCTAssertEqual(trail.frame.minX + trail.startPoint.x * trail.bounds.width, -length, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(trail.frame.minX + trail.endPoint.x * trail.bounds.width, 0, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(trail.frame.minY + trail.startPoint.y * trail.bounds.height, 0, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(trail.frame.minY + trail.endPoint.y * trail.bounds.height, 0, accuracy: 1e-10, file: file, line: line)
    }
    private func sampled(_ group: CAAnimationGroup, after elapsed: Double) throws -> CGPoint {
        let x = try XCTUnwrap(group.animations?.first as? CABasicAnimation)
        let y = try XCTUnwrap(group.animations?.last as? CAKeyframeAnimation)
        let values = try XCTUnwrap(y.values as? [NSNumber]), times = try XCTUnwrap(y.keyTimes)
        let phase = (group.timeOffset + elapsed).truncatingRemainder(dividingBy: group.duration) / group.duration
        let right = times.firstIndex { $0.doubleValue >= phase } ?? times.count - 1
        let left = max(0, right - 1)
        let fraction = right == left ? 0 : (phase - times[left].doubleValue) / (times[right].doubleValue - times[left].doubleValue)
        let height = values[left].doubleValue + (values[right].doubleValue - values[left].doubleValue) * fraction
        let start = try number(x.fromValue), end = try number(x.toValue)
        return CGPoint(x: start + (end - start) * phase, y: height)
    }
    private func animation(_ layer: WindRecordingLayer) throws -> CAAnimationGroup {
        try XCTUnwrap(layer.captured[NativeFanWindRenderer.animationKey] as? CAAnimationGroup)
    }
    private func number(_ value: Any?) throws -> Double { try XCTUnwrap(value as? NSNumber).doubleValue }
    private func assertPosition(_ actual: CGPoint, _ expected: CGPoint, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-9, file: file, line: line)
    }
    private func assertLinear(_ timing: CAMediaTimingFunction) throws {
        var point = [Float](repeating: -1, count: 2)
        point.withUnsafeMutableBufferPointer { timing.getControlPoint(at: 1, values: $0.baseAddress!) }
        XCTAssertEqual(point, [0, 0])
        point.withUnsafeMutableBufferPointer { timing.getControlPoint(at: 2, values: $0.baseAddress!) }
        XCTAssertEqual(point, [1, 1])
    }
    private func assertStopped(_ fixture: WindFixture, file: StaticString = #filePath, line: UInt = #line) {
        for layer in fixture.layers {
            XCTAssertNil(layer.captured[NativeFanWindRenderer.animationKey], file: file, line: line)
            XCTAssertEqual(layer.operations.last, .remove(NativeFanWindRenderer.animationKey), file: file, line: line)
        }
    }
}

private final class WindFixtureTime { var value: Double = 100 }
@MainActor private final class WindFixture {
    let time: WindFixtureTime
    let container: CALayer
    let layers: [WindRecordingLayer]
    let tint = CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
    let renderer: NativeFanWindRenderer
    init() {
        let clock = WindFixtureTime(), container = CALayer()
        let particles = (0..<18).map { _ in WindRecordingLayer() }
        time = clock; self.container = container; layers = particles
        renderer = NativeFanWindRenderer(container: container, particleLayer: { particles[$0] }, now: { clock.value })
    }
    func prepare(rpm: Double) {
        renderer.layout(in: CGRect(x: 0, y: 0, width: 400, height: 150), contentsScale: 2, color: tint)
        renderer.update(rpm: rpm, reduceMotion: false, visible: true)
    }
}
private final class WindRecordingLayer: CALayer {
    enum Operation: Equatable { case add(String?), remove(String) }
    private(set) var operations: [Operation] = []
    private(set) var captured: [String: CAAnimation] = [:]
    var additions: Int { operations.filter { if case .add = $0 { return true }; return false }.count }
    override func add(_ animation: CAAnimation, forKey key: String?) {
        operations.append(.add(key))
        if let key { captured[key] = animation.copy() as? CAAnimation }
    }
    override func removeAnimation(forKey key: String) {
        operations.append(.remove(key)); captured.removeValue(forKey: key)
    }
}
