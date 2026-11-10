package com.familyshield.agent.capabilities

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * ADR-0034 A2: a resume uploads the capability report **only when it changed**.
 *
 * The fingerprint is what decides that, so two things must hold and are pinned here: the same facts always
 * render the same string (or every resume would upload), and any change in a grant, a feature or a profile
 * always renders a different one (or a fix a parent just made would never reach the server).
 */
class CapabilityUploadPolicyTest {

    private fun report(grants: Map<String, String>, features: Map<String, String> = emptyMap()) = mapOf(
        "client" to mapOf("app" to "child-android", "version" to "0.2.0", "build" to 2, "flavour" to "full"),
        "grants" to grants,
        "features" to features,
    )

    @Test
    fun `the same facts render the same fingerprint, whatever order the map was built in`() {
        val a = CapabilityUploadPolicy.fingerprint(report(linkedMapOf("accessibility" to "granted", "location" to "missing")))
        val b = CapabilityUploadPolicy.fingerprint(report(linkedMapOf("location" to "missing", "accessibility" to "granted")))
        assertEquals("key order must not matter, or every resume would upload", a, b)
        assertEquals(a, CapabilityUploadPolicy.fingerprint(report(linkedMapOf("accessibility" to "granted", "location" to "missing"))))
    }

    @Test
    fun `any single changed fact renders a different fingerprint`() {
        val base = CapabilityUploadPolicy.fingerprint(report(mapOf("accessibility" to "missing")))
        assertNotEquals(
            "a grant a parent has just fixed must reach the server",
            base,
            CapabilityUploadPolicy.fingerprint(report(mapOf("accessibility" to "granted"))),
        )
        assertNotEquals(
            "a feature changing state is a change too",
            CapabilityUploadPolicy.fingerprint(report(mapOf("accessibility" to "granted"), mapOf("lock_screen" to "unavailable"))),
            CapabilityUploadPolicy.fingerprint(report(mapOf("accessibility" to "granted"), mapOf("lock_screen" to "ready"))),
        )
        assertNotEquals(
            "and so is a second space appearing or going",
            CapabilityUploadPolicy.fingerprint(mapOf("profiles" to mapOf("others" to 1, "kinds" to listOf("clone")))),
            CapabilityUploadPolicy.fingerprint(mapOf("profiles" to mapOf("others" to 0, "kinds" to emptyList<String>()))),
        )
    }

    @Test
    fun `a value that reads like the separators cannot be mistaken for a different shape`() {
        // The reason maps and lists are wrapped: without the braces, a single value containing `;` could
        // render the same as two entries, and a real change would be swallowed as "unchanged".
        val oneValue = CapabilityUploadPolicy.fingerprint(mapOf("a" to "1;b=2"))
        val twoEntries = CapabilityUploadPolicy.fingerprint(mapOf("a" to "1", "b" to "2"))
        assertNotEquals(oneValue, twoEntries)
        assertNotEquals(
            CapabilityUploadPolicy.fingerprint(mapOf("k" to listOf("x", "y"))),
            CapabilityUploadPolicy.fingerprint(mapOf("k" to "x,y")),
        )
    }
}
