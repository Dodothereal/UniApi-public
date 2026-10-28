import XCTest
@testable import UniApiCore

final class NativeNotificationChatLookupTests: XCTestCase {
    private let token = "fixture-bot-token"

    func testExplicitLookupUsesFixedGetWithoutOffsetOrMessageAndDeduplicatesChats() async throws {
        let json = #"{"ok":true,"result":[{"message":{"chat":{"id":123,"first_name":"Ada"}}},{"message":{"chat":{"id":123,"first_name":"Duplicate"}}},{"message":{"chat":{"id":-456,"title":"Team"}}}]}"#
        let chats = try await NativeNotifications.findChats(token: token, transport: { request in
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "api.telegram.org")
            XCTAssertEqual(request.url?.path, "/botfixture-bot-token/getUpdates")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.timeoutInterval, 20)
            return (Data(json.utf8), 200)
        })
        XCTAssertEqual(chats, [.init(id: "123", label: "Ada"), .init(id: "-456", label: "Team")])
    }

    func testEmptyAndSanitizedLabels() async throws {
        let empty = try await NativeNotifications.findChats(token: token, transport: { _ in (Data(#"{"ok":true,"result":[]}"#.utf8), 200) })
        XCTAssertTrue(empty.isEmpty)
        let json = #"{"ok":true,"result":[{"message":{"chat":{"id":1,"title":"fixture-bot-token\nGroup"}}},{"message":{"chat":{"id":2}}}]}"#
        let chats = try await NativeNotifications.findChats(token: token, transport: { _ in (Data(json.utf8), 200) })
        XCTAssertEqual(chats, [.init(id: "1", label: "[redacted]Group"), .init(id: "2", label: "Chat 2")])
    }

    func testChatIdsAndLabelsAreBounded() async throws {
        let label = String(repeating: "x", count: 200)
        let json = "{\"ok\":true,\"result\":[{\"message\":{\"chat\":{\"id\":1,\"title\":\"" + label + "\"}}},{\"message\":{\"chat\":{\"id\":4503599627370496}}}]}"
        let chats = try await NativeNotifications.findChats(token: token, transport: { _ in (Data(json.utf8), 200) })
        XCTAssertEqual(chats.count, 1)
        XCTAssertEqual(chats.first?.label.count, 80)
    }

    func testMalformedAndOversizedResponsesAreRejected() async throws {
        for json in ["not JSON", #"{"ok":"true","result":[]}"#, #"{"ok":true,"result":[{"message":{"chat":{"id":"1"}}}]}"#, #"{"ok":true}"#] {
            do {
                _ = try await NativeNotifications.findChats(token: token, transport: { _ in (Data(json.utf8), 200) })
                XCTFail("Malformed response accepted")
            } catch { XCTAssertEqual(error as? NativeNotifications.ChatLookupError, .invalidResponse) }
        }
        do {
            _ = try await NativeNotifications.findChats(token: token, transport: { _ in (Data(repeating: 65, count: 256 * 1024 + 1), 200) })
            XCTFail("Oversized response accepted")
        } catch { XCTAssertEqual(error as? NativeNotifications.ChatLookupError, .responseTooLarge) }
        let tooMany = #"{"ok":true,"result":["# + Array(repeating: "{}", count: 101).joined(separator: ",") + "]}"
        do {
            _ = try await NativeNotifications.findChats(token: token, transport: { _ in (Data(tooMany.utf8), 200) })
            XCTFail("Excess updates accepted")
        } catch { XCTAssertEqual(error as? NativeNotifications.ChatLookupError, .invalidResponse) }
    }

    func testConflictAndTransportErrorsNeverExposeTokenOrResponse() async throws {
        for (status, expected) in [(409, NativeNotifications.ChatLookupError.conflict), (401, .unavailable)] {
            do {
                _ = try await NativeNotifications.findChats(token: token, transport: { _ in (Data("fixture-bot-token".utf8), status) })
                XCTFail("Failure accepted")
            } catch {
                XCTAssertEqual(error as? NativeNotifications.ChatLookupError, expected)
                XCTAssertFalse(error.localizedDescription.contains(token))
            }
        }
        do {
            _ = try await NativeNotifications.findChats(token: token, transport: { _ in throw NativeFailure("fixture-bot-token") })
            XCTFail("Transport failure accepted")
        } catch {
            XCTAssertEqual(error as? NativeNotifications.ChatLookupError, .unavailable)
            XCTAssertFalse(error.localizedDescription.contains(token))
        }
    }

    func testCancellationRemainsCancellation() async throws {
        do {
            _ = try await NativeNotifications.findChats(token: token, transport: { _ in throw CancellationError() })
            XCTFail("Cancellation was ignored")
        } catch is CancellationError {
            // Cancellation is distinct from a lookup error and carries no URL.
        } catch { XCTFail("Unexpected lookup result") }
    }

    func testInvalidTokenDoesNotCallTransport() async throws {
        for invalid in ["", "bad/token", String(repeating: "a", count: 257)] {
            do {
                _ = try await NativeNotifications.findChats(token: invalid, transport: { _ in
                    XCTFail("Invalid token reached transport")
                    return (Data(), 200)
                })
                XCTFail("Invalid token accepted")
            } catch { XCTAssertEqual(error as? NativeNotifications.ChatLookupError, .invalidToken) }
        }
    }
}
