import Foundation

public struct CodeMarkdownSpan: Equatable, Sendable {
    public var text: String
    public var strong: Bool = false, emphasis: Bool = false, code: Bool = false, strike: Bool = false
    public var link: String?, image: String?, title: String?
    public init(text: String) { self.text = text }
}
public struct CodeMarkdownNode: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case document, paragraph, heading(Int), list(ordered: Bool), item(ordinal: Int, checked: Bool?), quote, code(language: String?), rule
        case table(alignments: [Alignment]), row(header: Bool), cell(column: Int)
    }
    public enum Alignment: Equatable, Sendable { case left, center, right }
    public let id: Int
    public var kind: Kind
    public var spans: [CodeMarkdownSpan]
    public var children: [CodeMarkdownNode]
    public var plainText: String { spans.map(\.text).joined() + children.map(\.plainText).joined() }
}

/// Foundation supplies CommonMark parsing plus GFM tables, autolinks and
/// strikethrough. This tree preserves its block identities and inline runs;
/// GFM task markers are promoted only inside a list item's first paragraph.
public enum CodeMarkdown {
    public static func parse(_ text: String) throws -> CodeMarkdownNode {
        let value = try AttributedString(markdown: text, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible, appliesSourcePositionAttributes: true))
        let root = Builder(id: 0, kind: .document), source = text.components(separatedBy: "\n")
        var anonymous: Builder?, anonymousID = -1
        for run in value.runs {
            var node = root
            let intents = run.presentationIntent?.components ?? []
            if intents.isEmpty {
                if anonymous == nil { let next = Builder(id: anonymousID, kind: .paragraph); anonymousID -= 1; root.children.append(next); anonymous = next }
                node = anonymous!
            } else { anonymous = nil }
            for intent in intents.reversed() {
                if let found = node.children.first(where: { $0.id == intent.identity }) { node = found }
                else { let next = Builder(id: intent.identity, kind: kind(intent.kind)); node.children.append(next); node = next }
            }
            var span = CodeMarkdownSpan(text: String(value[run.range].characters))
            if node.spans.isEmpty, let position = run.markdownSourcePosition, source.indices.contains(position.startLine - 1) {
                let start = String(decoding: source[position.startLine - 1].utf8.dropFirst(max(0, position.startColumn - 1)), as: UTF8.self)
                node.taskMarker = start.hasPrefix("[ ] ") || start.hasPrefix("[x] ") || start.hasPrefix("[X] ")
            }
            let inline = run.inlinePresentationIntent ?? []
            span.strong = inline.contains(.stronglyEmphasized); span.emphasis = inline.contains(.emphasized); span.code = inline.contains(.code); span.strike = inline.contains(.strikethrough)
            span.link = run.link.flatMap { safeURL($0.relativeString) }
            span.image = run.imageURL.flatMap { safeURL($0.relativeString) }; span.title = run.alternateDescription
            if span.image != nil && span.text == "\u{fffc}" { span.text = "" }
            node.spans.append(span)
        }
        return finish(root)
    }
    public static func safeURL(_ text: String) -> String? {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), let url = URL(string: text) else { return nil }
        guard let scheme = url.scheme else { return text }
        return ["http", "https", "mailto", "irc", "ircs", "xmpp"].contains(scheme.lowercased()) ? text : nil
    }
    public static func relativeAsset(_ link: String, document: String) -> String? {
        guard safeURL(link) != nil, let url = URL(string: link), url.scheme == nil, url.host == nil,
              let base = URL(string: "https://markdown.invalid/")?.appendingPathComponent(document), let resolved = URL(string: link, relativeTo: base)?.absoluteURL,
              resolved.host == "markdown.invalid" else { return nil }
        return String(resolved.path.dropFirst())
    }
    private final class Builder { let id: Int; var kind: CodeMarkdownNode.Kind; var taskMarker = false; var spans: [CodeMarkdownSpan] = [], children: [Builder] = []; init(id: Int, kind: CodeMarkdownNode.Kind) { self.id = id; self.kind = kind } }
    private static func kind(_ kind: PresentationIntent.Kind) -> CodeMarkdownNode.Kind {
        switch kind {
        case .paragraph: return .paragraph
        case .header(let level): return .heading(level)
        case .orderedList: return .list(ordered: true)
        case .unorderedList: return .list(ordered: false)
        case .listItem(let ordinal): return .item(ordinal: ordinal, checked: nil)
        case .blockQuote: return .quote
        case .codeBlock(let hint): return .code(language: hint)
        case .thematicBreak: return .rule
        case .table(let columns): return .table(alignments: columns.map { switch $0.alignment { case .left: return .left; case .center: return .center; case .right: return .right; @unknown default: return .left } })
        case .tableHeaderRow: return .row(header: true)
        case .tableRow: return .row(header: false)
        case .tableCell(let column): return .cell(column: column)
        @unknown default: return .paragraph
        }
    }
    private static func finish(_ builder: Builder) -> CodeMarkdownNode {
        var node = CodeMarkdownNode(id: builder.id, kind: builder.kind, spans: builder.spans, children: builder.children.map(finish))
        if case .item(let ordinal, _) = node.kind, let first = node.children.first, case .paragraph = first.kind, builder.children.first?.taskMarker == true {
            let text = first.spans.map(\.text).joined()
            if text.hasPrefix("[ ] ") || text.hasPrefix("[x] ") || text.hasPrefix("[X] ") {
                node.kind = .item(ordinal: ordinal, checked: !text.hasPrefix("[ ] "))
                var remaining = 4
                for i in node.children[0].spans.indices { let n = min(remaining, node.children[0].spans[i].text.count); node.children[0].spans[i].text = String(node.children[0].spans[i].text.dropFirst(n)); remaining -= n; if remaining == 0 { break } }
            }
        }
        if case .table(let alignments) = node.kind {
            for i in node.children.indices {
                var cells = node.children[i].children
                for column in alignments.indices where !cells.contains(where: { if case .cell(let c) = $0.kind { return c == column }; return false }) { cells.append(CodeMarkdownNode(id: -(node.children[i].id * 1000 + column + 1), kind: .cell(column: column), spans: [], children: [])) }
                node.children[i].children = cells.sorted { a, b in if case .cell(let x) = a.kind, case .cell(let y) = b.kind { return x < y }; return false }
            }
        }
        return node
    }
}
