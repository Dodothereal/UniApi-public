import SwiftUI
import AVKit
import UniApiCore

/// Visibility pauses playback; only destruction/replacement releases the
/// player and its owned temporary bytes. A retained window can resume at its
/// previous position without reconstructing AVPlayer during a render.
@MainActor final class NativeMediaPlayer: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var error = ""
    /// Whether the loaded media carries a picture; audio needs only a transport.
    @Published private(set) var hasVideo = false
    private var key = ""
    private var temporary: URL?

    func load(url: URL) {
        guard key != url.path || player == nil else { return }
        clear(); key = url.path; player = AVPlayer(url: url)
        inspect(url.path)
    }
    func load(data: Data, suffix: String, key: String) {
        guard self.key != key || player == nil else { return }
        clear()
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("uniapi-arena-media-" + UUID().uuidString).appendingPathExtension(suffix)
            try NativeFile.writeAtomic(data, to: url)
            temporary = url; self.key = key; player = AVPlayer(url: url)
            inspect(key)
        } catch { self.error = error.localizedDescription }
    }
    func pause() { player?.pause() }
    private func inspect(_ loaded: String) {
        guard let asset = player?.currentItem?.asset else { return }
        Task { [weak self] in
            let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            guard let self, self.key == loaded else { return }
            self.hasVideo = !tracks.isEmpty
        }
    }
    private func clear() {
        player?.pause(); player = nil; error = ""; key = ""; hasVideo = false
        if let temporary { try? FileManager.default.removeItem(at: temporary) }; temporary = nil
    }
    isolated deinit {
        player?.pause()
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }
}

/// Position, length and state of one player. AVPlayer reports time only while
/// it advances, so nothing ticks while playback is paused.
@MainActor final class NativeMediaClock: ObservableObject {
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playing = false
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?

    func attach(_ next: AVPlayer) {
        guard player !== next else { return }
        detach()
        player = next
        let current: Double = next.currentTime().seconds
        time = current.isFinite ? max(0, current) : 0
        playing = next.rate != 0
        timeObserver = next.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] time in
            let seconds: Double = time.seconds
            MainActor.assumeIsolated { if seconds.isFinite { self?.time = max(0, seconds) } }
        }
        rateObserver = next.observe(\.rate, options: [.new]) { [weak self] player, _ in
            let rate: Float = player.rate
            Task { @MainActor in self?.playing = rate != 0 }
        }
        guard let asset = next.currentItem?.asset else { return }
        Task { [weak self] in
            let seconds: Double = (try? await asset.load(.duration))?.seconds ?? 0
            guard let self, self.player === next else { return }
            self.duration = seconds.isFinite ? max(0, seconds) : 0
        }
    }
    func detach() {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil; rateObserver = nil; player = nil
        time = 0; duration = 0; playing = false
    }
    func toggle() {
        guard let player else { return }
        if player.rate != 0 { player.pause(); return }
        if duration > 0, time >= duration - 0.05 { player.seek(to: .zero); time = 0 }
        player.play()
    }
    /// A drag seeks loosely so the picture and sound keep up; letting go lands exactly.
    func seek(_ fraction: Double, precise: Bool) {
        guard let player, duration > 0 else { return }
        let target: Double = duration * min(1, max(0, fraction))
        time = target
        let tolerance = precise ? CMTime.zero : CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }
    func step(_ seconds: Double) {
        guard duration > 0 else { return }
        seek((time + seconds) / duration, precise: true)
    }
    isolated deinit {
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
    }
}

/// A thin ruled transport: play or pause, the position, a tick-scale scrubber
/// with the signal needle at the playhead, and the length.
struct NativeMediaTransport: View {
    let player: AVPlayer
    var ruled = true
    @StateObject private var clock = NativeMediaClock()

    static func stamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let whole = Int(seconds.rounded(.down))
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
            : String(format: "%02d:%02d", whole / 60, whole % 60)
    }
    var body: some View {
        HStack(spacing: 12) {
            // The glyph, not its 28-point hit area, stands on the content edge.
            IconPress(icon: clock.playing ? "pause" : "play", help: clock.playing ? "Pause" : "Play") { clock.toggle() }
                .padding(.leading, -7)
            Text(Self.stamp(clock.time)).font(Theme.mono(11)).foregroundStyle(Theme.ink)
                .monospacedDigit().lineLimit(1).fixedSize()
            NativeMediaScrubber(clock: clock)
            Text(clock.duration > 0 ? Self.stamp(clock.duration) : "--:--").font(Theme.mono(11)).foregroundStyle(Theme.muted)
                .monospacedDigit().lineLimit(1).fixedSize()
        }
        .frame(height: 40)
        .overlay(alignment: .top) { if ruled { Rule() } }
        .overlay(alignment: .bottom) { if ruled { Rule() } }
        .onAppear { clock.attach(player) }
        .onChange(of: ObjectIdentifier(player)) { _, _ in clock.attach(player) }
        .onDisappear { clock.detach() }
    }
}

/// The scrubber is a ruler. Played ticks are inked, the rest stay faint and
/// the signal needle marks now. Click or drag anywhere on it to seek.
private struct NativeMediaScrubber: View {
    @ObservedObject var clock: NativeMediaClock
    @State private var scrub: Double?
    @Environment(\.nativeReducedMotion) private var reduceMotion
    @Environment(\.nativeMotionVisible) private var visible
    private var ticks: TickScale { TickScale(step: 6, major: 5, minorHeight: 4, majorHeight: 8) }
    private var fraction: Double {
        if let scrub { return scrub }
        return clock.duration > 0 ? min(1, max(0, clock.time / clock.duration)) : 0
    }
    var body: some View {
        GeometryReader { geometry in
            let width: CGFloat = geometry.size.width
            let head: CGFloat = width * CGFloat(fraction)
            // The needle follows playback between quarter-second reports; a drag is immediate.
            let follows: Bool = clock.playing && scrub == nil && !reduceMotion && visible
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Theme.track).frame(height: 2)
                ticks.fill(Theme.faint).padding(.top, 3)
                Rectangle().fill(Theme.ink).frame(width: head, height: 2)
                ticks.fill(Theme.ink).padding(.top, 3)
                    .mask(alignment: .leading) { Rectangle().frame(width: head) }
                Theme.signal.frame(width: 2, height: 16).offset(x: min(max(0, head - 1), max(0, width - 2)))
            }
            .frame(height: 16)
            .frame(maxHeight: .infinity)
            .animation(follows ? .linear(duration: 0.25) : nil, value: head)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let next: Double = min(1, max(0, Double(value.location.x / max(1, width))))
                    scrub = next; clock.seek(next, precise: false)
                }
                .onEnded { value in
                    clock.seek(min(1, max(0, Double(value.location.x / max(1, width)))), precise: true)
                    scrub = nil
                })
        }
        .frame(height: 28)
        .opacity(clock.duration > 0 ? 1 : 0.5)
        .allowsHitTesting(clock.duration > 0)
        .pointingHand(clock.duration > 0)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(NativeMediaTransport.stamp(clock.time) + " of " + NativeMediaTransport.stamp(clock.duration))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: clock.step(10)
            case .decrement: clock.step(-10)
            @unknown default: break
            }
        }
    }
}

/// The picture of a video without AVKit's floating controls; the transport
/// beneath it is the only control surface.
private struct NativeMediaPicture: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct NativeFileMediaPlayer: View {
    let url: URL
    @StateObject private var media = NativeMediaPlayer()
    var body: some View {
        VStack(spacing: 12) {
            if let player = media.player {
                if media.hasVideo {
                    NativeMediaPicture(player: player)
                        .background(Theme.well)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusWell, style: .continuous))
                        .accessibilityLabel("Video")
                } else { Spacer(minLength: 0) }
                NativeMediaTransport(player: player)
                if !media.hasVideo { Spacer(minLength: 0) }
            } else if !media.error.isEmpty {
                Notice(text: media.error, tone: .fail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .nativePageTask(id: url) { media.load(url: url) }
        .nativePageActivity(suspended: { media.pause() })
    }
}
