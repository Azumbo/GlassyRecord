import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore

    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        Form {
            Section {
                Button {
                    coordinator.showUsageStats()
                } label: {
                    Label("Статистика использования", systemImage: "chart.bar")
                }
            } footer: {
                Text("Счётчики локально на устройстве. Скопируйте отчёт и вставьте в Cursor, чтобы понять, что удалить.")
            }

            qualitySection
            faceCamSection
            audioSection
            glassesSection
            touchSection
            gesturesSection
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var qualitySection: some View {
        Section("Качество") {
            Picker("Разрешение", selection: binding(\.quality, feature: .qualityChanged, param: { ["quality": $0.rawValue, "source": "settings"] })) {
                ForEach(RecordingQuality.allCases) { q in
                    Text(q.displayName).tag(q)
                }
            }
            Toggle("Экономия энергии", isOn: binding(\.lowPowerModeAware, feature: .lowPowerAwareToggled, param: { ["enabled": String($0)] }))
        }
    }

    private var faceCamSection: some View {
        Section("Face Cam") {
            Picker("Положение", selection: binding(\.faceCamCorner, feature: .faceCamCornerChanged, param: { ["corner": $0.rawValue, "source": "settings"] })) {
                ForEach(FaceCamCorner.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }
            Picker("Форма", selection: binding(\.faceCamShape, feature: .faceCamShapeChanged, param: { ["shape": $0.rawValue] })) {
                ForEach(FaceCamShape.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            Toggle("Зеркальное отражение", isOn: binding(\.faceCamMirrored, feature: .faceCamMirrorToggled, param: { ["enabled": String($0)] }))
            Picker("Крупность PiP", selection: faceCamSizePresetBinding) {
                ForEach(PiPFaceSizePreset.allCases) { preset in
                    Text(preset.menuLabel).tag(preset)
                }
            }
        }
    }

    private var faceCamSizePresetBinding: Binding<PiPFaceSizePreset> {
        Binding(
            get: { PiPFaceSizePreset.nearest(to: settingsStore.settings.faceCamScale) },
            set: { preset in
                settingsStore.update { $0.applyPipFaceSizePreset(preset) }
                UsageTracker.shared.track(.pipSizePreset, params: ["preset": preset.rawValue, "source": "settings"])
            }
        )
    }

    private var audioSection: some View {
        Section("Аудио") {
            Toggle("Микрофон", isOn: binding(\.microphoneEnabled, feature: .micToggled, param: { ["enabled": String($0), "source": "settings"] }))
            Toggle("Системный звук", isOn: binding(\.systemAudioEnabled, feature: .systemAudioToggled, param: { ["enabled": String($0)] }))
            if settingsStore.settings.microphoneEnabled {
                LabeledContent("Громкость микрофона") {
                    Slider(value: bindingFloat(\.microphoneVolume), in: 0...2)
                }
            }
            if settingsStore.settings.systemAudioEnabled {
                LabeledContent("Громкость системы") {
                    Slider(value: bindingFloat(\.systemAudioVolume), in: 0...2)
                }
            }
        }
    }

    private var glassesSection: some View {
        Section {
            Toggle("Включить наложение по умолчанию", isOn: binding(\.glassesEnabledByDefault, feature: .glassesDefaultToggled, param: { ["enabled": String($0), "source": "settings"] }))

            Picker("Цвет оправы", selection: binding(\.glassesColor, feature: .glassesColorChanged, param: { ["color": $0.rawValue, "source": "settings"] })) {
                ForEach(GlassesFrameColor.allCases) { color in
                    HStack {
                        Circle()
                            .fill(color == .red ? GlassyTheme.glassesRed : GlassyTheme.glassesBlue)
                            .frame(width: 14, height: 14)
                        Text(color.displayName)
                    }
                    .tag(color)
                }
            }

            LabeledContent("Прозрачность линз") {
                Slider(value: bindingFloat(\.lensTransparency), in: 0.3...1.0)
            }

            LabeledContent("Яркость оправы") {
                Slider(value: bindingFloat(\.frameBrightness), in: 0.5...1.5)
            }
        } header: {
            Label("Очки Monokol MK295", systemImage: "eyeglasses")
        } footer: {
            Text("Кубическая оправа c40 из глянцевого ацетата с антибликовыми линзами.")
        }
    }

    private var touchSection: some View {
        Section("Индикаторы касаний") {
            Toggle("Показывать касания", isOn: binding(\.touchIndicatorEnabled, feature: .touchIndicatorsToggled, param: { ["enabled": String($0)] }))
            LabeledContent("Размер") {
                Slider(value: bindingCGFloat(\.touchIndicatorSize), in: 12...48)
            }
            LabeledContent("Прозрачность") {
                Slider(value: bindingDouble(\.touchIndicatorOpacity), in: 0.2...1.0)
            }
        }
    }

    private var gesturesSection: some View {
        Section("Жесты и интерфейс") {
            LabeledContent("Скрытие панели (сек)") {
                Slider(value: bindingDouble(\.controlPanelAutoHideSeconds), in: 1...10, step: 1)
            }
            LabeledContent("Скрытие таймера (сек)") {
                Slider(value: bindingDouble(\.timerAutoHideSeconds), in: 2...15, step: 1)
            }
        }
    }

    // MARK: - Bindings

    private func binding<T: Equatable>(_ keyPath: WritableKeyPath<AppSettings, T>, feature: UsageFeature? = nil, param: ((T) -> [String: String])? = nil) -> Binding<T> {
        Binding(
            get: { settingsStore.settings[keyPath: keyPath] },
            set: { newValue in
                let old = settingsStore.settings[keyPath: keyPath]
                guard old != newValue else { return }
                settingsStore.update { $0[keyPath: keyPath] = newValue }
                if let feature {
                    UsageTracker.shared.track(feature, params: param?(newValue) ?? [:])
                }
            }
        )
    }

    private func bindingCGFloat(_ keyPath: WritableKeyPath<AppSettings, CGFloat>) -> Binding<CGFloat> {
        binding(keyPath)
    }

    private func bindingFloat(_ keyPath: WritableKeyPath<AppSettings, Float>) -> Binding<Float> {
        binding(keyPath)
    }

    private func bindingDouble(_ keyPath: WritableKeyPath<AppSettings, Double>) -> Binding<Double> {
        binding(keyPath)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(SettingsStore())
            .environmentObject(AppCoordinator(settingsStore: SettingsStore()))
    }
}
