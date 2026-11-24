import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var draft: AppSettings
    @State private var tokenInput = ""
    @State private var hasKeychainToken = HomeAssistantToken.hasKeychainToken()
    @AppStorage("HAPiPCamBackgroundAudio") private var backgroundAudio = true
    let onSave: (AppSettings, String) -> Void
    let onCancel: () -> Void

    init(
        draft: AppSettings,
        onSave: @escaping (AppSettings, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("HA PiP Cam Settings")
                .font(.title2.weight(.semibold))

            Form {
                streamSection
                homeAssistantSection
                windowSection
                motionSection
            }
            .formStyle(.grouped)

            footerButtons
        }
        .padding(20)
        .frame(width: 600)
    }

    private var streamSection: some View {
        Section("Live Stream (go2rtc / HLS)") {
            TextField("Camera Name", text: $draft.cameraName)
                .textFieldStyle(.roundedBorder)
            TextField("HLS Stream URL", text: $draft.streamURL)
                .textFieldStyle(.roundedBorder)
            Text("Example: http://127.0.0.1:1984/api/stream.m3u8?src=front_door")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var homeAssistantSection: some View {
        Section("Home Assistant (Optional)") {
            TextField("Base URL", text: $draft.haBaseURL)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                SecureField(tokenPlaceholder, text: $tokenInput)
                    .textFieldStyle(.roundedBorder)
                if hasKeychainToken {
                    Button("Clear") {
                        HomeAssistantToken.deleteKeychain()
                        hasKeychainToken = false
                        tokenInput = ""
                    }
                }
            }
            TextField("Fallback Token File", text: $draft.tokenPath)
                .textFieldStyle(.roundedBorder)
            TextField("Camera Entity", text: $draft.cameraEntity)
                .textFieldStyle(.roundedBorder)
            TextField("Temperature Sensor", text: $draft.temperatureEntity)
                .textFieldStyle(.roundedBorder)
            TextField("Humidity Sensor", text: $draft.humidityEntity)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var windowSection: some View {
        Section("Window & Audio") {
            Toggle("Show PiP window on launch", isOn: $draft.showOnLaunch)
            Toggle("Float above all windows", isOn: $draft.floatOnTop)
            Toggle("Visible on all Spaces (including full-screen)", isOn: $draft.allSpaces)
            Toggle("Keep audio playing when window is hidden", isOn: $backgroundAudio)
        }
    }

    private var motionSection: some View {
        Section("Motion & Menu Bar") {
            Toggle("Send macOS notification on motion", isOn: $draft.notifyOnMotion)
            Toggle("Auto-open PiP panel on motion", isOn: $draft.showOnMotion)
            Toggle("Show temperature & humidity in menu bar", isOn: $draft.climateInMenuBar)
        }
    }

    private var footerButtons: some View {
        HStack {
            Text("Global shortcut: ⌃⌥C")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button("Save") {
                onSave(draft, tokenInput)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var tokenPlaceholder: String {
        hasKeychainToken
            ? "Token stored in Keychain (leave blank to keep)"
            : "Long-Lived Access Token"
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let onSave: (AppSettings, String) -> Void

    init(settings: AppSettings, onSave: @escaping (AppSettings, String) -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 580),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "HA PiP Cam Settings"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentViewController = NSHostingController(
            rootView: SettingsView(
                draft: settings,
                onSave: { [weak self] newSettings, newToken in
                    self?.onSave(newSettings, newToken)
                    self?.close()
                },
                onCancel: { [weak self] in
                    self?.close()
                }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
