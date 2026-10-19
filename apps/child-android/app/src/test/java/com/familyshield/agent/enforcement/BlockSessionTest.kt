package com.familyshield.agent.enforcement

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #217: `BlockActivity` is `launchMode="singleTask"`, so a second block reuses the instance. The
 * old code read `EXTRA_PACKAGE` only in `onCreate`/`goHome`, which left the first app's package in the
 * label and in both actions — "Request access" would ask the parent to unblock **the previous app** and
 * `clearDebounce` cleared the wrong package. These cases drive the intent-to-screen transition twice.
 */
class BlockSessionTest {

    private val labels = mapOf(
        "com.netflix.mediaclient" to "Netflix",
        "com.familyshield.notanapp" to "Not an app",
    )

    @Test
    fun `a second intent replaces the label and both action targets`() {
        val session = BlockSession(labelOf = { labels[it] })

        session.apply("com.netflix.mediaclient", BlockActivity.REASON_BLOCKED)
        assertEquals("Netflix", session.appLabel)
        assertEquals("com.netflix.mediaclient", session.requestAccessPackage())
        assertEquals("com.netflix.mediaclient", session.clearDebouncePackage())

        session.apply("com.familyshield.notanapp", BlockActivity.REASON_TIME_LIMIT)

        assertEquals("Not an app", session.appLabel)
        assertEquals("com.familyshield.notanapp", session.requestAccessPackage())
        assertEquals("com.familyshield.notanapp", session.clearDebouncePackage())
        assertTrue("the second block's reason must travel with its package", session.request.timeLimit)
    }

    @Test
    fun `the label falls back to the package id when the app cannot be resolved`() {
        val session = BlockSession(labelOf = { null })

        session.apply("com.example.uninstalled", BlockActivity.REASON_BLOCKED)

        assertEquals("com.example.uninstalled", session.appLabel)
        assertEquals("com.example.uninstalled", session.requestAccessPackage())
    }

    @Test
    fun `every applied intent notifies Compose so the screen re-renders`() {
        val rendered = mutableListOf<Pair<String, String>>()
        val session = BlockSession(
            labelOf = { labels[it] },
            onChanged = { request, label -> rendered += request.packageId to label },
        )

        session.apply("com.netflix.mediaclient", BlockActivity.REASON_BLOCKED)
        session.apply("com.familyshield.notanapp", BlockActivity.REASON_BLOCKED)

        assertEquals(
            listOf("com.netflix.mediaclient" to "Netflix", "com.familyshield.notanapp" to "Not an app"),
            rendered,
        )
    }

    @Test
    fun `a blank package clears the debounce target instead of keeping the previous one`() {
        val session = BlockSession(labelOf = { labels[it] })
        session.apply("com.netflix.mediaclient", BlockActivity.REASON_BLOCKED)

        session.apply(null, null)

        assertEquals("", session.appLabel)
        assertEquals("", session.requestAccessPackage())
        assertNull("a blank package must not clear the previous app's debounce", session.clearDebouncePackage())
        assertEquals(BlockActivity.REASON_BLOCKED, session.request.reason)
    }
}
