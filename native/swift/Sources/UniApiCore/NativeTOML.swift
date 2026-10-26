import Foundation

/// A document editor, not a serializer. Defaults and native transport ownership
/// are separate projections; parsed equality protects every unowned value.
public enum NativeTOML {
    public static let defaultKeys = ["model", "model_reasoning_effort", "model_provider"]
    static let transportPaths: [String: [String]] = [
        "openai_base_url": ["openai_base_url"], "model_catalog_json": ["model_catalog_json"],
        "features.multi_agent": ["features", "multi_agent"], "features.multi_agent_v2": ["features", "multi_agent_v2"],
        "features.responses_websockets": ["features", "responses_websockets"], "features.responses_websockets_v2": ["features", "responses_websockets_v2"]
    ]
    public static func parse(_ text: String) throws -> JSONObject { try TOMLParser(text).parse().object }
    public static func quote(_ text: String) throws -> String { String(decoding: try JSONValue.string(text).encoded(), as: UTF8.self) }
    /// Ownership markers inside any TOML string are examples, never editable
    /// configuration. An exact block must also describe the complete live table.
    static func ownedProviderBlockRange(_ text: String, block: String) throws -> Range<String.Index>? {
        let parser = TOMLParser(text), document = try parser.parse()
        guard block.hasPrefix("\n# UniApi managed Codex provider: begin\n[model_providers.uniapi_managed]\n"),
              block.hasSuffix("# UniApi managed Codex provider: end\n") else { throw NativeFailure("Invalid owned Codex provider block") }
        let expected = try parse(block), registered = expected["model_providers"] ?? .null
        guard Set(expected.keys) == ["model_providers"], Set(registered.object.keys) == ["uniapi_managed"],
              case .object = registered["uniapi_managed"] else { throw NativeFailure("Invalid owned Codex provider table") }
        var cursor = text.startIndex, matches: [Range<String.Index>] = []
        while cursor < text.endIndex, let range = text.range(of: block, options: .literal, range: cursor..<text.endIndex) {
            let lower = text.unicodeScalars.distance(from: text.startIndex, to: range.lowerBound)
            // Ordinary quoted field values are part of the real provider block.
            // Only a match beginning inside a string is an instruction/example.
            if !parser.stringRanges.contains(where: { $0.contains(lower) }) { matches.append(range) }
            cursor = range.upperBound
        }
        guard matches.count <= 1 else { throw NativeFailure("Owned Codex provider block is ambiguous") }
        guard let range = matches.first,
              document["model_providers"]["uniapi_managed"] == registered["uniapi_managed"] else { return nil }
        return range
    }
    static func removingOwnedProviderBlock(_ text: String, block: String) throws -> String {
        guard let range = try ownedProviderBlockRange(text, block: block) else { throw NativeFailure("The owned Codex provider changed; its contents were preserved") }
        let before = try parse(text), prefix = String(text[..<range.lowerBound]), suffix = String(text[range.upperBound...])
        let separator = !prefix.isEmpty && !suffix.isEmpty && !prefix.hasSuffix("\n") && !suffix.hasPrefix("\n") ? "\n" : ""
        let output = prefix + separator + suffix, after = try parse(output)
        var expected = before, providers = before["model_providers"]?.object ?? [:]
        providers.removeValue(forKey: "uniapi_managed")
        if providers.isEmpty && after["model_providers"] == nil { expected.removeValue(forKey: "model_providers") }
        else { expected["model_providers"] = .object(providers) }
        guard after == expected else { throw NativeFailure("Removing the Codex provider would change another setting") }
        return output
    }
    public static func patchDefaults(_ text: String, values: JSONObject) throws -> String {
        guard Set(values.keys).isSubset(of: Set(defaultKeys)), values.values.allSatisfy({ value in
            if value.isNull { return true }; if case .string = value { return true }; return false
        }) else { throw NativeFailure("Invalid Codex default values") }
        var result = text
        for key in defaultKeys where values[key] != nil {
            let parser = TOMLParser(result), before = try parser.parse()
            var expected = before.object
            if values[key]!.isNull { expected.removeValue(forKey: key) } else { expected[key] = values[key]! }
            if expected == before.object { continue }
            let newline = result.contains("\r\n") ? "\r\n" : "\n"
            if before[key].isNull {
                result = key + " = " + (try quote(values[key]!.string)) + newline + result
            } else {
                guard let range = parser.rootAssignments[key], !parser.multilineDefaults.contains(key) else { throw NativeFailure("Codex \(key) has an unsupported or ambiguous layout; nothing was changed") }
                let characters = result.unicodeScalars.map { Character(String($0)) }
                let eol = String(characters[range]).hasSuffix("\r\n") ? "\r\n" : String(characters[range]).hasSuffix("\n") ? "\n" : ""
                let replacement = values[key]!.isNull ? "" : key + " = " + (try quote(values[key]!.string)) + eol
                result = String(characters[..<range.lowerBound]) + replacement + String(characters[range.upperBound...])
            }
            guard try parse(result) == expected else { throw NativeFailure("Could not safely patch Codex \(key)") }
        }
        return result
    }
    static func transportValues(_ document: JSONObject) -> JSONObject {
        Dictionary(uniqueKeysWithValues: transportPaths.map { key, path in
            (key, path.reduce(JSONValue.object(document)) { $0[$1] })
        })
    }
    /// The native route journal owns these transport scalars independently of
    /// the defaults journal. Parsed equality protects every other TOML value.
    static func patchTransport(_ text: String, values: JSONObject) throws -> String {
        guard Set(values.keys).isSubset(of: Set(transportPaths.keys)), values.allSatisfy({ key, value in
            if value.isNull { return true }
            if key.hasPrefix("features.") { if case .bool = value { return true }; return false }
            if case .string = value { return true }; return false
        }) else { throw NativeFailure("Invalid native Codex transport fields") }
        var output = text
        for key in values.keys.sorted() {
            let parser = TOMLParser(output), before = try parser.parse().object, value = values[key]!, path = transportPaths[key]!
            if transportValues(before)[key] == value { continue }
            var expected = before
            if path.count == 1 {
                if value.isNull { expected.removeValue(forKey: path[0]) } else { expected[path[0]] = value }
            } else {
                guard before[path[0]] == nil || { if case .object = before[path[0]]! { return true }; return false }() else { throw NativeFailure("Codex feature settings have an unsupported layout") }
                var fields = before[path[0]]?.object ?? [:]
                if value.isNull { fields.removeValue(forKey: path[1]) } else { fields[path[1]] = value }
                if fields.isEmpty && parser.featureHeaderEnd == nil { expected.removeValue(forKey: path[0]) }
                else { expected[path[0]] = .object(fields) }
            }
            let newline = output.contains("\r\n") ? "\r\n" : "\n"
            let literal: String
            switch value { case .string(let text): literal = try quote(text); case .bool(let flag): literal = flag ? "true" : "false"; default: literal = "" }
            var chars = output.unicodeScalars.map { Character(String($0)) }
            if let assignment = parser.transportAssignments[key] {
                guard !chars[assignment.value].contains("\n"), !chars[assignment.value].contains("\r") else { throw NativeFailure("Codex transport has an unsupported multiline value") }
                if value.isNull { chars.removeSubrange(assignment.statement) }
                else { chars.replaceSubrange(assignment.value, with: literal.map { $0 }) }
                output = String(chars)
            } else if !value.isNull {
                if path.count == 2, let position = parser.featureHeaderEnd {
                    let separator = position > 0 && chars[position - 1] != "\n" ? newline : ""
                    chars.insert(contentsOf: (separator + path[1] + " = " + literal + newline).map { $0 }, at: position); output = String(chars)
                } else { output = path.joined(separator: ".") + " = " + literal + newline + output }
            }
            guard try parse(output) == expected else { throw NativeFailure("Could not safely patch native Codex transport") }
        }
        return output
    }
}

private final class TOMLParser {
    let chars: [Character]
    var index = 0, root: JSONValue = [:], table: [String] = []
    var headers = Set<String>(), declaredTables = Set<String>(), sealed = Set<String>(), dottedTables = Set<String>()
    var rootAssignments: [String: Range<Int>] = [:], multilineDefaults = Set<String>()
    var transportAssignments: [String: (statement: Range<Int>, value: Range<Int>)] = [:]
    var featureHeaderEnd: Int?
    var stringRanges: [Range<Int>] = []
    init(_ text: String) { chars = text.unicodeScalars.map { Character(String($0)) } }
    func fail() -> NativeFailure { NativeFailure("Codex config is invalid TOML; nothing was changed") }
    var current: Character? { index < chars.count ? chars[index] : nil }
    func has(_ text: String) -> Bool { let pattern = Array(text); return index + pattern.count <= chars.count && Array(chars[index..<index + pattern.count]) == pattern }
    func whitespace(_ lines: Bool = false) {
        while let c = current {
            if c == " " || c == "\t" || (lines && (c == "\n" || c == "\r")) { index += 1 }
            else if lines && c == "#" { while current != nil && current != "\n" { index += 1 } }
            else { break }
        }
    }
    func require(_ c: Character) throws { guard current == c else { throw fail() }; index += 1 }
    func statementEnd() throws {
        whitespace(); if current == "#" { while current != nil && current != "\n" { index += 1 } }
        if current == "\r" { index += 1; try require("\n") }
        else if current == "\n" { index += 1 }
        else if current != nil { throw fail() }
    }
    func parse() throws -> JSONValue {
        while index < chars.count {
            let start = index; whitespace()
            if current == "#" { while current != nil && current != "\n" { index += 1 } }
            else if current == "[" {
                index += 1; let array = current == "["; if array { index += 1 }
                let path = try keys(); whitespace(); try require("]"); if array { try require("]") }
                let name = identity(path)
                guard !path.indices.contains(where: { sealed.contains(identity(Array(path.prefix($0 + 1)))) }) else { throw fail() }
                if array {
                    let existing = get(root, path)
                    guard existing.isNull || { if case .array = existing { return true }; return false }() else { throw fail() }
                    try put(&root, path, .array(existing.array + [[:]]), replace: true)
                } else {
                    guard headers.insert(name).inserted, !dottedTables.contains(name) else { throw fail() }
                    let existing = get(root, path)
                    guard existing.isNull || { if case .object = existing { return true }; return false }() else { throw fail() }
                    if existing.isNull { try put(&root, path, [:], replace: false) }
                }
                // Array-table identities include the current element, so a
                // later element keeps its own independent namespace.
                declaredTables.insert(identity(path)); table = path
                if !array && path == ["features"] { try statementEnd(); featureHeaderEnd = index; continue }
            } else if current != nil && current != "\n" && current != "\r" {
                let path = try keys(); whitespace(); try require("="); whitespace()
                let valueStart = index, value = try value(), valueEnd = index
                guard !table.isEmpty || path.count != 1 || rootAssignments[path[0]] == nil else { throw fail() }
                let full = table + path
                guard !full.dropLast().indices.contains(where: { sealed.contains(identity(Array(full.prefix($0 + 1)))) }) else { throw fail() }
                // Dotted keys may extend implicit parents, but cannot reopen
                // a namespace already declared by a table header.
                guard !(1..<path.count).contains(where: { declaredTables.contains(identity(table + Array(path.prefix($0)))) }) else { throw fail() }
                try put(&root, full, value, replace: false)
                // Dotted assignments define their parent tables; header-created
                // implicit parents may still be declared later, as TOML permits.
                for length in 1..<path.count { dottedTables.insert(identity(table + Array(path.prefix(length)))) }
                switch value {
                case .object, .array: sealed.insert(identity(full))
                default: break
                }
                if let key = NativeTOML.transportPaths.first(where: { $0.value == full })?.key {
                    try statementEnd(); transportAssignments[key] = (start..<index, valueStart..<valueEnd); continue
                }
                if table.isEmpty && path.count == 1 && NativeTOML.defaultKeys.contains(path[0]) {
                    if chars[valueStart..<index].contains("\n") || chars[valueStart..<index].contains("\r") { multilineDefaults.insert(path[0]) }
                    try statementEnd()
                    rootAssignments[path[0]] = start..<index; continue
                }
            }
            try statementEnd()
        }
        return root
    }
    func identity(_ path: [String]) -> String {
        var value = root, parts: [String] = []
        for key in path {
            parts.append(key + ":" + String(key.count)); value = value[key]
            if case .array(let values) = value { parts.append("[\(values.count - 1)]"); value = values.last ?? .null }
        }
        return parts.joined(separator: "/")
    }
    func keys() throws -> [String] {
        var result: [String] = []
        while true {
            whitespace()
            if current == "\"" || current == "'" { result.append(try string(multiline: false)) }
            else {
                let start = index
                while let c = current, c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-") { index += 1 }
                guard start != index else { throw fail() }; result.append(String(chars[start..<index]))
            }
            whitespace(); if current == "." { index += 1 } else { return result }
        }
    }
    func string(multiline allowed: Bool = true) throws -> String {
        let start = index
        defer { stringRanges.append(start..<index) }
        guard let delimiter = current else { throw fail() }; index += 1
        let multiline = allowed && current == delimiter && index + 1 < chars.count && chars[index + 1] == delimiter
        if multiline { index += 2; if current == "\r" { index += 1; try require("\n") } else if current == "\n" { index += 1 } }
        var output = ""
        while let c = current {
            if c == delimiter {
                if !multiline { index += 1; return output }
                if has(String(repeating: String(delimiter), count: 3)) {
                    index += 3
                    var extra = 0; while current == delimiter && extra < 2 { output.append(delimiter); index += 1; extra += 1 }
                    return output
                }
            }
            if c == "\n" || c == "\r" { guard multiline else { throw fail() }; if c == "\r" { index += 1; try require("\n"); output.append("\n"); continue } }
            if c == "\\" && delimiter == "\"" {
                index += 1; guard let escaped = current else { throw fail() }
                if multiline && (escaped == "\n" || escaped == "\r" || escaped == " " || escaped == "\t") {
                    while let c = current, ["\n", "\r", " ", "\t"].contains(c) { index += 1 }; continue
                }
                let escapes: [Character: Character] = ["b": "\u{8}", "t": "\t", "n": "\n", "f": "\u{c}", "r": "\r", "\"": "\"", "\\": "\\"]
                if let replacement = escapes[escaped] { output.append(replacement); index += 1; continue }
                if escaped == "u" || escaped == "U" {
                    index += 1; let length = escaped == "u" ? 4 : 8
                    guard index + length <= chars.count, let code = UInt32(String(chars[index..<index + length]), radix: 16), let scalar = UnicodeScalar(code) else { throw fail() }
                    output.unicodeScalars.append(scalar); index += length; continue
                }
                throw fail()
            }
            guard !c.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 && $0.value != 10 }) else { throw fail() }
            output.append(c); index += 1
        }
        throw fail()
    }
    func value() throws -> JSONValue {
        if current == "\"" || current == "'" { return .string(try string()) }
        if current == "[" {
            index += 1; var values: [JSONValue] = []; whitespace(true)
            while current != "]" { values.append(try value()); whitespace(true); if current != "," { break }; index += 1; whitespace(true) }
            try require("]"); return .array(values)
        }
        if current == "{" {
            index += 1; var object: JSONValue = [:], immutable = Set<[String]>(); whitespace()
            while current != "}" {
                let path = try keys(); try require("="); whitespace()
                guard !(1..<path.count).contains(where: { immutable.contains(Array(path.prefix($0))) }) else { throw fail() }
                let field = try value(); try put(&object, path, field, replace: false)
                // Inline values are complete declarations. Their nested tables
                // and static arrays cannot be extended by a later dotted key.
                switch field { case .object, .array: immutable.insert(path); default: break }
                whitespace()
                if current != "," { break }; index += 1; whitespace(); guard current != "}" else { throw fail() }
            }
            try require("}"); return object
        }
        let start = index
        while let c = current, c != " " && c != "\t" && c != "\r" && c != "\n" && c != "#" && c != "," && c != "]" && c != "}" { index += 1 }
        var token = String(chars[start..<index])
        if token.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil, current == " ", index + 3 < chars.count, chars[index + 3] == ":" {
            index += 1; let timeStart = index
            while let c = current, ![" ", "\t", "\r", "\n", "#", ",", "]", "}"].contains(c) { index += 1 }
            token += " " + String(chars[timeStart..<index])
        }
        let normalized = token.replacingOccurrences(of: "_", with: "")
        if token == "true" { return true }; if token == "false" { return false }
        if token.range(of: "^[+-]?(inf|nan)$", options: .regularExpression) != nil { return ["$toml": .string(token)] }
        let time = "([01][0-9]|2[0-3]):[0-5][0-9]:([0-5][0-9]|60)(\\.[0-9]+)?", zone = "([Zz]|[+-]([01][0-9]|2[0-3]):[0-5][0-9])?"
        if token.range(of: "^([0-9]{4}-[0-9]{2}-[0-9]{2}([Tt ]" + time + zone + ")?|" + time + ")$", options: .regularExpression) != nil {
            if token.count >= 10 && token[token.index(token.startIndex, offsetBy: 4)] == "-" {
                let pieces = token.prefix(10).split(separator: "-").compactMap { Int($0) }
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                guard pieces.count == 3, let date = calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])) else { throw fail() }
                let fields = calendar.dateComponents([.year, .month, .day], from: date)
                guard fields.year == pieces[0], fields.month == pieces[1], fields.day == pieces[2] else { throw fail() }
            }
            return ["$toml": .string(token)]
        }
        guard !token.isEmpty, !token.hasPrefix("_"), !token.hasSuffix("_"), !token.contains("__") else { throw fail() }
        for (prefix, radix) in [("0x", 16), ("0o", 8), ("0b", 2)] where normalized.hasPrefix(prefix) {
            let digits = radix == 16 ? "[0-9a-fA-F]" : radix == 8 ? "[0-7]" : "[01]"
            guard token.range(of: "^" + prefix + digits + "+(_" + digits + "+)*$", options: .regularExpression) != nil, let n = Int64(normalized.dropFirst(2), radix: radix) else { throw fail() }; return .number(Double(n))
        }
        if !normalized.contains(".") && !normalized.lowercased().contains("e") { guard Int64(normalized) != nil else { throw fail() } }
        if token.range(of: "(^_|_$|[^0-9]_+|_+[^0-9])", options: .regularExpression) != nil { throw fail() }
        guard token.range(of: "^[+-]?(0|[1-9][0-9_]*)(\\.[0-9][0-9_]*)?([eE][+-]?[0-9][0-9_]*)?$", options: .regularExpression) != nil,
              let n = Double(normalized), n.isFinite else { throw fail() }
        return .number(n)
    }
    func get(_ value: JSONValue, _ path: [String]) -> JSONValue {
        guard let first = path.first else { return value }
        if case .array(let values) = value { return get(values.last ?? [:], path) }
        return get(value[first], Array(path.dropFirst()))
    }
    func put(_ object: inout JSONValue, _ path: [String], _ value: JSONValue, replace: Bool) throws {
        guard let first = path.first else { throw fail() }
        if case .array(var values) = object {
            guard !values.isEmpty else { throw fail() }; var tail = values.removeLast(); try put(&tail, path, value, replace: replace); values.append(tail); object = .array(values); return
        }
        if object.isNull { object = [:] }; guard case .object = object else { throw fail() }
        if path.count == 1 { guard replace || object[first].isNull else { throw fail() }; object[first] = value }
        else { var child = object[first]; try put(&child, Array(path.dropFirst()), value, replace: replace); object[first] = child }
    }
}
