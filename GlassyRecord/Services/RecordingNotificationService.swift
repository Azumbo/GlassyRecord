import Foundation
import UserNotifications

/// Локальное уведомление «идёт запись» — iOS не позволяет PiP поверх чужих приложений.
enum RecordingNotificationService {
    static let recordingNotificationID = "com.glassyrecord.recording.active"

    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    static func showRecordingStarted() {
        let content = UNMutableNotificationContent()
        content.title = "Glassy Record"
        content.body = "Запись экрана и Face Cam. Вернитесь в приложение, чтобы остановить."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: recordingNotificationID,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func clearRecordingNotification() {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [recordingNotificationID])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [recordingNotificationID])
    }
}
