#if os(iOS)
import Foundation
import UserNotifications

public enum RingNotifier {
    private static let returnIdentifier = "ring.return"

    @discardableResult
    public static func showReturnNotification() async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
        let content = UNMutableNotificationContent()
        content.title = L10n.tr("ring_notification_title")
        content.body = L10n.tr("ring_notification_body")
        content.sound = .default
        let request = UNNotificationRequest(identifier: returnIdentifier, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            return false
        }
    }

    public static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [returnIdentifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [returnIdentifier])
    }
}
#endif
