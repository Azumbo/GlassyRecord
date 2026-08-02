import Foundation

/// Общий контейнер между приложением и Broadcast Extension.
enum AppGroup {
    static let identifier = "group.com.azumbo.glassyrecord.shared"
    static let broadcastExtensionBundleID = "com.azumbo.glassyrecord.app.broadcast"
    static let fallbackBroadcastExtensionBundleID = "com.azumbo.glassyrecord.app.broadcast"

    /// Без fatalError — extension крашится и выглядит как «зависание» приложения.
    static var containerURLOptional: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var containerURL: URL {
        guard let url = containerURLOptional else {
            fatalError("App Group '\(identifier)' недоступен. Включите App Groups в Xcode и Developer Portal.")
        }
        return url
    }

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    static var isConfigured: Bool {
        containerURLOptional != nil && sharedDefaults != nil
    }

    static var diagnosticMessage: String {
        if isConfigured {
            return "App Group: OK (\(identifier))"
        }
        return """
        App Group не настроен (\(identifier)).
        В Xcode → Signing & Capabilities для GlassyRecord и GlassyRecordBroadcastUpload включите App Groups.
        На developer.apple.com создайте группу и привяжите к обоим Bundle ID.
        """
    }
}
