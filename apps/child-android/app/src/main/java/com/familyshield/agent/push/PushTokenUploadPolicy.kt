package com.familyshield.agent.push

/**
 * Issue #319: when the command poll should publish the stored FCM token.
 *
 * The defect this closes: `FirebaseMessagingSvc.onNewToken` uploaded only when `settings.deviceId()`
 * was already set, so a token minted before pairing — which is the normal order on a fresh install,
 * because Firebase registers at first launch and pairing happens afterwards — was dropped and never
 * retried. FCM does not re-deliver a token it has already handed out, so the child stayed without a
 * push target until the token happened to rotate, and roadmap 1.5's acceptance ("a lock lands in under
 * 5 s with the app backgrounded") could not be met: the server had nothing to push to.
 *
 * The fix keeps the token in DataStore and lets the 15-minute poll upload it once a device id exists.
 * This object is the decision alone — pure and Android-free, so the cases below are JVM tests rather
 * than something only a phone can show.
 *
 * Three states, each deliberate:
 *  - no device id: there is no row to publish to yet. Wait; the token stays stored, so nothing is lost.
 *  - no (or a blank) stored token: nothing to publish. A blank is not a token — Firebase never hands
 *    one out, and posting `""` would be a 400 or, worse, an empty `Device.pushToken`.
 *  - stored == last uploaded: the server already has it. Re-sending every 15 minutes forever is a
 *    write per poll per device for no state change.
 */
object PushTokenUploadPolicy {

    /**
     * True when [stored] should be POSTed to `v1/devices/{id}/push-token` for [deviceId]:
     * a token exists, it is not blank, the device is paired, and the server has not already accepted
     * exactly that value.
     */
    fun shouldUpload(stored: String?, uploaded: String?, deviceId: String?): Boolean {
        if (deviceId.isNullOrBlank()) return false
        if (stored.isNullOrBlank()) return false
        return stored != uploaded
    }
}
