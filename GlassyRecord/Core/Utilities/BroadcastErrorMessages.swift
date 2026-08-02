import Foundation
import ReplayKit

/// Понятные сообщения об ошибках ReplayKit / Broadcast Extension.
enum BroadcastErrorMessages {
    static func message(for error: Error) -> String {
        let ns = error as NSError
        let text = ns.localizedDescription

        if let mapped = localizedExtensionMessage(text) {
            return mapped
        }

        let lower = text.lowercased()
        if lower.contains("declined") || lower.contains("user declined") || lower.contains("application recording") {
            return L10n.t("error.user_declined")
        }
        if lower.contains("preferred broadcast service not found") {
            return L10n.t("error.extension_missing")
        }

        if ns.domain == RPRecordingErrorDomain {
            switch RPRecordingErrorCode(rawValue: ns.code) {
            case .userDeclined:
                return L10n.t("error.user_declined")
            case .disabled:
                return L10n.t("error.screen_disabled")
            case .failed:
                return L10n.t("error.screen_start_failed")
            default:
                break
            }
        }

        if ns.domain == "GlassyRecord" {
            return ns.localizedDescription
        }

        return ns.localizedDescription
    }

    static func message(forOptionalReason reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return L10n.t("error.user_declined") }
        if let mapped = localizedExtensionMessage(reason) {
            return mapped
        }
        return message(for: NSError(
            domain: "GlassyRecord",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: reason]
        ))
    }

    /// Коды extension (`ext.*`) и старые русские тексты → локализованные строки.
    private static func localizedExtensionMessage(_ raw: String) -> String? {
        switch raw {
        case "ext.app_group_missing":
            return L10n.t("error.ext.app_group_missing")
        case "ext.config_missing":
            return L10n.t("error.ext.config_missing")
        case "ext.no_frames":
            return L10n.t("error.ext.no_frames")
        case "ext.save_failed":
            return L10n.t("error.ext.save_failed")
        case "ext.container_missing":
            return L10n.t("error.ext.container_missing")
        case "ext.no_pixel_buffer":
            return L10n.t("error.ext.no_pixel_buffer")
        case "ext.video_input_failed":
            return L10n.t("error.ext.video_input_failed")
        case "ext.write_video_failed":
            return L10n.t("error.ext.write_video_failed")
        case "ext.write_app_audio_failed":
            return L10n.t("error.ext.write_app_audio_failed")
        case "ext.write_mic_failed":
            return L10n.t("error.ext.write_mic_failed")
        case "ext.writer_missing":
            return L10n.t("error.ext.writer_missing")
        case "ext.no_screen_frames":
            return L10n.t("error.ext.no_screen_frames")
        default:
            break
        }

        if raw.hasPrefix("ext.file_corrupt") {
            return L10n.t("error.ext.file_corrupt")
        }

        // Старые сборки писали русский текст прямо в App Group.
        if raw.contains("App Group не настроен") || raw.contains("App Group контейнер") {
            return L10n.t("error.ext.app_group_missing")
        }
        if raw.contains("Конфигурация не найдена") {
            return L10n.t("error.ext.config_missing")
        }
        if raw.contains("без видеокадров") || raw.contains("Не получены кадры") {
            return L10n.t("error.ext.no_frames")
        }
        if raw.contains("Не удалось сохранить запись") {
            return L10n.t("error.ext.save_failed")
        }
        if raw.contains("повреждён") || raw.contains("пуст") {
            return L10n.t("error.ext.file_corrupt")
        }
        if raw.contains("Не удалось записать видеокадр") {
            return L10n.t("error.ext.write_video_failed")
        }
        if raw.contains("звук приложения") {
            return L10n.t("error.ext.write_app_audio_failed")
        }
        if raw.contains("микрофон") && raw.contains("записать") {
            return L10n.t("error.ext.write_mic_failed")
        }

        return nil
    }
}
