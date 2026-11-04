package com.familyshield.agent.capabilities

import com.familyshield.agent.security.ProfilePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * ADR-0034 decision 1: the report the phone sends says what this phone can actually do.
 *
 * The rules that are easy to get wrong, and are pinned below: **`ready` needs the working path, not the
 * grant** (the lock needs the accessibility service to re-raise its screen, #368); a build that cannot do a
 * feature **omits it** rather than claiming `not_supported`, which is the server's word; and a weaker path the
 * agent still serves is `degraded`, not `unavailable`.
 */
class CapabilitiesPolicyTest {

    /** Every key the vocabulary has — what the Full build asks for. */
    private val GRANT_ALL = CapabilitiesPolicy.GRANT_WIRE.toSet()

    /** The Play artefact's list: the same minus notification access (ADR-0016 §4). */
    private val GRANT_FULL_MINUS_LISTENER = GRANT_ALL - "notification_listener"

    private fun facts(
        fullBuild: Boolean = true,
        applicable: Set<String> = GRANT_ALL,
        granted: Set<String> = emptySet(),
        accessibility: Boolean = false,
        overlay: Boolean = false,
        adminLocked: Boolean = false,
        filterSetUp: Boolean = true,
        tunnel: Boolean = true,
        backgroundLocation: Boolean = false,
        callSms: Boolean = true,
        profiles: ProfilePolicy.Report? = null,
    ) = CapabilitiesPolicy.CapabilityFacts(
        versionName = "0.2.0",
        versionCode = 2,
        fullBuild = fullBuild,
        applicableGrants = applicable,
        grantedGrants = granted,
        accessibilityRunning = accessibility,
        canOverlay = overlay,
        adminLocked = adminLocked,
        webFilterSetUp = filterSetUp,
        tunnelRunning = tunnel,
        backgroundLocation = backgroundLocation,
        callSmsGranted = callSms,
        profiles = profiles,
    )

    @Test
    fun `every grant the vocabulary has is reported, in its order, with three states`() {
        val report = CapabilitiesPolicy.grants(
            facts(
                applicable = setOf("accessibility", "usage_access"),
                granted = setOf("accessibility"),
            ),
        )
        assertEquals(CapabilitiesPolicy.GRANT_WIRE, report.keys.toList())
        assertEquals("granted", report["accessibility"])
        assertEquals("missing", report["usage_access"])
        assertEquals("not_applicable", report["overlay"])
    }

    @Test
    fun `the Play build reports notification access as not applicable, not missing`() {
        // ADR-0016 §4: the Play artefact has no listener, so asking its parent to grant notification access
        // would request a permission the build cannot use. The key still appears — it is a key Android has.
        val play = CapabilitiesPolicy.grants(facts(fullBuild = false, applicable = GRANT_FULL_MINUS_LISTENER))
        assertEquals("not_applicable", play["notification_listener"])
        val full = CapabilitiesPolicy.grants(facts(fullBuild = true, applicable = GRANT_ALL))
        assertEquals("missing", full["notification_listener"])
    }

    @Test
    fun `the lock is ready only when a path can hold it, not when the grants are there`() {
        // #368: an overlay-only lock shows once and Home takes it away, so a granted overlay with the service
        // off is still unavailable. That is what EnforceabilityPolicy already decides, and this must agree.
        assertEquals("unavailable", CapabilitiesPolicy.features(facts(overlay = true, accessibility = false))["lock_screen"])
        assertEquals("ready", CapabilitiesPolicy.features(facts(overlay = true, accessibility = true))["lock_screen"])
        assertEquals(
            "the accessibility path alone still holds the screen",
            "ready",
            CapabilitiesPolicy.features(facts(overlay = false, accessibility = true))["lock_screen"],
        )
    }

    @Test
    fun `the filter is degraded while the tunnel is down, and unavailable without its consent`() {
        val noConsent = facts(granted = emptySet(), filterSetUp = false, tunnel = false)
        assertEquals("unavailable", CapabilitiesPolicy.features(noConsent)["web_filter"])

        val consentNoTunnel = facts(granted = setOf("web_filter"), filterSetUp = true, tunnel = false)
        assertEquals("degraded", CapabilitiesPolicy.features(consentNoTunnel)["web_filter"])

        val working = facts(granted = setOf("web_filter"), filterSetUp = true, tunnel = true)
        assertEquals("ready", CapabilitiesPolicy.features(working)["web_filter"])
    }

    @Test
    fun `location without background access is degraded, because the foreground path still answers`() {
        assertEquals("unavailable", CapabilitiesPolicy.features(facts())["location"])
        assertEquals(
            "degraded",
            CapabilitiesPolicy.features(facts(granted = setOf("location"), backgroundLocation = false))["location"],
        )
        assertEquals(
            "ready",
            CapabilitiesPolicy.features(facts(granted = setOf("location"), backgroundLocation = true))["location"],
        )
    }

    @Test
    fun `the Play build says nothing about the two features it cannot do`() {
        // `not_supported` is the server's word from its static table (A1). A device that claimed it would be
        // shown as `unavailable`, so the Play artefact omits the keys instead of reporting a state it cannot
        // honestly hold.
        val play = CapabilitiesPolicy.features(facts(fullBuild = false, granted = setOf("notification_listener")))
        assertTrue("no key at all", "notification_scan" !in play && "call_sms_log" !in play)
        val full = CapabilitiesPolicy.features(facts(fullBuild = true, granted = setOf("notification_listener")))
        assertEquals("ready", full["notification_scan"])
        assertEquals("unavailable", CapabilitiesPolicy.features(facts(fullBuild = true, callSms = false))["call_sms_log"])
    }

    @Test
    fun `the uninstall guard needs the admin and the service, and screen time needs usage access`() {
        assertEquals(
            "unavailable",
            CapabilitiesPolicy.features(facts(granted = setOf("device_admin"), accessibility = false))["uninstall_guard"],
        )
        assertEquals(
            "ready",
            CapabilitiesPolicy.features(facts(granted = setOf("device_admin"), accessibility = true))["uninstall_guard"],
        )
        assertEquals("unavailable", CapabilitiesPolicy.features(facts())["screen_time"])
        assertEquals("ready", CapabilitiesPolicy.features(facts(granted = setOf("usage_access")))["screen_time"])
    }

    @Test
    fun `pause and app blocking need the running service, and pausing the internet needs a running tunnel`() {
        // Claude's #535 review (f7, f10): each feature defers to the policy the command itself uses, so the
        // report cannot say ready for a command the phone would refuse.
        assertEquals("unavailable", CapabilitiesPolicy.features(facts(overlay = true, accessibility = false))["pause_screen"])
        assertEquals("ready", CapabilitiesPolicy.features(facts(overlay = false, accessibility = true))["pause_screen"])
        assertEquals("unavailable", CapabilitiesPolicy.features(facts(accessibility = false))["app_blocking"])
        assertEquals("ready", CapabilitiesPolicy.features(facts(accessibility = true))["app_blocking"])
        assertEquals("unavailable", CapabilitiesPolicy.features(facts(filterSetUp = false, tunnel = false))["pause_internet"])
        assertEquals("ready", CapabilitiesPolicy.features(facts(filterSetUp = true, tunnel = true))["pause_internet"])
    }

    @Test
    fun `profiles travel when they were read, and are absent when they were not`() {
        val withProfiles = CapabilitiesPolicy.report(
            "0.2.0",
            2,
            "full",
            facts(profiles = ProfilePolicy.Report(1, listOf("clone"))),
        )!!
        assertEquals(mapOf("others" to 1, "kinds" to listOf("clone")), withProfiles["profiles"])

        val without = CapabilitiesPolicy.report("0.2.0", 2, "full", facts(profiles = null))!!
        assertTrue("a report without profiles leaves the stored value alone", "profiles" !in without)
    }

    @Test
    fun `the client block is the same build the header names`() {
        val report = CapabilitiesPolicy.report("0.2", 2, "full", facts())!!
        @Suppress("UNCHECKED_CAST")
        val client = report["client"] as Map<String, Any?>
        assertEquals("child-android", client["app"])
        assertEquals("the padded version, not the raw one", "0.2.0", client["version"])
        assertEquals(2, client["build"])
        assertEquals("full", client["flavour"])
    }

    @Test
    fun `a build that cannot name itself sends no report`() {
        // A report whose client block fails the strict schema rejects the whole upload, so it is not sent.
        assertNull(CapabilitiesPolicy.report("0.2.0-rc1", 2, "full", facts()))
        assertNull(CapabilitiesPolicy.report(null, 2, "full", facts()))
    }
}
