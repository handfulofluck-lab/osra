import FamilyShieldAgent
import UserNotifications

/// #760: the notification service extension for the ring push, declared here in the extension's own
/// module and named `$(PRODUCT_MODULE_NAME).RingServiceExtension` in Info.plist (#561: a principal
/// class that lived only in the statically linked package could not load on the iPhone). A priority-5
/// background push cannot wake a locked/suspended/force-quit iPhone (physical-device row on #750), so
/// the server sends a visible alert and this extension runs the reduced ring drain before the
/// notification is shown. The AlarmKit attempt inside the drain is best-effort: whatever the outcome,
/// the content handler receives the approved localized lines with the ring sound.
final class RingServiceExtension: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        let content = bestAttemptContent ?? UNMutableNotificationContent()
        Task {
            // The drain polls the command channel and, on a `ring`, tries the AlarmKit schedule through
            // the existing controller. Started or fallback, the delivered content is the same localized
            // notification: a fetch or schedule failure must never blank it.
            _ = await RingPushDrainer.drainNow()
            deliver(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        deliver(bestAttemptContent ?? UNMutableNotificationContent())
    }

    /// Exactly once: the first caller wins, the other (the drained task losing the race to the
    /// deadline) finds no handler left.
    private func deliver(_ content: UNMutableNotificationContent) {
        guard let contentHandler else { return }
        self.contentHandler = nil
        bestAttemptContent = nil
        content.title = L10n.tr("ring_notification_title")
        content.body = L10n.tr("ring_notification_body")
        if #available(iOS 26.0, *) {
            content.sound = .defaultRingtone
        } else {
            content.sound = .default
        }
        contentHandler(content)
    }
}
