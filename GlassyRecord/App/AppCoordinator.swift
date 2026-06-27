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
    }

    func showEditor(for session: RecordingSession) {
        path.append(AppRoute.editor(session))
    }

    func showSettings() {
        path.append(AppRoute.settings)
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

/// Реактивное хранилище настроек с Combine.
@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings

    private let persistence: PersistenceController
    private let modelContext: ModelContext

  init(persistence: PersistenceController = .shared, modelContext: ModelContext) {
        self.persistence = persistence
        self.modelContext = modelContext
        self.settings = persistence.loadSettings(context: modelContext)
    }

    func update(_ transform: (inout AppSettings) -> Void) {
        var copy = settings
        transform(&copy)
        settings = copy
        persistence.saveSettings(copy, context: modelContext)
    }
}

import SwiftData
