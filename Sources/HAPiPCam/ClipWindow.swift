import AppKit
import AVFoundation
import SwiftUI

struct ClipView: View {
    let player: AVPlayer
    @ObservedObject var audio: StreamPlayer

    var body: some View {
        VStack(spacing: 0) {
            VideoView(player: player)
                .frame(minWidth: 480, minHeight: 270)
            PlaybackVolumeControl(player: audio)
        }
        .background(Color.black)
        .onReceive(audio.$volume) { player.volume = Float($0) }
        .onReceive(audio.$isMuted) { player.isMuted = $0 }
    }
}

@MainActor
final class ClipWindowController: NSWindowController, NSWindowDelegate {
    private var player: AVPlayer?
    private let audio: StreamPlayer
    private let onClose: () -> Void

    init(audio: StreamPlayer, onClose: @escaping () -> Void) {
        self.audio = audio
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Last Clip"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(url: URL, title: String) {
        player?.pause()
        let player = AVPlayer(url: url)
        player.volume = Float(audio.volume)
        player.isMuted = audio.isMuted
        self.player = player
        window?.contentViewController = NSHostingController(rootView: ClipView(player: player, audio: audio))
        window?.title = title
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        player.play()
    }

    func windowWillClose(_ notification: Notification) {
        player?.pause()
        player = nil
        onClose()
    }
}
