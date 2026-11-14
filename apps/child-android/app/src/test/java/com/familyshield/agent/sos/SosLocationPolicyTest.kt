package com.familyshield.agent.sos

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #672 (Flip4, scenario run 1 on #665): the SOS alert reached the parent in 5.2 s with metadata
 * `{deviceId}` only, while a 13-minute-old fix was on the phone. This class pins what the alert now says
 * about where.
 *
 * Rows, and the mutant that reddens each:
 * - a fix is carried, with its age → [the current fix travels with the alert];
 * - the age is the fix's own, not a constant → [an old fix is labelled with its age];
 * - no fix keeps the alert valid and location-free → [no fix means no location keys];
 * - an implausible fix is dropped whole, never half → [an impossible coordinate sends nothing];
 * - the keys are the ones the API and the parent app read → [the key names are the contract].
 */
class SosLocationPolicyTest {

    private val now = 1_769_000_000_000L // 2026-01-21T12:53:20Z, arbitrary but fixed
    private val good = SosLocationPolicy.Fix(lat = 25.2769, lng = 51.5211, accuracyM = 12f, takenAtMs = now - 300_000)

    @Test
    fun `the current fix travels with the alert`() {
        val meta = SosLocationPolicy.metadata(good, now)
        assertEquals("25.2769", meta[SosLocationPolicy.KEY_LAT])
        assertEquals("51.5211", meta[SosLocationPolicy.KEY_LNG])
        assertEquals("12.0", meta[SosLocationPolicy.KEY_ACCURACY_M])
        assertEquals("2026-01-21T12:48:20Z", meta[SosLocationPolicy.KEY_TAKEN_AT])
        assertEquals("300", meta[SosLocationPolicy.KEY_AGE_SECONDS])
    }

    @Test
    fun `an old fix is labelled with its age`() {
        // The reported case: a fix 13 minutes old is still worth sending, and the age says so.
        val old = good.copy(takenAtMs = now - 13 * 60_000)
        assertEquals("780", SosLocationPolicy.metadata(old, now)[SosLocationPolicy.KEY_AGE_SECONDS])
    }

    @Test
    fun `no fix means no location keys`() {
        val meta = SosLocationPolicy.metadata(null, now)
        assertTrue("an SOS without a fix must still be sendable, and say nothing it does not know", meta.isEmpty())
    }

    @Test
    fun `an impossible coordinate sends nothing`() {
        for (bad in listOf(good.copy(lat = 91.0), good.copy(lng = -181.0), good.copy(lat = Double.NaN), good.copy(takenAtMs = 0))) {
            assertTrue("$bad must be treated as no fix, never as a half one", SosLocationPolicy.metadata(bad, now).isEmpty())
        }
    }

    @Test
    fun `the key names are the contract`() {
        // These five strings are read by services/api/src/lib/alertLocation.ts and decoded by the parent
        // app's Alert.location. Renaming one here without the other two sides is a silent "no location".
        assertEquals("lat", SosLocationPolicy.KEY_LAT)
        assertEquals("lng", SosLocationPolicy.KEY_LNG)
        assertEquals("accuracyM", SosLocationPolicy.KEY_ACCURACY_M)
        assertEquals("takenAt", SosLocationPolicy.KEY_TAKEN_AT)
        assertEquals("ageSeconds", SosLocationPolicy.KEY_AGE_SECONDS)
    }
}
