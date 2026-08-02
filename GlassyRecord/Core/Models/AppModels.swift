import Foundation
import SwiftUI

// MARK: - Recording Quality

enum RecordingQuality: String, Codable, CaseIterable, Identifiable {
    case hd1080p
    case uhd4K

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hd1080p: "1080p"
        case .uhd4K: "4K"
        }
    }

    var resolution: CGSize {
        switch self {
        case .hd1080p: CGSize(width: 1920, height: 1080)
        case .uhd4K: CGSize(width: 3840, height: 2160)
        }
    }

    var preferredFPS: Int {
        switch self {
        case .hd1080p: 120
        case .uhd4K: 60
        }
    }
}

// MARK: - Face Cam

enum FaceCamShape: String, Codable, CaseIterable, Identifiable {
    case circle
    case roundedRectangle
    case capsule

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .circle: L10n.t("face.shape.circle")
        case .roundedRectangle: L10n.t("face.shape.rounded")
        case .capsule: L10n.t("face.shape.capsule")
        }
    }
}

enum FaceCamCorner: String, Codable, CaseIterable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeading: L10n.t("face.corner.top_leading")
        case .topTrailing: L10n.t("face.corner.top_trailing")
        case .bottomLeading: L10n.t("face.corner.bottom_leading")
        case .bottomTrailing: L10n.t("face.corner.bottom_trailing")
        }
    }

    var alignment: Alignment {
        switch self {
        case .topLeading: .topLeading
        case .topTrailing: .topTrailing
        case .bottomLeading: .bottomLeading
        case .bottomTrailing: .bottomTrailing
        }
    }
}

/// Фиксированные уровни крупности Face Cam / PiP относительно стандарта (S = 1.0).
enum PiPFaceSizePreset: String, CaseIterable, Codable, Identifiable {
    case half
    case minus25
    case standard
    case plus50
    case plus100
    case plus150

    var id: String { rawValue }

    /// Множитель aspect-fill кропа: 1.0 = кадр заполнен, больше = ближе к лицу.
    var scaleFactor: CGFloat {
        switch self {
        case .half: 1.0
        case .minus25: 1.25
        case .standard: 1.5
        case .plus50: 1.75
        case .plus100: 2.0
        case .plus150: 2.5
        }
    }

    var shortLabel: String {
        switch self {
        case .half: "½"
        case .minus25: "−25%"
        case .standard: "S"
        case .plus50: "+50%"
        case .plus100: "+100%"
        case .plus150: "+150%"
        }
    }

    var menuLabel: String {
        switch self {
        case .half: L10n.t("pip.preset.half_menu")
        case .minus25: L10n.t("pip.preset.minus25_menu")
        case .standard: L10n.t("pip.preset.standard_menu")
        case .plus50: L10n.t("pip.preset.plus50_menu")
        case .plus100: L10n.t("pip.preset.plus100_menu")
        case .plus150: L10n.t("pip.preset.plus150_menu")
        }
    }

    static func nearest(to scale: CGFloat) -> PiPFaceSizePreset {
        allCases.min { abs($0.scaleFactor - scale) < abs($1.scaleFactor - scale) } ?? .standard
    }
}

/// Уровень размытия фона за человеком в Face Cam / PiP.
enum BackgroundBlurLevel: String, CaseIterable, Codable, Identifiable {
    case off
    case light
    case medium
    case strong

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: L10n.t("blur.off")
        case .light: L10n.t("blur.light")
        case .medium: L10n.t("blur.medium")
        case .strong: L10n.t("blur.strong")
        }
    }

    var shortLabel: String {
        switch self {
        case .off: L10n.t("blur.short.off")
        case .light: L10n.t("blur.short.light")
        case .medium: L10n.t("blur.short.medium")
        case .strong: L10n.t("blur.short.strong")
        }
    }

    /// Радиус CIGaussianBlur при VGA Face Cam.
    var blurRadius: CGFloat {
        switch self {
        case .off: 0
        case .light: 6
        case .medium: 12
        case .strong: 22
        }
    }
}

/// Стартовый aspect PiP Face Cam (ориентир минимума сообщества: 68×120 / 120×68).
enum PiPAspectRatio: String, CaseIterable, Codable, Identifiable {
    case portrait9x16 = "9:16"
    case landscape16x9 = "16:9"

    var id: String { rawValue }

    var shortLabel: String { rawValue }

    var displayName: String {
        switch self {
        case .portrait9x16: L10n.t("pip.aspect.portrait")
        case .landscape16x9: L10n.t("pip.aspect.landscape")
        }
    }

    /// SF Symbol телефона — сразу видно ориентацию.
    var symbolName: String {
        switch self {
        case .portrait9x16: "iphone"
        case .landscape16x9: "iphone.landscape"
        }
    }

    var startSize: CGSize {
        switch self {
        case .portrait9x16: CGSize(width: 68, height: 120)
        case .landscape16x9: CGSize(width: 120, height: 68)
        }
    }

    var previewSize: CGSize { startSize }
}

// MARK: - Glasses

enum GlassesFrameColor: String, Codable, CaseIterable, Identifiable {
    case red
    case blue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .red: L10n.t("glasses.red")
        case .blue: L10n.t("glasses.blue")
        }
    }

    /// Фирменные цвета c40 — Monokol MK295
    var uiColor: Color {
        switch self {
        case .red: Color("GlassesRed")
        case .blue: Color("GlassesBlue")
        }
    }

    var resourceName: String {
        switch self {
        case .red: "MonokolMK295_Red"
        case .blue: "MonokolMK295_Blue"
        }
    }
}

// MARK: - Editor

enum EditorTab: String, CaseIterable, Identifiable {
    case trim
    case audio
    case filters
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trim: L10n.t("editor.trim")
        case .audio: L10n.t("editor.audio")
        case .filters: L10n.t("editor.filters")
        case .text: L10n.t("editor.text")
        }
    }

    var systemImage: String {
        switch self {
        case .trim: "scissors"
        case .audio: "waveform"
        case .filters: "camera.filters"
        case .text: "textformat"
        }
    }
}

enum ExportCodec: String, Codable, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

enum VideoFilter: String, Codable, CaseIterable, Identifiable {
    case none
    case vivid
    case mono
    case warm
    case cool

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: L10n.t("filter.none")
        case .vivid: L10n.t("filter.vivid")
        case .mono: L10n.t("filter.mono")
        case .warm: L10n.t("filter.warm")
        case .cool: L10n.t("filter.cool")
        }
    }
}

// MARK: - Recording Session

/// Одна готовая запись: MP4 из Broadcast Extension (App Group) или mock на симуляторе.
struct RecordingSession: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    /// Единственный выходной файл — screen capture с системным PiP.
    let fileURL: URL
    var thumbnailData: Data?
    var quality: RecordingQuality
    var glassesEnabled: Bool
    var glassesColor: GlassesFrameColor

    init(
        id: UUID = UUID(),
        title: String = "Запись",
        createdAt: Date = .now,
        duration: TimeInterval = 0,
        fileURL: URL,
        thumbnailData: Data? = nil,
        quality: RecordingQuality = .hd1080p,
        glassesEnabled: Bool = false,
        glassesColor: GlassesFrameColor = .red
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.fileURL = fileURL
        self.thumbnailData = thumbnailData
        self.quality = quality
        self.glassesEnabled = glassesEnabled
        self.glassesColor = glassesColor
    }
}

// MARK: - App Settings

struct AppSettings: Codable, Equatable {
    var quality: RecordingQuality = .hd1080p
    var faceCamCorner: FaceCamCorner = .bottomTrailing
    /// Свободная позиция превью (0…1). Углы из `faceCamCorner` — только стартовый пресет.
    var faceCamNormalizedX: Double = Double(FaceCamCorner.bottomTrailing.normalizedPosition.x)
    var faceCamNormalizedY: Double = Double(FaceCamCorner.bottomTrailing.normalizedPosition.y)
    var faceCamShape: FaceCamShape = .roundedRectangle
    var faceCamMirrored: Bool = true
    var faceCamScale: CGFloat = PiPFaceSizePreset.half.scaleFactor
    var pipAspectRatio: PiPAspectRatio = .portrait9x16
    var microphoneEnabled: Bool = true
    var systemAudioEnabled: Bool = true
    var microphoneVolume: Float = 1.0
    var systemAudioVolume: Float = 1.0
    var backgroundBlurLevel: BackgroundBlurLevel = .off
    var touchIndicatorEnabled: Bool = true
    var touchIndicatorColorHex: String = "#FF3B30"
    var touchIndicatorSize: CGFloat = 24
    var touchIndicatorOpacity: Double = 0.7
    var glassesEnabledByDefault: Bool = false
    var glassesColor: GlassesFrameColor = .red
    var lensTransparency: Float = 0.85
    var frameBrightness: Float = 1.0
    var controlPanelAutoHideSeconds: Double = 3
    var timerAutoHideSeconds: Double = 5
    var lowPowerModeAware: Bool = true

    var faceCamNormalizedPosition: CGPoint {
        get { CGPoint(x: faceCamNormalizedX, y: faceCamNormalizedY) }
        set {
            faceCamNormalizedX = Double(newValue.x)
            faceCamNormalizedY = Double(newValue.y)
        }
    }

    /// Пресет крупности PiP / Face Cam (нормализует `faceCamScale`).
    var pipFaceSizePreset: PiPFaceSizePreset {
        PiPFaceSizePreset.nearest(to: faceCamScale)
    }

    /// Множитель для `PiPFrameScaler` и превью (S = 1.0, +100% = 2.0).
    var pipContentScaleFactor: CGFloat {
        pipFaceSizePreset.scaleFactor
    }

    mutating func applyPipFaceSizePreset(_ preset: PiPFaceSizePreset) {
        faceCamScale = preset.scaleFactor
    }

    mutating func applyFaceCamCorner(_ corner: FaceCamCorner) {
        faceCamCorner = corner
        let point = corner.normalizedPosition
        faceCamNormalizedX = Double(point.x)
        faceCamNormalizedY = Double(point.y)
    }
}

// MARK: - Errors

enum GlassyRecordError: LocalizedError {
    case cameraUnavailable
    case microphoneUnavailable
    case screenRecordingDenied
    case screenRecordingFailed(String)
    case exportFailed(String)
    case faceTrackingUnavailable
    case arSessionFailed(String)
    case fileNotFound
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            L10n.t("error.camera")
        case .microphoneUnavailable:
            L10n.t("error.mic")
        case .screenRecordingDenied:
            L10n.t("error.screen_denied")
        case .screenRecordingFailed(let reason):
            L10n.format("error.screen_failed", reason)
        case .exportFailed(let reason):
            L10n.format("error.export_failed", reason)
        case .faceTrackingUnavailable:
            L10n.t("error.face_tracking")
        case .arSessionFailed(let reason):
            L10n.format("error.ar_failed", reason)
        case .fileNotFound:
            L10n.t("error.file_missing")
        case .permissionDenied(let resource):
            L10n.format("error.permission", resource)
        }
    }
}

// MARK: - Navigation

enum AppRoute: Hashable {
    case recording
    case editor(RecordingSession)
    case settings
    case usageStats
}
