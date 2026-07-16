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

    func showRecording() {
        path.append(AppRoute.recording)
        UsageTracker.shared.track(.recordingOpened)
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
        self.settings = SettingsUserDefaults.load()
    }

    func update(_ transform: (inout AppSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy
        SettingsUserDefaults.save(copy)
    }
}
