import SwiftUI
import AppKit
import PDFKit
import AVKit
import UniApiCore
import UniApiPresentation

struct NativeArenaArtifactPreview: View {
    let runtime: NativeRuntime
    let slotID: String
    let path: String
    @Environment(\.dismiss) private var dismiss
    @State private var error = ""
    var body: some View { VStack(alignment: .leading, spacing: 12) { HStack { Text(path).font(Theme.mono(13)); Spacer(); Button("Done") { dismiss() } }; NativeArenaFileView(runtime: runtime, slotID: slotID, path: path).frame(maxWidth: .infinity, maxHeight: .infinity); if !error.isEmpty { NativeError(message: error) }; HStack { Spacer(); Button("Save original") { let panel = NSSavePanel(); panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent; panel.nativeBegin { response in if response == .OK, let url = panel.url { do { try NativeArenaArtifacts.read(runtime: runtime, slotID: slotID, path: path).data.write(to: url, options: .atomic) } catch { self.error = error.localizedDescription } } } } } }.padding(20).frame(width: 950, height: 700).background(Theme.bg) }
}

struct NativeArenaFileView: View {
    let runtime: NativeRuntime
    let slotID: String
    let path: String
    @State private var asset: NativeArenaAsset?
    @State private var assetKey = ""
    @State private var error = ""
    @State private var linked: String?
    var body: some View { Group {
        if let asset, assetKey == slotID + ":" + path {
            if ["text/html", "application/xhtml+xml", "image/svg+xml"].contains(asset.mime) { NativeArenaWebPreview(runtime: runtime, slotID: slotID, path: path) }
            else if asset.mime.hasPrefix("image/"), let image = NSImage(data: asset.data) { Image(nsImage: image).resizable().scaledToFit() }
            else if asset.mime == "application/pdf" { NativeArenaPDF(data: asset.data) }
            else if asset.mime.hasPrefix("audio/") || asset.mime.hasPrefix("video/") { NativeArenaMedia(data: asset.data, suffix: URL(fileURLWithPath: path).pathExtension, key: slotID + ":" + path) }
            else { ScrollView([.horizontal, .vertical]) { if asset.mime == "text/markdown" { NativeMarkdown(text: String(decoding: asset.data.prefix(256 * 1024), as: UTF8.self), imageResolver: { address in
                if let relative = CodeMarkdown.relativeAsset(address, document: path) { let value = try NativeArenaArtifacts.read(runtime: runtime, slotID: slotID, path: relative); return NativeMarkdownAsset(data: value.data, mime: value.mime) }
                return try await NativeMarkdownImages.remote(address)
            }, openLink: { address in if let relative = CodeMarkdown.relativeAsset(address, document: path) { linked = relative } else if let url = URL(string: address), CodeMarkdown.safeURL(address) != nil { NSWorkspace.shared.open(url) } }) } else { Text(String(decoding: asset.data.prefix(256 * 1024), as: UTF8.self)).font(Theme.mono(11)).textSelection(.enabled) }; if asset.data.count > 256 * 1024 { Text("Text preview truncated; save the original for the full file.").font(Theme.ui(10)).foregroundStyle(Theme.muted) } } }
        } else if !error.isEmpty { NativeError(message: error) } else { ProgressView() }
    }.nativePageTask(id: slotID + ":" + path) { do { asset = try NativeArenaArtifacts.read(runtime: runtime, slotID: slotID, path: path); assetKey = slotID + ":" + path; error = "" } catch { asset = nil; self.error = error.localizedDescription } }.sheet(isPresented: Binding(get: { linked != nil }, set: { if !$0 { linked = nil } })) { if let linked { NativeArenaArtifactPreview(runtime: runtime, slotID: slotID, path: linked) } } }
}
private struct NativeArenaMedia: View {
    let data: Data
    let suffix: String
    let key: String
    @StateObject private var media = NativeMediaPlayer()
    var body: some View {
        Group {
            if let player = media.player { VideoPlayer(player: player) }
            else if !media.error.isEmpty { NativeError(message: media.error) }
            else { ShimmerText(text: "Loading media") }
        }
        .nativePageTask(id: key) { media.load(data: data, suffix: suffix, key: key) }
        .nativePageActivity(suspended: { media.pause() })
    }
}
private struct NativeArenaPDF: NSViewRepresentable { let data: Data; func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(data: data); return view }; func updateNSView(_ view: PDFView, context: Context) { view.document = PDFDocument(data: data) } }
