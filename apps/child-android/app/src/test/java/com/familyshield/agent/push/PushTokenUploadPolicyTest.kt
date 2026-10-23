package com.familyshield.agent.push

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-JVM tests for issue #319's upload decision. The defect: a token minted before pairing was
 * dropped forever (`FirebaseMessagingSvc.onNewToken` uploaded only when `deviceId` was set), so the
 * child never reached the server's `Device.pushToken` and a backgrounded `lock` had no push to land on.
 */
class PushTokenUploadPolicyTest {

    private val deviceId = "dev-319"

    /**
     * Mutant: delete the `stored.isNullOrBlank()` guard in [PushTokenUploadPolicy.shouldUpload] (or
     * narrow it to `stored == null`) and this test fails while every other one in the class still
     * passes — `blank stored token is never published` then gets `true` for `("", null, deviceId)`.
     * That is the mutant that matters here: a blank would be POSTed as a real token, and the server's
     * `min(1)` on the body rejects it (400 on every poll) or stores an empty push target.
     */
    @Test
    fun `blank stored token is never published`() {
        assertFalse(PushTokenUploadPolicy.shouldUpload("", null, deviceId))
        assertFalse(PushTokenUploadPolicy.shouldUpload("   ", null, deviceId))
        assertFalse(PushTokenUploadPolicy.shouldUpload("", "old-token", deviceId))
    }

    @Test
    fun `no device id means nothing to publish to`() {
        assertFalse(PushTokenUploadPolicy.shouldUpload("token", null, null))
        assertFalse(PushTokenUploadPolicy.shouldUpload("token", null, ""))
        assertFalse(PushTokenUploadPolicy.shouldUpload("token", null, "  "))
    }

    @Test
    fun `no stored token means nothing to upload`() {
        assertFalse(PushTokenUploadPolicy.shouldUpload(null, null, deviceId))
        assertFalse(PushTokenUploadPolicy.shouldUpload(null, "old-token", deviceId))
    }

    @Test
    fun `first upload after pairing goes out`() {
        assertTrue(PushTokenUploadPolicy.shouldUpload("fcm-token-1", null, deviceId))
    }

    @Test
    fun `token identical to the last uploaded one is skipped`() {
        assertFalse(PushTokenUploadPolicy.shouldUpload("fcm-token-1", "fcm-token-1", deviceId))
    }

    @Test
    fun `a rotated token is uploaded again`() {
        assertTrue(PushTokenUploadPolicy.shouldUpload("fcm-token-2", "fcm-token-1", deviceId))
    }

    @Test
    fun `a blank upload marker is treated as never uploaded`() {
        // A re-pair clears the marker (AgentSettings.clearPairing), never the token, so the next poll
        // must publish the token again to the new enrolment.
        assertTrue(PushTokenUploadPolicy.shouldUpload("fcm-token-1", "", deviceId))
    }
}
