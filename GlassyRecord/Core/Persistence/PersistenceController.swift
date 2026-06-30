import Foundation
import SwiftData

@Model
final class SettingsEntity {
    @Attribute(.unique) var id: UUID
    var qualityRaw: String
    var faceCamCornerRaw: String
    var faceCamShapeRaw: String
    var faceCamMirrored: Bool
    var faceCamScale: Double
    var microphoneEnabled: Bool
    var systemAudioEnabled: Bool
    var microphoneVolume: Float
    var systemAudioVolume: Float
    var touchIndicatorEnabled: Bool
    var touchIndicatorColorHex: String
    var touchIndicatorSize: Double
    var touchIndicatorOpacity: Double
    var glassesEnabledByDefault: Bool
    var glassesColorRaw: String
    var lensTransparency: Float
    var frameBrightness: Float
    var controlPanelAutoHideSeconds: Double
    var timerAutoHideSeconds: Double
    var lowPowerModeAware: Bool

    init(from settings: AppSettings = AppSettings()) {
        self.id = UUID()
        self.qualityRaw = settings.quality.rawValue
        self.faceCamCornerRaw = settings.faceCamCorner.rawValue
        self.faceCamShapeRaw = settings.faceCamShape.rawValue
        self.faceCamMirrored = settings.faceCamMirrored
        self.faceCamScale = Double(settings.faceCamScale)
        self.microphoneEnabled = settings.microphoneEnabled
        self.systemAudioEnabled = settings.systemAudioEnabled
        self.microphoneVolume = settings.microphoneVolume
        self.systemAudioVolume = settings.systemAudioVolume
        self.touchIndicatorEnabled = settings.touchIndicatorEnabled
        self.touchIndicatorColorHex = settings.touchIndicatorColorHex
        self.touchIndicatorSize = Double(settings.touchIndicatorSize)
        self.touchIndicatorOpacity = settings.touchIndicatorOpacity
        self.glassesEnabledByDefault = settings.glassesEnabledByDefault
        self.glassesColorRaw = settings.glassesColor.rawValue
        self.lensTransparency = settings.lensTransparency
        self.frameBrightness = settings.frameBrightness
        self.controlPanelAutoHideSeconds = settings.controlPanelAutoHideSeconds
        self.timerAutoHideSeconds = settings.timerAutoHideSeconds
        self.lowPowerModeAware = settings.lowPowerModeAware
    }

    func toAppSettings() -> AppSettings {
        AppSettings(
            quality: RecordingQuality(rawValue: qualityRaw) ?? .hd1080p,
            faceCamCorner: FaceCamCorner(rawValue: faceCamCornerRaw) ?? .bottomTrailing,
            faceCamShape: FaceCamShape(rawValue: faceCamShapeRaw) ?? .roundedRectangle,
            faceCamMirrored: faceCamMirrored,
            faceCamScale: CGFloat(faceCamScale),
            microphoneEnabled: microphoneEnabled,
            systemAudioEnabled: systemAudioEnabled,
            microphoneVolume: microphoneVolume,
            systemAudioVolume: systemAudioVolume,
            touchIndicatorEnabled: touchIndicatorEnabled,
            touchIndicatorColorHex: touchIndicatorColorHex,
            touchIndicatorSize: CGFloat(touchIndicatorSize),
            touchIndicatorOpacity: touchIndicatorOpacity,
            glassesEnabledByDefault: glassesEnabledByDefault,
            glassesColor: GlassesFrameColor(rawValue: glassesColorRaw) ?? .red,
            lensTransparency: lensTransparency,
            frameBrightness: frameBrightness,
            controlPanelAutoHideSeconds: controlPanelAutoHideSeconds,
            timerAutoHideSeconds: timerAutoHideSeconds,
            lowPowerModeAware: lowPowerModeAware
        )
    }

    func apply(_ settings: AppSettings) {
        qualityRaw = settings.quality.rawValue
        faceCamCornerRaw = settings.faceCamCorner.rawValue
        faceCamShapeRaw = settings.faceCamShape.rawValue
        faceCamMirrored = settings.faceCamMirrored
        faceCamScale = Double(settings.faceCamScale)
        microphoneEnabled = settings.microphoneEnabled
        systemAudioEnabled = settings.systemAudioEnabled
        microphoneVolume = settings.microphoneVolume
        systemAudioVolume = settings.systemAudioVolume
        touchIndicatorEnabled = settings.touchIndicatorEnabled
        touchIndicatorColorHex = settings.touchIndicatorColorHex
        touchIndicatorSize = Double(settings.touchIndicatorSize)
        touchIndicatorOpacity = settings.touchIndicatorOpacity
        glassesEnabledByDefault = settings.glassesEnabledByDefault
        glassesColorRaw = settings.glassesColor.rawValue
        lensTransparency = settings.lensTransparency
        frameBrightness = settings.frameBrightness
        controlPanelAutoHideSeconds = settings.controlPanelAutoHideSeconds
        timerAutoHideSeconds = settings.timerAutoHideSeconds
        lowPowerModeAware = settings.lowPowerModeAware
    }
}

@Model
final class RecordingEntity {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var filePath: String?
    @Attribute(.externalStorage) var thumbnailData: Data?
    var qualityRaw: String
    var glassesEnabled: Bool
    var glassesColorRaw: String

    init(from session: RecordingSession) {
        self.id = session.id
        self.title = session.title
        self.createdAt = session.createdAt
        self.duration = session.duration
        self.filePath = session.fileURL.path
        self.thumbnailData = session.thumbnailData
        self.qualityRaw = session.quality.rawValue
        self.glassesEnabled = session.glassesEnabled
        self.glassesColorRaw = session.glassesColor.rawValue
    }

    func toRecordingSession() -> RecordingSession? {
        guard let path = filePath else { return nil }
        return RecordingSession(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: duration,
            fileURL: URL(fileURLWithPath: path),
            thumbnailData: thumbnailData,
            quality: RecordingQuality(rawValue: qualityRaw) ?? .hd1080p,
            glassesEnabled: glassesEnabled,
            glassesColor: GlassesFrameColor(rawValue: glassesColorRaw) ?? .red
        )
    }
}

@MainActor
final class PersistenceController {
    static let shared = PersistenceController()

    let container: ModelContainer

    init(inMemory: Bool = false) {
        let schema = Schema([SettingsEntity.self, RecordingEntity.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        do {
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("SwiftData container failed: \(error)")
        }
    }

    func loadSettings(context: ModelContext) -> AppSettings {
        let descriptor = FetchDescriptor<SettingsEntity>()
        if let entity = try? context.fetch(descriptor).first {
            return entity.toAppSettings()
        }
        let entity = SettingsEntity()
        context.insert(entity)
        try? context.save()
        return entity.toAppSettings()
    }

    func saveSettings(_ settings: AppSettings, context: ModelContext) {
        let descriptor = FetchDescriptor<SettingsEntity>()
        let entity = (try? context.fetch(descriptor).first) ?? SettingsEntity()
        if entity.modelContext == nil { context.insert(entity) }
        entity.apply(settings)
        try? context.save()
    }

    func saveRecording(_ session: RecordingSession, context: ModelContext) {
        context.insert(RecordingEntity(from: session))
        try? context.save()
    }
}
