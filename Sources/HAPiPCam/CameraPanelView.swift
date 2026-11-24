import AppKit
import SwiftUI

struct CameraPanelView: View {
    @ObservedObject var model: CameraViewModel
    @ObservedObject var player: StreamPlayer
    let onSettings: () -> Void
    let onLastClip: () -> Void
    let onRefresh: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            PlaybackVolumeControl(player: player)
            videoArea
            bottomBar
        }
        .frame(minWidth: 420, minHeight: 280)
        .background(Color.black)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.8), radius: 4)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.settings.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }

            Spacer(minLength: 8)

            iconButton("arrow.clockwise", label: "Restart stream", action: onRefresh)
            iconButton("gearshape.fill", label: "Settings", action: onSettings)
            iconButton("xmark", label: "Hide", action: onClose)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.94))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var videoArea: some View {
        ZStack {
            Color.black
            VideoView(player: player.player)

            if player.status != .playing {
                streamPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            if let temperature = model.reading.temperature {
                chip(String(format: "%.1f %@", temperature.value, temperature.unit))
            }
            if let humidity = model.reading.humidity {
                chip(String(format: "%.0f %@", humidity.value, humidity.unit))
            }

            Spacer(minLength: 8)

            if model.haError != nil {
                chip("HA offline", color: .orange)
            }

            if let shortMotionTime {
                Text(shortMotionTime)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Button(action: onLastClip) {
                Label("Last Clip", systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(.white)
            .disabled(model.reading.streamAddress == nil)
            .opacity(model.reading.streamAddress == nil ? 0.45 : 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.94))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var streamPlaceholder: some View {
        VStack(spacing: 10) {
            if case let .failed(message) = player.status {
                Image(systemName: "video.slash")
                    .font(.system(size: 30, weight: .light))
                Text("Stream Unavailable")
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(3)
                if let url = model.settings.stream {
                    Button("Retry") {
                        player.play(url: url)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting…")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                if player.isSlowToConnect {
                    Text("No video frames after 15s. Verify that go2rtc (or your HLS server) is running and allowed Local Network access in macOS Privacy & Security.")
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(maxWidth: 320)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusColor: Color {
        if model.motionActive { return .red }
        return player.status.isPlaying ? .green : .gray
    }

    private var shortMotionTime: String? {
        guard let value = model.reading.motionTime else { return nil }
        let time = String(value.suffix(8).prefix(5))
        return time.contains(":") ? time : value
    }

    private var statusLabel: String {
        switch player.status {
        case .playing:
            model.motionActive ? "Motion" : "Live"
        case .loading:
            "Connecting…"
        case .failed:
            "Offline"
        case .idle:
            "Idle"
        }
    }

    private func chip(_ text: String, color: Color = .white) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func iconButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 32)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
        .help(label)
    }
}

enum PanelStreamDecision: Equatable {
    case play(URL)
    case resume
    case none
}

enum PanelStreamPolicy {
    static func show(url: URL?, lastURL: URL?, hasStarted: Bool) -> PanelStreamDecision {
        guard let url else { return .none }
        if lastURL != url || !hasStarted { return .play(url) }
        return .resume
    }
}

@MainActor
final class CameraPanelController: NSWindowController, NSWindowDelegate {
    private let model: CameraViewModel
    private let player: StreamPlayer
    private let panel: NSPanel
    private let onSettings: () -> Void
    private let onLastClip: () -> Void
    private var lastStreamURL: URL?
    private static let frameKey = "HAPiPCamPanelFrame"
    private static let backgroundAudioKey = "HAPiPCamBackgroundAudio"

    init(
        model: CameraViewModel,
        player: StreamPlayer,
        onSettings: @escaping () -> Void,
        onLastClip: @escaping () -> Void
    ) {
        self.model = model
        self.player = player
        self.onSettings = onSettings
        self.onLastClip = onLastClip

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = model.settings.displayTitle
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 420, height: 280)
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = true

        super.init(window: panel)
        let view = CameraPanelView(
            model: model,
            player: player,
            onSettings: onSettings,
            onLastClip: onLastClip,
            onRefresh: { [weak self] in self?.refresh() },
            onClose: { [weak self] in self?.hide() }
        )
        panel.contentViewController = NSHostingController(rootView: view)
        panel.setContentSize(NSSize(width: 520, height: 360))
        panel.delegate = self
        applyWindowSettings()
        restoreFrame()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func show() {
        model.setPanelVisible(true)
        ensureFrameOnScreen()
        player.setPreventsDisplaySleep(true)
        switch PanelStreamPolicy.show(
            url: model.settings.stream,
            lastURL: lastStreamURL,
            hasStarted: player.hasStarted
        ) {
        case let .play(url):
            player.play(url: url)
            lastStreamURL = url
        case .resume:
            player.resume()
        case .none:
            break
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func refresh() {
        player.restart()
    }

    func hide() {
        model.setPanelVisible(false)
        panel.orderOut(nil)
        player.setPreventsDisplaySleep(false)
        if !backgroundAudioEnabled {
            player.stop()
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func settingsDidChange() {
        panel.title = model.settings.displayTitle
        applyWindowSettings()
        guard let url = model.settings.stream else { return }

        guard isVisible else {
            if !backgroundAudioEnabled {
                player.stop()
            } else if player.hasStarted, lastStreamURL != url {
                player.play(url: url)
                lastStreamURL = url
            }
            return
        }

        if lastStreamURL != url {
            player.play(url: url)
            lastStreamURL = url
        }
    }

    private func applyWindowSettings() {
        let settings = model.settings
        panel.isFloatingPanel = settings.floatOnTop
        panel.level = settings.floatOnTop ? .floating : .normal
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .stationary]
        if settings.allSpaces {
            behavior.insert(.canJoinAllSpaces)
        }
        panel.collectionBehavior = behavior
    }

    private var backgroundAudioEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.backgroundAudioKey) as? Bool ?? true
    }

    func windowDidMove(_ notification: Notification) {
        saveFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveFrame()
    }

    func windowWillClose(_ notification: Notification) {
        model.setPanelVisible(false)
        player.setPreventsDisplaySleep(false)
        if !backgroundAudioEnabled {
            player.stop()
        }
    }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    private func ensureFrameOnScreen() {
        guard !isFrameVisible(panel.frame) else { return }
        moveToDefaultPosition()
    }

    private func isFrameVisible(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains { screen in
            let visible = screen.visibleFrame.intersection(frame)
            return visible.width >= 80 && visible.height >= 40
        }
    }

    private func moveToDefaultPosition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrame(
            NSRect(
                x: visible.maxX - size.width - 24,
                y: visible.maxY - size.height - 24,
                width: size.width,
                height: size.height
            ),
            display: false
        )
    }

    private func restoreFrame() {
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let frame = NSRectFromString(saved)
            if frame.width >= 420,
               frame.height >= 280,
               isFrameVisible(frame) {
                panel.setFrame(frame, display: false)
                return
            }
        }
        moveToDefaultPosition()
    }
}
