import Foundation

/// Настройки записи, которые main app передаёт в extension через App Group.
struct BroadcastRecordingConfig: Codable, Sendable, Equatable {
    var quality: String
    var microphoneEnabled: Bool
    var systemAudioEnabled: Bool
    var faceCamNormalizedX: Double
    var faceCamNormalizedY: Double
    var faceCamScale: Double
    var faceCamShape: String
    var faceCamMirrored: Bool
    var glassesEnabled: Bool
    var glassesColor: String
}

/// Чтение/запись конфигурации и статуса broadcast в App Group.
enum BroadcastConfigStore {
    private static var defaults: UserDefaults? { AppGroup.sharedDefaults }

    static func saveConfig(_ config: BroadcastRecordingConfig) {
        guard let defaults else { return }
        let data = try? JSONEncoder().encode(config)
        defaults.set(data, forKey: BroadcastDefaultsKey.config)
        defaults.set(BroadcastState.idle.rawValue, forKey: BroadcastDefaultsKey.state)
        defaults.removeObject(forKey: BroadcastDefaultsKey.screenOutputPath)
        defaults.removeObject(forKey: BroadcastDefaultsKey.errorMessage)
    }

    static func loadConfig() -> BroadcastRecordingConfig? {
        guard let defaults,
              let data = defaults.data(forKey: BroadcastDefaultsKey.config) else { return nil }
        return try? JSONDecoder().decode(BroadcastRecordingConfig.self, from: data)
    }

    static var state: BroadcastState {
        get {
            guard let defaults,
                  let raw = defaults.string(forKey: BroadcastDefaultsKey.state),
                  let value = BroadcastState(rawValue: raw) else { return .idle }
            return value
        }
        set {
            defaults?.set(newValue.rawValue, forKey: BroadcastDefaultsKey.state)
        }
    }

    static var screenOutputPath: String? {
        defaults?.string(forKey: BroadcastDefaultsKey.screenOutputPath)
    }

    static var errorMessage: String? {
        defaults?.string(forKey: BroadcastDefaultsKey.errorMessage)
    }

    static var startTimestamp: TimeInterval {
        defaults?.double(forKey: BroadcastDefaultsKey.startTimestamp) ?? 0
    }

    static func markRecordingStarted() {
        state = .recording
        defaults?.set(Date().timeIntervalSince1970, forKey: BroadcastDefaultsKey.startTimestamp)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.screenOutputPath)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.errorMessage)
    }

    static func markScreenFinished(path: String) {
        defaults?.set(path, forKey: BroadcastDefaultsKey.screenOutputPath)
        state = .finished
    }

    static func markFailed(_ message: String) {
        state = .failed
        defaults?.set(message, forKey: BroadcastDefaultsKey.errorMessage)
    }

    static func reset() {
        state = .idle
        defaults?.removeObject(forKey: BroadcastDefaultsKey.screenOutputPath)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.errorMessage)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.startTimestamp)
    }
}

enum BroadcastState: String, Codable {
    case idle
    case recording
    case finished
    case failed
}

enum BroadcastDefaultsKey {
    static let config = "broadcast.config"
    static let state = "broadcast.state"
    static let screenOutputPath = "broadcast.screenOutputPath"
    static let errorMessage = "broadcast.errorMessage"
    static let startTimestamp = "broadcast.startTimestamp"
}
