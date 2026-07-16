import SwiftUI

@main
struct GlassyRecordApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var settingsStore = SettingsStore()
    @StateObject private var coordinator: AppCoordinator

    init() {
        let store = SettingsStore()
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
                    case .usageStats:
                        UsageStatsView()
                    }
                }
        }
        .environmentObject(coordinator)
        .environmentObject(settingsStore)
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
