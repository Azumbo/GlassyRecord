import SwiftUI

/// Цвета и типографика в духе HIG 2026 + Liquid Glass.
enum GlassyTheme {
    // MARK: - Brand (c40 Monokol MK295)

    static let glassesRed = Color(red: 0.77, green: 0.12, blue: 0.16)   // #C41F29
    static let glassesBlue = Color(red: 0.10, green: 0.28, blue: 0.72)  // #1A47B8

    // MARK: - Semantic

    static let recordRed = Color(red: 1.0, green: 0.23, blue: 0.19)
    static let neonAccent = Color(red: 0.4, green: 0.95, blue: 1.0)

    // MARK: - Glass Materials

    static var primaryGlass: some ShapeStyle {
        if #available(iOS 26.0, *) {
            return AnyShapeStyle(.ultraThinMaterial)
        } else {
            return AnyShapeStyle(.ultraThinMaterial)
        }
    }

    // MARK: - Animation

    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
    static let pulse = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)

    // MARK: - Layout

    static let cornerRadius: CGFloat = 20
    static let faceCamDefaultSize: CGFloat = 140
    static let controlPanelHeight: CGFloat = 72
}

/// Модификатор Liquid Glass для Face Cam и панелей управления.
struct LiquidGlassModifier: ViewModifier {
    var cornerRadius: CGFloat = GlassyTheme.cornerRadius
    var strokeOpacity: Double = 0.35

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(strokeOpacity),
                                        .white.opacity(strokeOpacity * 0.3),
                                        .clear
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
            }
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
