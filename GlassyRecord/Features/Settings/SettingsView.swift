import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var audioService = AudioService()

    var body: some View {
        Form {
            languageSection

            Section {
                Button {
                    coordinator.showUsageStats()
                } label: {
                    Label(L10n.t("settings.usage_stats"), systemImage: "chart.bar")
                }
            }

            qualitySection
            faceCamSection
            virtualBackgroundSection
            appearanceSection
            audioSection
            glassesSection
            touchSection
            gesturesSection
        }
        .navigationTitle(L10n.t("nav.settings"))
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            audioService.stopAllTests()
        }
    }

    private var languageSection: some View {
        Section {
            Picker(L10n.t("settings.language"), selection: Binding(
                get: { settingsStore.settings.appLanguage },
                set: { newValue in
                    settingsStore.update { $0.appLanguage = newValue }
                }
            )) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language)
                }
            }
            Text(L10n.t("settings.language.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(L10n.t("settings.language"))
        }
    }

    private var qualitySection: some View {
        Section {
            Picker(L10n.t("settings.quality"), selection: binding(\.quality, feature: .qualityChanged, param: { ["quality": $0.rawValue, "source": "settings"] })) {
                ForEach(RecordingQuality.allCases) { q in
                    Text(q.displayName).tag(q)
                }
            }
            Toggle(L10n.t("settings.low_power"), isOn: binding(\.lowPowerModeAware, feature: .lowPowerAwareToggled, param: { ["enabled": String($0)] }))
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

            faceCamSizeAndBlurControls
        }
    }

    /// Те же пресеты Size + Background blur, что на экране записи.
    private var faceCamSizeAndBlurControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.t("pip.size"), systemImage: "person.crop.rectangle")
                .font(.subheadline.weight(.semibold))

            Text(L10n.t("pip.size.hint"))
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                ForEach(PiPFaceSizePreset.allCases) { preset in
                    Button {
                        faceCamSizePresetBinding.wrappedValue = preset
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(preset.shortLabel)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(PipPresetButtonStyle(
                        isSelected: PiPFaceSizePreset.nearest(to: settingsStore.settings.faceCamScale) == preset
                    ))
                    .accessibilityLabel(preset.menuLabel)
                }
            }

            Text(L10n.t("settings.background_blur"))
                .font(.subheadline.weight(.semibold))
                .padding(.top, 6)

            Text(L10n.t("settings.background_blur_hint"))
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                ForEach(BackgroundBlurLevel.allCases) { level in
                    Button {
                        setBlurLevel(level)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(level.shortLabel)
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(PipPresetButtonStyle(
                        isSelected: settingsStore.settings.backgroundBlurLevel == level
                    ))
                    .accessibilityLabel(level.displayName)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var virtualBackgroundSection: some View {
        Section {
            HStack(spacing: 12) {
                virtualBackgroundCard(
                    title: L10n.t("settings.vb.none"),
                    systemImage: "person.crop.rectangle",
                    isBlurPreview: false,
                    selected: settingsStore.settings.backgroundBlurLevel == .off
                ) {
                    setBlurLevel(.off)
                }
                virtualBackgroundCard(
                    title: L10n.t("settings.vb.blur"),
                    systemImage: "person.fill.viewfinder",
                    isBlurPreview: true,
                    selected: settingsStore.settings.backgroundBlurLevel != .off
                ) {
                    if settingsStore.settings.backgroundBlurLevel == .off {
                        setBlurLevel(.medium)
                    }
                }
            }
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

            if settingsStore.settings.backgroundBlurLevel != .off {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52), spacing: 8)], spacing: 8) {
                    ForEach(BackgroundBlurLevel.allCases.filter { $0 != .off }) { level in
                        Button {
                            setBlurLevel(level)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text(level.shortLabel)
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 40)
                        }
                        .buttonStyle(PipPresetButtonStyle(
                            isSelected: settingsStore.settings.backgroundBlurLevel == level
                        ))
                        .accessibilityLabel(level.displayName)
                    }
                }
            }

            Text(L10n.t("settings.background_blur_hint"))
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)
        } header: {
            Text(L10n.t("settings.vb.title"))
        }
    }

    private var appearanceSection: some View {
        Section {
            Toggle(isOn: binding(\.faceCamTouchUpEnabled)) {
                Label(L10n.t("settings.appearance.touch_up"), systemImage: "sparkles")
            }
            if settingsStore.settings.faceCamTouchUpEnabled {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(L10n.t("settings.vb.low"))
                            .font(.caption2)
                            .foregroundStyle(GlassyTheme.labelSecondary)
                        Slider(value: bindingFloat(\.faceCamTouchUpStrength), in: 0.1...1.0)
                        Text(L10n.t("settings.vb.high"))
                            .font(.caption2)
                            .foregroundStyle(GlassyTheme.labelSecondary)
                    }
                }
            }

            Toggle(isOn: binding(\.faceCamLowLightEnabled)) {
                Label(L10n.t("settings.appearance.low_light"), systemImage: "sun.min.fill")
            }

            Toggle(isOn: binding(\.faceCamPortraitLightingEnabled)) {
                Label(L10n.t("settings.appearance.portrait_light"), systemImage: "lightbulb.fill")
            }

            Text(L10n.t("settings.appearance.hint"))
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)
        } header: {
            Text(L10n.t("settings.appearance.title"))
        }
    }

    private func virtualBackgroundCard(
        title: String,
        systemImage: String,
        isBlurPreview: Bool,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: isBlurPreview
                                ? [Color.blue.opacity(0.35), Color.purple.opacity(0.25)]
                                : [Color.secondary.opacity(0.25), Color.secondary.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(height: 88)
                    .overlay {
                        if isBlurPreview {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                    }
                VStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.title2)
                    Text(title)
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(title)
    }

    private func setBlurLevel(_ level: BackgroundBlurLevel) {
        settingsStore.update { $0.backgroundBlurLevel = level }
        UsageTracker.shared.track(
            .backgroundBlurChanged,
            params: ["level": level.rawValue, "source": "settings"]
        )
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
        Section {
            Toggle(L10n.t("settings.mic"), isOn: Binding(
                get: { settingsStore.settings.microphoneEnabled },
                set: { enabled in
                    settingsStore.update { $0.microphoneEnabled = enabled }
                    UsageTracker.shared.track(.micToggled, params: ["enabled": String(enabled), "source": "settings"])
                    if enabled {
                        Task { await audioService.startMicrophoneTest() }
                    } else {
                        audioService.stopMicrophoneTest()
                    }
                }
            ))

            if settingsStore.settings.microphoneEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("settings.mic_volume"))
                        .font(.subheadline)
                    HStack(spacing: 10) {
                        Image(systemName: "mic.fill")
                            .foregroundStyle(GlassyTheme.labelSecondary)
                        Slider(
                            value: Binding(
                                get: { settingsStore.settings.microphoneVolume },
                                set: { value in
                                    settingsStore.update { $0.microphoneVolume = value }
                                    audioService.microphoneVolume = value
                                }
                            ),
                            in: 0...2
                        )
                        Image(systemName: "mic.circle.fill")
                            .foregroundStyle(GlassyTheme.labelSecondary)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "waveform")
                            .foregroundStyle(GlassyTheme.labelSecondary)
                        AudioLevelMeterView(
                            level: audioService.microphoneLevel,
                            isActive: audioService.isTestingMicrophone
                        )
                    }

                    Button {
                        Task {
                            if audioService.isTestingMicrophone {
                                audioService.stopMicrophoneTest()
                            } else {
                                await audioService.startMicrophoneTest()
                            }
                        }
                    } label: {
                        Label(
                            audioService.isTestingMicrophone
                                ? L10n.t("settings.audio.stop_mic_test")
                                : L10n.t("settings.audio.test_mic"),
                            systemImage: audioService.isTestingMicrophone ? "stop.circle" : "mic.badge.plus"
                        )
                    }
                }
                .onAppear {
                    audioService.microphoneVolume = settingsStore.settings.microphoneVolume
                    if !audioService.isTestingSpeaker {
                        Task { await audioService.startMicrophoneTest() }
                    }
                }
            }

            Toggle(L10n.t("settings.system_audio"), isOn: binding(\.systemAudioEnabled, feature: .systemAudioToggled, param: { ["enabled": String($0)] }))

            if settingsStore.settings.systemAudioEnabled {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("settings.system_volume"))
                        .font(.subheadline)
                    HStack(spacing: 10) {
                        Image(systemName: "speaker.fill")
                            .foregroundStyle(GlassyTheme.labelSecondary)
                        Slider(
                            value: Binding(
                                get: { settingsStore.settings.systemAudioVolume },
                                set: { value in
                                    settingsStore.update { $0.systemAudioVolume = value }
                                    audioService.systemAudioVolume = value
                                }
                            ),
                            in: 0...2
                        )
                        Image(systemName: "speaker.wave.3.fill")
                            .foregroundStyle(GlassyTheme.labelSecondary)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(GlassyTheme.labelSecondary)
                        AudioLevelMeterView(
                            level: audioService.speakerLevel,
                            isActive: audioService.isTestingSpeaker || audioService.speakerLevel > 0.01
                        )
                    }

                    Button {
                        audioService.systemAudioVolume = settingsStore.settings.systemAudioVolume
                        audioService.playSpeakerTest()
                    } label: {
                        Label(
                            audioService.isTestingSpeaker
                                ? L10n.t("settings.audio.testing_speaker")
                                : L10n.t("settings.audio.test_speaker"),
                            systemImage: "speaker.wave.3.fill"
                        )
                    }
                    .disabled(audioService.isTestingSpeaker)
                }
                .onAppear {
                    audioService.systemAudioVolume = settingsStore.settings.systemAudioVolume
                }
            }

            Text(L10n.t("settings.audio.test_hint"))
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)

            Text(L10n.t("settings.audio.hint"))
                .font(.caption)
                .foregroundStyle(GlassyTheme.labelSecondary)
        } header: {
            Text(L10n.t("settings.audio"))
        }
    }

    private var glassesSection: some View {
        Section {
            Toggle(L10n.t("settings.glasses_default"), isOn: binding(\.glassesEnabledByDefault, feature: .glassesDefaultToggled, param: { ["enabled": String($0), "source": "settings"] }))

            Picker(L10n.t("settings.glasses_color"), selection: binding(\.glassesColor, feature: .glassesColorChanged, param: { ["color": $0.rawValue, "source": "settings"] })) {
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

            LabeledContent(L10n.t("settings.frame_brightness")) {
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
            LabeledContent(L10n.t("settings.hide_panel")) {
                Slider(value: bindingDouble(\.controlPanelAutoHideSeconds), in: 1...10, step: 1)
            }
            LabeledContent(L10n.t("settings.hide_timer")) {
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
