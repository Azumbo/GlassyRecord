import SwiftUI

/// Превью Face Cam для симулятора — силуэт лица и 2D-очки Monokol MK295.
struct SimulatorFaceCamPreview: View {
    let glassesEnabled: Bool
    let glassesColor: GlassesFrameColor
    var mirrored: Bool = true

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.teal.opacity(0.7), .indigo.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Силуэт лица
            Ellipse()
                .fill(.pink.opacity(0.45))
                .frame(width: 72, height: 96)
                .offset(y: 4)

            // Глаза
            HStack(spacing: 22) {
                Circle().fill(.white.opacity(0.9)).frame(width: 10, height: 10)
                Circle().fill(.white.opacity(0.9)).frame(width: 10, height: 10)
            }
            .offset(y: -6)

            if glassesEnabled {
                SimulatorGlassesOverlay(color: glassesColor)
                    .offset(y: -8)
            }
        }
        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
    }
}

/// Упрощённые квадратные очки MK295 для превью на симуляторе.
struct SimulatorGlassesOverlay: View {
    let color: GlassesFrameColor

    private var frameColor: Color {
        color == .red ? GlassyTheme.glassesRed : GlassyTheme.glassesBlue
    }

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 0)
                    .stroke(frameColor, lineWidth: 4)
                    .frame(width: 30, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 0)
                            .fill(.white.opacity(0.08))
                    )

                RoundedRectangle(cornerRadius: 0)
                    .stroke(frameColor, lineWidth: 4)
                    .frame(width: 30, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 0)
                            .fill(.white.opacity(0.08))
                    )
            }

            Rectangle()
                .fill(frameColor)
                .frame(width: 6, height: 3)
        }
    }
}

/// Баннер режима симулятора.
struct SimulatorBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone.gen3.slash")
            Text(SimulatorSupport.previewNotice)
                .font(.caption2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.85), in: Capsule())
        .padding(.top, 52)
    }
}
