import Foundation

public final class NativeCodexCatalogStore: @unchecked Sendable {
    public let file: URL, providersFile: URL
    public init(bridgeHome: URL, providersFile: URL) { file = bridgeHome.appendingPathComponent("uniapi-catalog.json"); self.providersFile = providersFile.standardizedFileURL }
    public static func id(provider: String, model: String) -> String { "uniapi/" + NativeProviderInfo.encoded(provider) + "/" + NativeProviderInfo.encoded(model) }
    public static func parseID(_ value: String) -> (provider: String, model: String)? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "uniapi", let provider = String(parts[1]).removingPercentEncoding, let model = String(parts[2]).removingPercentEncoding,
              !provider.isEmpty, !model.isEmpty, id(provider: provider, model: model) == value else { return nil }; return (provider, model)
    }
    public static func validate(_ value: JSONValue) throws {
        guard Set(value.object.keys) == ["providerIds", "workerModels"], case .array = value["providerIds"], case .array = value["workerModels"], value["providerIds"].array.count <= 100, value["workerModels"].array.count <= 4,
              value["providerIds"].array.allSatisfy({ SwitcherDisk.validLabel($0, limit: 100) }), value["workerModels"].array.allSatisfy({ SwitcherDisk.validLabel($0, limit: 1024) }),
              Set(value["providerIds"].array).count == value["providerIds"].array.count, Set(value["workerModels"].array).count == value["workerModels"].array.count else { throw NativeFailure("Choose unique providers and at most four preferred worker models") }
    }
    public func read() throws -> JSONValue {
        let bytes = try SwitcherDisk.read(file, limit: 65536); if bytes.isEmpty { return ["providerIds": [], "workerModels": []] }
        let value = try JSONValue.decode(bytes)
        guard Set(value.object.keys) == ["version", "providersFile", "providerIds", "workerModels"], value["version"] == 1, URL(fileURLWithPath: value["providersFile"].string).standardizedFileURL == providersFile else { throw NativeFailure("The catalog belongs to a different provider configuration or is invalid; its contents were preserved") }
        let choices: JSONValue = ["providerIds": value["providerIds"], "workerModels": value["workerModels"]]; try Self.validate(choices); return choices
    }
    public func write(_ choices: JSONValue) throws {
        try Self.validate(choices)
        try SwitcherDisk.locked(file) { let before = try SwitcherDisk.read(file, limit: 65536); _ = try read(); let value: JSONValue = ["version": 1, "providersFile": .string(providersFile.path), "providerIds": choices["providerIds"], "workerModels": choices["workerModels"]]; try SwitcherDisk.atomic(file, try value.encoded(pretty: true), expected: before) }
    }
}
