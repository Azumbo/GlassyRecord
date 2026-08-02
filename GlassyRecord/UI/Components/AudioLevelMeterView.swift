import SwiftUI

/// Сегментный индикатор уровня как в Zoom (зелёный → жёлтый → красный).
struct AudioLevelMeterView: View {
    /// 0…1
    var level: Float
    var isActive: Bool = true
    var segmentCount: Int = 16

    var body: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 2
            let totalSpacing = spacing * CGFloat(max(segmentCount - 1, 0))
            let segmentWidth = max(2, (geo.size.width - totalSpacing) / CGFloat(segmentCount))
            let litCount = isActive
                ? Int((CGFloat(level) * CGFloat(segmentCount)).rounded(.up))
                : 0

            HStack(spacing: spacing) {
                ForEach(0..<segmentCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(color(for: index, lit: index < litCount))
                        .frame(width: segmentWidth, height: geo.size.height)
                }
            }
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text("\(Int((level * 100).rounded()))%"))
    }

    private var accessibilityLabel: String {
        L10n.t("settings.audio.level_a11y")
    }

    private func color(for index: Int, lit: Bool) -> Color {
        guard lit else {
            return GlassyTheme.fillTertiary
        }
        let ratio = CGFloat(index + 1) / CGFloat(segmentCount)
        if ratio <= 0.62 {
            return GlassyTheme.success
        }
        if ratio <= 0.82 {
            return GlassyTheme.warning
        }
        return GlassyTheme.record
    }
}
