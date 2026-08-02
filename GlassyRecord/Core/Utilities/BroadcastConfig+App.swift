import Foundation
import CoreGraphics

extension BroadcastRecordingConfig {
    static func from(
        settings: AppSettings,
        faceCamPosition: CGPoint,
        faceCamScale: CGFloat,
        glassesEnabled: Bool
    ) -> BroadcastRecordingConfig {
        BroadcastRecordingConfig(
            quality: settings.quality.rawValue,
            microphoneEnabled: settings.microphoneEnabled,
            systemAudioEnabled: settings.systemAudioEnabled,
            faceCamNormalizedX: Double(faceCamPosition.x),
            faceCamNormalizedY: Double(faceCamPosition.y),
            faceCamScale: Double(faceCamScale),
            faceCamShape: settings.faceCamShape.rawValue,
            faceCamMirrored: settings.faceCamMirrored,
            glassesEnabled: glassesEnabled,
            glassesColor: settings.glassesColor.rawValue
        )
    }
}

extension FaceCamCorner {
    var normalizedPosition: CGPoint {
        switch self {
        case .topLeading: CGPoint(x: 0.18, y: 0.18)
        case .topTrailing: CGPoint(x: 0.82, y: 0.18)
        case .bottomLeading: CGPoint(x: 0.18, y: 0.82)
        case .bottomTrailing: CGPoint(x: 0.82, y: 0.82)
        }
    }
}
