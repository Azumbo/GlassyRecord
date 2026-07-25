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
                    Label(L10n.t("settings.usage_stats"), systemImage: "chart.bar")
                }
            }

            qualitySection
            faceCamSection
            audioSection
            glassesSection
            touchSection
            gesturesSection
        }
        .navigationTitle(L10n.t("nav.settings"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var qualitySection: some View {
        Section {
            Picker(L10n.t("settings.quality"), selection: binding(\.quality, feature: .qualityChanged, param: { ["quality": $0.rawValue, "source": "settings"] })) {
                ForEach(RecordingQuality.allCases) { q in
                    Text(q.displayName).tag(q)
                }
            }
            Toggle("Экономия энергии", isOn: binding(\.lowPowerModeAware, feature: .lowPowerAwareToggled, param: { ["enabled": String($0)] }))
        }
    }

    private var faceCamSection: some View {
        Section(L10n.t("settings.face_cam")) {
            Picker(L10n.t("settings.position"), selection: faceCamCornerBinding) {
                ForEach(FaceCamCorner.allCases) { c in
                    Text(c.displayName).tag(c)
                }
            }
            Text(L10n.t("settings.position_hint"))
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)
            Picker(L10n.t("settings.shape"), selection: binding(\.faceCamShape, feature: .faceCamShapeChanged, param: { ["shape": $0.rawValue] })) {
                ForEach(FaceCamShape.allCases) { s in
                    Text(s.displayName).tag(s)
                }
            }
            Toggle(L10n.t("settings.mirror"), isOn: binding(\.faceCamMirrored, feature: .faceCamMirrorToggled, param: { ["enabled": String($0)] }))

            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.t("settings.pip_aspect"))
                    .font(.subheadline)
                HStack(spacing: 12) {
                    ForEach(PiPAspectRatio.allCases) { aspect in
                        Button {
                            settingsStore.update { $0.pipAspectRatio = aspect }
                            UsageTracker.shared.track(
                                .pipAspectChanged,
                                params: ["aspect": aspect.rawValue, "source": "settings"]
                            )
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: aspect.symbolName)
                                    .font(.system(size: 28, weight: .medium))
                                    .symbolRenderingMode(.hierarchical)
                                    .frame(height: 36)
                                Text(aspect.shortLabel)
                                    .font(.caption.weight(.semibold))
                                Text(aspect.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(GlassyTheme.labelSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(settingsStore.settings.pipAspectRatio == aspect
                                          ? Color.accentColor.opacity(0.18)
                                          : GlassyTheme.fillTertiary)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        settingsStore.settings.pipAspectRatio == aspect
                                            ? Color.accentColor
                                            : Color.clear,
                                        lineWidth: 2
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(aspect.displayName), \(aspect.shortLabel)")
                    }
                }
                Text(L10n.t("settings.pip_aspect_hint"))
                    .font(.caption)
                    .foregroundStyle(GlassyTheme.labelSecondary)
            }

            Picker(L10n.t("settings.pip_size"), selection: faceCamSizePresetBinding) {
                ForEach(PiPFaceSizePreset.allCases) { preset in
                    Text(preset.menuLabel).tag(preset)
                }
            }
            Text(L10n.t("pip.size.hint"))
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)
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
        Section(L10n.t("settings.audio")) {
            Toggle(L10n.t("settings.mic"), isOn: binding(\.microphoneEnabled, feature: .micToggled, param: { ["enabled": String($0), "source": "settings"] }))
            Toggle("Системный звук", isOn: binding(\.systemAudioEnabled, feature: .systemAudioToggled, param: { ["enabled": String($0)] }))
            if settingsStore.settings.microphoneEnabled {
                LabeledContent(L10n.t("settings.mic_volume")) {
                    Slider(value: bindingFloat(\.microphoneVolume), in: 0...2)
                }
            }
            if settingsStore.settings.systemAudioEnabled {
                LabeledContent(L10n.t("settings.system_volume")) {
                    Slider(value: bindingFloat(\.systemAudioVolume), in: 0...2)
                }
            }
        }
    }

    private var glassesSection: some View {
        Section {
            Toggle(L10n.t("settings.glasses_default"), isOn: binding(\.glassesEnabledByDefault, feature: .glassesDefaultToggled, param: { ["enabled": String($0), "source": "settings"] }))

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

            LabeledContent(L10n.t("settings.lens_transparency")) {
                Slider(value: lensTransparencyBinding, in: 0.3...1.0)
            }

            // Живой превью-эффект ползунка прозрачности.
            HStack(spacing: 16) {
                ForEach(GlassesFrameColor.allCases) { color in
                    GlassesPreviewTile(
                        color: color,
                        isSelected: settingsStore.settings.glassesColor == color,
                        lensTransparency: settingsStore.settings.lensTransparency
                    ) {
                        settingsStore.update { $0.glassesColor = color }
                    }
                }
            }
            .padding(.vertical, 4)

            LabeledContent("Яркость оправы") {
                Slider(value: bindingFloat(\.frameBrightness), in: 0.5...1.5)
            }
        } header: {
            Label(L10n.t("glasses.title"), systemImage: "eyeglasses")
        }
    }

    private var touchSection: some View {
        Section {
            Toggle(L10n.t("settings.show_taps"), isOn: binding(\.touchIndicatorEnabled, feature: .touchIndicatorsToggled, param: { ["enabled": String($0)] }))
            LabeledContent(L10n.t("settings.tap_size")) {
                Slider(value: bindingCGFloat(\.touchIndicatorSize), in: 12...48)
            }
            LabeledContent(L10n.t("settings.opacity")) {
                Slider(value: bindingDouble(\.touchIndicatorOpacity), in: 0.2...1.0)
            }
        }
    }

    private var gesturesSection: some View {
        Section(L10n.t("settings.gestures")) {
            LabeledContent("Скрытие панели (сек)") {
                Slider(value: bindingDouble(\.controlPanelAutoHideSeconds), in: 1...10, step: 1)
            }
            LabeledContent("Скрытие таймера (сек)") {
                Slider(value: bindingDouble(\.timerAutoHideSeconds), in: 2...15, step: 1)
            }
        }
    }

    // MARK: - Bindings

    private var lensTransparencyBinding: Binding<Float> {
        Binding(
            get: { settingsStore.settings.lensTransparency },
            set: { value in
                settingsStore.update { $0.lensTransparency = value }
            }
        )
    }

    private var faceCamCornerBinding: Binding<FaceCamCorner> {
        Binding(
            get: { settingsStore.settings.faceCamCorner },
            set: { corner in
                settingsStore.update { $0.applyFaceCamCorner(corner) }
                UsageTracker.shared.track(
                    .faceCamCornerChanged,
                    params: ["corner": corner.rawValue, "source": "settings"]
                )
            }
        )
    }

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
