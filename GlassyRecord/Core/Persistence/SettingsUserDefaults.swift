import Foundation

/// Хранение настроек без SwiftData — совместимо с iOS 16+.
enum SettingsUserDefaults {
    private static let key = "com.glassyrecord.app.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return AppSettings()
        }
        if var settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings.applyPipFaceSizePreset(settings.pipFaceSizePreset)
            return settings
        }
        // Старые сохранения без новых полей (например pipAspectRatio).
        if var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if object["pipAspectRatio"] == nil {
                object["pipAspectRatio"] = PiPAspectRatio.portrait9x16.rawValue
            }
            if object["faceCamNormalizedX"] == nil || object["faceCamNormalizedY"] == nil {
                let corner = FaceCamCorner(rawValue: object["faceCamCorner"] as? String ?? "") ?? .bottomTrailing
                object["faceCamNormalizedX"] = Double(corner.normalizedPosition.x)
                object["faceCamNormalizedY"] = Double(corner.normalizedPosition.y)
            }
            if let migrated = try? JSONSerialization.data(withJSONObject: object),
               var settings = try? JSONDecoder().decode(AppSettings.self, from: migrated) {
                settings.applyPipFaceSizePreset(settings.pipFaceSizePreset)
                return settings
            }
        }
        return AppSettings()
    }

    static func save(_ settings: AppSettings) {
        var normalized = settings
        normalized.applyPipFaceSizePreset(normalized.pipFaceSizePreset)
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
