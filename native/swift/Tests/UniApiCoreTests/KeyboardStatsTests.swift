import XCTest
@testable import UniApiCore

final class KeyboardStatsTests: XCTestCase {
    private static let utc: Calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "UTC")!; return value }()
    // 2024-01-15 10:00:00 UTC, a Monday.
    private let base = 1_705_312_800_000.0
    private func fold() -> NativeKeyboardFold { NativeKeyboardFold(slot: { NativeKeyboardSlot.local($0, calendar: Self.utc) }) }
    private func total(_ delta: NativeKeyboardDelta) -> NativeKeyboardTotals {
        var value = NativeKeyboardTotals(); for item in delta.slots.values { value.add(item) }; return value
    }
    /// Types letters at a fixed interval and returns the time after the last one.
    @discardableResult private func type(_ fold: inout NativeKeyboardFold, _ codes: [Int], from start: Double, every interval: Double = 200) -> Double {
        var time = start
        for code in codes { fold.record(.init(code: code, time: time)); time += interval }
        return time - interval
    }

    func testCountsWordsCharactersAndSpeed() {
        var fold = fold()
        // "hello world " : five letters, space, five letters, space.
        let codes = [4, 14, 37, 37, 31, 49, 13, 31, 15, 37, 2, 49]
        let end = type(&fold, codes, from: base)
        XCTAssertEqual(fold.sessionKeys, 12)
        let value = total(fold.drain(now: end))
        XCTAssertEqual(value.keys, 12); XCTAssertEqual(value.characters, 12); XCTAssertEqual(value.words, 2)
        XCTAssertEqual(value.timedCharacters, 11); XCTAssertEqual(value.activeMs, 2_200); XCTAssertEqual(value.bursts, 1)
        // Eleven intervals of 200 ms: 11 / 5 words in 2.2 seconds is 60 WPM.
        XCTAssertEqual(value.wpm, 60, accuracy: 0.001)
        XCTAssertEqual(value.deleted, 0); XCTAssertEqual(value.correctionRate, 0)
    }
    func testPausesDoNotCountAsTypingTime() {
        var fold = fold()
        let end = type(&fold, [0, 1, 2], from: base)
        type(&fold, [3, 5, 4], from: end + 60_000)
        let value = total(fold.drain(now: end + 61_000))
        XCTAssertEqual(value.bursts, 2); XCTAssertEqual(value.activeMs, 800); XCTAssertEqual(value.timedCharacters, 4)
    }
    func testCorrectionsCountDeletedCharactersAndRuns() {
        var fold = fold()
        var time = type(&fold, [0, 1, 2, 3], from: base)
        for _ in 0..<3 { time += 150; fold.record(.init(code: NativeKeyboardKeys.delete, time: time)) }
        time = type(&fold, [5, 4], from: time + 150)
        fold.record(.init(code: NativeKeyboardKeys.forwardDelete, time: time + 150))
        // A held delete key removes more characters without another press.
        fold.record(.init(code: NativeKeyboardKeys.forwardDelete, repeated: true, time: time + 300))
        let delta = fold.drain(now: time + 400), value = total(delta)
        XCTAssertEqual(value.characters, 6); XCTAssertEqual(value.deleted, 5); XCTAssertEqual(value.corrections, 2)
        XCTAssertEqual(value.repeats, 1); XCTAssertEqual(value.keys, 10)
        XCTAssertEqual(value.correctionRate, 5.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(delta.keys["2024-01-15"]?[NativeKeyboardKeys.delete], 3)
        XCTAssertEqual(delta.keys["2024-01-15"]?[NativeKeyboardKeys.forwardDelete], 1)
    }
    func testShortcutsAndModifiersAreNotTyping() {
        var fold = fold()
        fold.record(.init(code: 55, command: true, time: base))
        fold.record(.init(code: 8, command: true, time: base + 100))
        fold.record(.init(code: 9, command: true, shift: true, time: base + 200))
        fold.record(.init(code: 8, command: true, time: base + 300))
        // Option produces characters, so it is typing rather than a shortcut.
        fold.record(.init(code: 37, option: true, time: base + 400))
        let delta = fold.drain(now: base + 500), value = total(delta)
        XCTAssertEqual(value.keys, 5); XCTAssertEqual(value.shortcuts, 3); XCTAssertEqual(value.characters, 1); XCTAssertEqual(value.words, 0)
        XCTAssertEqual(delta.shortcuts["2024-01-15"], ["cmd+8": 2, "shift+cmd+9": 1])
        XCTAssertEqual(delta.keys["2024-01-15"]?[55], 1)
    }
    func testPeakSpeedNeedsASustainedBurst() {
        var fold = fold()
        // 40 characters at 100 ms is 3.9 s: too short to rank.
        var end = type(&fold, Array(repeating: 0, count: 40), from: base, every: 100)
        XCTAssertEqual(total(fold.drain(now: end + 5_000)).peakWpm, 0)
        // 61 characters at 100 ms: 60 intervals in 6 s is 120 WPM.
        end = type(&fold, Array(repeating: 0, count: 61), from: base + 60_000, every: 100)
        XCTAssertEqual(fold.liveWpm(now: end), 120, accuracy: 0.5)
        XCTAssertEqual(total(fold.drain(now: end + 100)).peakWpm, 0)
        XCTAssertEqual(total(fold.drain(now: end + 5_000)).peakWpm, 120, accuracy: 0.001)
        XCTAssertEqual(fold.liveWpm(now: end + 5_000), 0)
    }
    func testPeakOfABurstEndedByTheNextBurstIsKept() {
        var fold = fold()
        let end = type(&fold, Array(repeating: 0, count: 61), from: base, every: 100)
        type(&fold, [1, 2], from: end + 10_000)
        XCTAssertEqual(total(fold.drain(now: end + 10_300)).peakWpm, 120, accuracy: 0.001)
    }
    func testHourAndDayBoundaries() {
        var fold = fold()
        fold.record(.init(code: 0, time: base + 3_599_000))
        fold.record(.init(code: 0, time: base + 3_600_500))
        fold.record(.init(code: 0, time: base + 14 * 3_600_000))
        let delta = fold.drain(now: base + 15 * 3_600_000)
        XCTAssertEqual(Set(delta.slots.keys), [.init(day: "2024-01-15", hour: 10), .init(day: "2024-01-15", hour: 11), .init(day: "2024-01-16", hour: 0)])
        XCTAssertEqual(delta.keys["2024-01-16"]?[0], 1)
        XCTAssertTrue(fold.drain(now: base + 16 * 3_600_000).isEmpty)
    }
    func testInvalidEventsAreIgnored() {
        var fold = fold()
        fold.record(.init(code: -1, time: base)); fold.record(.init(code: 9_999, time: base)); fold.record(.init(code: 0, time: .nan))
        XCTAssertTrue(fold.drain(now: base).isEmpty)
    }

    func testLayoutsAreConsistent() {
        for iso in [false, true] {
            let rows = NativeKeyboardLayout.rows(iso: iso)
            XCTAssertEqual(rows.count, NativeKeyboardLayout.rowTitles.count)
            for row in rows { XCTAssertEqual(row.reduce(0) { $0 + $1.width }, 14.5, accuracy: 0.0001, "iso \(iso)") }
            let codes = rows.flatMap { $0 }.filter { !$0.continuation }.flatMap { [$0.code] + ($0.lower.map { [$0] } ?? []) }
            XCTAssertEqual(codes.count, Set(codes).count)
            for code in codes where !(96...122).contains(code) { XCTAssertNotNil(NativeKeyboardLayout.finger(code), "code \(code)") }
        }
        XCTAssertNotNil(NativeKeyboardLayout.row(10, iso: true)); XCTAssertNil(NativeKeyboardLayout.row(10, iso: false))
        // Home keys cost nothing; a neighbouring key costs one pitch there and back.
        XCTAssertEqual(NativeKeyboardLayout.travelMeters([0: 100, 38: 100, 49: 100], iso: false), 0)
        XCTAssertEqual(NativeKeyboardLayout.travelMeters([5: 10], iso: false), 10 * 2 * 19.05 / 1000, accuracy: 0.000001)
        XCTAssertEqual(NativeKeyboardKeys.category(0), "Letters"); XCTAssertEqual(NativeKeyboardKeys.category(18), "Digits")
        XCTAssertEqual(NativeKeyboardKeys.category(51), "Corrections"); XCTAssertEqual(NativeKeyboardKeys.category(43), "Punctuation")
        XCTAssertEqual(NativeKeyboardKeys.category(122), "Function keys"); XCTAssertEqual(NativeKeyboardKeys.category(56), "Modifiers")
    }
    func testStreaks() {
        let calendar = Self.utc
        XCTAssertEqual(NativeKeyboardSummary.streaks(["2024-01-12", "2024-01-13", "2024-01-14", "2024-01-15"], today: "2024-01-15", calendar: calendar).current, 4)
        // Yesterday's streak still stands until today ends.
        XCTAssertEqual(NativeKeyboardSummary.streaks(["2024-01-13", "2024-01-14"], today: "2024-01-15", calendar: calendar).current, 2)
        let broken = NativeKeyboardSummary.streaks(["2024-01-01", "2024-01-02", "2024-01-03", "2024-01-10"], today: "2024-01-15", calendar: calendar)
        XCTAssertEqual(broken.current, 0); XCTAssertEqual(broken.longest, 3)
        XCTAssertEqual(NativeKeyboardSummary.streaks(["2024-02-28", "2024-02-29", "2024-03-01"], today: "2024-03-01", calendar: calendar).current, 3)
        XCTAssertEqual(NativeKeyboardSummary.firstDay("7d", now: base, calendar: calendar), "2024-01-09")
        XCTAssertEqual(NativeKeyboardSummary.firstDay("today", now: base, calendar: calendar), "2024-01-15")
        XCTAssertNil(NativeKeyboardSummary.firstDay("all", now: base, calendar: calendar))
    }
    func testSummaryFigures() {
        var morning = NativeKeyboardTotals(); morning.keys = 120; morning.characters = 100; morning.timedCharacters = 100
        morning.deleted = 10; morning.corrections = 4; morning.words = 20; morning.activeMs = 60_000; morning.peakWpm = 35
        var evening = NativeKeyboardTotals(); evening.keys = 30; evening.characters = 20; evening.timedCharacters = 20; evening.activeMs = 30_000
        let state = NativeKeyboardSummary.build(
            slots: [.init(day: "2024-01-15", hour: 9): morning, .init(day: "2024-01-13", hour: 21): evening],
            keys: [0: 60, 38: 30, 51: 10, 49: 20, 56: 30], shortcuts: ["cmd+8": 5, "cmd+9": 7],
            allDays: ["2024-01-13", "2024-01-15"], range: "7d", now: base, iso: false, calendar: Self.utc)
        let totals = state["totals"] ?? .null
        XCTAssertEqual(totals["keys"].int, 150); XCTAssertEqual(totals["characters"].int, 120)
        XCTAssertEqual(totals["wpm"].double, 16, accuracy: 0.001)
        XCTAssertEqual(totals["netWpm"].double, 14.6667, accuracy: 0.001)
        XCTAssertEqual(totals["peakWpm"].double, 35); XCTAssertEqual(totals["correctionRate"].double, 10.0 / 120, accuracy: 0.0001)
        XCTAssertEqual(totals["accuracy"].double, 1 - 10.0 / 120, accuracy: 0.0001)
        XCTAssertEqual(totals["deletedPerCorrection"].double, 2.5); XCTAssertEqual(totals["days"].int, 2)
        XCTAssertEqual(totals["bestDay"]["day"].string, "2024-01-15"); XCTAssertEqual(totals["busiestHour"].int, 9)
        XCTAssertEqual(totals["streak"].int, 1); XCTAssertEqual(totals["longestStreak"].int, 1); XCTAssertEqual(totals["uniqueKeys"].int, 5)
        let keys = state["keys"]?.array ?? []
        XCTAssertEqual(keys.map { $0["code"].int }, [0, 38, 56, 49, 51])
        XCTAssertEqual(keys[0]["share"].double, 0.4, accuracy: 0.0001)
        XCTAssertEqual(state["daily"]?.array.count, 7); XCTAssertEqual(state["daily"]?.array.last?["keys"].int, 120)
        XCTAssertEqual(state["hours"]?.array.count, 24); XCTAssertEqual(state["hours"]?.array[21]["keys"].int, 30)
        // 2024-01-15 is a Monday and 2024-01-13 a Saturday.
        XCTAssertEqual(state["weekdays"]?.array[0]["keys"].int, 120); XCTAssertEqual(state["weekdays"]?.array[5]["keys"].int, 30)
        XCTAssertEqual(state["hands"]?["left"].int, 90); XCTAssertEqual(state["hands"]?["right"].int, 40)
        XCTAssertEqual(state["shortcuts"]?.array.first?["combo"].string, "cmd+9")
        XCTAssertEqual(state["rows"]?.array[3]["count"].int, 90)
    }

    private final class Board: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [NativeKeyboardEvent] = []
        private var allowed = false, running = false, asked = 0
        var clock = 1_705_312_800_000.0
        func press(_ events: [NativeKeyboardEvent]) { lock.withLock { if running { queue += events } } }
        func take() -> [NativeKeyboardEvent] { lock.withLock { defer { queue = [] }; return queue } }
        func allow(_ value: Bool) { lock.withLock { allowed = value } }
        var permitted: Bool { lock.withLock { allowed } }
        var isRunning: Bool { lock.withLock { running } }
        var requests: Int { lock.withLock { asked } }
        func request() -> Bool { lock.withLock { asked += 1; return allowed } }
        func begin() -> Bool { lock.withLock { running = allowed; return running } }
        func end() { lock.withLock { running = false } }
    }
    private func service() throws -> (NativeKeyboardService, Board, NativeRuntime, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("uniapi-keyboard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root, dataRoot: root.appendingPathComponent("data")))
        let board = Board()
        let io = NativeKeyboardIO(permitted: { board.permitted }, requestPermission: { board.request() }, begin: { board.begin() },
                                  end: { board.end() }, take: { board.take() }, slot: { NativeKeyboardSlot.local($0, calendar: Self.utc) },
                                  now: { board.clock }, sleep: { _ in try await Task.sleep(nanoseconds: 5_000_000) })
        return (NativeKeyboardService(runtime: runtime, io: io), board, runtime, root)
    }
    func testRecordingIsOffUntilEnabledAndPermitted() async throws {
        let (service, board, _, root) = try service(); defer { try? FileManager.default.removeItem(at: root) }
        try await service.start()
        var state = try await service.handle("status")
        XCTAssertFalse(state["enabled"].bool); XCTAssertFalse(state["recording"].bool); XCTAssertFalse(board.isRunning)
        XCTAssertEqual(board.requests, 0)
        // Enabling without permission asks macOS once and records nothing.
        state = try await service.handle("set-enabled", input: ["enabled": true])
        XCTAssertTrue(state["enabled"].bool); XCTAssertFalse(state["recording"].bool); XCTAssertFalse(state["permitted"].bool)
        XCTAssertEqual(board.requests, 1)
        // Recording starts by itself once permission arrives.
        board.allow(true)
        for _ in 0..<400 where !board.isRunning { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(board.isRunning)
        state = try await service.handle("set-enabled", input: ["enabled": false])
        XCTAssertFalse(state["recording"].bool); XCTAssertFalse(board.isRunning)
        await service.stop()
    }
    func testCountsPersistAcrossServicesAndReset() async throws {
        let (service, board, runtime, root) = try service(); defer { try? FileManager.default.removeItem(at: root) }
        board.allow(true)
        _ = try await service.handle("set-enabled", input: ["enabled": true])
        let start = board.clock
        board.press([4, 14, 37, 37, 31, 49].enumerated().map { .init(code: $0.element, time: start + Double($0.offset) * 200) })
        board.press([.init(code: 51, time: start + 1_200), .init(code: 8, command: true, time: start + 1_400)])
        board.clock = start + 2_000
        await service.stop()
        var state = try await service.handle("status", input: ["range": "today"])
        XCTAssertEqual(state["totals"]["keys"].int, 8); XCTAssertEqual(state["totals"]["words"].int, 1)
        XCTAssertEqual(state["totals"]["deleted"].int, 1); XCTAssertEqual(state["totals"]["shortcuts"].int, 1)
        XCTAssertEqual(state["keys"].array.first?["code"].int, 37); XCTAssertTrue(state["hasData"].bool)
        // Only counters are stored: no table holds an ordered press.
        let tables = try runtime.db.query("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'keyboard_%'").compactMap { $0["name"]?.string }.sorted()
        XCTAssertEqual(tables, ["keyboard_hours", "keyboard_keys", "keyboard_preferences", "keyboard_shortcuts"])
        XCTAssertEqual(try runtime.db.query("SELECT * FROM keyboard_hours").count, 1)

        let again = NativeKeyboardService(runtime: runtime, io: .init(permitted: { false }, requestPermission: { false }, begin: { false }, end: {}, take: { [] },
                                                                      slot: { NativeKeyboardSlot.local($0, calendar: Self.utc) }, now: { start + 3_000 }))
        state = try await again.handle("status", input: ["range": "all"])
        XCTAssertTrue(state["enabled"].bool); XCTAssertEqual(state["totals"]["keys"].int, 8)
        state = try await again.handle("reset")
        XCTAssertEqual(state["totals"]["keys"].int, 0); XCTAssertFalse(state["hasData"].bool); XCTAssertTrue(state["enabled"].bool)
        do { _ = try await again.handle("unknown"); XCTFail("Expected refusal") } catch {}
    }
}
