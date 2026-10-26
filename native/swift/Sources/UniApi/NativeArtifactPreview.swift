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
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(preview["fileName"].string).font(Theme.ui(16, weight: .semibold)).lineLimit(1)
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if preview["truncated"].bool { Text("This text or byte preview is bounded; save or open the original for the whole file.").font(Theme.ui(11)).foregroundStyle(Theme.muted) }
            if let error { NativeError(message: error) }
            HStack {
                Text(ByteCountFormatter.string(fromByteCount: Int64(preview["size"].double), countStyle: .file)).font(Theme.mono(11)).foregroundStyle(Theme.muted)
                Spacer()
                Button("Save original") { save() }
                Button("Open") { open() }
            }
        }.padding(20).frame(width: 850, height: 640).background(Theme.bg).foregroundStyle(Theme.ink)
    }
    @ViewBuilder private var content: some View {
        let url = URL(fileURLWithPath: preview["path"].string)
        switch preview["kind"].string {
        case "html": NativeDocumentWebPreview(url: url, mime: preview["mimeType"].string)
        case "pdf": NativePDFPreview(url: url).background(Color.white)
        case "audio", "video": NativeFileMediaPlayer(url: url)
        case "image":
            if preview["mimeType"].string == "image/svg+xml" { NativeDocumentWebPreview(url: url, mime: "image/svg+xml") }
            else if let image = thumbnail(url) { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { NativeEmptyState(title: "Image preview unavailable", detail: "Save or open the original with a compatible application.") }
        default:
            ScrollView([.horizontal, .vertical]) {
                Text(preview["text"].string).font(Theme.mono(12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
            }.background(Theme.surface)
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
