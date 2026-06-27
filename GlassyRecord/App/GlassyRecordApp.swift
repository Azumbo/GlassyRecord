import SwiftUI
import SwiftData

@main
struct GlassyRecordApp: App {
    private let persistence = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(persistence.container)
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var settingsStore: SettingsStore
    @StateObject private var coordinator: AppCoordinator

    init() {
        let persistence = PersistenceController.shared
        // Временный контекст для инициализации; заменяется через environment.
        let container = persistence.container
        let context = ModelContext(container)
        let store = SettingsStore(persistence: persistence, modelContext: context)
        _settingsStore = StateObject(wrappedValue: store)
        _coordinator = StateObject(wrappedValue: AppCoordinator(settingsStore: store))
    }

    var body: some View {
        NavigationStack(path: $coordinator.path) {
            HomeView()
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .recording:
                        RecordingOverlayView()
                    case .editor(let session):
                        EditorView(session: session)
                    case .settings:
                        SettingsView()
                    }
                }
        }
        .environmentObject(coordinator)
        .environmentObject(settingsStore)
        .onAppear {
            // Синхронизируем контекст SwiftData из environment.
            settingsStore.reloadIfNeeded(context: modelContext)
        }
        .alert("Ошибка", isPresented: .init(
            get: { coordinator.alertMessage != nil },
            set: { if !$0 { coordinator.dismissAlert() } }
        )) {
            Button("OK", role: .cancel) { coordinator.dismissAlert() }
        } message: {
            Text(coordinator.alertMessage ?? "")
        }
    }
}

extension SettingsStore {
    func reloadIfNeeded(context: ModelContext) {
        settings = PersistenceController.shared.loadSettings(context: context)
    }
}
