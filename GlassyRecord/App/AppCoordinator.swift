import Combine
import SwiftUI

/// Coordinator-паттерн для навигации между экранами приложения.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var path = NavigationPath()
    @Published var presentedSheet: AppRoute?
    @Published var alertMessage: String?

    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Если true — после старта записи сразу открыть демо-браузер с видимыми тапами.
    @Published var openDemoBrowserWhenRecordingStarts = false

    func showRecording(openDemoOnStart: Bool = false) {
        openDemoBrowserWhenRecordingStarts = openDemoOnStart
        path.append(AppRoute.recording)
        UsageTracker.shared.track(
            .recordingOpened,
            params: ["demo": openDemoOnStart ? "true" : "false"]
        )
    }

    func showDemoRecording() {
        showRecording(openDemoOnStart: true)
    }

    func showEditor(for session: RecordingSession) {
        path.append(AppRoute.editor(session))
        UsageTracker.shared.track(
            .editorOpened,
            params: [
                "duration_s": String(format: "%.1f", session.duration),
                "glasses": String(session.glassesEnabled),
                "quality": session.quality.rawValue
            ]
        )
    }

    func showSettings() {
        path.append(AppRoute.settings)
        UsageTracker.shared.track(.settingsOpened)
    }

    func showUsageStats() {
        path.append(AppRoute.usageStats)
    }

    func popToRoot() {
        path.removeLast(path.count)
    }

    func presentError(_ error: Error) {
        alertMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    func dismissAlert() {
        alertMessage = nil
    }
}

/// Реактивное хранилище настроек.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings

    init() {
        let loaded = SettingsUserDefaults.load()
        self.settings = loaded
        L10n.localeOverride = loaded.appLanguage.locale
    }

    func update(_ transform: (inout AppSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy
        SettingsUserDefaults.save(copy)
        L10n.localeOverride = copy.appLanguage.locale
    }
}
