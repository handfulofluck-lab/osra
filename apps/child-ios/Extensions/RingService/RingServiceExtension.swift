import FamilyShieldAgent
import UserNotifications

/// #760 redesign: the notification service extension for the ring push. A physical-device row proved
/// a priority-5 background push cannot wake a locked/suspended/force-quit iPhone, so the server sends
/// a visible time-sensitive alert with a bundled sound (`ring.wav`). This extension only ensures the
/// title and body are localized and that the sound is preserved; it does **not** call AlarmKit or
/// poll the command channel. The full AlarmKit ring starts only when the app process launches.
final class RingServiceExtension: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        deliver(bestAttemptContent ?? UNMutableNotificationContent())
    }

    override func serviceExtensionTimeWillExpire() {
        deliver(bestAttemptContent ?? UNMutableNotificationContent())
    }

    /// Exactly once: the first caller wins. The delivered content always has localized title/body
    /// and a non-nil sound, so a ring push is never silent even if the server payload is unexpected.
    private func deliver(_ content: UNMutableNotificationContent) {
        guard let contentHandler else { return }
        self.contentHandler = nil
        bestAttemptContent = nil
        content.title = L10n.tr("ring_notification_title")
        content.body = L10n.tr("ring_notification_body")
        // Preserve the server-supplied bundled sound (`ring.wav`). If the payload carried no sound,
        // fall back to the default so the time-sensitive alert is still audible.
        if content.sound == nil {
            content.sound = .default
        }
        contentHandler(content)
    }
}
