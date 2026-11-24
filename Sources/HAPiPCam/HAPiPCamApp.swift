import AppKit
import Foundation
import UserNotifications

@main
enum HAPiPCamApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = CameraViewModel()
    private let player = StreamPlayer()
    private var panelController: CameraPanelController?
    private var settingsController: SettingsWindowController?
    private var clipController: ClipWindowController?
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var uiTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var resumeAfterClip = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let index = CommandLine.arguments.firstIndex(of: "--stream"),
           CommandLine.arguments.indices.contains(index + 1) {
            var settings = model.settings
            settings.streamURL = CommandLine.arguments[index + 1]
            model.apply(settings, persist: false)
        }

        panelController = CameraPanelController(
            model: model,
            player: player,
            onSettings: { [weak self] in self?.showSettings() },
            onLastClip: { [weak self] in self?.showLastClip() }
        )
        clipController = ClipWindowController(audio: player) { [weak self] in
            guard let self else { return }
            guard self.resumeAfterClip else { return }
            self.resumeAfterClip = false
            self.player.resume()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "HA PiP Cam")
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.setAccessibilityLabel("HA PiP Cam")
        }

        UNUserNotificationCenter.current().delegate = self
        if model.settings.notifyOnMotion && model.settings.hasHomeAssistantConfigured {
            MotionNotifier.requestAuthorization()
        }
        model.onMotion = { [weak self] motionTime in
            self?.handleMotion(motionTime)
        }

        hotKey = GlobalHotKey { [weak self] in
            self?.togglePanel()
        }

        model.start()
        updateStatusItem()

        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusItem()
            }
        }

        if model.settings.showOnLaunch || CommandLine.arguments.contains("--show") {
            panelController?.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        uiTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        model.stop()
        player.stop()
    }

    fileprivate func showPanelFromNotification() {
        panelController?.show()
    }

    private func handleMotion(_ motionTime: String?) {
        let reaction = MotionReaction(
            settings: model.settings,
            panelVisible: panelController?.isVisible == true
        )
        if reaction.showPanel {
            panelController?.show()
        }
        if reaction.notify {
            MotionNotifier.post(cameraName: model.settings.displayTitle, motionTime: motionTime)
        }
    }

    private func handleWake() {
        guard player.isActive else { return }
        player.restart()
        Task { await model.refresh() }
    }

    @objc private func statusClick(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        guard let button = statusItem?.button else { return }
        let menu = makeMenu()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.height + 4),
            in: button
        )
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let toggle = NSMenuItem(
            title: panelController?.isVisible == true ? "Hide Window" : "Show Window",
            action: #selector(togglePanelAction),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let mute = NSMenuItem(
            title: player.isSilent ? "Unmute Audio" : "Mute Audio",
            action: #selector(toggleMuteAction),
            keyEquivalent: ""
        )
        mute.target = self
        menu.addItem(mute)

        let clip = NSMenuItem(
            title: "Last Motion Clip",
            action: #selector(showLastClipAction),
            keyEquivalent: ""
        )
        clip.target = self
        clip.isEnabled = model.reading.streamAddress != nil
        menu.addItem(clip)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettingsAction),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit HA PiP Cam",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func togglePanelAction() { togglePanel() }

    @objc private func toggleMuteAction() {
        player.toggleMute()
        updateStatusItem()
    }

    @objc private func showLastClipAction() { showLastClip() }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func quitAction() { NSApp.terminate(nil) }

    private func togglePanel() {
        panelController?.toggle()
    }

    private func showSettings() {
        settingsController?.close()
        let controller = SettingsWindowController(settings: model.settings) { [weak self] newSettings, newToken in
            guard let self else { return }
            if !newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HomeAssistantToken.saveKeychain(newToken)
            }
            self.model.apply(newSettings)
            self.panelController?.settingsDidChange()
            if newSettings.notifyOnMotion && newSettings.hasHomeAssistantConfigured {
                MotionNotifier.requestAuthorization()
            }
            self.updateStatusItem()
        }
        settingsController = controller
        controller.show()
    }

    private func showLastClip() {
        guard let url = model.reading.streamAddress else { return }
        resumeAfterClip = resumeAfterClip || player.isActive
        player.pause()
        let title = "Last Clip" + (model.reading.motionTime.map { " · \($0)" } ?? "")
        clipController?.show(url: url, title: title)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol = model.motionActive ? "record.circle" : "video.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.settings.displayTitle)
        if model.motionActive {
            button.image = image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        } else {
            button.image = image
        }

        var parts = [model.settings.displayTitle]
        if let temperature = model.reading.temperature {
            parts.append(String(format: "%.1f %@", temperature.value, temperature.unit))
        }
        if let humidity = model.reading.humidity {
            parts.append(String(format: "%.0f %@", humidity.value, humidity.unit))
        }
        if model.haError != nil {
            parts.append("HA offline")
        }
        if player.isSilent {
            parts.append("muted")
        }
        button.toolTip = parts.joined(separator: " · ")

        let climate = model.settings.climateInMenuBar
            ? MenuBarClimate.text(
                temperature: model.reading.temperature,
                humidity: model.reading.humidity,
                haOffline: model.haError != nil
            )
            : ""
        if button.title != climate {
            button.title = climate
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            self.showPanelFromNotification()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
