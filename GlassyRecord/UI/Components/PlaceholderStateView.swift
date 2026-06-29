import SwiftUI

struct PlaceholderStateView: View {
    let title: String
    let systemImage: String
    var subtitle: String?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(GlassyTheme.labelSecondary)
            Text(title)
                .font(.headline)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(GlassyTheme.labelSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}
