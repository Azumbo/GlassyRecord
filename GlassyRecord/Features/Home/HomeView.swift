import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var settingsStore: SettingsStore
    @State private var pulse = false

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(spacing: 28) {
                    header
                    recordButton
                    quickSettings
                    glassesCard
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
        }
        .navigationTitle("Glassy Record")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Настройки")
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(.systemBackground),
                Color.accentColor.opacity(0.08)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Запись экрана + Face Cam")
                .font(.title2.weight(.semibold))
            Text("С наложением очков Monokol MK295 в реальном времени")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            coordinator.showRecording()
        } label: {
            ZStack {
                Circle()
                    .fill(GlassyTheme.recordRed.opacity(0.2))
                    .frame(width: pulse ? 120 : 100, height: pulse ? 120 : 100)
                    .animation(GlassyTheme.pulse, value: pulse)

                Circle()
                    .fill(GlassyTheme.recordRed)
                    .frame(width: 88, height: 88)
                    .overlay {
                        Image(systemName: "record.circle")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: GlassyTheme.recordRed.opacity(0.5), radius: 16, y: 6)
            }
            .frame(height: 140)
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
        .accessibilityLabel("Начать запись")
    }

    private var quickSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Быстрые настройки")
                .font(.headline)

            HStack(spacing: 12) {
                ForEach(RecordingQuality.allCases) { quality in
                    QualityChip(
                        title: quality.displayName,
                        isSelected: settingsStore.settings.quality == quality
                    ) {
                        settingsStore.update { $0.quality = quality }
                    }
                }
            }

            HStack(spacing: 12) {
                ToggleChip(
                    title: "Микрофон",
                    systemImage: "mic.fill",
                    isOn: settingsStore.settings.microphoneEnabled
                ) {
                    settingsStore.update { $0.microphoneEnabled.toggle() }
                }

                Picker("Face Cam", selection: Binding(
                    get: { settingsStore.settings.faceCamCorner },
                    set: { corner in settingsStore.update { $0.faceCamCorner = corner } }
                )) {
                    ForEach(FaceCamCorner.allCases) { corner in
                        Text(corner.displayName).tag(corner)
                    }
                }
                .pickerStyle(.menu)
                .liquidGlass(cornerRadius: 12)
            }
        }
        .padding(16)
        .liquidGlass()
    }

    private var glassesCard: some View {
        GlassesSelectionCard(
            isEnabled: settingsStore.settings.glassesEnabledByDefault,
            selectedColor: settingsStore.settings.glassesColor,
            lensTransparency: settingsStore.settings.lensTransparency
        ) { enabled in
            settingsStore.update { $0.glassesEnabledByDefault = enabled }
        } onColorChange: { color in
            settingsStore.update { $0.glassesColor = color }
        }
    }
}

struct QualityChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemFill))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ToggleChip: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color(.secondarySystemFill))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .environmentObject(AppCoordinator(settingsStore: SettingsStore(
                modelContext: ModelContext(PersistenceController.shared.container)
            )))
            .environmentObject(SettingsStore(
                modelContext: ModelContext(PersistenceController.shared.container)
            ))
    }
}

import SwiftData
