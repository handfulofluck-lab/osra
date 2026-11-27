package com.familyshield.agent.setup

import com.familyshield.agent.capabilities.CapabilitiesPolicy
import com.familyshield.agent.enforcement.OverlayRetryBudget
import com.familyshield.agent.enforcement.RetryDecision
import com.familyshield.agent.security.TamperAlertWorker
import com.familyshield.agent.ui.theme.ChildUxFlags
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1236: tests the after-test Xiaomi/MIUI lock/block/guard backstop policy, default-off
 * switch, daily per-surface alert dedupe, and separate `capabilities.grants.miui_popup`
 * (`confirmed_unverified`) reporting.
 */
class MiuiLaunchBackstopPolicyTest {

    @Test
    fun `default-off switch starts false and disables both backstop decision paths`() {
        assertFalse("default-off switch must start false for Saturday", ChildUxFlags.miuiLockBackstopEnabled)
        assertEquals(
            MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false),
            MiuiLaunchBackstopPolicy.decide(
                enabled = false,
                manufacturer = "Xiaomi",
                retryDecision = RetryDecision.EXHAUSTED_ONCE,
            ),
        )
        assertEquals(
            MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false),
            MiuiLaunchBackstopPolicy.decideBlockBypass(
                enabled = false,
                manufacturer = "Redmi",
                reportBypass = true,
                alreadyCovering = true,
            ),
        )
    }

    @Test
    fun `non-Xiaomi devices never activate backstop even when switch is enabled`() {
        for (oem in listOf("Samsung", "Google", "OnePlus", null, "")) {
            assertEquals(
                MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false),
                MiuiLaunchBackstopPolicy.decide(true, oem, RetryDecision.EXHAUSTED_ONCE),
            )
            assertEquals(
                MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false),
                MiuiLaunchBackstopPolicy.decideBlockBypass(true, oem, reportBypass = true, alreadyCovering = false),
            )
        }
    }

    @Test
    fun `Xiaomi family raises cover and alerts once on EXHAUSTED_ONCE then stays quiet on EXHAUSTED`() {
        for (oem in listOf("Xiaomi", "Redmi", "POCO")) {
            assertEquals(
                MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false),
                MiuiLaunchBackstopPolicy.decide(true, oem, RetryDecision.ATTEMPT),
            )
            assertEquals(
                MiuiBackstopDecision(showAccessibilityCover = true, alertParent = true),
                MiuiLaunchBackstopPolicy.decide(true, oem, RetryDecision.EXHAUSTED_ONCE),
            )
            assertEquals(
                MiuiBackstopDecision(showAccessibilityCover = true, alertParent = false),
                MiuiLaunchBackstopPolicy.decide(true, oem, RetryDecision.EXHAUSTED),
            )
        }
    }

    @Test
    fun `block bypass backstop alerts once then keeps cover up without duplicate alerts`() {
        assertEquals(
            MiuiBackstopDecision(showAccessibilityCover = false, alertParent = false),
            MiuiLaunchBackstopPolicy.decideBlockBypass(true, "Redmi", reportBypass = false, alreadyCovering = false),
        )
        assertEquals(
            MiuiBackstopDecision(showAccessibilityCover = true, alertParent = true),
            MiuiLaunchBackstopPolicy.decideBlockBypass(true, "Redmi", reportBypass = true, alreadyCovering = false),
        )
        assertEquals(
            MiuiBackstopDecision(showAccessibilityCover = true, alertParent = false),
            MiuiLaunchBackstopPolicy.decideBlockBypass(true, "Redmi", reportBypass = false, alreadyCovering = true),
        )
    }

    @Test
    fun `OverlayRetryBudget reset clears prior exhaustion so a fresh lock episode can retry`() {
        val budget = OverlayRetryBudget(maxAttempts = 2)
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("sig-a"))
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("sig-a"))
        assertEquals(RetryDecision.EXHAUSTED_ONCE, budget.attempt("sig-a"))
        assertEquals(RetryDecision.EXHAUSTED, budget.attempt("sig-a"))
        budget.reset()
        assertEquals(RetryDecision.ATTEMPT, budget.attempt("sig-a"))
    }

    @Test
    fun `dedupeKey caps alerts to one per device, surface, and UTC day`() {
        assertEquals(
            "miui_launch_blocked:dev-1:lock:2026-11-28",
            MiuiLaunchBackstopPolicy.dedupeKey("dev-1", MiuiBackstopSurface.LOCK, "2026-11-28"),
        )
        assertEquals(
            "miui_launch_blocked:dev-1:block:2026-11-28",
            MiuiLaunchBackstopPolicy.dedupeKey("dev-1", MiuiBackstopSurface.BLOCK, "2026-11-28"),
        )
        assertEquals(
            "miui_launch_blocked:dev-1:guard:2026-11-28",
            MiuiLaunchBackstopPolicy.dedupeKey("dev-1", MiuiBackstopSurface.GUARD, "2026-11-28"),
        )
        assertNull(MiuiLaunchBackstopPolicy.dedupeKey(" ", MiuiBackstopSurface.LOCK, "2026-11-28"))
        assertNull(MiuiLaunchBackstopPolicy.dedupeKey("dev-1", MiuiBackstopSurface.LOCK, ""))
    }

    @Test
    fun `miuiPopupWireState distinguishes OS-verified granted from parent-confirmed unreadable and never overrides readable denial`() {
        assertEquals(
            CapabilitiesPolicy.NOT_APPLICABLE,
            MiuiLaunchBackstopPolicy.miuiPopupWireState("Samsung", null, null, parentConfirmed = true),
        )
        assertEquals(
            CapabilitiesPolicy.GRANTED,
            MiuiLaunchBackstopPolicy.miuiPopupWireState("Xiaomi", MiuiBackgroundPopupPolicy.MODE_ALLOWED, null, parentConfirmed = false),
        )
        assertEquals(
            CapabilitiesPolicy.MISSING,
            MiuiLaunchBackstopPolicy.miuiPopupWireState("Redmi", 1, null, parentConfirmed = true),
        )
        assertEquals(
            CapabilitiesPolicy.MISSING,
            MiuiLaunchBackstopPolicy.miuiPopupWireState("POCO", null, 1, parentConfirmed = true),
        )
        assertEquals(
            CapabilitiesPolicy.MISSING,
            MiuiLaunchBackstopPolicy.miuiPopupWireState("Xiaomi", null, null, parentConfirmed = false),
        )
        assertEquals(
            CapabilitiesPolicy.CONFIRMED_UNVERIFIED,
            MiuiLaunchBackstopPolicy.miuiPopupWireState("Xiaomi", null, null, parentConfirmed = true),
        )
    }

    @Test
    fun `CapabilitiesPolicy omits miui_popup when null and emits confirmed_unverified when provided`() {
        val base = CapabilitiesPolicy.CapabilityFacts(
            versionName = "0.2.0",
            versionCode = 2,
            fullBuild = true,
            applicableGrants = CapabilitiesPolicy.GRANT_WIRE.toSet(),
            grantedGrants = setOf("accessibility", "overlay"),
            accessibilityRunning = true,
            canOverlay = true,
            adminLocked = true,
            webFilterSetUp = true,
            tunnelRunning = true,
            backgroundLocation = true,
            callSmsGranted = true,
        )
        val withoutMiui = CapabilitiesPolicy.grants(base)
        assertFalse(withoutMiui.containsKey(CapabilitiesPolicy.GRANT_MIUI_POPUP))

        val withMiui = CapabilitiesPolicy.grants(base.copy(miuiPopupState = CapabilitiesPolicy.CONFIRMED_UNVERIFIED))
        assertEquals(CapabilitiesPolicy.CONFIRMED_UNVERIFIED, withMiui[CapabilitiesPolicy.GRANT_MIUI_POPUP])
    }

    @Test
    fun `TamperAlertWorker computes daily per-surface dedupe key, metadata, and unique work name`() {
        val ts = 1795780800000L // 2026-11-28T12:00:00Z
        val key = TamperAlertWorker.dedupeKeyFor(
            type = TamperAlertWorker.TYPE_MIUI_LAUNCH_BLOCKED,
            deviceId = "dev-redmi",
            guardWindow = null,
            app = "lock",
            layout = "",
            eventAtMs = ts,
            adminRemovedAtMs = 0L,
        )
        assertEquals("miui_launch_blocked:dev-redmi:lock:2026-11-28", key)
        assertEquals(
            mapOf("type" to TamperAlertWorker.TYPE_MIUI_LAUNCH_BLOCKED, "surface" to "guard"),
            TamperAlertWorker.metadataFor(TamperAlertWorker.TYPE_MIUI_LAUNCH_BLOCKED, "guard", ""),
        )
        assertEquals(
            "tamper_alert_miui_launch_blocked_block",
            TamperAlertWorker.uniqueWorkName(TamperAlertWorker.TYPE_MIUI_LAUNCH_BLOCKED, 0L, "block"),
        )
        assertTrue(MiuiLaunchBackstopPolicy.alertBody(MiuiBackstopSurface.LOCK).contains("Display pop-up windows"))
    }

    @Test
    fun `fullScreenBounds rejects non-positive dimensions`() {
        assertNull(MiuiLaunchBackstopPolicy.fullScreenBounds(0, 1080))
        assertNull(MiuiLaunchBackstopPolicy.fullScreenBounds(1080, -1))
        val bounds = MiuiLaunchBackstopPolicy.fullScreenBounds(1080, 2400)
        assertNotNull(bounds)
        assertEquals(0, bounds!!.left)
        assertEquals(0, bounds.top)
        assertEquals(1080, bounds.right)
        assertEquals(2400, bounds.bottom)
    }

    @Test
    fun `source wiring gates AccessibilityMonitorService and CapabilityReporter behind default-off flag`() {
        val root = locateAppDir()
        val service = File(root, "src/main/java/com/familyshield/agent/services/AccessibilityMonitorService.kt").readText()
        val reporter = File(root, "src/main/java/com/familyshield/agent/capabilities/CapabilityReporter.kt").readText()

        assertTrue(service.contains("ChildUxFlags.miuiLockBackstopEnabled"))
        assertTrue(service.contains("MiuiLaunchBackstopPolicy.decide("))
        assertTrue(service.contains("MiuiLaunchBackstopPolicy.decideBlockBypass("))
        assertTrue(service.contains("removeAllMiuiBackstopCovers()"))
        assertTrue(reporter.contains("ChildUxFlags.miuiLockBackstopEnabled"))
        assertTrue(reporter.contains("MiuiBackgroundPopupPolicy.wireGrantState(context)"))
    }

    private fun locateAppDir(): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".")
        repeat(6) {
            if (dir != null) {
                if (File(dir, "src/main/java/com/familyshield/agent").isDirectory) return dir!!
                val nested = File(dir, "app")
                if (File(nested, "src/main/java/com/familyshield/agent").isDirectory) return nested
                dir = dir!!.parentFile
            }
        }
        error("Could not locate apps/child-android/app from ${System.getProperty("user.dir")}")
    }
}
