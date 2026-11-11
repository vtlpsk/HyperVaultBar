import Foundation
import UserNotifications

protocol NotificationSending {
    func requestPermission() async throws -> Bool
    func send(title: String, body: String) async throws
}

struct NotificationService: NotificationSending {
    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func send(title: String, body: String) async throws {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { throw SettingsApplyError.notificationsDenied }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
