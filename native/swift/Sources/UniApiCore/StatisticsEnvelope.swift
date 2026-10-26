import Foundation

/// Usage readers need metadata, clocks and counters, never prompt/tool bodies.
/// JSONDecoder validates the whole JSON but skips constructing ignored values.
struct StatisticsEnvelope: Decodable {
    let value: JSONValue
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: Key.self)
        func fields(_ container: KeyedDecodingContainer<Key>, _ names: [String]) throws -> JSONObject {
            var result: JSONObject = [:]
            for name in names where container.contains(Key(name)) { result[name] = try container.decode(JSONValue.self, forKey: Key(name)) }
            return result
        }
        var result = try fields(root, ["type", "timestamp", "uuid", "parentUuid", "cwd", "sessionId", "isSidechain", "effort"])
        if let message = try? root.nestedContainer(keyedBy: Key.self, forKey: Key("message")) {
            // Claude thinking and server-tool counters are already in usage.
            result["message"] = .object(try fields(message, ["id", "model", "usage"]))
        }
        if let payload = try? root.nestedContainer(keyedBy: Key.self, forKey: Key("payload")) {
            let type = result["type"]?.string ?? ""
            let names: [String]
            switch type {
            case "session_meta": names = ["id", "session_id", "cwd", "source", "parent_thread_id"]
            case "turn_context": names = ["turn_id", "model", "cwd", "effort"]
            case "response_item": names = ["type", "turn_id", "call_id", "role"]
            case "token_usage_record": names = ["turn_id", "response_id", "thread_id", "usage"]
            case "event_msg": names = ["type", "turn_id", "info"]
            default: names = []
            }
            result["payload"] = .object(try fields(payload, names))
        }
        value = .object(result)
    }
}
