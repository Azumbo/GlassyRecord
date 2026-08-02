import SwiftUI

/// Превью Face Cam для симулятора — нейтральные системные тона.
struct SimulatorFaceCamPreview: View {
    let glassesEnabled: Bool
    let glassesColor: GlassesFrameColor
    var mirrored: Bool = true

    var body: some View {
        ZStack {
            GlassyTheme.fillSecondary

            // Силуэт лица
            Ellipse()
                .fill(GlassyTheme.fillTertiary)
                .frame(width: 72, height: 96)
                .offset(y: 4)

            // Глаза
            HStack(spacing: 22) {
                Circle().fill(GlassyTheme.labelTertiary).frame(width: 10, height: 10)
                Circle().fill(GlassyTheme.labelTertiary).frame(width: 10, height: 10)
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
                            .fill(GlassyTheme.fillPrimary.opacity(0.5))
                    )

                RoundedRectangle(cornerRadius: 0)
                    .stroke(frameColor, lineWidth: 4)
                    .frame(width: 30, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 0)
                            .fill(GlassyTheme.fillPrimary.opacity(0.5))
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
        .foregroundStyle(GlassyTheme.labelPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(GlassyTheme.separator, lineWidth: 0.5)
        }
        .padding(.top, 52)
    }
}
