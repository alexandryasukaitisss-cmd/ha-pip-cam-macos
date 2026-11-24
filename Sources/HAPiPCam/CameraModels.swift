import Foundation

enum JSONValue: Decodable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }
}

struct HAEntityState: Decodable, Sendable {
    let entityID: String
    let state: String
    let attributes: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case entityID = "entity_id"
        case state
        case attributes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        entityID = try container.decode(String.self, forKey: .entityID)
        state = try container.decode(String.self, forKey: .state)
        attributes = try container.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
    }

    init(entityID: String, state: String, attributes: [String: JSONValue] = [:]) {
        self.entityID = entityID
        self.state = state
        self.attributes = attributes
    }
}

struct SensorReading: Equatable, Sendable {
    let value: Double
    let unit: String

    static func parse(_ entity: HAEntityState?) -> SensorReading? {
        guard let entity else { return nil }
        let normalized = entity.state.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !["unavailable", "unknown", "none"].contains(normalized.lowercased()),
              let value = Double(normalized.replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let unit = entity.attributes["unit_of_measurement"]?.stringValue ?? ""
        return SensorReading(value: value, unit: unit)
    }
}

struct CameraReading: Equatable, Sendable {
    var state: String
    var motionTime: String?
    var motionType: String?
    var streamAddress: URL?
    var snapshotURL: URL?
    var temperature: SensorReading?
    var humidity: SensorReading?
    var fetchedAt: Date
    var haReachable: Bool

    static let empty = CameraReading(
        state: "unknown",
        motionTime: nil,
        motionType: nil,
        streamAddress: nil,
        snapshotURL: nil,
        temperature: nil,
        humidity: nil,
        fetchedAt: .distantPast,
        haReachable: false
    )
}

enum CameraDataParser {
    static func cameraReading(
        camera: HAEntityState,
        temperature: HAEntityState?,
        humidity: HAEntityState?,
        now: Date = .now
    ) -> CameraReading {
        let streamAddress = camera.attributes["stream_address"]?.stringValue
            .flatMap(URL.init(string:))
        let snapshotURL = camera.attributes["entity_picture"]?.stringValue
            .flatMap(URL.init(string:))
        return CameraReading(
            state: camera.state,
            motionTime: camera.attributes["motion_video_time"]?.stringValue,
            motionType: camera.attributes["motion_video_type"]?.stringValue,
            streamAddress: streamAddress,
            snapshotURL: snapshotURL,
            temperature: SensorReading.parse(temperature),
            humidity: SensorReading.parse(humidity),
            fetchedAt: now,
            haReachable: true
        )
    }
}

/// Tracks changes of the camera's last-motion timestamp. The first reading is
/// treated as baseline, so launching the app does not fire a stale alert.
struct MotionTracker: Equatable, Sendable {
    private(set) var lastSeenTime: String?
    private(set) var lastMotionAt: Date?

    mutating func update(motionTime: String?, now: Date = .now) -> Bool {
        guard let motionTime else { return false }
        if lastSeenTime == nil {
            lastSeenTime = motionTime
            return false
        }
        guard motionTime != lastSeenTime else { return false }
        lastSeenTime = motionTime
        lastMotionAt = now
        return true
    }

    func isActive(now: Date = .now, window: TimeInterval = 15) -> Bool {
        guard let lastMotionAt else { return false }
        return now.timeIntervalSince(lastMotionAt) < window
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var cameraName: String
    var streamURL: String
    var haBaseURL: String
    var tokenPath: String
    var cameraEntity: String
    var temperatureEntity: String
    var humidityEntity: String
    var showOnLaunch: Bool
    var floatOnTop: Bool
    var allSpaces: Bool
    var notifyOnMotion: Bool
    var showOnMotion: Bool
    var climateInMenuBar: Bool

    static let `default` = AppSettings(
        cameraName: "Live Camera",
        streamURL: "http://127.0.0.1:1984/api/stream.m3u8?src=camera",
        haBaseURL: "",
        tokenPath: "~/.config/ha-pip-cam/token",
        cameraEntity: "",
        temperatureEntity: "",
        humidityEntity: "",
        showOnLaunch: false,
        floatOnTop: true,
        allSpaces: true,
        notifyOnMotion: true,
        showOnMotion: false,
        climateInMenuBar: true
    )

    private static let storageKey = "HAPiPCamSettings"

    var displayTitle: String {
        let trimmed = cameraName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Live Camera" : trimmed
    }

    var tokenURL: URL? {
        let trimmed = tokenPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    var stream: URL? {
        let trimmed = streamURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var haBase: URL? {
        let trimmed = haBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    var hasHomeAssistantConfigured: Bool {
        haBase != nil && !cameraEntity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func load(from defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return .default }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

extension AppSettings {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AppSettings.default
        func value<T: Decodable>(_ key: CodingKeys, _ defaultValue: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? defaultValue
        }
        cameraName = try value(.cameraName, fallback.cameraName)
        streamURL = try value(.streamURL, fallback.streamURL)
        haBaseURL = try value(.haBaseURL, fallback.haBaseURL)
        tokenPath = try value(.tokenPath, fallback.tokenPath)
        cameraEntity = try value(.cameraEntity, fallback.cameraEntity)
        temperatureEntity = try value(.temperatureEntity, fallback.temperatureEntity)
        humidityEntity = try value(.humidityEntity, fallback.humidityEntity)
        showOnLaunch = try value(.showOnLaunch, fallback.showOnLaunch)
        floatOnTop = try value(.floatOnTop, fallback.floatOnTop)
        allSpaces = try value(.allSpaces, fallback.allSpaces)
        notifyOnMotion = try value(.notifyOnMotion, fallback.notifyOnMotion)
        showOnMotion = try value(.showOnMotion, fallback.showOnMotion)
        climateInMenuBar = try value(.climateInMenuBar, fallback.climateInMenuBar)
    }
}

struct MotionReaction: Equatable {
    let notify: Bool
    let showPanel: Bool

    init(settings: AppSettings, panelVisible: Bool) {
        notify = !panelVisible && settings.notifyOnMotion
        showPanel = !panelVisible && settings.showOnMotion
    }
}

enum MenuBarClimate {
    /// Short menu bar text such as "21.6° 53%". Empty while Home Assistant is offline
    /// so stale readings are never displayed as live values.
    static func text(temperature: SensorReading?, humidity: SensorReading?, haOffline: Bool) -> String {
        guard !haOffline else { return "" }
        var parts: [String] = []
        if let temperature {
            parts.append(String(format: "%.1f°", temperature.value))
        }
        if let humidity {
            parts.append(String(format: "%.0f%%", humidity.value))
        }
        return parts.joined(separator: " ")
    }
}
