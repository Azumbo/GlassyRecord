import SwiftUI

/// Карточка выбора очков Monokol MK295 на главном экране.
struct GlassesSelectionCard: View {
    let isEnabled: Bool
    let selectedColor: GlassesFrameColor
    let lensTransparency: Float
    let onToggle: (Bool) -> Void
    let onColorChange: (GlassesFrameColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Очки Monokol MK295", systemImage: "eyeglasses")
                    .font(.headline)
                Spacer()
                Toggle("", isOn: Binding(get: { isEnabled }, set: onToggle))
                    .labelsHidden()
            }

            HStack(spacing: 16) {
                ForEach(GlassesFrameColor.allCases) { color in
                    GlassesPreviewTile(
                        color: color,
                        isSelected: selectedColor == color,
                        lensTransparency: lensTransparency
                    ) {
                        onColorChange(color)
                    }
                }
            }

            Text("Кубическая оправа из глянцевого ацетата c40")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .liquidGlass()
        .accessibilityElement(children: .contain)
    }
}

struct GlassesPreviewTile: View {
    let color: GlassesFrameColor
    let isSelected: Bool
    let lensTransparency: Float
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.secondarySystemFill))
                        .frame(height: 64)

                    GlassesIconShape()
                        .stroke(frameColor, lineWidth: 4)
                        .frame(width: 56, height: 28)

                    GlassesIconShape()
                        .fill(.white.opacity(Double(lensTransparency) * 0.15))
                        .frame(width: 48, height: 20)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
                }

                Text(color == .red ? "Красный" : "Синий")
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private var frameColor: Color {
        color == .red ? GlassyTheme.glassesRed : GlassyTheme.glassesBlue
    }
}

/// Векторная иконка квадратных очков.
struct GlassesIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lensW = rect.width * 0.38
        let lensH = rect.height * 0.75
        let gap = rect.width * 0.08
        let y = rect.midY - lensH / 2

        path.addRect(CGRect(x: rect.minX, y: y, width: lensW, height: lensH))
        path.addRect(CGRect(x: rect.maxX - lensW, y: y, width: lensW, height: lensH))
        path.addRect(CGRect(x: rect.midX - gap / 2, y: y + lensH * 0.35, width: gap, height: lensH * 0.15))
        return path
    }
}
