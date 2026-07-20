import SwiftUI

struct RecordingControlPanel: View {
    let isRecording: Bool
    let glassesEnabled: Bool
    let glassesColor: GlassesFrameColor
    let onStop: () -> Void
    let onToggleGlasses: () -> Void
    let onGlassesColor: (GlassesFrameColor) -> Void
    var onOpenDemo: (() -> Void)? = nil
    var onAppLaunchFailed: ((String) -> Void)? = nil

    @State private var pulse = false
    @State private var appLaunchText = ""

    var body: some View {
        VStack(spacing: 10) {
            if isRecording {
                openAppField
            }

            HStack(spacing: 20) {
                glassesControls

                if let onOpenDemo {
                    Button(action: onOpenDemo) {
                        Label(L10n.t("recording.demo"), systemImage: "safari")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(GlassyTheme.fillSecondary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.t("recording.demo.a11y"))
                }

                Spacer()

                stopButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .liquidGlass(cornerRadius: 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .onAppear { pulse = true }
    }

    /// Поле без пресет-кнопок: Enter / «Перейти» на клавиатуре открывает схему или ссылку.
    private var openAppField: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(GlassyTheme.labelSecondary)
            TextField(L10n.t("recording.open_app_placeholder"), text: $appLaunchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { submitAppLaunch() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(GlassyTheme.fillSecondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func submitAppLaunch() {
        switch AppLauncher.open(appLaunchText) {
        case .success:
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            appLaunchText = ""
        case .failure(let error):
            onAppLaunchFailed?(error.errorDescription ?? error.localizedDescription)
        }
    }

    private var glassesControls: some View {
        HStack(spacing: 8) {
            Button(action: onToggleGlasses) {
                Image(systemName: glassesEnabled ? "eyeglasses" : "eyeglasses.slash")
                    .font(.title3)
                    .foregroundStyle(glassesEnabled ? .yellow : .secondary)
            }

            if glassesEnabled {
                ForEach(GlassesFrameColor.allCases) { color in
                    Circle()
                        .fill(color == .red ? GlassyTheme.glassesRed : GlassyTheme.glassesBlue)
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle()
                                .stroke(glassesColor == color ? Color.white : .clear, lineWidth: 2)
                        }
                        .onTapGesture { onGlassesColor(color) }
                }
            }
        }
    }

    private var stopButton: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .fill(GlassyTheme.record.opacity(0.25))
                    .frame(width: pulse ? 58 : 52, height: pulse ? 58 : 52)
                    .animation(GlassyTheme.pulse, value: pulse)

                RoundedRectangle(cornerRadius: 6)
                    .fill(GlassyTheme.record)
                    .frame(width: 28, height: 28)
            }
        }
        .accessibilityLabel(L10n.t("recording.stop.a11y"))
    }
}
