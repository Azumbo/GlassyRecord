import Foundation
import ReplayKit

/// Понятные сообщения об ошибках ReplayKit (вместо сырого English).
enum BroadcastErrorMessages {
    static func message(for error: Error) -> String {
        let ns = error as NSError
        let text = ns.localizedDescription.lowercased()

        if text.contains("declined") || text.contains("user declined") || text.contains("application recording") {
            return userDeclinedMessage
        }
        if text.contains("preferred broadcast service not found") {
            return extensionNotFoundMessage
        }

        if ns.domain == RPRecordingErrorDomain {
            switch RPRecordingErrorCode(rawValue: ns.code) {
            case .userDeclined:
                return userDeclinedMessage
            case .disabled:
                return "Запись экрана отключена. Проверьте Настройки → Экранное время → Ограничения контента."
            case .failed:
                return "Не удалось начать запись. Перезагрузите iPhone и попробуйте снова."
            default:
                break
            }
        }

        return ns.localizedDescription
    }

    static func message(forOptionalReason reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return userDeclinedMessage }
        return message(for: NSError(
            domain: "GlassyRecord",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: reason]
        ))
    }

    static let userDeclinedMessage = """
    Запись экрана не начата.

    • Нажмите красную кнопку «Начать запись экрана» ниже
    • В списке выберите Glassy Record
    • Нажмите «Начать трансляцию»
    • Разрешите запись экрана и микрофон

    Не нажимайте «Отмена» и не закрывайте окно свайпом.
    """

    static let extensionNotFoundMessage = """
    iOS не видит расширение Glassy Record.

    Удалите приложение с iPhone, в Xcode укажите Team для GlassyRecord и GlassyRecordBroadcastUpload, затем Run снова.
    """
}
