import SwiftUI
import AppKit
import ImageIO
import UniApiCore
import UniApiPresentation

enum NativeMarkdownImages {
    static func remote(_ address: String) async throws -> NativeMarkdownAsset {
        let absolute = address.hasPrefix("//") ? "https:" + address : address
        guard CodeMarkdown.safeURL(absolute) != nil, let url = URL(string: absolute), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw NativeFailure("Image URL unavailable") }
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), response.expectedContentLength <= 25 * 1024 * 1024 else { throw NativeFailure("Image response unavailable or too large") }
        let mime = response.mimeType?.lowercased() ?? "application/octet-stream"
        guard mime.hasPrefix("image/") else { throw NativeFailure("Image response has an unsupported content type") }
        var data = Data()
        for try await byte in stream { guard data.count < 25 * 1024 * 1024 else { throw NativeFailure("Image exceeds 25 MiB") }; data.append(byte) }
        return NativeMarkdownAsset(data: data, mime: mime)
    }
}
@MainActor private final class NativeMarkdownImageState: ObservableObject {
    @Published var raster: NSImage?
    @Published var svg: URL?
    @Published var error = ""
    let reads = NativePageReadScope()
    private var loadedAddress: String?
    func load(address: String, resolver: ((String) async throws -> NativeMarkdownAsset)?) async {
        guard loadedAddress != address || raster == nil && svg == nil else { return }
        guard let ticket = reads.begin() else { return }
        clear(); error = ""
        do {
            let asset: NativeMarkdownAsset
            if let resolver { asset = try await resolver(address) } else { asset = try await NativeMarkdownImages.remote(address) }
            guard reads.accepts(ticket) else { return }
            if asset.mime == "image/svg+xml" {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("uniapi-markdown-" + UUID().uuidString + ".svg")
                try NativeFile.writeAtomic(asset.data, to: url); svg = url
            } else {
                guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw NativeFailure("Image could not be decoded") }
                raster = NSImage(cgImage: thumbnail, size: .zero)
            }
            loadedAddress = address
        } catch { if reads.accepts(ticket) { self.error = error.localizedDescription } }
    }
    private func clear() { raster = nil; if let svg { try? FileManager.default.removeItem(at: svg) }; svg = nil; loadedAddress = nil }
    isolated deinit { if let svg { try? FileManager.default.removeItem(at: svg) } }
}

struct NativeMarkdownImage: View {
    let span: CodeMarkdownSpan
    let resolver: NativeMarkdownImageResolver?
    @StateObject private var image = NativeMarkdownImageState()
    init(span: CodeMarkdownSpan, resolver: NativeMarkdownImageResolver?) { self.span = span; self.resolver = resolver }
    var body: some View { Group {
        if let raster = image.raster { Image(nsImage: raster).resizable().scaledToFit().frame(maxHeight: 480).accessibilityLabel(span.text.isEmpty ? "Image" : span.text) }
        else if let svg = image.svg { NativeDocumentWebPreview(url: svg, mime: "image/svg+xml").id(svg).frame(height: 350).accessibilityLabel(span.text.isEmpty ? "Image" : span.text) }
        else { VStack(alignment: .leading, spacing: 4) { Text(span.text.isEmpty ? "Image" : span.text).font(Theme.ui(12)); if !image.error.isEmpty { Text(image.error).font(Theme.ui(11)).foregroundStyle(Theme.muted) } else { ShimmerText(text: "Loading image") } } }
    }.help(span.title ?? span.text)
        .nativePageTask(id: span.image) { await image.load(address: span.image ?? "", resolver: resolver) }
        .nativePageActivity(reads: image.reads)
    }
}
