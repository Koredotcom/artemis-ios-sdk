import AVKit
import SwiftUI

private final class MediaTimeObservation {
    let player: AVPlayer
    let token: Any
    init(player: AVPlayer, token: Any) {
        self.player = player
        self.token = token
    }
    deinit { player.removeTimeObserver(token) }
}

@MainActor final class ChatMediaPlayer: ObservableObject {
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playing = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var failed = false
    private var timeObservation: MediaTimeObservation?
    private var statusObserver: NSKeyValueObservation?
    private var playbackObserver: NSKeyValueObservation?
    private var source: URL?

    static func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.isHTTP else { return nil }
        return url
    }
    func load(_ value: String) {
        dispose()
        guard let url = Self.safeURL(value) else {
            failed = true
            return
        }
        source = url
        failed = false
        elapsed = 0
        duration = 0
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        self.player = player
        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player?.currentItem === item else { return }
                self.failed = item.status == .failed
                self.updateDuration(item)
            }
        }
        playbackObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
            [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.player === observed else { return }
                self.playing = observed.timeControlStatus != .paused
            }
        }
        let token = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) {
            [weak self, weak player] time in
            Task { @MainActor in
                guard let self, let player, self.player === player else { return }
                self.elapsed = time.seconds.isFinite ? max(0, time.seconds) : 0
                if let item = player.currentItem { self.updateDuration(item) }
            }
        }
        timeObservation = MediaTimeObservation(player: player, token: token)
    }
    func toggle() {
        guard !failed, let player else { return }
        if playing {
            player.pause()
            playing = false
        } else {
            if duration > 0, elapsed >= duration - 0.1 { player.seek(to: .zero) }
            player.play()
            playing = true
        }
    }
    func seek(_ seconds: Double) {
        guard duration > 0, seconds.isFinite else { return }
        player?.seek(to: CMTime(seconds: min(duration, max(0, seconds)), preferredTimescale: 600))
    }
    func pause() {
        player?.pause()
        playing = false
    }
    func dispose() {
        player?.pause()
        timeObservation = nil
        statusObserver = nil
        playbackObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        playing = false
    }
    private func updateDuration(_ item: AVPlayerItem) {
        let value = item.duration.seconds
        duration = value.isFinite ? max(0, value) : 0
    }
}

#if os(iOS)
    private struct NativeVideoControls: UIViewControllerRepresentable {
        let player: AVPlayer
        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let controller = AVPlayerViewController()
            controller.player = player
            controller.showsPlaybackControls = true
            return controller
        }
        func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
            controller.player = player
        }
        static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
            controller.player = nil
        }
    }
#endif

struct InlineVideoPlayer: View {
    let media: MediaContent
    @StateObject private var model = ChatMediaPlayer()
    @State private var fullscreen = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatStrings) private var strings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.failed {
                Text(strings("Unable to play this media.")).font(.caption)
                if ChatMediaPlayer.safeURL(media.url) != nil {
                    Button(strings("Retry")) { model.load(media.url) }
                }
            } else if let player = model.player {
                controls(player).frame(height: 210)
                #if os(iOS)
                    Button(strings("Fullscreen")) { fullscreen = true }
                        .fullScreenCover(isPresented: $fullscreen) {
                            VStack {
                                HStack {
                                    Spacer()
                                    Button(strings("Done")) { fullscreen = false }.padding()
                                }
                                controls(player)
                            }.background(Color.black).foregroundStyle(.white)
                        }
                #endif
            } else {
                ProgressView()
            }
            if let caption = media.caption ?? media.alt { Text(caption).templateBody() }
        }.templateCard()
            .task(id: media.url) { model.load(media.url) }
            .onDisappear { if !fullscreen { model.dispose() } }
            .onChange(of: scenePhase) { if $0 != .active { model.pause() } }
    }
    @ViewBuilder private func controls(_ player: AVPlayer) -> some View {
        #if os(iOS)
            NativeVideoControls(player: player)
        #else
            VideoPlayer(player: player)
        #endif
    }
}

struct InlineAudioPlayer: View {
    let media: MediaContent
    @StateObject private var model = ChatMediaPlayer()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatStrings) private var strings
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(media.caption ?? media.alt ?? strings("Audio")).templateTitle()
            if model.failed {
                Text(strings("Unable to play this media.")).font(.caption)
                if ChatMediaPlayer.safeURL(media.url) != nil {
                    Button(strings("Retry")) { model.load(media.url) }
                }
            } else {
                HStack {
                    Button(action: model.toggle) {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(
                            minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(strings(model.playing ? "Pause" : "Play"))
                    Slider(
                        value: Binding(get: { min(model.elapsed, max(1, model.duration)) }, set: model.seek),
                        in: 0...max(1, model.duration)
                    ).disabled(model.duration <= 0)
                        .accessibilityLabel(strings("Playback position"))
                    Text(time(model.elapsed) + " / " + time(model.duration)).font(.caption.monospacedDigit())
                }
            }
        }.templateCard()
            .task(id: media.url) { model.load(media.url) }
            .onDisappear { model.dispose() }
            .onChange(of: scenePhase) { if $0 != .active { model.pause() } }
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite ? min(86_400_000, max(0, seconds)) : 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
