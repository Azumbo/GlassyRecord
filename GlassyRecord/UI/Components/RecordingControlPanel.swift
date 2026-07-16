import SwiftUI

struct RecordingControlPanel: View {
    let isRecording: Bool
    let glassesEnabled: Bool
    let glassesColor: GlassesFrameColor
    let onStop: () -> Void
    let onToggleGlasses: () -> Void
    let onGlassesColor: (GlassesFrameColor) -> Void

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 20) {
            glassesControls

            Spacer()

            stopButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .liquidGlass(cornerRadius: 24)
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
        .onAppear { pulse = true }
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
        .accessibilityLabel("Остановить запись")
    }
}
