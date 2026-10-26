import XCTest
@testable import UniApiCore

final class PublicSettingsTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("public-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testMissingAndDisabledConfigurationNeverUsesLegacyCredentialsOrTransport() async throws {
        let home = try home()
        try NativeFile.writeAtomic(Data("TELEGRAM_BOT_TOKEN=legacy-fixture\nTELEGRAM_CHAT_ID=legacy-chat\n".utf8), to: home.appendingPathComponent(".claude/.env"))
        XCTAssertEqual(try NativeNotifications.configuration(home: home), .init())
        let forbidden: NativeNotifications.Transport = { _ in
            XCTFail("Disabled notifications attempted transport")
            throw NativeFailure("Unexpected fixture request")
        }
        let sent = try await NativeNotifications.send("fixture", home: home, transport: forbidden)
        XCTAssertFalse(sent)
        try NativeNotifications.save(.init(enabled: false, token: "fixture-bot", chat: "fixture-chat"), home: home)
        try await NativeNotifications.send("fixture", home: home, transport: forbidden)
    }

    func testConfigurationRequiresExactBooleanAndStringTypes() async throws {
        let home = try home()
        let url = try NativeNotifications.configurationURL(home: home)
        for json in [
            #"{"enabled":"true","token":"fixture","chat":"fixture"}"#,
            #"{"enabled":1,"token":"fixture","chat":"fixture"}"#,
            #"{"enabled":true,"token":7,"chat":"fixture"}"#,
            #"{"enabled":true,"token":"fixture","chat":7}"#,
            #"{"enabled":true}"#,
            "not JSON"
        ] {
            try NativeFile.writeAtomic(Data(json.utf8), to: url)
            XCTAssertThrowsError(try NativeNotifications.configuration(home: home))
            do {
                try await NativeNotifications.send("fixture", home: home, transport: { _ in
                    XCTFail("Invalid configuration attempted transport")
                    return (Data(), 200)
                })
                XCTFail("Invalid configuration was accepted")
            } catch { XCTAssertEqual(error.localizedDescription, "Notification configuration is unavailable") }
        }
    }

    func testSaveIsPrivateAndRoundTripsOnlyAppOwnedConfiguration() throws {
        let home = try home()
        let value = NativeNotifications.Configuration(enabled: true, token: "fixture-bot", chat: "fixture-chat")
        try NativeNotifications.save(value, home: home)
        let url = try NativeNotifications.configurationURL(home: home)
        XCTAssertEqual(url, home.appendingPathComponent("Library/Application Support/UniApi/notifications.json"))
        XCTAssertEqual(try NativeNotifications.configuration(home: home), value)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((try XCTUnwrap(mode)).intValue & 0o777, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path))
        XCTAssertThrowsError(try NativeNotifications.save(.init(enabled: true), home: home))
        XCTAssertEqual(try NativeNotifications.configuration(home: home), value)
    }

    func testLinkedConfigurationAndAncestorsAreRejectedWithoutChangingTarget() throws {
        for component in ["Library", "Library/Application Support", "Library/Application Support/UniApi", "Library/Application Support/UniApi/notifications.json"] {
            let home = try home()
            let target = home.appendingPathComponent("fixture-target")
            let link = home.appendingPathComponent(component)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            if component.hasSuffix(".json") {
                try Data("fixture unchanged".utf8).write(to: target)
            } else {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try NativeNotifications.configuration(home: home))
            XCTAssertThrowsError(try NativeNotifications.save(.init(enabled: true, token: "fixture", chat: "fixture"), home: home))
            if component.hasSuffix(".json") {
                XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "fixture unchanged")
            } else {
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
            }
        }
    }

    func testEnabledDeliveryRequiresConfirmationAndRedactsTransportErrors() async throws {
        let home = try home()
        try NativeNotifications.save(.init(enabled: true, token: "fixture-bot", chat: "fixture-chat"), home: home)
        try await NativeNotifications.send(String(repeating: "x", count: 5000), home: home, transport: { request in
            XCTAssertEqual(request.url?.host, "api.telegram.org")
            XCTAssertEqual(request.url?.path, "/botfixture-bot/sendMessage")
            XCTAssertEqual(request.httpMethod, "POST")
            let body = try JSONValue.decode(try XCTUnwrap(request.httpBody))
            XCTAssertEqual(body["text"].string.count, 4096)
            XCTAssertEqual(body["chat_id"], "fixture-chat")
            return (Data(#"{"ok":true}"#.utf8), 200)
        })
        for response in [(Data(#"{"ok":false}"#.utf8), 200), (Data(#"{"ok":true}"#.utf8), 500), (Data(#"{"ok":"true"}"#.utf8), 200)] {
            do {
                try await NativeNotifications.send("fixture", home: home, transport: { _ in response })
                XCTFail("Unconfirmed delivery was accepted")
            } catch { XCTAssertEqual(error.localizedDescription, "Telegram notification delivery failed") }
        }
        do {
            try await NativeNotifications.send("fixture", home: home, transport: { _ in throw NativeFailure("fixture-bot fixture-chat") })
            XCTFail("Transport error was ignored")
        } catch { XCTAssertEqual(error.localizedDescription, "Telegram notification delivery failed") }
    }

    func testPublicProviderExampleHasNoProvidersOrTargets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let example = try NativeFile.readJSON(root.appendingPathComponent("providers.example.json"))
        XCTAssertEqual(example["providers"], .array([]))
        XCTAssertEqual(example["targets"], .array([]))
        XCTAssertEqual(example["model_overrides"], .object([:]))
        XCTAssertEqual(example["settings"], .object([:]))
        XCTAssertFalse(NativeBenchmarkService.scheduleDue(["enabled": false, "time": "04:00", "lastRun": .null], now: Date(timeIntervalSince1970: 1_800_000_000)))
    }
}
