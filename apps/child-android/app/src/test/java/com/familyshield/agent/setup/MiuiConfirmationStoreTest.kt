package com.familyshield.agent.setup

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * #1287 finding 3: a parent's "I turned it on" tap may only stand in for an op the app cannot read. A readable
 * allow needs no confirmation, and a readable denial must never be overridden by the tap.
 *
 * Mutant: store the confirmation for every state — a readable denial then reads as granted after the tap, and
 * MIUI can drop the background start of `LockActivity`/`BlockActivity` while setup says done.
 */
class MiuiConfirmationStoreTest {

    @Test
    fun `only the unreadable state keeps the parent's word`() {
        assertTrue(MiuiBackgroundPopupPolicy.storesConfirmation(MiuiPopupState.UNREADABLE))
        assertFalse(MiuiBackgroundPopupPolicy.storesConfirmation(MiuiPopupState.ALLOWED))
        assertFalse(MiuiBackgroundPopupPolicy.storesConfirmation(MiuiPopupState.DENIED))
    }

    @Test
    fun `a readable denial cannot become granted through the confirmation path`() {
        val state = MiuiBackgroundPopupPolicy.classifyState("Xiaomi", op10021Mode = 1 /* MODE_IGNORED */)
        assertFalse(MiuiBackgroundPopupPolicy.storesConfirmation(state))
        assertFalse(
            MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(
                manufacturer = "Xiaomi",
                op10021Mode = 1,
                parentConfirmed = true,
            ),
        )
    }
}
