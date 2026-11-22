import SwiftUI
import AppKit
import UniApiCore

struct NativeMarkdownAsset: Sendable { let data: Data; let mime: String }
typealias NativeMarkdownImageResolver = @Sendable (String) async throws -> NativeMarkdownAsset

/// Shared native GFM renderer. HTML is never evaluated by this view. Only a
/// separately isolated document viewer may render an untrusted SVG image.
struct NativeMarkdown: View {
    let text: String
    var imageResolver: NativeMarkdownImageResolver? = nil
    var openLink: ((String) -> Void)? = nil
    @State private var tree: CodeMarkdownNode?
    @State private var parsedText: String?
    init(text: String, imageResolver: NativeMarkdownImageResolver? = nil, openLink: ((String) -> Void)? = nil) {
        self.text = text; self.imageResolver = imageResolver; self.openLink = openLink
    }
    var body: some View {
        Group { if let tree { NativeMarkdownNode(node: tree, imageResolver: imageResolver, openLink: openLink) } else { Text(text).textSelection(.enabled) } }
            .font(Theme.ui(13)).lineSpacing(5).foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .nativePageTask(id: text) {
                guard parsedText != text else { return }
                let source = text
                let parsed = await Task.detached(priority: .utility) { try? CodeMarkdown.parse(source) }.value
                guard !Task.isCancelled else { return }; tree = parsed; parsedText = source
            }
    }
}

private struct NativeMarkdownNode: View {
    let node: CodeMarkdownNode
    let imageResolver: NativeMarkdownImageResolver?
    let openLink: ((String) -> Void)?
    var ordered = false
    init(node: CodeMarkdownNode, imageResolver: NativeMarkdownImageResolver?, openLink: ((String) -> Void)?, ordered: Bool = false) {
        self.node = node; self.imageResolver = imageResolver; self.openLink = openLink; self.ordered = ordered
    }
    var body: some View { rendered }
    @ViewBuilder private var rendered: some View {
        switch node.kind {
        case .document: contents
        case .paragraph, .cell: NativeMarkdownInline(spans: node.spans, imageResolver: imageResolver, openLink: openLink)
        // Headings speak in the expanded voice: a title, a section name, then
        // plain semibold body for anything deeper.
        case .heading(let level): NativeMarkdownInline(spans: node.spans, imageResolver: imageResolver, openLink: openLink)
            .font(level == 1 ? Theme.display(17) : level == 2 ? Theme.heading() : Theme.ui(13, weight: .semibold))
            .lineSpacing(2).padding(.top, level <= 2 ? 8 : 4).accessibilityAddTraits(.isHeader)
        case .list(let ordered): VStack(alignment: .leading, spacing: 5) { ForEach(node.children) { child in NativeMarkdownNode(node: child, imageResolver: imageResolver, openLink: openLink, ordered: ordered) } }
        case .item(let ordinal, let checked): HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let checked { NativeIcon(checked ? "square-check" : "square", size: 13, strokeWidth: 1.75).foregroundStyle(checked ? Theme.ink : Theme.muted).offset(y: 2).accessibilityLabel(checked ? "Completed task" : "Incomplete task") }
            else { Text(ordered ? "\(ordinal)." : "–").font(ordered ? Theme.mono(11) : Theme.ui(13)).foregroundStyle(Theme.muted).frame(minWidth: 16, alignment: .trailing).accessibilityHidden(true) }
            contents
        }.padding(.leading, 4)
        case .quote: HStack(alignment: .top, spacing: 12) { Theme.ruleStrong.frame(width: 2); contents.foregroundStyle(Theme.dim) }.fixedSize(horizontal: false, vertical: true)
        case .code(let language): NativeMarkdownCode(text: node.plainText, language: language)
        case .rule: Rule().padding(.vertical, 6)
        case .table(let alignments): NativeMarkdownTable(node: node, alignments: alignments, imageResolver: imageResolver, openLink: openLink)
        case .row: contents
        }
    }
    private var contents: some View { VStack(alignment: .leading, spacing: 10) { if !node.spans.isEmpty { NativeMarkdownInline(spans: node.spans, imageResolver: imageResolver, openLink: openLink) }; ForEach(node.children) { child in NativeMarkdownNode(node: child, imageResolver: imageResolver, openLink: openLink) } } }
}

private struct NativeMarkdownTable: View {
    let node: CodeMarkdownNode
    let alignments: [CodeMarkdownNode.Alignment]
    let imageResolver: NativeMarkdownImageResolver?
    let openLink: ((String) -> Void)?
    init(node: CodeMarkdownNode, alignments: [CodeMarkdownNode.Alignment], imageResolver: NativeMarkdownImageResolver?, openLink: ((String) -> Void)?) {
        self.node = node; self.alignments = alignments; self.imageResolver = imageResolver; self.openLink = openLink
    }
    // A ledger: engraved heads over a strong rule, hairlines between rows, no
    // outline and no cell fills. Every column starts on the content edge.
    var body: some View { ScrollView(.horizontal) { Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(node.children) { row in GridRow { ForEach(row.children) { cell in
            NativeMarkdownInline(spans: cell.spans, imageResolver: imageResolver, openLink: openLink)
                .font(isHeader(row) ? Theme.ui(11.5, weight: .semibold) : Theme.ui(12.5)).lineSpacing(2)
                .foregroundStyle(isHeader(row) ? Theme.dim : Theme.ink)
                .frame(minWidth: 84, maxWidth: 350, alignment: alignment(cell))
                .padding(.trailing, 24).padding(.vertical, 7)
                .overlay(alignment: .bottom) { Rule(strong: isHeader(row)) }
                .gridColumnAlignment(horizontal(cell))
        } } }
    }.padding(.bottom, 1) }.accessibilityLabel("Table") }
    private func isHeader(_ row: CodeMarkdownNode) -> Bool { if case .row(let header) = row.kind { return header }; return false }
    private func column(_ node: CodeMarkdownNode) -> CodeMarkdownNode.Alignment { if case .cell(let i) = node.kind, alignments.indices.contains(i) { return alignments[i] }; return .left }
    private func alignment(_ node: CodeMarkdownNode) -> Alignment { switch column(node) { case .left: return .leading; case .center: return .center; case .right: return .trailing } }
    private func horizontal(_ node: CodeMarkdownNode) -> HorizontalAlignment { switch column(node) { case .left: return .leading; case .center: return .center; case .right: return .trailing } }
}

private struct NativeMarkdownInline: View {
    let spans: [CodeMarkdownSpan]
    let imageResolver: NativeMarkdownImageResolver?
    let openLink: ((String) -> Void)?
    init(spans: [CodeMarkdownSpan], imageResolver: NativeMarkdownImageResolver?, openLink: ((String) -> Void)?) {
        self.spans = spans; self.imageResolver = imageResolver; self.openLink = openLink
    }
    private struct Piece: Identifiable { let id: Int; var text: [CodeMarkdownSpan]; var image: CodeMarkdownSpan? }
    private var pieces: [Piece] {
        var out: [Piece] = [], text: [CodeMarkdownSpan] = []
        for span in spans {
            if span.image != nil { if !text.isEmpty { out.append(Piece(id: out.count, text: text)); text = [] }; out.append(Piece(id: out.count, text: [], image: span)) }
            else { text.append(span) }
        }
        if !text.isEmpty { out.append(Piece(id: out.count, text: text)) }; return out
    }
    var body: some View { VStack(alignment: .leading, spacing: 8) { ForEach(pieces) { piece in
        if let image = piece.image { NativeMarkdownImage(span: image, resolver: imageResolver) }
        else { Text(attributed(piece.text)).textSelection(.enabled).tint(Theme.link).environment(\.openURL, OpenURLAction { url in
            guard CodeMarkdown.safeURL(url.relativeString) != nil else { return .discarded }
            if let openLink { openLink(url.relativeString); return .handled }
            return url.scheme == nil ? .discarded : .systemAction
        }) }
    } } }
    private func attributed(_ spans: [CodeMarkdownSpan]) -> AttributedString {
        var result = AttributedString()
        for span in spans {
            var value = AttributedString(span.text), inline: InlinePresentationIntent = []
            if span.strong { inline.insert(.stronglyEmphasized) }; if span.emphasis { inline.insert(.emphasized) }; if span.strike { inline.insert(.strikethrough) }; if span.code { inline.insert(.code); value.font = Theme.mono(12); value.backgroundColor = Theme.hover }
            value.inlinePresentationIntent = inline
            if let link = span.link, let url = URL(string: link) { value.link = url; value.foregroundColor = Theme.link }
            result.append(value)
        }
        return result
    }
}

private struct NativeMarkdownCode: View {
    let text: String
    let language: String?
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MicroLabel(language ?? "Code")
                Spacer(minLength: 0)
                Button { NSPasteboard.general.clearContents(); copied = NSPasteboard.general.setString(text, forType: .string) } label: {
                    HStack(spacing: 5) {
                        NativeIcon(copied ? "check" : "copy", size: 11, strokeWidth: 1.75)
                        Text(copied ? "Copied" : "Copy")
                    }
                }
                .buttonStyle(Press(.quiet, height: 22)).accessibilityLabel("Copy code")
            }
            ScrollView(.horizontal) {
                Text(text).font(Theme.mono(12)).lineSpacing(3).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.top, 8).padding(.bottom, 12)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
    }
}
