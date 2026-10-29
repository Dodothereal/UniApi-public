import Foundation
import CoreFoundation
import Darwin
import XCTest
@testable import UniApiCore

final class NativeUIProfileFileTests: XCTestCase {
    private final class Clock { var seconds: Double = 0 }

    private func fixture() throws -> (root: URL, data: URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("uniapi-ui-profile-" + UUID().uuidString, isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (root, data)
    }

    private func writer(_ data: URL, session: UUID = UUID(), bytes: Int = 4 << 20, records: Int = 4096,
                        duration: Double = 300, elapsed: @escaping () -> Double = { 0 }) throws -> NativeUIProfileFile {
        try NativeUIProfileFile(dataRoot: data, sessionID: session, maximumBytes: bytes,
                                maximumRecords: records, maximumDuration: duration, elapsed: elapsed)
    }

    private func row(_ file: NativeUIProfileFile, visit: Int = 1) -> [String: Any] {
        ["schema": 1, "pid": Int(getpid()), "session": file.sessionID.uuidString,
         "visit": visit, "page": "stats", "initial": false, "trigger": "refresh", "phase": "dataViewCommit",
         "elapsedMs": 12.5, "userCPUMs": 2.25, "systemCPUMs": 0.5,
         "peakResidentBytes": 8_388_608, "recordedAt": "2026-10-29T12:34:56Z"]
    }

    private func encoded(_ value: [String: Any], pretty: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted] : [])
    }

    private func metadata(_ url: URL) throws -> stat {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw NativeFailure("Cannot inspect the private test file") }
        return info
    }

    private func appendIndependently(_ bytes: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw NativeFailure("Cannot open the private append fixture") }
        defer { Darwin.close(descriptor) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw NativeFailure("Cannot write the private append fixture") }
                offset += written
            }
        }
    }

    private func rejection(_ input: (NativeUIProfileFile) throws -> Data,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let f = try fixture(), recording = try writer(f.data)
        defer { recording.close() }
        let valid = try encoded(row(recording))
        try recording.append(valid)
        let before = try Data(contentsOf: recording.url)
        // Encode outside XCTAssertThrowsError: a serializer error must not be
        // mistaken for the production writer rejecting and closing its file.
        let invalid = try input(recording)
        XCTAssertThrowsError(try recording.append(invalid), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: recording.url), before, file: file, line: line)
        XCTAssertThrowsError(try recording.append(valid), file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: recording.url), before, file: file, line: line)
    }

    func testPublicWriterCreatesFreshPrivateCanonicalMetadataAndCloseIsFinal() throws {
        let f = try fixture()
        let recording = try NativeUIProfileFile(dataRoot: f.data)
        defer { recording.close() }
        XCTAssertEqual(recording.url.deletingLastPathComponent(), f.data.appendingPathComponent("logs/ui-recordings", isDirectory: true))
        XCTAssertEqual(try metadata(recording.url).st_mode & 0o7777, 0o600)
        XCTAssertEqual(try metadata(recording.url).st_uid, getuid())
        XCTAssertEqual(try metadata(recording.url).st_nlink, 1)
        XCTAssertEqual(try metadata(recording.url.deletingLastPathComponent()).st_mode & 0o7777, 0o700)
        XCTAssertEqual(try metadata(f.data.appendingPathComponent("logs")).st_mode & 0o7777, 0o700)
        XCTAssertTrue(try Data(contentsOf: recording.url).isEmpty)
        var value = row(recording, visit: 2)
        value["session"] = recording.sessionID.uuidString.lowercased()
        value["parentNavigationVisit"] = 1
        let pretty = try encoded(value, pretty: true)
        try recording.append(Data(" \n\t".utf8) + pretty + Data("\n ".utf8))
        let saved = try Data(contentsOf: recording.url)
        XCTAssertEqual(saved.last, 10)
        XCTAssertEqual(saved.filter { $0 == 10 }.count, 1, "One canonical JSONL record, not unchecked source formatting")
        let admitted = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertEqual(Set(admitted.keys), Set(value.keys).union(["origin"]))
        XCTAssertEqual(admitted["session"] as? String, recording.sessionID.uuidString)
        XCTAssertEqual(admitted["origin"] as? String, "manual")
        XCTAssertEqual(admitted["page"] as? String, "stats")
        XCTAssertEqual(admitted["elapsedMs"] as? Double, 12.5)
        let initial = try XCTUnwrap(admitted["initial"] as? NSNumber)
        XCTAssertEqual(CFGetTypeID(initial), CFBooleanGetTypeID()); XCTAssertFalse(initial.boolValue)
        let second = try NativeUIProfileFile(dataRoot: f.data)
        defer { second.close() }
        XCTAssertNotEqual(second.sessionID, recording.sessionID); XCTAssertNotEqual(second.url, recording.url)
        XCTAssertTrue(try Data(contentsOf: second.url).isEmpty)
        recording.close(); recording.close()
        XCTAssertThrowsError(try recording.append(try encoded(row(recording))))
        XCTAssertEqual(try Data(contentsOf: recording.url), saved)
    }

    func testForeignContentSchemaSessionAndNonBooleanInitialAreRejectedWithoutWriting() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["model"] = "unrequested content" }, { $0["path"] = "/fixture/private" },
            { $0["page"] = "free-form page" }, { $0["trigger"] = "free-form action" },
            { $0["phase"] = "free-form result" }, { $0["reason"] = "free-form failure" },
            { $0["origin"] = "automatic" }, { $0["session"] = UUID().uuidString },
            { $0["schema"] = 2 }, { $0["schema"] = "1" }, { $0["initial"] = true },
            { $0["initial"] = NSNumber(value: 0) }, { $0["initial"] = "false" },
            { $0["recordedAt"] = "yesterday" }, { $0["recordedAt"] = "2026-10-29T12:34:56+00:00" },
            { $0.removeValue(forKey: "elapsedMs") }
        ]
        for mutate in mutations {
            try rejection { recording in var value = self.row(recording); mutate(&value); return try self.encoded(value) }
        }
        for invalid in [Data("not JSON\n".utf8), Data("[]".utf8), Data("{\"schema\":1".utf8)] {
            try rejection { _ in invalid }
        }
        try rejection { recording in Data(repeating: 0x20, count: 16_385) + (try self.encoded(self.row(recording))) }
    }

    func testCFBooleansAndInvalidNumericMetadataCannotMasqueradeAsCounters() throws {
        let boolean = NSNumber(value: true)
        XCTAssertEqual(CFGetTypeID(boolean), CFBooleanGetTypeID())
        for key in ["schema", "pid", "visit", "elapsedMs", "userCPUMs", "systemCPUMs", "peakResidentBytes", "parentNavigationVisit"] {
            try rejection { recording in var value = self.row(recording); value[key] = boolean; return try self.encoded(value) }
        }
        for (key, invalid) in [("pid", 0.0), ("visit", 1.5), ("parentNavigationVisit", 0.0),
                               ("elapsedMs", -0.5), ("userCPUMs", -1.0), ("systemCPUMs", 1e19), ("peakResidentBytes", -1.0)] {
            try rejection { recording in var value = self.row(recording); value[key] = invalid; return try self.encoded(value) }
        }
    }

    func testRecordAndCanonicalByteCapsRetainEveryPreviouslyAcceptedByte() throws {
        let f = try fixture(), recording = try writer(f.data, records: 1)
        defer { recording.close() }
        let valid = try encoded(row(recording))
        try recording.append(valid)
        let first = try Data(contentsOf: recording.url)
        XCTAssertThrowsError(try recording.append(valid))
        XCTAssertEqual(try Data(contentsOf: recording.url), first)
        XCTAssertThrowsError(try recording.append(valid))
        // Use actual admitted bytes as the black-box size oracle; input JSON
        // may be smaller/larger than the writer's canonical representation.
        for capacity in [first.count - 1, first.count] {
            let other = try fixture()
            let bounded = try writer(other.data, session: recording.sessionID, bytes: capacity)
            defer { bounded.close() }
            if capacity == first.count {
                try bounded.append(valid)
                XCTAssertEqual(try Data(contentsOf: bounded.url), first)
            }
            let before = try Data(contentsOf: bounded.url)
            XCTAssertThrowsError(try bounded.append(valid))
            XCTAssertEqual(try Data(contentsOf: bounded.url), before)
            XCTAssertThrowsError(try bounded.append(valid))
            XCTAssertEqual(try Data(contentsOf: bounded.url), before)
        }
    }

    func testMonotonicFiveMinuteBoundaryAndInvalidBudgetsFailClosedWithoutSleeping() throws {
        let f = try fixture(), clock = Clock()
        let recording = try writer(f.data, elapsed: { clock.seconds })
        defer { recording.close() }
        let valid = try encoded(row(recording))
        try recording.append(valid)
        clock.seconds = 299.999; try recording.append(valid)
        let before = try Data(contentsOf: recording.url)
        clock.seconds = 300
        XCTAssertThrowsError(try recording.append(valid), "The recording's clock, not the row's elapsedMs, owns expiry")
        XCTAssertEqual(try Data(contentsOf: recording.url), before)
        clock.seconds = 0
        XCTAssertThrowsError(try recording.append(valid)); XCTAssertEqual(try Data(contentsOf: recording.url), before)
        for invalidAge in [-1.0, Double.nan, Double.infinity] {
            let other = try fixture(), invalidClock = Clock()
            let bounded = try writer(other.data, elapsed: { invalidClock.seconds })
            defer { bounded.close() }
            let row = try encoded(self.row(bounded)); try bounded.append(row)
            let saved = try Data(contentsOf: bounded.url)
            invalidClock.seconds = invalidAge
            XCTAssertThrowsError(try bounded.append(row)); XCTAssertEqual(try Data(contentsOf: bounded.url), saved)
            invalidClock.seconds = 0
            XCTAssertThrowsError(try bounded.append(row))
        }
        for limits in [(0, 1, 300.0), ((4 << 20) + 1, 1, 300.0), (4096, 0, 300.0), (4096, 4097, 300.0),
                       (4096, 1, 0.0), (4096, 1, 300.001), (4096, 1, Double.nan), (4096, 1, Double.infinity)] {
            let other = try fixture()
            XCTAssertThrowsError(try writer(other.data, bytes: limits.0, records: limits.1, duration: limits.2))
            XCTAssertFalse(FileManager.default.fileExists(atPath: other.data.appendingPathComponent("logs").path))
        }
    }

    func testLinkedComponentsAndPreexistingCollisionRefuseWithoutChangingIndependentFiles() throws {
        for component in ["data", "logs", "ui-recordings", "file"] {
            let f = try fixture(), session = UUID()
            let outside = f.root.appendingPathComponent("independent", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let sentinel = outside.appendingPathComponent("sentinel")
            let independent = Data("independent fixture bytes".utf8); try independent.write(to: sentinel)
            var dataRoot = f.data
            if component == "data" {
                dataRoot = f.root.appendingPathComponent("linked-data")
                try FileManager.default.createSymbolicLink(at: dataRoot, withDestinationURL: f.data)
            } else if component == "logs" {
                try FileManager.default.createSymbolicLink(at: f.data.appendingPathComponent("logs"), withDestinationURL: outside)
            } else {
                let logs = f.data.appendingPathComponent("logs", isDirectory: true)
                try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let directory = logs.appendingPathComponent("ui-recordings", isDirectory: true)
                if component == "ui-recordings" {
                    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
                } else {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("ui-" + session.uuidString.lowercased() + ".jsonl"), withDestinationURL: sentinel)
                }
            }
            XCTAssertThrowsError(try writer(dataRoot, session: session))
            XCTAssertEqual(try Data(contentsOf: sentinel), independent)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["sentinel"])
        }
        let f = try fixture(), session = UUID()
        let directory = f.data.appendingPathComponent("logs/ui-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let collision = directory.appendingPathComponent("ui-" + session.uuidString.lowercased() + ".jsonl")
        let independent = Data("preexisting unrelated bytes".utf8); try independent.write(to: collision)
        XCTAssertEqual(chmod(collision.path, 0o600), 0)
        let inode = try metadata(collision).st_ino
        XCTAssertThrowsError(try writer(f.data, session: session))
        XCTAssertEqual(try Data(contentsOf: collision), independent); XCTAssertEqual(try metadata(collision).st_ino, inode)
    }

    func testIndependentAppendPermissionAndHardLinkChangesAreRejectedWithoutRepairOrTruncation() throws {
        for change in ["append", "chmod", "hardlink"] {
            let f = try fixture(), recording = try writer(f.data)
            defer { recording.close() }
            let valid = try encoded(row(recording)); try recording.append(valid)
            let alias = f.root.appendingPathComponent("independent-alias")
            if change == "append" { try appendIndependently(Data("independent appended tail\n".utf8), to: recording.url) }
            if change == "chmod" { XCTAssertEqual(chmod(recording.url.path, 0o640), 0) }
            if change == "hardlink" { XCTAssertEqual(link(recording.url.path, alias.path), 0) }
            let before = try Data(contentsOf: recording.url), info = try metadata(recording.url)
            XCTAssertThrowsError(try recording.append(valid))
            XCTAssertThrowsError(try recording.append(valid))
            XCTAssertEqual(try Data(contentsOf: recording.url), before)
            XCTAssertEqual(try metadata(recording.url).st_mode, info.st_mode)
            XCTAssertEqual(try metadata(recording.url).st_nlink, info.st_nlink)
            if change == "hardlink" { XCTAssertEqual(try Data(contentsOf: alias), before) }
        }
    }

    func testNameReplacementNeverMutatesReplacementOrRetiredInodeBytes() throws {
        for replacement in ["same-size-file", "symlink", "retired-inode-append"] {
            let f = try fixture(), recording = try writer(f.data)
            defer { recording.close() }
            let valid = try encoded(row(recording)); try recording.append(valid)
            let baseline = try Data(contentsOf: recording.url)
            let retired = f.root.appendingPathComponent("retired-recording")
            XCTAssertEqual(rename(recording.url.path, retired.path), 0)
            let independent = Data(repeating: 0x52, count: baseline.count)
            let target = replacement == "symlink" ? f.root.appendingPathComponent("independent-target") : recording.url
            try independent.write(to: target, options: .withoutOverwriting)
            XCTAssertEqual(chmod(target.path, 0o600), 0)
            if replacement == "symlink" { try FileManager.default.createSymbolicLink(at: recording.url, withDestinationURL: target) }
            if replacement == "retired-inode-append" { try appendIndependently(Data("independent retired tail\n".utf8), to: retired) }
            let retiredBefore = try Data(contentsOf: retired)
            XCTAssertThrowsError(try recording.append(valid)); XCTAssertThrowsError(try recording.append(valid))
            XCTAssertEqual(try Data(contentsOf: target), independent)
            XCTAssertEqual(try Data(contentsOf: retired), retiredBefore)
            XCTAssertEqual(try Data(contentsOf: recording.url), independent)
        }
    }
}
