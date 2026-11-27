import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var updater: GitHubCommitUpdater
    @State private var draft: AppSettings
    @State private var tokenInput = ""
    @State private var hasKeychainToken = HomeAssistantToken.hasKeychainToken()
    @AppStorage("HAPiPCamBackgroundAudio") private var backgroundAudio = true
    let onSave: (AppSettings, String) -> Void
    let onCancel: () -> Void

    init(
        draft: AppSettings,
        updater: GitHubCommitUpdater,
        onSave: @escaping (AppSettings, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.updater = updater
        _draft = State(initialValue: draft)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                streamSection
                homeAssistantSection
                windowSection
                motionSection
                updatesSection
            }
            .formStyle(.grouped)

            footerButtons
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(width: 600, height: 640)
    }

    private var streamSection: some View {
        Section {
            LabeledContent("Camera Name") {
                TextField("Front Door", text: $draft.cameraName)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("HLS Stream URL") {
                TextField("http://127.0.0.1:1984/api/stream.m3u8?src=front_door", text: $draft.streamURL)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
            }
        } header: {
            Text("Live Stream (go2rtc / HLS)")
        } footer: {
            Text("Example: http://127.0.0.1:1984/api/stream.m3u8?src=front_door")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var homeAssistantSection: some View {
        Section("Home Assistant (Optional)") {
            LabeledContent("Base URL") {
                TextField("http://homeassistant.local:8123", text: $draft.haBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
            }
            LabeledContent("Access Token") {
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
            }
            LabeledContent("Fallback Token File") {
                TextField("~/.config/ha-pip-cam/token", text: $draft.tokenPath)
                    .textFieldStyle(.roundedBorder)
                    .monospacedDigit()
            }
            LabeledContent("Camera Entity") {
                TextField("camera.front_door", text: $draft.cameraEntity)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Temperature Sensor") {
                TextField("sensor.room_temperature", text: $draft.temperatureEntity)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Humidity Sensor") {
                TextField("sensor.room_humidity", text: $draft.humidityEntity)
                    .textFieldStyle(.roundedBorder)
            }
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

    private var updatesSection: some View {
        Section("Updates") {
            CommitUpdateRowView(updater: updater)
        }
    }

    private var footerButtons: some View {
        HStack {
            Text("Global shortcut: ⌃⌥C")
                .font(.caption.monospacedDigit())
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

    init(settings: AppSettings, updater: GitHubCommitUpdater, onSave: @escaping (AppSettings, String) -> Void) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
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
                updater: updater,
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
