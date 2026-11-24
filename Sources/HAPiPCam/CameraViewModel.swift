import Foundation
import SwiftUI

@MainActor
final class CameraViewModel: ObservableObject {
    @Published private(set) var reading: CameraReading = .empty
    @Published private(set) var haError: String?
    @Published private(set) var motionActive = false
    @Published private(set) var settings: AppSettings
    var onMotion: ((String?) -> Void)?

    private var pollTask: Task<Void, Never>?
    private var motionTracker = MotionTracker()
    private var isRefreshing = false
    private var cachedToken: String?
    private var cachedTemperature: HAEntityState?
    private var cachedHumidity: HAEntityState?
    private var lastSensorsAt = Date.distantPast
    private let sensorInterval: TimeInterval = 10
    private var isPanelVisible = false

    init(settings: AppSettings = .load()) {
        self.settings = settings
    }

    deinit {
        pollTask?.cancel()
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval: TimeInterval = self?.isPanelVisible == true ? 2 : 10
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func setPanelVisible(_ visible: Bool) {
        isPanelVisible = visible
    }

    func apply(_ newSettings: AppSettings, persist: Bool = true) {
        settings = newSettings
        cachedToken = nil
        cachedTemperature = nil
        cachedHumidity = nil
        lastSensorsAt = .distantPast
        if !newSettings.hasHomeAssistantConfigured {
            haError = nil
            reading = .empty
        }
        if persist {
            newSettings.save()
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        motionActive = motionTracker.isActive()

        // Home Assistant sensors & motion are optional; HLS PiP works standalone without HA.
        guard settings.hasHomeAssistantConfigured, let baseURL = settings.haBase else {
            haError = nil
            return
        }

        let token: String
        if let cachedToken {
            token = cachedToken
        } else {
            do {
                token = try HomeAssistantToken.read(fallbackFileURL: settings.tokenURL)
                cachedToken = token
            } catch {
                fail(error.localizedDescription)
                return
            }
        }

        let client = HomeAssistantClient(baseURL: baseURL, token: token)
        let shouldRefreshSensors = Date.now.timeIntervalSince(lastSensorsAt) >= sensorInterval
        let tempEntity = settings.temperatureEntity.trimmingCharacters(in: .whitespacesAndNewlines)
        let humEntity = settings.humidityEntity.trimmingCharacters(in: .whitespacesAndNewlines)

        let temperatureTask: Task<HAEntityState?, Never>? = (shouldRefreshSensors && !tempEntity.isEmpty)
            ? Task { try? await client.entity(tempEntity) }
            : nil
        let humidityTask: Task<HAEntityState?, Never>? = (shouldRefreshSensors && !humEntity.isEmpty)
            ? Task { try? await client.entity(humEntity) }
            : nil

        do {
            let camera = try await client.entity(settings.cameraEntity.trimmingCharacters(in: .whitespacesAndNewlines))
            if let temperatureTask {
                cachedTemperature = await temperatureTask.value
            }
            if let humidityTask {
                cachedHumidity = await humidityTask.value
            }
            if shouldRefreshSensors {
                lastSensorsAt = .now
            }
            let newReading = CameraDataParser.cameraReading(
                camera: camera,
                temperature: cachedTemperature,
                humidity: cachedHumidity
            )
            let isNewMotion = motionTracker.update(motionTime: newReading.motionTime)
            reading = newReading
            motionActive = motionTracker.isActive()
            haError = nil
            if isNewMotion {
                onMotion?(newReading.motionTime)
            }
        } catch is CancellationError {
            temperatureTask?.cancel()
            humidityTask?.cancel()
        } catch {
            temperatureTask?.cancel()
            humidityTask?.cancel()
            if let haError = error as? HomeAssistantError,
               case let .httpStatus(code) = haError,
               code == 401 {
                cachedToken = nil
            }
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        haError = message
        if reading.haReachable {
            reading.haReachable = false
        }
        motionActive = motionTracker.isActive()
    }
}
