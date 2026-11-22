import SwiftUI
import AppKit
import WebKit
import PDFKit
import AVKit
import ImageIO
import UniApiCore
import UniApiPresentation

/// WebKit renders user-authored documents only. No app UI, native message
/// handler, provider credential, persistent cookie store or filesystem grant
/// is installed in this document viewer.
struct NativeArtifactPreview: View {
    let preview: JSONValue
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private var size: String { ByteCountFormatter.string(fromByteCount: Int64(preview["size"].double), countStyle: .file) }
    var body: some View {
        BenchSheet(title: preview["fileName"].string, detail: size, width: 880, height: 660) {
            VStack(alignment: .leading, spacing: 12) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.well)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
                if let error { BenchFailure(message: error) }
            }
        } note: {
            if preview["truncated"].bool { Text("Preview is bounded. Save or open the original for the whole file.") }
        } actions: {
            Button("Save original", nativeIcon: "download") { save() }.buttonStyle(Press(.quiet))
            Button("Open", nativeIcon: "external-link") { open() }
            Button("Done") { dismiss() }.buttonStyle(Press(.primary)).keyboardShortcut(.cancelAction)
        }
    }
    @ViewBuilder private var content: some View {
        let url = URL(fileURLWithPath: preview["path"].string)
        switch preview["kind"].string {
        case "html": NativeDocumentWebPreview(url: url, mime: preview["mimeType"].string)
        case "pdf": NativePDFPreview(url: url)
        case "audio", "video": NativeFileMediaPlayer(url: url)
        case "image":
            if preview["mimeType"].string == "image/svg+xml" { NativeDocumentWebPreview(url: url, mime: "image/svg+xml") }
            else if let image = thumbnail(url) { Image(decorative: image, scale: 1).resizable().scaledToFit().padding(16) }
            else {
                Blank(icon: "file", title: "Image preview unavailable", detail: "Save or open the original with a compatible application.")
                    .padding(.horizontal, 20).frame(maxHeight: .infinity, alignment: .top)
            }
        default:
            ScrollView([.horizontal, .vertical]) {
                Text(preview["text"].string).font(Theme.mono(12)).foregroundStyle(Theme.ink).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(16)
            }
        }
    }
    private func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
    }
    private func save() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = preview["fileName"].string
        panel.nativeBegin { response in
            guard response == .OK, let url = panel.url else { return }
            do { let bytes = try NativePromptFiles.read(URL(fileURLWithPath: preview["path"].string)); try bytes.data.write(to: url, options: .atomic) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func open() {
        if preview["kind"].string == "html" || preview["mimeType"].string == "image/svg+xml" {
            NativeDocumentWindow.open(url: URL(fileURLWithPath: preview["path"].string), mime: preview["mimeType"].string, title: preview["fileName"].string)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: preview["path"].string))
    }
}

/// The sheet shape Prompts and Arena share: a name on a tick rule (optionally
/// typed in place), the content, then a note on the left and the actions on
/// the right with the one primary last.
struct BenchSheet<Content: View, Note: View, Actions: View>: View {
    var eyebrow = ""
    var title: String
    var detail = ""
    var editing: Binding<String>? = nil
    var placeholder = ""
    var titleLabel = ""
    var focusTitle = false
    var width: CGFloat
    var height: CGFloat? = nil
    @ViewBuilder var content: () -> Content
    @ViewBuilder var note: () -> Note
    @ViewBuilder var actions: () -> Actions
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !eyebrow.isEmpty { MicroLabel(eyebrow).padding(.bottom, 8) }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                if let editing {
                    TextField(placeholder, text: editing).textFieldStyle(.plain).font(Theme.display(17))
                        .foregroundStyle(Theme.ink).focused($titleFocused).accessibilityLabel(titleLabel)
                        .onAppear { if focusTitle { titleFocused = true } }
                } else {
                    Text(title).font(Theme.display(17)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                }
                if !detail.isEmpty {
                    Text(detail).font(Theme.mono(11)).foregroundStyle(Theme.muted).lineLimit(1).fixedSize()
                }
            }
            ZStack(alignment: .topLeading) {
                TickRule(span: 72)
                if editing != nil && titleFocused { Theme.signal.frame(width: 2, height: 7) }
            }.padding(.top, 12)
            content().padding(.top, 20)
                .frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity, alignment: .topLeading)
            HStack(alignment: .center, spacing: 8) {
                note().font(Theme.ui(11.5)).foregroundStyle(Theme.muted).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                actions()
            }.padding(.top, 20)
        }
        .padding(24)
        .frame(width: width, height: height)
        .background(Theme.canvas).foregroundStyle(Theme.ink).font(Theme.ui(13))
        .buttonStyle(Press(.secondary)).tint(Theme.signal)
    }
}

/// A failed command or read, said inline where it happened.
struct BenchFailure: View {
    var message: String
    var body: some View { Notice(text: message, tone: .fail).accessibilityLabel("Error: " + message) }
}

/// Engraved caption above a field inside a sheet.
struct BenchField<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            MicroLabel(label)
            content()
        }
    }
}

/// A multi-line editor on a well, with a hint where the text will go.
struct BenchEditor: View {
    @Binding var text: String
    var placeholder: String
    var label: String
    var height: CGFloat? = nil
    var body: some View {
        TextEditor(text: $text).font(Theme.ui(13)).lineSpacing(3).foregroundStyle(Theme.ink)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 11).padding(.vertical, 14)
            .frame(height: height).frame(maxHeight: height == nil ? .infinity : nil)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(Theme.ui(13)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel(label)
    }
}

@MainActor
private final class NativeDocumentWindow: NSWindowController, NSWindowDelegate {
    private static var openWindows: [String: NativeDocumentWindow] = [:]
    private let key: String
    private init(url: URL, mime: String, title: String) {
        key = url.path
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: NativeDocumentWebPreview(url: url, mime: mime))
        super.init(window: window)
        window.delegate = self; window.center()
    }
    required init?(coder: NSCoder) { fatalError("Document windows are created from managed files") }
    static func open(url: URL, mime: String, title: String) {
        let controller = openWindows[url.path] ?? NativeDocumentWindow(url: url, mime: mime, title: title)
        openWindows[url.path] = controller; controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { Self.openWindows.removeValue(forKey: key) }
}

private struct NativePDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.document = PDFDocument(url: url); return view }
    func updateNSView(_ view: PDFView, context: Context) {}
}

struct NativeDocumentWebPreview: NSViewRepresentable {
    let url: URL
    let mime: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = WKUserContentController()
        configuration.setURLSchemeHandler(DocumentHandler(url: url, mime: mime), forURLScheme: "uniapi-document")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: URL(string: "uniapi-document://preview/artifact")!))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.targetFrame?.isMainFrame != false && url.scheme != "uniapi-document" && url.scheme != "about" {
                if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel); return
            }
            decisionHandler(["http", "https", "data", "blob", "about", "uniapi-document"].contains(url.scheme ?? "") ? .allow : .cancel)
        }
    }
    private final class DocumentHandler: NSObject, WKURLSchemeHandler {
        let url: URL, mime: String
        init(url: URL, mime: String) { self.url = url; self.mime = mime }
        func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
            guard task.request.url?.host == "preview", task.request.url?.path == "/artifact" else { task.didFailWithError(NativeFailure("Document asset unavailable")); return }
            do {
                let bytes = try NativePromptFiles.read(url).data
                let response = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime + "; charset=utf-8", "Content-Security-Policy": "sandbox allow-scripts allow-forms allow-popups; base-uri 'none'; frame-src https: http: data: blob:; object-src 'none'", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"])!
                task.didReceive(response); task.didReceive(bytes); task.didFinish()
            } catch { task.didFailWithError(error) }
        }
        func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    }
}

// Arena uses the same restricted document boundary, with managed sibling
// asset reads supplied by its workspace resolver.
/// This WebKit surface renders contestant artifacts, never app UI. Its data
/// store is ephemeral and there is no message handler or native API bridge.
struct NativeArenaWebPreview: NSViewRepresentable {
    let runtime: NativeRuntime
    let slotID: String
    let path: String
    func makeCoordinator() -> NativeArenaNavigation { NativeArenaNavigation() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController = WKUserContentController()
        config.setURLSchemeHandler(NativeArenaScheme(runtime: runtime, slotID: slotID), forURLScheme: "uniapi-arena")
        let view = WKWebView(frame: .zero, configuration: config); view.navigationDelegate = context.coordinator; context.coordinator.loadedPath = path; load(view); return view
    }
    func updateNSView(_ view: WKWebView, context: Context) { if context.coordinator.loadedPath != path { context.coordinator.loadedPath = path; load(view) } }
    private func load(_ view: WKWebView) { if let url = Self.url(path) { view.load(URLRequest(url: url)) } }
    private static func url(_ path: String) -> URL? { var url = URLComponents(); url.scheme = "uniapi-arena"; url.host = "preview"; url.path = "/" + path; return url.url }
    static func dismantleNSView(_ view: WKWebView, coordinator: NativeArenaNavigation) { view.stopLoading(); view.navigationDelegate = nil }
}

struct NativeArenaURLPreview: NSViewRepresentable {
    let url: String
    func makeCoordinator() -> NativeArenaNavigation { NativeArenaNavigation() }
    func makeNSView(context: Context) -> WKWebView { let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent(); config.userContentController = WKUserContentController(); let view = WKWebView(frame: .zero, configuration: config); view.navigationDelegate = context.coordinator; let escaped = url.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;"); view.loadHTMLString("<!doctype html><meta name=referrer content=no-referrer><style>html,body,iframe{margin:0;width:100%;height:100%;border:0}</style><iframe sandbox='allow-scripts allow-forms allow-popups' src=\"\(escaped)\"></iframe>", baseURL: nil); return view }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: NativeArenaNavigation) { view.stopLoading(); view.navigationDelegate = nil }
}
final class NativeArenaNavigation: NSObject, WKNavigationDelegate {
    var loadedPath = ""
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if action.targetFrame?.isMainFrame != false && !["uniapi-arena", "about"].contains(url.scheme ?? "") {
            if action.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel); return
        }
        decisionHandler(["uniapi-arena", "about", "http", "https", "blob", "data"].contains(url.scheme ?? "") ? .allow : .cancel)
    }
}
private final class NativeArenaScheme: NSObject, WKURLSchemeHandler {
    let runtime: NativeRuntime
    let slotID: String
    init(runtime: NativeRuntime, slotID: String) { self.runtime = runtime; self.slotID = slotID }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "preview" else { task.didFailWithError(NativeFailure("Invalid artifact request")); return }
        do {
            let asset = try NativeArenaArtifacts.read(runtime: runtime, slotID: slotID, path: String(url.path.dropFirst()))
            let headers = ["Content-Type": asset.mime, "Content-Security-Policy": "sandbox allow-scripts allow-forms allow-popups; base-uri 'none'; object-src 'none'", "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Access-Control-Allow-Origin": "*"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!); task.didReceive(asset.data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
