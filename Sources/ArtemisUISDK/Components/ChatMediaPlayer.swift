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
    @Published private(set) var isMuted = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var failed = false
    @Published private(set) var videoAspectRatio: CGFloat?
    private var timeObservation: MediaTimeObservation?
    private var statusObserver: NSKeyValueObservation?
    private var playbackObserver: NSKeyValueObservation?
    private var presentationSizeObserver: NSKeyValueObservation?
    private var source: URL?

    static func safeURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.isHTTP else { return nil }
        return url
    }
    func load(_ value: String, force: Bool = false) {
        guard let url = Self.safeURL(value) else {
            dispose()
            failed = true
            return
        }
        if !force, source == url, player != nil { return }
        dispose()
        source = url
        failed = false
        elapsed = 0
        duration = 0
        isMuted = false
        videoAspectRatio = nil
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
        presentationSizeObserver = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            let aspectRatio = size.width / size.height
            Task { @MainActor in
                guard let self, self.player?.currentItem === item,
                    size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                    aspectRatio.isFinite, aspectRatio > 0
                else { return }
                self.videoAspectRatio = aspectRatio
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
    func toggleMuted() {
        guard let player else { return }
        isMuted.toggle()
        player.isMuted = isMuted
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
        presentationSizeObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        source = nil
        playing = false
        isMuted = false
        videoAspectRatio = nil
        videoAspectRatio = nil
    }
    private func updateDuration(_ item: AVPlayerItem) {
        let value = item.duration.seconds
        duration = value.isFinite ? max(0, value) : 0
    }
}

#if os(iOS)
    private struct NativeVideoControls: UIViewControllerRepresentable {
        let player: AVPlayer
        let onFullscreenChanged: (Bool) -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(onFullscreenChanged: onFullscreenChanged)
        }

        func makeUIViewController(context: Context) -> AVPlayerViewController {
            let controller = AVPlayerViewController()
            controller.player = player
            controller.showsPlaybackControls = true
            controller.delegate = context.coordinator
            return controller
        }
        func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
            controller.player = player
            controller.delegate = context.coordinator
            context.coordinator.onFullscreenChanged = onFullscreenChanged
        }
        static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
            controller.delegate = nil
        }

        final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
            var onFullscreenChanged: (Bool) -> Void

            init(onFullscreenChanged: @escaping (Bool) -> Void) {
                self.onFullscreenChanged = onFullscreenChanged
            }

            func playerViewController(
                _ playerViewController: AVPlayerViewController,
                willBeginFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
            ) {
                onFullscreenChanged(true)
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    if context.isCancelled { self?.onFullscreenChanged(false) }
                }
            }

            func playerViewController(
                _ playerViewController: AVPlayerViewController,
                willEndFullScreenPresentationWithAnimationCoordinator coordinator: UIViewControllerTransitionCoordinator
            ) {
                coordinator.animate(alongsideTransition: nil) { [weak self] context in
                    if !context.isCancelled { self?.onFullscreenChanged(false) }
                }
            }
        }
    }
#endif

struct InlineVideoPlayer: View {
    let media: MediaContent
    var displayCaption: String? = nil
    var presentation: ChatPresentationState? = nil
    @StateObject private var model = ChatMediaPlayer()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.chatStrings) private var strings
    @Environment(\.chatTheme) private var chatTheme

    private var assistantSurface: Color {
        Color(hexString: chatTheme?.assistantBubbleColor ?? "#F1F5F9")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.failed {
                Text(strings("Unable to play this media.")).font(.caption)
                if ChatMediaPlayer.safeURL(media.url) != nil {
                    Button(strings("Retry")) { model.load(media.url, force: true) }
                }
            } else if let player = model.player {
                controls(player)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(model.videoAspectRatio ?? (16.0 / 9.0), contentMode: .fit)
                    .cornerRadius(10)
            } else {
                ProgressView()
            }
            if let caption = displayCaption ?? media.caption ?? media.alt { Text(caption).templateBody() }
        }.templateCard(
            padding: 0,
            backgroundColor: assistantSurface,
            borderColor: assistantSurface,
            cornerRadius: 0
        )
            .task(id: media.url) { model.load(media.url) }
            .onAppear {
                if presentation?.isVideoFullscreenPresented == true {
                    presentation?.setVideoFullscreenPresented(false)
                }
            }
            .onDisappear {
                if presentation?.isVideoFullscreenPresented != true { model.dispose() }
            }
            .onChange(of: scenePhase) { if $0 != .active { model.pause() } }
    }
    @ViewBuilder private func controls(_ player: AVPlayer) -> some View {
        #if os(iOS)
            NativeVideoControls(player: player) { isPresented in
                presentation?.setVideoFullscreenPresented(isPresented)
            }
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
    @Environment(\.chatTheme) private var chatTheme

    private var assistantSurface: Color {
        Color(hexString: chatTheme?.assistantBubbleColor ?? "#F1F5F9")
    }
    private var controlForeground: Color {
        Color(hexString: chatTheme?.textColor ?? "#202124")
    }
    private var displayCaption: String? {
        guard let caption = media.caption?.templateTrimmed, !caption.isEmpty else { return nil }
        return caption
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.failed {
                Text(strings("Unable to play this media."))
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if ChatMediaPlayer.safeURL(media.url) != nil {
                    Button(strings("Retry")) { model.load(media.url, force: true) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(spacing: 8) {
                    Button(action: model.toggle) {
                        Image(systemName: model.playing ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(controlForeground)
                            .frame(width: 30, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(strings(model.playing ? "Pause" : "Play"))

                    Text(time(model.elapsed) + " / " + time(model.duration))
                        .font(chatTheme?.font(size: 14, weight: .medium) ?? .system(size: 14, weight: .medium))
                        .foregroundStyle(controlForeground)
                        .monospacedDigit()
                        .fixedSize()

                    Slider(
                        value: Binding(get: { min(model.elapsed, max(1, model.duration)) }, set: model.seek),
                        in: 0...max(1, model.duration)
                    ).disabled(model.duration <= 0)
                        .tint(Color(hexString: "#606060"))
                        .frame(minWidth: 40)
                        .accessibilityLabel(strings("Playback position"))

                    Button(action: model.toggleMuted) {
                        Image(systemName: model.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(controlForeground)
                            .frame(width: 28, height: 40)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(strings(model.isMuted ? "Unmute" : "Mute"))

                    Menu {
                        Button(strings("Restart")) { model.seek(0) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(controlForeground)
                            .rotationEffect(.degrees(90))
                            .frame(width: 24, height: 40)
                    }
                    .accessibilityLabel(strings("More audio options"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(Color(hexString: "#F1F3F4"))
                .clipShape(Capsule())
            }

            if let displayCaption {
                Text(displayCaption)
                    .templateBody()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }.templateCard(padding: 0,backgroundColor: assistantSurface, borderColor: assistantSurface, cornerRadius: 0)
            .task(id: media.url) { model.load(media.url) }
            .onDisappear { model.dispose() }
            .onChange(of: scenePhase) { if $0 != .active { model.pause() } }
    }
    private func time(_ seconds: Double) -> String {
        let value = Int(seconds.isFinite ? min(86_400_000, max(0, seconds)) : 0)
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
