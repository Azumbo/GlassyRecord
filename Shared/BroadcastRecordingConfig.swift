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

/// Снимок статуса для IPC через файл (надёжнее UserDefaults между app ↔ extension).
private struct BroadcastStatusPayload: Codable {
    var state: String
    var screenOutputPath: String?
    var errorMessage: String?
    var startTimestamp: TimeInterval
    var extensionHeartbeat: TimeInterval
    var extensionLastEvent: String?
    var updatedAt: TimeInterval
}

/// Чтение/запись конфигурации и статуса broadcast в App Group.
enum BroadcastConfigStore {
    private static var defaults: UserDefaults? { AppGroup.sharedDefaults }
    private static let configFileName = "broadcast_config.json"
    private static let statusFileName = "broadcast_status.json"
    private static let ioQueue = DispatchQueue(label: "com.glassyrecord.broadcast.status")

    static func saveConfig(_ config: BroadcastRecordingConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults?.set(data, forKey: BroadcastDefaultsKey.config)
        writeData(data, fileName: configFileName)

        // Не затираем handoff, если extension уже пишет/финиширует/закончил файл.
        switch state {
        case .recording, .finalizing, .finished:
            break
        case .idle, .failed:
            applyStatusMutation { payload in
                payload.state = BroadcastState.idle.rawValue
                payload.screenOutputPath = nil
                payload.errorMessage = nil
            }
        }
        defaults?.synchronize()
    }

    static func loadConfig() -> BroadcastRecordingConfig? {
        if let data = defaults?.data(forKey: BroadcastDefaultsKey.config),
           let config = try? JSONDecoder().decode(BroadcastRecordingConfig.self, from: data) {
            return config
        }
        guard let data = readData(fileName: configFileName),
              let config = try? JSONDecoder().decode(BroadcastRecordingConfig.self, from: data) else {
            return nil
        }
        return config
    }

    static var state: BroadcastState {
        get {
            if let raw = mergedStatus().state, let value = BroadcastState(rawValue: raw) {
                return value
            }
            return .idle
        }
        set {
            applyStatusMutation { $0.state = newValue.rawValue }
        }
    }

    static var screenOutputPath: String? {
        mergedStatus().screenOutputPath
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
        mergedStatus().errorMessage
    }

    static var startTimestamp: TimeInterval {
        mergedStatus().startTimestamp
    }

    static var extensionHeartbeatAt: TimeInterval {
        mergedStatus().extensionHeartbeat
    }

    static var extensionLastEvent: String? {
        mergedStatus().extensionLastEvent
    }

    static var hasExtensionHeartbeat: Bool {
        extensionHeartbeatAt > 0
    }

    static func markRecordingStarted() {
        applyStatusMutation { payload in
            payload.state = BroadcastState.recording.rawValue
            payload.startTimestamp = Date().timeIntervalSince1970
            payload.screenOutputPath = nil
            payload.errorMessage = nil
        }
    }

    static func markFinalizing() {
        applyStatusMutation { payload in
            payload.state = BroadcastState.finalizing.rawValue
        }
        markExtensionAlive(event: "finalizing")
    }

    static func markScreenFinished(relativeFileName: String) {
        applyStatusMutation { payload in
            payload.screenOutputPath = relativeFileName
            payload.state = BroadcastState.finished.rawValue
            payload.errorMessage = nil
        }
    }

    /// Обратная совместимость со старыми absolute path.
    static func markScreenFinished(path: String) {
        markScreenFinished(relativeFileName: path)
    }

    static func markFailed(_ message: String) {
        applyStatusMutation { payload in
            payload.state = BroadcastState.failed.rawValue
            payload.errorMessage = message
        }
    }

    static func markCancelled() {
        applyStatusMutation { payload in
            payload.state = BroadcastState.idle.rawValue
            payload.errorMessage = nil
            payload.startTimestamp = 0
            payload.screenOutputPath = nil
        }
    }

    static func clearFailure() {
        applyStatusMutation { payload in
            if payload.state == BroadcastState.failed.rawValue {
                payload.state = BroadcastState.idle.rawValue
            }
            payload.errorMessage = nil
        }
    }

    static func touchExtensionHeartbeat() {
        let now = Date().timeIntervalSince1970
        let last = extensionHeartbeatAt
        guard now - last >= 1 else { return }
        applyStatusMutation { payload in
            payload.extensionHeartbeat = now
        }
    }

    static func markExtensionAlive(event: String, extra: String = "") {
        let stamp = Date().timeIntervalSince1970
        let value = extra.isEmpty ? event : "\(event);\(String(extra.prefix(80)))"
        applyStatusMutation { payload in
            payload.extensionHeartbeat = stamp
            payload.extensionLastEvent = value
        }
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
        applyStatusMutation { payload in
            payload.state = BroadcastState.idle.rawValue
            payload.screenOutputPath = nil
            payload.errorMessage = nil
            payload.startTimestamp = 0
            payload.extensionHeartbeat = 0
            payload.extensionLastEvent = nil
        }
    }

    // MARK: - Dual store (UserDefaults + file)

    private struct MergedStatus {
        var state: String?
        var screenOutputPath: String?
        var errorMessage: String?
        var startTimestamp: TimeInterval
        var extensionHeartbeat: TimeInterval
        var extensionLastEvent: String?
    }

    private static func mergedStatus() -> MergedStatus {
        let file = readStatusPayload()
        let defaultsState = defaults?.string(forKey: BroadcastDefaultsKey.state)
        let defaultsPath = defaults?.string(forKey: BroadcastDefaultsKey.screenOutputPath)
        let defaultsError = defaults?.string(forKey: BroadcastDefaultsKey.errorMessage)
        let defaultsStart = defaults?.double(forKey: BroadcastDefaultsKey.startTimestamp) ?? 0
        let defaultsHB = defaults?.double(forKey: BroadcastDefaultsKey.extensionHeartbeat) ?? 0
        let defaultsEvent = defaults?.string(forKey: BroadcastDefaultsKey.extensionLastEvent)

        // Файл — основной канал; UserDefaults — fallback/legacy.
        return MergedStatus(
            state: file?.state ?? defaultsState,
            screenOutputPath: nonEmpty(file?.screenOutputPath) ?? nonEmpty(defaultsPath),
            errorMessage: nonEmpty(file?.errorMessage) ?? nonEmpty(defaultsError),
            startTimestamp: max(file?.startTimestamp ?? 0, defaultsStart),
            extensionHeartbeat: max(file?.extensionHeartbeat ?? 0, defaultsHB),
            extensionLastEvent: nonEmpty(file?.extensionLastEvent) ?? nonEmpty(defaultsEvent)
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func applyStatusMutation(_ mutate: (inout BroadcastStatusPayload) -> Void) {
        ioQueue.sync {
            var payload = readStatusPayload() ?? BroadcastStatusPayload(
                state: BroadcastState.idle.rawValue,
                screenOutputPath: nil,
                errorMessage: nil,
                startTimestamp: 0,
                extensionHeartbeat: 0,
                extensionLastEvent: nil,
                updatedAt: 0
            )
            mutate(&payload)
            payload.updatedAt = Date().timeIntervalSince1970
            writeStatusPayload(payload)

            defaults?.set(payload.state, forKey: BroadcastDefaultsKey.state)
            if let path = payload.screenOutputPath {
                defaults?.set(path, forKey: BroadcastDefaultsKey.screenOutputPath)
            } else {
                defaults?.removeObject(forKey: BroadcastDefaultsKey.screenOutputPath)
            }
            if let error = payload.errorMessage {
                defaults?.set(error, forKey: BroadcastDefaultsKey.errorMessage)
            } else {
                defaults?.removeObject(forKey: BroadcastDefaultsKey.errorMessage)
            }
            if payload.startTimestamp > 0 {
                defaults?.set(payload.startTimestamp, forKey: BroadcastDefaultsKey.startTimestamp)
            } else {
                defaults?.removeObject(forKey: BroadcastDefaultsKey.startTimestamp)
            }
            if payload.extensionHeartbeat > 0 {
                defaults?.set(payload.extensionHeartbeat, forKey: BroadcastDefaultsKey.extensionHeartbeat)
            } else {
                defaults?.removeObject(forKey: BroadcastDefaultsKey.extensionHeartbeat)
            }
            if let event = payload.extensionLastEvent {
                defaults?.set(event, forKey: BroadcastDefaultsKey.extensionLastEvent)
            } else {
                defaults?.removeObject(forKey: BroadcastDefaultsKey.extensionLastEvent)
            }
            defaults?.synchronize()
        }
    }

    private static func statusFileURL() -> URL? {
        AppGroup.containerURLOptional?.appendingPathComponent(statusFileName)
    }

    private static func configFileURL() -> URL? {
        AppGroup.containerURLOptional?.appendingPathComponent(configFileName)
    }

    private static func readStatusPayload() -> BroadcastStatusPayload? {
        guard let url = statusFileURL(),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BroadcastStatusPayload.self, from: data)
    }

    private static func writeStatusPayload(_ payload: BroadcastStatusPayload) {
        guard let url = statusFileURL(),
              let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    private static func readData(fileName: String) -> Data? {
        guard let url = AppGroup.containerURLOptional?.appendingPathComponent(fileName) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func writeData(_ data: Data, fileName: String) {
        guard let url = AppGroup.containerURLOptional?.appendingPathComponent(fileName) else { return }
        try? data.write(to: url, options: [.atomic])
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
