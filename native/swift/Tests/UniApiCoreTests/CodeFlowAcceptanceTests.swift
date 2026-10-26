import XCTest
import Foundation
@testable import UniApiCore

final class CodeFlowAcceptanceTests: XCTestCase {
    private func fixture() throws -> NativeRuntime {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("code-flow-" + UUID().uuidString)
        let runtime = try NativeRuntime(paths: NativePaths(root: root, home: root.appendingPathComponent("home")))
        try FileManager.default.createDirectory(at: runtime.paths.home, withIntermediateDirectories: true)
        addTeardownBlock { await runtime.jobs.suspendForShutdown(); try? FileManager.default.removeItem(at: root) }; return runtime
    }
    private static func acp(_ frame: JSONValue, _ response: JSONValue) -> JSONValue { ["jsonrpc": "2.0", "id": frame["id"], "result": response] }
    func testACPHeldTurnFollowupsStayFIFOAndInterruptDiscardsOnlyUnstartedTurns() async throws {
        let runtime = try fixture()
        let channel = CodeFixtureChannel { frame in
            if frame["method"].string == "initialize" { return [Self.acp(frame, [:])] }
            if frame["method"].string == "session/new" { return [Self.acp(frame, ["sessionId": "fixture"])] }
            if frame["method"].string == "session/prompt" || frame["id"].isNull { return [] }
            return [Self.acp(frame, [:])]
        }
        let driver = CodeDriver(runtime: runtime, directory: runtime.paths.root, thread: ["id": "thread", "permission_mode": "default"], wire: .acp, channelFactory: { channel }, sink: { _,_ in }, permission: { _ in })
        addTeardownBlock { await driver.close() }
        try await driver.send("first"); try await driver.send("second"); try await driver.send("third")
        try await codeFixtureEventually { channel.frames().filter { $0["method"].string == "session/prompt" }.count == 1 }
        let first = try XCTUnwrap(channel.frames().first { $0["method"].string == "session/prompt" })
        XCTAssertEqual(first["params"]["prompt"].array.first?["text"], "first")
        channel.emit(Self.acp(first, ["stopReason": "end_turn"]))
        try await codeFixtureEventually { channel.frames().filter { $0["method"].string == "session/prompt" }.count == 2 }
        let second = channel.frames().filter { $0["method"].string == "session/prompt" }[1]
        XCTAssertEqual(second["params"]["prompt"].array.first?["text"], "second")
        try await driver.interrupt()
        XCTAssertTrue(channel.frames().contains { $0["method"].string == "session/cancel" })
        channel.emit(Self.acp(second, ["stopReason": "cancelled"]))
        try await driver.send("fourth")
        try await codeFixtureEventually { channel.frames().filter { $0["method"].string == "session/prompt" }.count == 3 }
        let prompts = channel.frames().filter { $0["method"].string == "session/prompt" }
        XCTAssertEqual(prompts.map { $0["params"]["prompt"].array.first?["text"].string ?? "" }, ["first", "second", "fourth"])
        channel.emit(Self.acp(prompts[2], ["stopReason": "end_turn"]))
        await driver.close(); XCTAssertTrue(channel.didClose())
    }
    func testClaudeQueuedDuringHeldHandshakeMatchesDurableUserOrderAndHistoricalError() async throws {
        let runtime = try fixture(), channel = CodeFixtureChannel { _ in [] }
        let service = NativeCodeService(runtime: runtime, channelFactory: { _ in channel })
        addTeardownBlock { await service.shutdown() }
        let project = try await service.handle("project.add", input: ["path": .string(runtime.paths.root.path)])
        let thread = try await service.handle("thread.create", input: ["projectId": project["id"]])
        for text in ["first", "second", "third"] { _ = try await service.handle("send", input: ["id": thread["id"], "text": .string(text)]) }
        try await codeFixtureEventually { channel.frames().contains { $0["request"]["subtype"].string == "initialize" } }
        let initialize = try XCTUnwrap(channel.frames().first { $0["request"]["subtype"].string == "initialize" })
        channel.emit(["type": "control_response", "response": ["subtype": "success", "request_id": initialize["request_id"], "response": ["models": []]]])
        try await codeFixtureEventually { channel.frames().filter { $0["type"].string == "user" }.count == 3 }
        let data = try await service.handle("thread", input: ["id": thread["id"]])
        let stored = data["events"].array.filter { $0["type"].string == "user" }.map { $0["payload"]["content"].string }
        XCTAssertEqual(channel.frames().filter { $0["type"].string == "user" }.map { $0["message"]["content"].string }, stored)
        XCTAssertEqual(stored, ["first", "second", "third"])
        channel.emit(["type": "assistant", "uuid": "failed-assistant", "message": ["id": "failed", "content": [["type": "text", "text": "partial"]]], "error": "historical failure", "aborted": true])
        channel.emit(["type": "result", "uuid": "success-later", "subtype": "success", "is_error": false, "usage": [:]])
        try await codeFixtureEventually { let row = try await service.handle("thread", input: ["id": thread["id"]]); return row["thread"]["turns"].int == 1 && row["thread"]["last_error"].isNull }
        let history = try await service.handle("thread", input: ["id": thread["id"]])
        let assistant = try XCTUnwrap(history["events"].array.first { $0["type"].string == "assistant" })
        XCTAssertTrue(history["thread"]["last_error"].isNull)
        XCTAssertEqual(CodeEventPresentation.errorText(assistant["payload"]["error"]), "historical failure"); XCTAssertTrue(assistant["payload"]["aborted"].bool)
        await service.shutdown()
    }
    func testOfflineProjectGitStatusTrackedAndUntrackedDiffsSelectCorrectRepository() async throws {
        let runtime = try fixture(), home = runtime.paths.home
        let first = runtime.paths.root.appendingPathComponent("first"), second = runtime.paths.root.appendingPathComponent("second")
        try await CodeOfflineGit.repository(first, home: home); try await CodeOfflineGit.repository(second, home: home)
        try await CodeOfflineGit.checked(["branch", "-m", "different"], at: second, home: home)
        try Data("after\n".utf8).write(to: first.appendingPathComponent("README.md")); try Data("untracked fixture\n".utf8).write(to: first.appendingPathComponent("new.txt"))
        let service = NativeCodeService(runtime: runtime, gitEnvironment: CodeOfflineGit.environment(home: home))
        let a = try await service.handle("project.add", input: ["path": .string(first.path)]), b = try await service.handle("project.add", input: ["path": .string(second.path)])
        let one = try await service.handle("thread.create", input: ["projectId": a["id"]]), two = try await service.handle("thread.create", input: ["projectId": b["id"]])
        let allThreads = try await service.handle("threads"); XCTAssertEqual(Set(allThreads.array.map { $0["id"] }), [one["id"], two["id"]])
        let projectThreads = try await service.handle("threads", input: ["project": a["id"]]); XCTAssertEqual(projectThreads.array.map { $0["id"] }, [one["id"]])
        let status = try await service.handle("project.git", input: ["id": a["id"]])
        XCTAssertTrue(status["branch"].string.contains("main")); XCTAssertEqual(Set(status["files"].array.map { $0["path"].string }), ["README.md", "new.txt"])
        XCTAssertTrue(status["diffStat"].string.contains("README.md"))
        let tracked = try await service.handle("project.diff", input: ["id": a["id"], "file": "README.md"])
        XCTAssertTrue(tracked["diff"].string.contains("-before")); XCTAssertTrue(tracked["diff"].string.contains("+after"))
        let untracked = try await service.handle("project.diff", input: ["id": a["id"], "file": "new.txt"])
        XCTAssertTrue(untracked["diff"].string.contains("+untracked fixture"))
        let other = try await service.handle("project.git", input: ["id": b["id"]])
        XCTAssertTrue(other["branch"].string.contains("different")); XCTAssertTrue(other["files"].array.isEmpty)
    }
    func testImageLimitsRejectBeforePersistingAndSixValidImagesReachInjectedChannel() async throws {
        let runtime = try fixture(), channel = CodeFixtureChannel { frame in
            if frame["type"].string == "control_request" { return [["type": "control_response", "response": ["subtype": "success", "request_id": frame["request_id"], "response": [:]]]] }
            if frame["type"].string == "user" { return [["type": "result", "uuid": "image-result", "subtype": "success", "usage": [:]]] }; return []
        }
        let service = NativeCodeService(runtime: runtime, channelFactory: { _ in channel })
        addTeardownBlock { await service.shutdown() }
        let project = try await service.handle("project.add", input: ["path": .string(runtime.paths.root.path)])
        let thread = try await service.handle("thread.create", input: ["projectId": project["id"]])
        let image: JSONValue = ["media_type": "image/png", "data": "AQID"]
        let bad: [[JSONValue]] = [Array(repeating: image, count: 7), [["media_type": "text/html", "data": "AQID"]], [["media_type": "image/png", "data": "not-base64!"]], [["media_type": "image/png", "data": .string(Data(repeating: 0, count: 10 * 1024 * 1024 + 1).base64EncodedString())]]]
        for images in bad {
            do { _ = try await service.handle("send", input: ["id": thread["id"], "text": "Fixture", "images": .array(images)]); XCTFail("Invalid image request accepted") } catch {}
        }
        let before = try await service.handle("thread", input: ["id": thread["id"]]); XCTAssertTrue(before["events"].array.isEmpty); XCTAssertTrue(channel.frames().isEmpty)
        _ = try await service.handle("send", input: ["id": thread["id"], "text": "Fixture", "images": .array(Array(repeating: image, count: 6))])
        try await codeFixtureEventually { try await service.handle("thread", input: ["id": thread["id"]])["thread"]["turns"].int == 1 }
        let sent = try XCTUnwrap(channel.frames().first { $0["type"].string == "user" })
        XCTAssertEqual(sent["message"]["content"].array.filter { $0["type"].string == "image" }.count, 6)
        XCTAssertEqual(sent["message"]["content"].array.last?["text"], "Fixture")
    }
}
