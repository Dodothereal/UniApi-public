import Foundation

public enum NativeNotifications {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    /// Explicit app-owned opt-in. Credentials never enter UserDefaults or diagnostics.
    public struct Configuration: Codable, Equatable, Sendable {
        public var enabled: Bool
        public var token: String
        public var chat: String
        public init(enabled: Bool = false, token: String = "", chat: String = "") {
            self.enabled = enabled; self.token = token; self.chat = chat
        }
    }

    /// Reject linked components before reading or publishing credentials. The caller
    /// supplies the home, so fixtures and previews do not consult the operator home.
    public static func configurationURL(home: URL) throws -> URL {
        do {
            return try NativePaths(root: home, home: home).containedFile("Library/Application Support/UniApi/notifications.json", in: home)
        } catch { throw NativeFailure("Notification configuration is unavailable") }
    }

    public static func configuration(home: URL) throws -> Configuration {
        do {
            let url = try configurationURL(home: home)
            guard FileManager.default.fileExists(atPath: url.path) else { return Configuration() }
            // Codable requires an actual JSON Boolean and actual strings; numbers
            // and string truthiness must never enable external delivery.
            return try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
        } catch { throw NativeFailure("Notification configuration is unavailable") }
    }

    public static func save(_ configuration: Configuration, home: URL) throws {
        do {
            if configuration.enabled { try validate(configuration) }
            let url = try configurationURL(home: home)
            try NativeFile.writeAtomic(JSONEncoder().encode(configuration), to: url, permissions: 0o600)
        } catch { throw NativeFailure("Notification configuration could not be saved") }
    }

    private static func validate(_ configuration: Configuration) throws {
        guard validToken(configuration.token),
              !configuration.chat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeFailure("Notification configuration is incomplete")
        }
    }

    private static func validToken(_ token: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-")
        return !token.isEmpty && token.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public struct Chat: Equatable, Identifiable, Sendable {
        public let id: String
        public let label: String
        public init(id: String, label: String) { self.id = id; self.label = label }
    }

    public enum ChatLookupError: Error, LocalizedError, Equatable, Sendable {
        case invalidToken, unavailable, conflict, invalidResponse, responseTooLarge
        public var errorDescription: String? {
            switch self {
            case .invalidToken: return "Enter a valid bot token before finding chats."
            case .unavailable: return "Could not find chats. Check the token and connection, then retry."
            case .conflict: return "Telegram could not provide updates. A webhook or another client may be using them; enter a chat ID manually."
            case .invalidResponse: return "Telegram returned an unreadable chat list. Try again or enter a chat ID manually."
            case .responseTooLarge: return "Telegram returned too much data. Enter a chat ID manually."
            }
        }
    }

    /// Called only on an explicit user action. No offset is sent, so this request
    /// does not acknowledge updates or change the bot's webhook configuration.
    public static func findChats(token: String, transport: Transport? = nil) async throws -> [Chat] {
        guard token.utf8.count <= 256, validToken(token), let url = URL(string: "https://api.telegram.org/bot\(token)/getUpdates") else {
            throw ChatLookupError.invalidToken
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        let response: (Data, Int)
        do {
            try Task.checkCancellation()
            response = try await (transport ?? boundedChatTransport)(request)
            try Task.checkCancellation()
        } catch is CancellationError { throw CancellationError() }
        catch let error as ChatLookupError { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            throw ChatLookupError.unavailable
        }
        guard response.0.count <= chatResponseLimit else { throw ChatLookupError.responseTooLarge }
        if response.1 == 409 { throw ChatLookupError.conflict }
        guard response.1 == 200 else { throw ChatLookupError.unavailable }
        let envelope: ChatEnvelope
        do { envelope = try JSONDecoder().decode(ChatEnvelope.self, from: response.0) }
        catch { throw ChatLookupError.invalidResponse }
        guard envelope.ok, let updates = envelope.result, updates.count <= 100 else { throw ChatLookupError.invalidResponse }
        var seen = Set<Int64>()
        var chats: [Chat] = []
        for update in updates {
            for item in [update.message, update.editedMessage, update.channelPost, update.editedChannelPost].compactMap({ $0 }) {
                let chat = item.chat
                // Telegram documents chat identifiers as at most 52 significant bits.
                guard chat.id != 0, (-4_503_599_627_370_495...4_503_599_627_370_495).contains(chat.id),
                      seen.insert(chat.id).inserted else { continue }
                let pieces = [chat.firstName, chat.lastName].compactMap { $0 }.joined(separator: " ")
                let preferred = [chat.title, pieces.isEmpty ? nil : pieces, chat.username].compactMap { $0 }.first
                let label = cleanChatLabel(preferred, id: chat.id, token: token)
                chats.append(Chat(id: String(chat.id), label: label))
                if chats.count == 50 { return chats }
            }
        }
        return chats
    }

    private static let chatResponseLimit = 256 * 1024

    private static func cleanChatLabel(_ label: String?, id: Int64, token: String) -> String {
        guard let label else { return "Chat \(id)" }
        let scalars = label.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: token, with: "[redacted]").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Chat \(id)" : String(cleaned.prefix(80))
    }

    private static func boundedChatTransport(_ request: URLRequest) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: ChatRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < chatResponseLimit else { throw ChatLookupError.responseTooLarge }
            data.append(byte)
        }
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private struct ChatEnvelope: Decodable {
        let ok: Bool
        let result: [ChatUpdate]?
    }
    private struct ChatUpdate: Decodable {
        let message: ChatMessage?
        let editedMessage: ChatMessage?
        let channelPost: ChatMessage?
        let editedChannelPost: ChatMessage?
        enum CodingKeys: String, CodingKey {
            case message
            case editedMessage = "edited_message", channelPost = "channel_post", editedChannelPost = "edited_channel_post"
        }
    }
    private struct ChatMessage: Decodable { let chat: ChatRecord }
    private struct ChatRecord: Decodable {
        let id: Int64
        let title: String?
        let firstName: String?
        let lastName: String?
        let username: String?
        enum CodingKeys: String, CodingKey {
            case id, title, username
            case firstName = "first_name", lastName = "last_name"
        }
    }

    @discardableResult
    public static func send(_ text: String, home: URL, transport: Transport? = nil) async throws -> Bool {
        let configuration = try configuration(home: home)
        guard configuration.enabled else { return false }
        try validate(configuration)
        guard let url = URL(string: "https://api.telegram.org/bot\(configuration.token)/sendMessage") else { throw NativeFailure("Notification configuration is incomplete") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONValue.object(["chat_id": .string(configuration.chat), "text": .string(String(text.prefix(4096))), "disable_web_page_preview": true]).encoded()
        let perform = transport ?? { request in let (data, response) = try await URLSession.shared.data(for: request); return (data, (response as? HTTPURLResponse)?.statusCode ?? 0) }
        do {
            let (data, status) = try await perform(request)
            guard status == 200, (try? JSONValue.decode(data)["ok"].bool) == true else { throw NativeFailure("Telegram did not confirm notification delivery") }
        } catch { throw NativeFailure("Telegram notification delivery failed") }
        return true
    }
}

/// Telegram credentials are in the URL path, so never forward a redirect.
private final class ChatRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
