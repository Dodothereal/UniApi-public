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
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_-")
        guard !configuration.token.isEmpty,
              configuration.token.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              !configuration.chat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NativeFailure("Notification configuration is incomplete")
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
