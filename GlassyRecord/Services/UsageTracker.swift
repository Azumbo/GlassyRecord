import Foundation
import UIKit
#if canImport(Darwin)
import Darwin
#endif

/// Локальный трекер фич: без сети. Нужен, чтобы понять, что реально используют на устройстве.
@MainActor
final class UsageTracker: ObservableObject {
    static let shared = UsageTracker()

    private let defaults = UserDefaults.standard
    private let countsKey = "usage.featureCounts.v1"
    private let paramsKey = "usage.featureParams.v1"
    private let firstLaunchKey = "usage.firstLaunchAt"
    private let sessionStartKey = "usage.currentSessionStartedAt"

    @Published private(set) var counts: [String: Int]
    @Published private(set) var lastParams: [String: String]

    private init() {
        counts = (defaults.dictionary(forKey: countsKey) as? [String: Int]) ?? [:]
        lastParams = (defaults.dictionary(forKey: paramsKey) as? [String: String]) ?? [:]
        if defaults.object(forKey: firstLaunchKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: firstLaunchKey)
        }
        defaults.set(Date().timeIntervalSince1970, forKey: sessionStartKey)
        track(.appLaunched)
    }

    func track(_ feature: UsageFeature, params: [String: String] = [:]) {
        counts[feature.rawValue, default: 0] += 1
        if !params.isEmpty {
            let flat = params
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ";")
            lastParams[feature.rawValue] = flat
        }
        persist()
    }

    func reset() {
        counts = [:]
        lastParams = [:]
        defaults.removeObject(forKey: countsKey)
        defaults.removeObject(forKey: paramsKey)
        defaults.set(Date().timeIntervalSince1970, forKey: firstLaunchKey)
        defaults.set(Date().timeIntervalSince1970, forKey: sessionStartKey)
        track(.usageReset)
    }

    /// Готовый текст для вставки в чат Cursor — «USED / UNUSED / SETTINGS».
    func makeHandoffReport(settings: AppSettings) -> String {
        let first = Date(timeIntervalSince1970: defaults.double(forKey: firstLaunchKey))
        let session = Date(timeIntervalSince1970: defaults.double(forKey: sessionStartKey))
        let formatter = ISO8601DateFormatter()

        var used: [(UsageFeature, Int)] = []
        var unused: [UsageFeature] = []
        for feature in UsageFeature.allCases where feature != .usageReset {
            let count = counts[feature.rawValue, default: 0]
            if count > 0 {
                used.append((feature, count))
            } else {
                unused.append(feature)
            }
        }
        used.sort { $0.1 > $1.1 }

        var lines: [String] = []
        lines.append("=== GLASSY RECORD USAGE REPORT ===")
        lines.append("generated_at: \(formatter.string(from: Date()))")
        lines.append("first_launch: \(formatter.string(from: first))")
        lines.append("session_start: \(formatter.string(from: session))")
        lines.append("app_version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
        lines.append("build: \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")")
        lines.append("device: \(simulatorLabel)")
        lines.append("")
        lines.append("--- USED (\(used.count)) ---")
        if used.isEmpty {
            lines.append("(none yet)")
        } else {
            for (feature, count) in used {
                let params = lastParams[feature.rawValue].map { " | last: \($0)" } ?? ""
                lines.append("\(feature.rawValue)=\(count)\(params)")
            }
        }
        lines.append("")
        lines.append("--- NEVER USED (\(unused.count)) ---")
        for feature in unused {
            lines.append(feature.rawValue)
        }
        lines.append("")
        lines.append("--- CURRENT SETTINGS ---")
        lines.append("quality=\(settings.quality.rawValue)")
        lines.append("mic=\(settings.microphoneEnabled)")
        lines.append("system_audio=\(settings.systemAudioEnabled)")
        lines.append("glasses_default=\(settings.glassesEnabledByDefault)")
        lines.append("glasses_color=\(settings.glassesColor.rawValue)")
        lines.append("lens_transparency=\(String(format: "%.2f", settings.lensTransparency))")
        lines.append("frame_brightness=\(String(format: "%.2f", settings.frameBrightness))")
        lines.append("face_cam_corner=\(settings.faceCamCorner.rawValue)")
        lines.append("face_cam_shape=\(settings.faceCamShape.rawValue)")
        lines.append("face_cam_mirrored=\(settings.faceCamMirrored)")
        lines.append("pip_scale=\(String(format: "%.2f", settings.faceCamScale))")
        lines.append("pip_preset=\(PiPFaceSizePreset.nearest(to: settings.faceCamScale).rawValue)")
        lines.append("touch_indicators=\(settings.touchIndicatorEnabled)")
        lines.append("low_power_aware=\(settings.lowPowerModeAware)")
        lines.append("control_auto_hide_s=\(Int(settings.controlPanelAutoHideSeconds))")
        lines.append("timer_auto_hide_s=\(Int(settings.timerAutoHideSeconds))")
        lines.append("")
        lines.append("--- DIAGNOSTICS ---")
        lines.append("ios=\(UIDevice.current.systemVersion)")
        lines.append("model=\(deviceModelIdentifier)")
        lines.append("app_group_ok=\(AppGroup.isConfigured)")
        lines.append("extension_embedded=\(BroadcastExtensionLocator.isExtensionEmbedded)")
        lines.append("low_power_mode=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        lines.append("thermal=\(thermalLabel)")
        lines.append("screen_captured=\(UIScreen.main.isCaptured)")
        lines.append(BroadcastConfigStore.diagnosticSnapshot(isScreenCaptured: UIScreen.main.isCaptured))
        lines.append("")
        lines.append("--- HINT ---")
        lines.append("Paste this whole report into Cursor chat.")
        lines.append("Items under NEVER USED are candidates to remove.")
        lines.append("=== END ===")
        return lines.joined(separator: "\n")
    }

    private var simulatorLabel: String {
        #if targetEnvironment(simulator)
        "simulator"
        #else
        "device"
        #endif
    }

    private var deviceModelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { raw in
            guard let base = raw.baseAddress else { return "unknown" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }

    private var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private func persist() {
        defaults.set(counts, forKey: countsKey)
        defaults.set(lastParams, forKey: paramsKey)
        objectWillChange.send()
    }
}

/// Каталог фич. Всё, чего нет в USED после недели использования — кандидат на удаление.
enum UsageFeature: String, CaseIterable, Identifiable {
    case appLaunched = "app_launched"
    case homeOpened = "home_opened"
    case settingsOpened = "settings_opened"
    case usageStatsOpened = "usage_stats_opened"
    case usageReportCopied = "usage_report_copied"
    case usageReset = "usage_reset"

    case recordingOpened = "recording_opened"
    case broadcastPrepare = "broadcast_prepare"
    case broadcastStarted = "broadcast_started"
    case broadcastStopRequested = "broadcast_stop_requested"
    case broadcastStopSucceeded = "broadcast_stop_succeeded"
    case broadcastStopFailed = "broadcast_stop_failed"
    case broadcastFinished = "broadcast_finished"
    case recordingFailed = "recording_failed"
    case exitRecording = "exit_recording"

    case pipActivated = "pip_activated"
    case pipSizePreset = "pip_size_preset"
    case glassesToggled = "glasses_toggled"
    case glassesColorChanged = "glasses_color_changed"
    case touchIndicatorShown = "touch_indicator_shown"

    case micToggled = "mic_toggled"
    case qualityChanged = "quality_changed"
    case faceCamCornerChanged = "face_cam_corner_changed"
    case faceCamShapeChanged = "face_cam_shape_changed"
    case faceCamMirrorToggled = "face_cam_mirror_toggled"
    case systemAudioToggled = "system_audio_toggled"
    case touchIndicatorsToggled = "touch_indicators_toggled"
    case lowPowerAwareToggled = "low_power_aware_toggled"
    case glassesDefaultToggled = "glasses_default_toggled"

    case editorOpened = "editor_opened"
    case exportSucceeded = "export_succeeded"
    case exportFailed = "export_failed"
    case trimUsed = "trim_used"

    var id: String { rawValue }

    var titleRU: String {
        switch self {
        case .appLaunched: "Запуск приложения"
        case .homeOpened: "Экран Home"
        case .settingsOpened: "Настройки"
        case .usageStatsOpened: "Статистика использования"
        case .usageReportCopied: "Скопирован отчёт"
        case .usageReset: "Сброс статистики"
        case .recordingOpened: "Экран записи"
        case .broadcastPrepare: "Подготовка записи экрана"
        case .broadcastStarted: "Запись экрана начата"
        case .broadcastStopRequested: "Запрос остановки записи"
        case .broadcastStopSucceeded: "Остановка broadcast OK"
        case .broadcastStopFailed: "Остановка broadcast сбой"
        case .broadcastFinished: "Запись экрана завершена"
        case .recordingFailed: "Ошибка записи"
        case .exitRecording: "Выход с экрана записи"
        case .pipActivated: "PiP Face Cam"
        case .pipSizePreset: "Крупность PiP"
        case .glassesToggled: "Очки вкл/выкл"
        case .glassesColorChanged: "Цвет очков"
        case .touchIndicatorShown: "Индикатор касания"
        case .micToggled: "Микрофон"
        case .qualityChanged: "Качество"
        case .faceCamCornerChanged: "Угол Face Cam"
        case .faceCamShapeChanged: "Форма Face Cam"
        case .faceCamMirrorToggled: "Зеркало Face Cam"
        case .systemAudioToggled: "Системный звук"
        case .touchIndicatorsToggled: "Касания (настройка)"
        case .lowPowerAwareToggled: "Экономия энергии"
        case .glassesDefaultToggled: "Очки по умолчанию"
        case .editorOpened: "Редактор"
        case .exportSucceeded: "Сохранение в Фото"
        case .exportFailed: "Ошибка экспорта"
        case .trimUsed: "Обрезка видео"
        }
    }
}
