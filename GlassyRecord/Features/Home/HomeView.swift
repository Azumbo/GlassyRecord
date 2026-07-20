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
                    demoCard
                    quickSettings
                    glassesCard
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
            }
        }
        .navigationTitle(L10n.t("app.name"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.showSettings()
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(L10n.t("nav.settings"))
            }
        }
        .onAppear {
            UsageTracker.shared.track(.homeOpened)
        }
    }

    private var background: some View {
        GlassyTheme.backgroundGrouped
            .ignoresSafeArea()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.t("home.headline"))
                .font(.title2.weight(.semibold))
            Text(L10n.t("home.subtitle"))
                .font(.subheadline)
                .foregroundStyle(GlassyTheme.labelSecondary)
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
                    .fill(GlassyTheme.record.opacity(0.15))
                    .frame(width: pulse ? 120 : 100, height: pulse ? 120 : 100)
                    .animation(GlassyTheme.pulse, value: pulse)

                Circle()
                    .fill(GlassyTheme.record)
                    .frame(width: 88, height: 88)
                    .overlay {
                        Image(systemName: "record.circle")
                            .font(.system(size: 36, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .shadow(color: GlassyTheme.record.opacity(0.25), radius: 8, y: 4)
            }
            .frame(height: 140)
        }
        .buttonStyle(.plain)
        .onAppear { pulse = true }
        .accessibilityLabel(L10n.t("home.record.a11y"))
    }

    private var demoCard: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            coordinator.showDemoRecording()
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "safari.fill")
                    .font(.title2)
                    .foregroundStyle(GlassyTheme.tint)
                    .frame(width: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("home.demo.title"))
                        .font(.headline)
                        .foregroundStyle(GlassyTheme.labelPrimary)
                    Text(L10n.t("home.demo.body"))
                        .font(.caption)
                        .foregroundStyle(GlassyTheme.labelSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(GlassyTheme.labelTertiary)
            }
            .padding(16)
            .liquidGlass()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.t("home.demo.a11y"))
    }

    private var quickSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("home.quick_settings"))
                .font(.headline)

            HStack(spacing: 12) {
                ForEach(RecordingQuality.allCases) { quality in
                    QualityChip(
                        title: quality.displayName,
                        isSelected: settingsStore.settings.quality == quality
                    ) {
                        settingsStore.update { $0.quality = quality }
                        UsageTracker.shared.track(.qualityChanged, params: ["quality": quality.rawValue])
                    }
                }
            }

            HStack(spacing: 12) {
                ToggleChip(
                    title: L10n.t("home.mic"),
                    systemImage: "mic.fill",
                    isOn: settingsStore.settings.microphoneEnabled
                ) {
                    settingsStore.update { $0.microphoneEnabled.toggle() }
                    UsageTracker.shared.track(
                        .micToggled,
                        params: ["enabled": String(settingsStore.settings.microphoneEnabled)]
                    )
                }

                Picker(L10n.t("home.face_cam"), selection: Binding(
                    get: { settingsStore.settings.faceCamCorner },
                    set: { corner in
                        settingsStore.update { $0.faceCamCorner = corner }
                        UsageTracker.shared.track(.faceCamCornerChanged, params: ["corner": corner.rawValue])
                    }
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
            isEnabled: Binding(
                get: { settingsStore.settings.glassesEnabledByDefault },
                set: { enabled in
                    settingsStore.update { $0.glassesEnabledByDefault = enabled }
                    UsageTracker.shared.track(.glassesDefaultToggled, params: ["enabled": String(enabled)])
                }
            ),
            selectedColor: settingsStore.settings.glassesColor,
            lensTransparency: settingsStore.settings.lensTransparency,
            onColorChange: { color in
                settingsStore.update { $0.glassesColor = color }
                UsageTracker.shared.track(.glassesColorChanged, params: ["color": color.rawValue, "source": "home"])
            }
        )
    }
}

struct QualityChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(SelectableCapsuleStyle(isSelected: isSelected))
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
        }
        .buttonStyle(SelectableCapsuleStyle(isSelected: isOn))
    }
}

#Preview {
    NavigationStack {
        HomeView()
            .environmentObject(AppCoordinator(settingsStore: SettingsStore()))
            .environmentObject(SettingsStore())
    }
}
