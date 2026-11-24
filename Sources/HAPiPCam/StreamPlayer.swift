import AppKit
import AVFoundation
import Foundation
import OSLog
import SwiftUI

@MainActor
final class StreamPlayer: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case playing
        case failed(String)

        var isPlaying: Bool {
            if case .playing = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var isSlowToConnect = false
    @Published var isMuted = false {
        didSet { player.isMuted = isMuted }
    }
    @Published private(set) var volume: Double

    var isSilent: Bool { isMuted || volume == 0 }

    let player = AVPlayer()

    var isActive: Bool {
        shouldPlay && !isSuspended
    }

    var hasStarted: Bool {
        shouldPlay
    }

    private var currentItem: AVPlayerItem?
    private var statusObservation: NSKeyValueObservation?
    private var retryTask: Task<Void, Never>?
    private var currentURL: URL?
    private var shouldPlay = false
    private var isSuspended = false
    private var healthTask: Task<Void, Never>?
    private var lastObservedTime: Double = -1
    private var lastProgressAt = Date()
    private var lastRestartAt = Date.distantPast
    private var loadingStartedAt = Date.distantPast
    private var pausedAt = Date.distantPast
    private let log = Logger(subsystem: "io.github.hapipcam.HAPiPCam", category: "stream")

    private let defaults: UserDefaults
    private static let volumeKey = "HAPiPCamVolume"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        volume = Self.validVolume(defaults.object(forKey: Self.volumeKey) as? Double ?? 1)
        player.isMuted = false
        player.volume = Float(volume)
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.checkHealth()
            }
        }
    }

    deinit {
        retryTask?.cancel()
        healthTask?.cancel()
        statusObservation?.invalidate()
    }

    func play(url: URL) {
        shouldPlay = true
        isSuspended = false
        lastObservedTime = -1
        lastProgressAt = .now
        retryTask?.cancel()

        if currentURL == url, currentItem?.status == .readyToPlay {
            player.play()
            return
        }

        currentURL = url
        statusObservation?.invalidate()
        loadingStartedAt = .now
        log.info("opening \(url.absoluteString, privacy: .public)")

        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        item.preferredForwardBufferDuration = 1
        currentItem = item
        player.replaceCurrentItem(with: item)
        status = .loading

        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handle(item, error: item.error)
            }
        }
        player.play()
    }

    func pause() {
        isSuspended = true
        pausedAt = .now
        retryTask?.cancel()
        player.pause()
    }

    func resume() {
        let wasSuspended = isSuspended
        isSuspended = false
        guard shouldPlay else { return }
        if case .failed = status, let currentURL {
            play(url: currentURL)
            return
        }
        if wasSuspended, Date.now.timeIntervalSince(pausedAt) > 30 {
            restart()
            return
        }
        player.play()
    }

    func setPreventsDisplaySleep(_ enabled: Bool) {
        player.preventsDisplaySleepDuringVideoPlayback = enabled
    }

    func stop() {
        shouldPlay = false
        isSuspended = true
        retryTask?.cancel()
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentItem = nil
        currentURL = nil
        status = .idle
        isSlowToConnect = false
    }

    func toggleMute() {
        if isSilent {
            if volume == 0 { setVolume(1) }
            isMuted = false
        } else {
            isMuted = true
        }
    }

    func setVolume(_ value: Double) {
        volume = Self.validVolume(value)
        player.volume = Float(volume)
        defaults.set(volume, forKey: Self.volumeKey)
    }

    private static func validVolume(_ value: Double) -> Double {
        value.isFinite ? min(4, max(0, value)) : 1
    }

    func restart() {
        guard let url = currentURL else { return }
        lastRestartAt = .now
        currentURL = nil
        play(url: url)
    }

    private func checkHealth() {
        if status == .loading, shouldPlay, !isSuspended {
            let playbackTime = player.currentTime().seconds
            if playbackTime.isFinite, playbackTime > 0 {
                status = .playing
                isSlowToConnect = false
                lastObservedTime = playbackTime
                lastProgressAt = .now
                log.info("HLS playing (frames advancing)")
                return
            }
            let loadingFor = Date.now.timeIntervalSince(loadingStartedAt)
            if loadingFor > 15, Date.now.timeIntervalSince(lastRestartAt) > 15 {
                log.error("stream stuck loading for \(Int(loadingFor))s, restarting")
                isSlowToConnect = true
                restart()
            }
            return
        }
        guard status == .playing, shouldPlay, !isSuspended else {
            lastObservedTime = -1
            lastProgressAt = .now
            return
        }
        let time = player.currentTime().seconds
        guard time.isFinite else { return }
        if lastObservedTime < 0 || abs(time - lastObservedTime) > 0.001 {
            lastObservedTime = time
            lastProgressAt = .now
            return
        }
        let stalledFor = Date.now.timeIntervalSince(lastProgressAt)
        guard stalledFor > 10,
              Date.now.timeIntervalSince(lastRestartAt) > 10
        else { return }
        log.error("stream watchdog restart after \(Int(stalledFor))s without progress")
        restart()
    }

    private func handle(_ item: AVPlayerItem, error: Error?) {
        guard item === currentItem else { return }
        switch item.status {
        case .readyToPlay:
            status = .playing
            isSlowToConnect = false
            log.info("HLS ready")
            if shouldPlay, !isSuspended { player.play() }
        case .failed:
            let message = error?.localizedDescription ?? "Stream unavailable"
            status = .failed(message)
            log.error("HLS failed: \(message, privacy: .public)")
            scheduleRetry()
        case .unknown:
            status = .loading
        @unknown default:
            status = .loading
        }
    }

    private func scheduleRetry() {
        guard shouldPlay, !isSuspended, let currentURL else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, self.shouldPlay, !self.isSuspended else { return }
            self.play(url: currentURL)
        }
    }
}

struct PlaybackVolumeControl: View {
    @ObservedObject var player: StreamPlayer

    var body: some View {
        HStack(spacing: 8) {
            Button(action: { player.toggleMute() }) {
                Image(systemName: player.isSilent ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isSilent ? "Unmute" : "Mute")
            .help(player.isSilent ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { player.volume },
                    set: { player.setVolume($0) }
                ),
                in: 0...4,
                step: 0.05
            ) {
                Text("Volume")
            }
            .tint(.white)
            .accessibilityValue("\(Int((player.volume * 100).rounded())) percent")
            .help("100% is native level. Above 100% boosts quiet audio without changing macOS system volume.")

            Text("\(Int((player.volume * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

struct VideoView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.player = player
    }
}

final class PlayerLayerView: NSView {
    private var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = AVPlayerLayer()
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
