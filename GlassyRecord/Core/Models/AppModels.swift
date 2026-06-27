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
        case .circle: "Круг"
        case .roundedRectangle: "Скруглённый"
        case .capsule: "Пилюля"
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
        case .topLeading: "Верх-лево"
        case .topTrailing: "Верх-право"
        case .bottomLeading: "Низ-лево"
        case .bottomTrailing: "Низ-право"
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

// MARK: - Glasses

enum GlassesFrameColor: String, Codable, CaseIterable, Identifiable {
    case red
    case blue

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .red: "Красная оправа"
        case .blue: "Синяя оправа"
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

// MARK: - Drawing

enum DrawingTool: String, Codable, CaseIterable, Identifiable {
    case pen
    case marker
    case neon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .pen: "Перо"
        case .marker: "Маркер"
        case .neon: "Неон"
        }
    }

    var systemImage: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .neon: "sparkles"
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
        case .trim: "Обрезка"
        case .audio: "Звук"
        case .filters: "Фильтры"
        case .text: "Текст"
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
        case .none: "Оригинал"
        case .vivid: "Яркий"
        case .mono: "Моно"
        case .warm: "Тёплый"
        case .cool: "Холодный"
        }
    }
}

// MARK: - Recording Session

struct RecordingSession: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var fileURL: URL?
    var thumbnailData: Data?
    var quality: RecordingQuality
    var glassesEnabled: Bool
    var glassesColor: GlassesFrameColor

    init(
        id: UUID = UUID(),
        title: String = "Запись",
        createdAt: Date = .now,
        duration: TimeInterval = 0,
        fileURL: URL? = nil,
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
    var faceCamShape: FaceCamShape = .roundedRectangle
    var faceCamMirrored: Bool = true
    var faceCamScale: CGFloat = 1.0
    var microphoneEnabled: Bool = true
    var systemAudioEnabled: Bool = true
    var microphoneVolume: Float = 1.0
    var systemAudioVolume: Float = 1.0
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
            "Камера недоступна на этом устройстве."
        case .microphoneUnavailable:
            "Микрофон недоступен. Проверьте разрешения в Настройках."
        case .screenRecordingDenied:
            "Запись экрана запрещена. Разрешите доступ в Настройках."
        case .screenRecordingFailed(let reason):
            "Не удалось записать экран: \(reason)"
        case .exportFailed(let reason):
            "Ошибка экспорта: \(reason)"
        case .faceTrackingUnavailable:
            "Отслеживание лица недоступно. Требуется TrueDepth или iOS 18+ с Vision."
        case .arSessionFailed(let reason):
            "Ошибка AR-сессии: \(reason)"
        case .fileNotFound:
            "Файл записи не найден."
        case .permissionDenied(let resource):
            "Нет доступа к \(resource). Откройте Настройки → Glassy Record."
        }
    }
}

// MARK: - Navigation

enum AppRoute: Hashable {
    case recording
    case editor(RecordingSession)
    case settings
}
