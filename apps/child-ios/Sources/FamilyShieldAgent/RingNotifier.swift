#if os(iOS)
import Foundation
import UserNotifications

public enum RingNotifier {
    private static let returnIdentifier = "ring.return"

    private static var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Requests the notification authorization the ring push needs. Called at pairing so a background
    /// ring is not silently dropped before the child has ever seen the ring screen (#760 device row).
    @discardableResult
    public static func requestPermission() async -> Bool {
        guard available else { return false }
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) == true
    }

    @discardableResult
    public static func showReturnNotification() async -> Bool {
        guard available else { return false }
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
        guard available else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [returnIdentifier])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [returnIdentifier])
    }
}
#endif
