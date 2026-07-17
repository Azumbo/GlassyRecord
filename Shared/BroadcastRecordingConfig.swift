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
        // Не затираем handoff, если extension уже пишет/финиширует/закончил файл.
        switch state {
        case .recording, .finalizing, .finished:
            break
        case .idle, .failed:
            defaults.set(BroadcastState.idle.rawValue, forKey: BroadcastDefaultsKey.state)
            defaults.removeObject(forKey: BroadcastDefaultsKey.screenOutputPath)
            defaults.removeObject(forKey: BroadcastDefaultsKey.errorMessage)
        }
        defaults.synchronize()
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
            defaults?.synchronize()
        }
    }

    static var screenOutputPath: String? {
        defaults?.string(forKey: BroadcastDefaultsKey.screenOutputPath)
    }

    /// Полный URL к MP4 в App Group (relative или absolute path из extension).
    static var screenOutputURL: URL? {
        guard let path = screenOutputPath, !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        guard let container = AppGroup.containerURLOptional else { return nil }
        return container.appendingPathComponent(path)
    }

    static var errorMessage: String? {
        defaults?.string(forKey: BroadcastDefaultsKey.errorMessage)
    }

    static var startTimestamp: TimeInterval {
        defaults?.double(forKey: BroadcastDefaultsKey.startTimestamp) ?? 0
    }

    static var extensionHeartbeatAt: TimeInterval {
        defaults?.double(forKey: BroadcastDefaultsKey.extensionHeartbeat) ?? 0
    }

    static var extensionLastEvent: String? {
        defaults?.string(forKey: BroadcastDefaultsKey.extensionLastEvent)
    }

    static func markRecordingStarted() {
        state = .recording
        defaults?.set(Date().timeIntervalSince1970, forKey: BroadcastDefaultsKey.startTimestamp)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.screenOutputPath)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.errorMessage)
        defaults?.synchronize()
    }

    static func markFinalizing() {
        state = .finalizing
        markExtensionAlive(event: "finalizing")
    }

    static func markScreenFinished(relativeFileName: String) {
        defaults?.set(relativeFileName, forKey: BroadcastDefaultsKey.screenOutputPath)
        state = .finished
        defaults?.synchronize()
    }

    /// Обратная совместимость со старыми absolute path.
    static func markScreenFinished(path: String) {
        markScreenFinished(relativeFileName: path)
    }

    static func markFailed(_ message: String) {
        state = .failed
        defaults?.set(message, forKey: BroadcastDefaultsKey.errorMessage)
        defaults?.synchronize()
    }

    static func markCancelled() {
        state = .idle
        defaults?.removeObject(forKey: BroadcastDefaultsKey.errorMessage)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.startTimestamp)
        defaults?.synchronize()
    }

    static func clearFailure() {
        if state == .failed {
            state = .idle
        }
        defaults?.removeObject(forKey: BroadcastDefaultsKey.errorMessage)
        defaults?.synchronize()
    }

    static func touchExtensionHeartbeat() {
        let now = Date().timeIntervalSince1970
        let last = defaults?.double(forKey: BroadcastDefaultsKey.extensionHeartbeat) ?? 0
        guard now - last >= 1 else { return }
        defaults?.set(now, forKey: BroadcastDefaultsKey.extensionHeartbeat)
    }

    static func markExtensionAlive(event: String, extra: String = "") {
        let stamp = Date().timeIntervalSince1970
        defaults?.set(stamp, forKey: BroadcastDefaultsKey.extensionHeartbeat)
        let value = extra.isEmpty ? event : "\(event);\(String(extra.prefix(80)))"
        defaults?.set(value, forKey: BroadcastDefaultsKey.extensionLastEvent)
        defaults?.synchronize()
    }

    static func diagnosticSnapshot(isScreenCaptured: Bool? = nil) -> String {
        let hb = extensionHeartbeatAt
        let age: String
        if hb > 0 {
            age = String(format: "%.1fs", Date().timeIntervalSince1970 - hb)
        } else {
            age = "none"
        }
        let path = screenOutputPath ?? "nil"
        let err = errorMessage.map { String($0.prefix(80)) } ?? "nil"
        let event = extensionLastEvent ?? "nil"
        var parts = [
            "state=\(state.rawValue)",
            "hb_age=\(age)",
            "event=\(event)",
            "path=\(path)",
            "err=\(err)"
        ]
        if let isScreenCaptured {
            parts.append("captured=\(isScreenCaptured)")
        }
        return parts.joined(separator: ";")
    }

    static func reset() {
        state = .idle
        defaults?.removeObject(forKey: BroadcastDefaultsKey.screenOutputPath)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.errorMessage)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.startTimestamp)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.extensionHeartbeat)
        defaults?.removeObject(forKey: BroadcastDefaultsKey.extensionLastEvent)
        defaults?.synchronize()
    }
}

enum BroadcastState: String, Codable {
    case idle
    case recording
    case finalizing
    case finished
    case failed
}

enum BroadcastDefaultsKey {
    static let config = "broadcast.config"
    static let state = "broadcast.state"
    static let screenOutputPath = "broadcast.screenOutputPath"
    static let errorMessage = "broadcast.errorMessage"
    static let startTimestamp = "broadcast.startTimestamp"
    static let extensionHeartbeat = "broadcast.extensionHeartbeat"
    static let extensionLastEvent = "broadcast.extensionLastEvent"
}