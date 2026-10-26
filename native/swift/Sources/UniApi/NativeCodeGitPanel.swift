import SwiftUI
import UniApiCore
import UniApiPresentation

struct NativeCodeGitPanel: View {
    let service: NativeCodeService
    let projectID: String, threadID: String
    let revision: Int
    let close: () -> Void
    @State private var selection = CodeGitSelection()
    @State private var git: JSONValue = .null
    @State private var diff = ""
    @State private var error = ""
    @State private var reads = NativePageReadScope()
    private struct Load: Hashable { let context: CodeGitContext; let revision: Int }
    private var context: CodeGitContext { CodeGitContext(project: projectID, thread: threadID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                NativeIcon("git-branch", size: 14).foregroundStyle(Theme.muted)
                Text(git.isNull ? "Reading Git status…" : git["git"].bool ? git["branch"].string : "Not a Git repository")
                    .font(Theme.ui(12.5, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .help(git["branch"].string)
                if git["git"].bool {
                    Text("\(git["files"].array.count) changed").font(Theme.ui(11)).foregroundStyle(Theme.muted).fixedSize()
                }
                T3IconButton(system: "rotate-cw", help: "Refresh Git status", size: 13) { Task { await refresh() } }
                T3IconButton(system: "x", help: "Close changes", size: 14, action: close)
            }.padding(.horizontal, 14).frame(height: 48)
            Rectangle().fill(Theme.border).frame(height: 1).accessibilityHidden(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !error.isEmpty { NativeError(message: error).padding(12) }
                    if !git["diffStat"].string.isEmpty {
                        DisclosureGroup("Diff summary") {
                            ScrollView(.horizontal) {
                                Text(git["diffStat"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: true).padding(.vertical, 6)
                            }
                        }.font(Theme.ui(11)).foregroundStyle(Theme.muted).padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    if git["git"].bool && git["files"].array.isEmpty {
                        Text("Working tree clean").font(Theme.ui(12)).foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 32)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(git["files"].array, id: \.self) { file in
                            NativeGitFileRow(file: file, selected: selection.file == file["path"].string) { Task { await open(file["path"].string) } }
                        }
                    }.padding(.horizontal, 6)
                    if selection.file != nil {
                        Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 4).accessibilityHidden(true)
                        ScrollView(.horizontal) {
                            Text(styledDiff).font(Theme.mono(11)).lineSpacing(5).textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: true).padding(8)
                        }.frame(maxWidth: .infinity, alignment: .leading).background(Theme.well)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 250, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.bg).foregroundStyle(Theme.ink)
            .nativePageTask(id: Load(context: context, revision: revision)) { await refresh() }
            .nativePageActivity(reads: reads)
    }
    private var styledDiff: AttributedString {
        var text = AttributedString()
        let lines = diff.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var span = AttributedString(line + (index < lines.count - 1 ? "\n" : ""))
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                span.foregroundColor = Theme.okFg; span.backgroundColor = Theme.ok.opacity(0.08)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                span.foregroundColor = Theme.failFg; span.backgroundColor = Theme.fail.opacity(0.08)
            } else { span.foregroundColor = line.hasPrefix("@@") ? Theme.link : Theme.dim }
            text.append(span)
        }
        return text
    }
    private func refresh() async {
        guard let ticket = reads.begin("git") else { return }
        if selection.configure(context) { git = .null; diff = ""; error = "" }
        let read = selection.begin()
        do {
            let result = try await service.handle("project.git", input: ["id": .string(read.context.project)])
            guard reads.accepts(ticket), selection.accepts(read) else { return }
            git = result; error = ""
            if let file = read.file {
                if !result["files"].array.contains(where: { $0["path"].string == file }) { selection.select(nil); diff = ""; return }
                try await loadDiff(read, file: file, ticket: ticket)
            }
        } catch { if reads.accepts(ticket), selection.accepts(read) { self.error = error.localizedDescription } }
    }
    private func open(_ file: String) async {
        guard let ticket = reads.begin("git") else { return }
        selection.configure(context); selection.select(selection.file == file ? nil : file); diff = ""; error = ""
        let read = selection.begin(); guard let file = read.file else { return }
        do { try await loadDiff(read, file: file, ticket: ticket) }
        catch { if reads.accepts(ticket), selection.accepts(read) { self.error = error.localizedDescription } }
    }
    private func loadDiff(_ read: CodeGitRead, file: String, ticket: NativePageReadScope.Ticket) async throws {
        let result = try await service.handle("project.diff", input: ["id": .string(read.context.project), "file": .string(file)])
        guard reads.accepts(ticket), selection.accepts(read) else { return }; diff = result["diff"].string
    }
}

private struct NativeGitFileRow: View {
    let file: JSONValue
    let selected: Bool
    let open: () -> Void
    @State private var hovering = false
    @Environment(\.nativeReducedMotion) private var reduceMotion
    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Text(file["status"].string.isEmpty ? "M" : file["status"].string)
                    .foregroundStyle(file["status"].string.contains("?") ? Theme.okFg : file["status"].string.contains("D") ? Theme.failFg : Theme.warnFg)
                    .frame(width: 20, alignment: .leading)
                Text(file["path"].string).foregroundStyle(Theme.dim).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(Theme.mono(11.5)).padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                .background(selected ? Theme.subtle2 : hovering ? Theme.subtle : .clear, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        }.buttonStyle(.plain).pointingHand().onHover { hovering = $0 }
            .animation(reduceMotion ? nil : NativeMotion.hover, value: hovering)
            .help(file["path"].string).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
