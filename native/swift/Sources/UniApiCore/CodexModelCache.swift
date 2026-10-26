import Foundation

/// Model catalogs can contain large tool/prompt metadata that the picker never
/// uses. Decode only its fields; do not apply the smaller settings-file limit
/// or retain every configured tool definition for every model.
enum NativeCodexModelCache {
    static func rows(_ file: URL) throws -> [JSONValue] {
        let data = try SwitcherDisk.read(file, limit: 64 * 1024 * 1024)
        guard !data.isEmpty else { return [] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.models.map(\.value)
    }
    private struct Envelope: Decodable {
        let models: [Row]
        enum Key: String, CodingKey { case models }
        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Key.self) else { models = []; return }
            models = (try? container.decode([Row].self, forKey: .models)) ?? []
        }
    }
    private struct Row: Decodable {
        let value: JSONValue
        enum Key: String, CodingKey {
            case slug, display_name, visibility, hidden, supported_in_api, priority, multi_agent_version, supported_reasoning_levels
        }
        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Key.self) else { value = .null; return }
            var row: JSONObject = [:]
            for key in [Key.slug, .display_name, .visibility, .multi_agent_version] {
                if let text = try? container.decode(String.self, forKey: key) { row[key.rawValue] = .string(text) }
            }
            for key in [Key.hidden, .supported_in_api] {
                if let flag = try? container.decode(Bool.self, forKey: key) { row[key.rawValue] = .bool(flag) }
            }
            if let priority = try? container.decode(JSONValue.self, forKey: .priority) { row["priority"] = priority }
            if let levels = try? container.decode([Effort].self, forKey: .supported_reasoning_levels) { row["supported_reasoning_levels"] = .array(levels.map(\.value)) }
            value = .object(row)
        }
    }
    private struct Effort: Decodable {
        let value: JSONValue
        enum Key: String, CodingKey { case effort }
        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: Key.self), let effort = try? container.decode(String.self, forKey: .effort) else { value = .null; return }
            value = ["effort": .string(effort)]
        }
    }
}
