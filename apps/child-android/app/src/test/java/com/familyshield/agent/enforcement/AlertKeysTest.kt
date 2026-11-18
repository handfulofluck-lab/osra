package com.familyshield.agent.enforcement

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** #830: the grouping keys the server deduplicates on, and the site-alert quiet window. */
class AlertKeysTest {

    @Test
    fun `blocked app and site keys name the object and the utc day`() {
        assertEquals("app:com.google.android.youtube:2026-11-16", AlertKeys.blockedApp("com.google.android.youtube", "2026-11-16"))
        assertEquals("domain:youtube.com:2026-11-16", AlertKeys.blockedSite("youtube.com", "2026-11-16"))
    }

    @Test
    fun `a site alert is due the first time and again only after the quiet window`() {
        val quiet = 10 * 60 * 1000L
        assertTrue(AlertKeys.siteAlertDue(null, 1_000L, quiet))
        assertFalse(AlertKeys.siteAlertDue(1_000L, 1_000L + quiet - 1, quiet))
        assertTrue(AlertKeys.siteAlertDue(1_000L, 1_000L + quiet, quiet))
        assertTrue(AlertKeys.siteAlertDue(1_000L, 1_000L + quiet + 5, quiet))
    }
}
