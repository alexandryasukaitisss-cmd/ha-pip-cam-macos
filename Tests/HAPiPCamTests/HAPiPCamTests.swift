import AppKit
import Foundation
import SwiftUI
import Testing
@testable import HAPiPCam

struct CameraDataParserTests {
    @Test func parsesCameraAttributesAndSensors() throws {
        let json = """
        {
          "entity_id": "camera.front_door",
          "state": "idle",
          "attributes": {
            "motion_video_time": "2026-11-11 22:23:30",
            "motion_video_type": "ObjectMotion",
            "stream_address": "https://example.com/last.m3u8",
            "entity_picture": "/api/camera_proxy/camera.front_door?token=sample"
          }
        }
        """.data(using: .utf8)!
        let camera = try JSONDecoder().decode(HAEntityState.self, from: json)

        let temperature = HAEntityState(
            entityID: "sensor.temperature",
            state: "22.1",
            attributes: ["unit_of_measurement": .string("°C")]
        )
        let humidity = HAEntityState(
            entityID: "sensor.humidity",
            state: "58",
            attributes: ["unit_of_measurement": .string("%")]
        )

        let reading = CameraDataParser.cameraReading(
            camera: camera,
            temperature: temperature,
            humidity: humidity
        )

        #expect(reading.state == "idle")
        #expect(reading.motionTime == "2026-11-11 22:23:30")
        #expect(reading.motionType == "ObjectMotion")
        #expect(reading.streamAddress?.absoluteString == "https://example.com/last.m3u8")
        #expect(reading.temperature?.value == 22.1)
        #expect(reading.temperature?.unit == "°C")
        #expect(reading.humidity?.value == 58)
        #expect(reading.humidity?.unit == "%")
        #expect(reading.haReachable)
    }

    @Test func missingSensorsAreGraceful() {
        let camera = HAEntityState(entityID: "camera.test", state: "idle")
        let reading = CameraDataParser.cameraReading(camera: camera, temperature: nil, humidity: nil)
        #expect(reading.temperature == nil)
        #expect(reading.humidity == nil)
        #expect(reading.streamAddress == nil)
        #expect(reading.haReachable)
    }

    @Test func unavailableSensorIsNil() {
        let entity = HAEntityState(entityID: "sensor.test", state: "unavailable")
        #expect(SensorReading.parse(entity) == nil)
    }
}

struct MotionTrackerTests {
    @Test func firstReadingIsBaseline() {
        var tracker = MotionTracker()
        let first = tracker.update(motionTime: "t1", now: Date(timeIntervalSince1970: 100))
        #expect(!first)
        #expect(!tracker.isActive(now: Date(timeIntervalSince1970: 100)))
    }

    @Test func changedTimestampStartsMotionWindow() {
        var tracker = MotionTracker()
        _ = tracker.update(motionTime: "t1", now: Date(timeIntervalSince1970: 100))
        let now = Date(timeIntervalSince1970: 110)
        let triggered = tracker.update(motionTime: "t2", now: now)
        #expect(triggered)
        #expect(tracker.isActive(now: now, window: 15))
        #expect(!tracker.isActive(now: now.addingTimeInterval(16), window: 15))
    }

    @Test func repeatingTimestampDoesNotRetrigger() {
        var tracker = MotionTracker()
        _ = tracker.update(motionTime: "t1", now: Date(timeIntervalSince1970: 100))
        _ = tracker.update(motionTime: "t2", now: Date(timeIntervalSince1970: 110))
        let retriggered = tracker.update(motionTime: "t2", now: Date(timeIntervalSince1970: 120))
        #expect(!retriggered)
    }
}

struct AppSettingsTests {
    @Test func roundTripsThroughUserDefaults() {
        let domain = "HAPiPCamTests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: domain)!
        defer { suite.removePersistentDomain(forName: domain) }

        var settings = AppSettings.default
        settings.cameraName = "Porch"
        settings.streamURL = "http://127.0.0.1:1984/api/stream.m3u8?src=porch"
        settings.haBaseURL = "http://homeassistant.local:8123"
        settings.cameraEntity = "camera.porch"
        settings.showOnLaunch = true
        settings.save(to: suite)

        let loaded = AppSettings.load(from: suite)
        #expect(loaded == settings)
        #expect(loaded.hasHomeAssistantConfigured)
    }

    @Test func homeAssistantIsOptionalWhenBlank() {
        let settings = AppSettings.default
        #expect(!settings.hasHomeAssistantConfigured)
        #expect(settings.displayTitle == "Live Camera")
    }

    @Test func decodesOlderSettingsWithoutNewKeys() throws {
        let legacy = """
        {"streamURL":"http://example/stream.m3u8","haBaseURL":"http://ha:8123",\
        "tokenPath":"~/t","cameraEntity":"camera.x","temperatureEntity":"sensor.t",\
        "humidityEntity":"sensor.h","showOnLaunch":true}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(settings.streamURL == "http://example/stream.m3u8")
        #expect(settings.cameraName == AppSettings.default.cameraName)
        #expect(settings.floatOnTop == AppSettings.default.floatOnTop)
        #expect(settings.allSpaces == AppSettings.default.allSpaces)
    }
}

struct PanelStreamPolicyTests {
    private let oldURL = URL(string: "http://127.0.0.1:1984/old.m3u8")!
    private let newURL = URL(string: "http://127.0.0.1:1984/new.m3u8")!

    @Test func startsStoppedStreamOnShow() {
        #expect(PanelStreamPolicy.show(url: newURL, lastURL: nil, hasStarted: false) == .play(newURL))
    }

    @Test func appliesNewURLOnShow() {
        #expect(PanelStreamPolicy.show(url: newURL, lastURL: oldURL, hasStarted: true) == .play(newURL))
    }

    @Test func resumesAlreadyRunningStream() {
        #expect(PanelStreamPolicy.show(url: oldURL, lastURL: oldURL, hasStarted: true) == .resume)
    }

    @Test func noStreamURLDoesNothing() {
        #expect(PanelStreamPolicy.show(url: nil, lastURL: oldURL, hasStarted: true) == .none)
    }
}

struct MenuBarClimateAndMotionTests {
    @Test func formatsClimateAndHidesWhenOffline() {
        let text = MenuBarClimate.text(
            temperature: SensorReading(value: 21.64, unit: "°C"),
            humidity: SensorReading(value: 53.4, unit: "%"),
            haOffline: false
        )
        #expect(text == "21.6° 53%")
        #expect(
            MenuBarClimate.text(
                temperature: SensorReading(value: 21.64, unit: "°C"),
                humidity: SensorReading(value: 53.4, unit: "%"),
                haOffline: true
            ).isEmpty
        )
    }

    @Test func motionReactionsApplyOnlyWhenPanelHidden() {
        var settings = AppSettings.default
        settings.notifyOnMotion = true
        settings.showOnMotion = true
        let hidden = MotionReaction(settings: settings, panelVisible: false)
        #expect(hidden.notify && hidden.showPanel)
        let visible = MotionReaction(settings: settings, panelVisible: true)
        #expect(!visible.notify && !visible.showPanel)
    }
}

@MainActor
struct StreamPlayerAndPanelTests {
    @Test(arguments: [
        (-2.0, 0.0), (0, 0), (0.35, 0.35), (1, 1), (2.5, 2.5), (4, 4), (9, 4),
        (Double.nan, 1), (Double.infinity, 1), (-Double.infinity, 1),
    ] as [(Double, Double)])
    func volumeIsBoundedAppliedAndSaved(_ input: Double, _ expected: Double) {
        let domain = "HAPiPCamVolumeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(input, forKey: "HAPiPCamVolume")
        let player = StreamPlayer(defaults: defaults)
        #expect(player.volume == expected)
        #expect(player.player.volume == Float(expected))
        player.setVolume(input)
        #expect(player.volume == expected)
        #expect(defaults.double(forKey: "HAPiPCamVolume") == expected)
    }

    @Test func savingSettingsWhileHiddenDoesNotStartStream() {
        _ = NSApplication.shared
        let model = CameraViewModel(settings: .default)
        let player = StreamPlayer()
        let controller = CameraPanelController(
            model: model,
            player: player,
            onSettings: {},
            onLastClip: {}
        )
        #expect(!controller.isVisible)
        controller.settingsDidChange()
        #expect(!player.hasStarted)
        #expect(!player.isActive)
    }

    @Test func appliesFloatingAndSpacesWindowSettings() {
        _ = NSApplication.shared
        var settings = AppSettings.default
        settings.floatOnTop = false
        settings.allSpaces = false
        let model = CameraViewModel(settings: settings)
        let controller = CameraPanelController(
            model: model,
            player: StreamPlayer(),
            onSettings: {},
            onLastClip: {}
        )
        #expect(controller.window?.level == .normal)
        #expect(controller.window?.collectionBehavior.contains(.canJoinAllSpaces) == false)

        settings.floatOnTop = true
        settings.allSpaces = true
        model.apply(settings, persist: false)
        controller.settingsDidChange()
        #expect(controller.window?.level == .floating)
        #expect(controller.window?.collectionBehavior.contains(.canJoinAllSpaces) == true)
    }
}
