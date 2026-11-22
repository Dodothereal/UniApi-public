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
    private var isRepository: Bool { git["git"].bool }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    MicroLabel(isRepository ? "Branch" : "Changes")
                    Text(git.isNull ? "Reading Git status" : isRepository ? git["branch"].string : "Not a Git repository")
                        .font(Theme.mono(12)).foregroundStyle(git.isNull ? Theme.muted : Theme.ink).lineLimit(1).truncationMode(.middle)
                        .help(git["branch"].string)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isRepository {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        NativeNumberText(text: String(git["files"].array.count), font: Theme.readout(17), color: Theme.ink)
                        MicroLabel("changed")
                    }
                    .fixedSize().padding(.trailing, 8)
                    .accessibilityElement(children: .ignore).accessibilityLabel("\(git["files"].array.count) changed")
                }
                IconPress(icon: "rotate-cw", help: "Refresh Git status", size: 13) { Task { await refresh() } }
                IconPress(icon: "x", help: "Close changes", size: 14, action: close)
            }
            .padding(.leading, 16).padding(.trailing, 10).frame(height: NativeCodeMetrics.head)
            Rule().accessibilityHidden(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !error.isEmpty { Notice(text: error, tone: .fail).accessibilityLabel("Error: " + error).padding(.vertical, 12) }
                    if isRepository && git["files"].array.isEmpty {
                        Blank(icon: "git-branch", title: "Working tree clean", detail: "Files the agent or you change will be listed here.")
                    } else if !git.isNull && !isRepository {
                        Blank(icon: "git-branch", title: "Not a Git repository", detail: "Changes are listed for projects under Git.")
                    }
                    if !git["files"].array.isEmpty {
                        LedgerHead {
                            MicroLabel("St").frame(width: 22, alignment: .leading)
                            MicroLabel("File")
                        }
                        .padding(.top, 6)
                    }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(git["files"].array, id: \.self) { file in
                            let selected = selection.file == file["path"].string
                            NativeGitFileRow(file: file, selected: selected) { Task { await open(file["path"].string) } }
                            // The diff grows from the row that opened it.
                            if selected {
                                ScrollView(.horizontal) {
                                    Text(styledDiff).font(Theme.mono(11)).lineSpacing(5).textSelection(.enabled)
                                        .fixedSize(horizontal: true, vertical: true).padding(10)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
                                .padding(.vertical, 8)
                            }
                        }
                    }
                    if !git["diffStat"].string.isEmpty {
                        NativeCodeFold("Diff summary") {
                            ScrollView(.horizontal) {
                                Text(git["diffStat"].string).font(Theme.mono(10.5)).foregroundStyle(Theme.muted).textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: true).padding(.bottom, 6)
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 250, idealWidth: 380, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.canvas).foregroundStyle(Theme.ink)
        .nativePageTask(id: Load(context: context, revision: revision)) { await refresh() }
        .nativePageActivity(reads: reads)
    }
    private var styledDiff: AttributedString {
        var text = AttributedString()
        let lines = diff.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var span = AttributedString(line + (index < lines.count - 1 ? "\n" : ""))
            if line.hasPrefix("+") && !line.hasPrefix("+++") {
                span.foregroundColor = Theme.okFg; span.backgroundColor = Theme.surfaceFor(Theme.ok)
            } else if line.hasPrefix("-") && !line.hasPrefix("---") {
                span.foregroundColor = Theme.failFg; span.backgroundColor = Theme.surfaceFor(Theme.fail)
            } else { span.foregroundColor = line.hasPrefix("@@") ? Theme.muted : Theme.dim }
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
    private var status: String { file["status"].string.isEmpty ? "M" : file["status"].string }
    var body: some View {
        LedgerRow(selected: selected, minHeight: 30, action: open) {
            HStack(spacing: 12) {
                Text(status)
                    .foregroundStyle(status.contains("?") ? Theme.okFg : status.contains("D") ? Theme.failFg : Theme.warnFg)
                    .frame(width: 22, alignment: .leading)
                Text(file["path"].string).foregroundStyle(selected ? Theme.ink : Theme.dim).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Theme.mono(11.5))
        }
        .help(file["path"].string)
    }
}
