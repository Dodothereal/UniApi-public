import Foundation

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Sendable, Codable, Equatable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object(JSONObject)

    public init(any: Any?) {
        switch any {
        case nil, is NSNull: self = .null
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSONValue(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { JSONValue(any: $0) })
        default: self = .null
        }
    }
    public var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .number(let v): return v.isFinite ? v as Any : NSNull()
        case .string(let v): return v
        case .array(let v): return v.map(\.any)
        case .object(let v): return v.mapValues(\.any)
        }
    }
    public var object: JSONObject { if case .object(let v) = self { return v }; return [:] }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var string: String {
        switch self { case .string(let v): return v; case .number(let v): return v == v.rounded() ? String(format: "%.0f", v) : String(v); default: return "" }
    }
    public var double: Double { if case .number(let v) = self { return v }; return Double(string) ?? 0 }
    public var int: Int { let v = double; return v.isFinite && v >= Double(Int.min) && v < Double(Int.max) ? Int(v) : 0 }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
    public var isNull: Bool { self == .null }
    public subscript(_ key: String) -> JSONValue {
        get { object[key] ?? .null }
        set { var d = object; d[key] = newValue; self = .object(d) }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode(JSONObject.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): if v.isFinite { try c.encode(v) } else { try c.encodeNil() }
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public static func decode(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: data) }
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let v): hasher.combine(1); hasher.combine(v)
        case .number(let v): hasher.combine(2); hasher.combine(v)
        case .string(let v): hasher.combine(3); hasher.combine(v)
        case .array(let v): hasher.combine(4); hasher.combine(v)
        case .object(let v): hasher.combine(5); for key in v.keys.sorted() { hasher.combine(key); hasher.combine(v[key]) }
        }
    }
    public func encoded(pretty: Bool = false) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }
}

import CoreFoundation
extension JSONValue: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }
extension JSONValue: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension JSONValue: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int) { self = .number(Double(value)) } }
extension JSONValue: ExpressibleByFloatLiteral { public init(floatLiteral value: Double) { self = .number(value) } }
extension JSONValue: ExpressibleByStringLiteral { public init(stringLiteral value: String) { self = .string(value) } }
extension JSONValue: ExpressibleByArrayLiteral { public init(arrayLiteral elements: JSONValue...) { self = .array(elements) } }
extension JSONValue: ExpressibleByDictionaryLiteral { public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last })) } }

public struct NativeFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
