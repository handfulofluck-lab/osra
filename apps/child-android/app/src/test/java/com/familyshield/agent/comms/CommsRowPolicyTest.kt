package com.familyshield.agent.comms

import com.familyshield.agent.comms.CommsRowPolicy.Identity
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #229 (TR-24): Google Meet writes an answered call into the system call log with no number
 * and a VoIP `subscription_component_name`, and once wrote the same call twice. Both rows were
 * copied into `comms_events`.
 *
 * A numberless app row is skipped rather than stored with an empty number: the timeline has no app
 * column and the unknown-contact alert needs digits (see [CommsRowPolicy]). A repeat of
 * `(date, type, duration, component)` inside one harvest is skipped. The cursor wiring is pinned by
 * [CommsGrantWiringTest].
 */
class CommsRowPolicyTest {

    private val meet = "com.google.android.apps.meetings/.calling.CallService"

    private fun identity(
        date: Long = 1_760_000_000_000L,
        type: Int = 1,
        duration: Long = 42L,
        component: String? = meet,
    ) = Identity(date, type, duration, component)

    @Test
    fun `a numbered phone call is imported`() {
        assertTrue(CommsRowPolicy.shouldImport("+441234567890", component = null, identity(component = null), emptySet()))
    }

    @Test
    fun `a numberless VoIP row is skipped`() {
        assertTrue(CommsRowPolicy.isNumberlessAppCall("", meet))
        assertTrue(CommsRowPolicy.isNumberlessAppCall(null, meet))
        assertFalse(CommsRowPolicy.shouldImport("", meet, identity(), emptySet()))
    }

    @Test
    fun `a private or withheld number with no component stays imported, as before`() {
        assertFalse(CommsRowPolicy.isNumberlessAppCall("", null))
        assertTrue(CommsRowPolicy.shouldImport("", null, identity(component = null), emptySet()))
    }

    @Test
    fun `the second identical row inside one harvest is skipped`() {
        val first = identity()
        val seen = mutableSetOf<Identity>()

        assertTrue(CommsRowPolicy.shouldImport("+441234567890", meet, first, seen))
        seen += first

        assertFalse(
            "the provider wrote the same call twice: same date, type, duration and component",
            CommsRowPolicy.shouldImport("+441234567890", meet, identity(), seen),
        )
    }

    @Test
    fun `a different component is not a duplicate of the same instant`() {
        val seen = setOf(identity(component = meet))

        assertTrue(
            CommsRowPolicy.shouldImport(
                "+441234567890",
                "com.google.android.dialer/.CallService",
                identity(component = "com.google.android.dialer/.CallService"),
                seen,
            ),
        )
    }

    @Test
    fun `the same number and start with a different duration is not a duplicate`() {
        val seen = setOf(identity(duration = 42L))

        assertTrue(CommsRowPolicy.shouldImport("+441234567890", meet, identity(duration = 43L), seen))
    }

    @Test
    fun `the dedupe set is per harvest, so a later harvest is not suppressed by a fresh set`() {
        val row = identity()

        assertTrue(CommsRowPolicy.shouldImport("+441234567890", meet, row, emptySet()))
        assertTrue(
            "the durable guard against re-importing across harvests is the watermark, not this set",
            CommsRowPolicy.shouldImport("+441234567890", meet, row, emptySet()),
        )
    }
}
