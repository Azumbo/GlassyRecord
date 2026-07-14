import SwiftUI

/// Семантическая палитра по рекомендациям Apple HIG.
/// Используются системные цвета — автоматически адаптируются к Light/Dark и Increase Contrast.
enum GlassyTheme {
    // MARK: - Brand (Monokol MK295 — только для очков)

    static let glassesRed = Color("GlassesRed")
    static let glassesBlue = Color("GlassesBlue")

    // MARK: - Semantic (Apple system colors)

    static let record = Color(.systemRed)
    static let success = Color(.systemGreen)
    static let warning = Color(.systemOrange)

    static let backgroundPrimary = Color(.systemBackground)
    static let backgroundGrouped = Color(.systemGroupedBackground)
    static let backgroundSecondary = Color(.secondarySystemBackground)
    static let fillPrimary = Color(.systemFill)
    static let fillSecondary = Color(.secondarySystemFill)
    static let fillTertiary = Color(.tertiarySystemFill)

    static let labelPrimary = Color(.label)
    static let labelSecondary = Color(.secondaryLabel)
    static let labelTertiary = Color(.tertiaryLabel)

    static let separator = Color(.separator)
    static let tint = Color.accentColor

    // MARK: - Drawing tools (system ink colors)

    static let inkPen = Color(.label)
    static let inkMarker = Color(.systemYellow)
    static let inkNeon = Color(.systemCyan)

    // MARK: - Animation

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let pulse = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)

    // MARK: - Layout

    static let cornerRadius: CGFloat = 16
    static let faceCamDefaultSize: CGFloat = 140
    static let pipPreviewBaseWidth: CGFloat = 88
    static let pipPreviewBaseHeight: CGFloat = 118
    /// Стандарт (S) = 1.0; пресеты от ½ (×0.5) до +150%.
    static let pipScaleStandard: CGFloat = 1.0
    static let pipScaleMinimum: CGFloat = 0.5
    static let pipScaleMaximum: CGFloat = 2.5
    static let controlPanelHeight: CGFloat = 72
}

/// Материал в стиле Liquid Glass с адаптивной обводкой под color scheme.
struct LiquidGlassModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    var cornerRadius: CGFloat = GlassyTheme.cornerRadius

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(GlassyTheme.separator.opacity(colorScheme == .dark ? 0.55 : 0.35), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.08), radius: 12, y: 4)
            }
    }
}

/// Стиль кapsule-кнопки выбора (1080p, 4K и т.д.) по HIG.
struct SelectableCapsuleStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? GlassyTheme.tint : GlassyTheme.fillSecondary)
            .foregroundStyle(isSelected ? Color.white : GlassyTheme.labelPrimary)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// Кнопка пресета крупности PiP (компактная, для сетки).
struct PipPresetButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(isSelected ? GlassyTheme.tint : GlassyTheme.fillSecondary)
            .foregroundStyle(isSelected ? Color.white : GlassyTheme.labelPrimary)
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

extension View {
    func liquidGlass(cornerRadius: CGFloat = GlassyTheme.cornerRadius) -> some View {
        modifier(LiquidGlassModifier(cornerRadius: cornerRadius))
    }

    func hapticTap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) -> some View {
        simultaneousGesture(
            TapGesture().onEnded { _ in
                UIImpactFeedbackGenerator(style: style).impactOccurred()
            }
        )
    }
}
