import Foundation

/// Хранение настроек без SwiftData — совместимо с iOS 16+.
enum SettingsUserDefaults {
    private static let key = "com.glassyrecord.app.settings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              var settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        settings.applyPipFaceSizePreset(settings.pipFaceSizePreset)
        return settings
    }

    static func save(_ settings: AppSettings) {
        var normalized = settings
        normalized.applyPipFaceSizePreset(normalized.pipFaceSizePreset)
        guard let data = try? JSONEncoder().encode(normalized) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
