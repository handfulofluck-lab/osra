package com.familyshield.agent.setup

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Issue #81: what `pm clear` leaves behind, and the three states that must not be mistaken for it. */
class WipeDetectorTest {

    @Test
    fun `pm clear - admin still active, no pairing, no PIN - is a wipe`() {
        assertTrue(WipeDetector.dataCleared(adminActive = true, paired = false, pinConfigured = false))
    }

    @Test
    fun `a fresh install has no admin grant`() {
        assertFalse(WipeDetector.dataCleared(adminActive = false, paired = false, pinConfigured = false))
    }

    @Test
    fun `the parent's Re-pair keeps the PIN`() {
        assertFalse(WipeDetector.dataCleared(adminActive = true, paired = false, pinConfigured = true))
    }

    @Test
    fun `a paired phone is never a wipe`() {
        assertFalse(WipeDetector.dataCleared(adminActive = true, paired = true, pinConfigured = false))
    }
}
