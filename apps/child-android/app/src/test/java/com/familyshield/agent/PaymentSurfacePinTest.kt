package com.familyshield.agent

import com.familyshield.agent.enforcement.EssentialPackages
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #172, decision of record: **OS payment surfaces stay blocked during bedtime.** The decision is
 * "keep them blocked and say so" (option 2), not "exempt them" (options 1 and 3).
 *
 * The set exists so protection cannot make the phone unsafe or unusable — the dialer, the emergency
 * dialer and the launcher are in it for that reason. A payment app is a *convenience* at night, and the
 * parent can always allow a specific one for their own family; exempting every payment surface by default
 * would widen the hole for every family to save a few a tap. Role-based detection (option 3, "the app
 * that handles NFC payment") is the shape that would be right, but it is not something a beta should bet
 * that decision on.
 *
 * **Why a row and not just a comment:** the cheap "fix" for a support ticket is to add a package name to
 * [EssentialPackages.EXACT], and that set is consulted by every block path, so one line there turns
 * bedtime off for that app everywhere. This row makes that line cost a deliberate change with its own
 * argument.
 *
 * Mutant: add either name to `EXACT` and the corresponding assertion goes red.
 */
class PaymentSurfacePinTest {

    /** The two surfaces named in the decision; the list is not exhaustive and must not be treated as one. */
    private val paymentSurfaces = listOf(
        "com.samsung.android.spay",
        // #172 review: the real Wallet package. `com.google.android.walletnfcrel` does not exist, and a
        // pin on a name nobody ships passes for the wrong reason.
        "com.google.android.apps.walletnfcrel",
        // The watch surface: contains none of "spay", "wallet" or "payment", which is why the shape guard
        // below matches on "pay".
        "com.samsung.android.samsungpay.gear",
    )

    @Test
    fun `a payment surface is not on the essential set, so bedtime still blocks it`() {
        for (pkg in paymentSurfaces) {
            assertFalse("$pkg must stay blockable: #172 chose option 2", EssentialPackages.isEssential(pkg))
            assertFalse("$pkg must not be in EXACT", pkg in EssentialPackages.EXACT)
        }
    }

    @Test
    fun `the set itself has not grown a payment surface under another name`() {
        // Guards the shape rather than the two names: any future entry that looks like a wallet is a
        // policy change, and a test failing here is the place to have that argument.
        val suspicious = EssentialPackages.EXACT.filter { name -> name.lowercase().contains("pay") }
        // `assertTrue`, not Kotlin's `assert`: that one only runs when the JVM has -ea on, so the row
        // would depend on a Gradle default (#172 review).
        assertTrue(
            "the essential set gained a payment surface (#172 chose option 2): $suspicious",
            suspicious.isEmpty(),
        )
    }
}
