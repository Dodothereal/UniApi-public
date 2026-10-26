import SwiftUI
import AVKit
import UniApiCore

/// Visibility pauses playback; only destruction/replacement releases the
/// player and its owned temporary bytes. A retained window can resume at its
/// previous position without reconstructing AVPlayer during a render.
@MainActor final class NativeMediaPlayer: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error = ""
    private var key = ""
    private var temporary: URL?

    func load(url: URL) {
        guard key != url.path || player == nil else { return }
        clear(); key = url.path; player = AVPlayer(url: url)
    }
    func load(data: Data, suffix: String, key: String) {
        guard self.key != key || player == nil else { return }
        clear()
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("uniapi-arena-media-" + UUID().uuidString).appendingPathExtension(suffix)
            try NativeFile.writeAtomic(data, to: url)
            temporary = url; self.key = key; player = AVPlayer(url: url)
        } catch { self.error = error.localizedDescription }
    }
    func pause() { player?.pause() }
    private func clear() {
        player?.pause(); player = nil; error = ""; key = ""
        if let temporary { try? FileManager.default.removeItem(at: temporary) }; temporary = nil
    }
    isolated deinit {
        player?.pause()
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }
}

struct NativeFileMediaPlayer: View {
    let url: URL
    @StateObject private var media = NativeMediaPlayer()
    var body: some View {
        VideoPlayer(player: media.player)
            .nativePageTask(id: url) { media.load(url: url) }
            .nativePageActivity(suspended: { media.pause() })
    }
}
