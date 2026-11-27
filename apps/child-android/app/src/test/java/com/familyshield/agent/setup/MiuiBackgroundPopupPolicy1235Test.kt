package com.familyshield.agent.setup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Issue #1235 (Ahmed's Redmi / MIUI / HyperOS note on #1208):
 * When Xiaomi's background pop-up AppOp (`10021`) cannot be read (`null`), the phone must NEVER
 * silently count it as granted. It classifies as [MiuiPopupState.UNREADABLE], stays incomplete
 * (and listed in the single `setup_incomplete:<deviceId>` notice), and requires explicit parent
 * confirmation in the guided onboarding step — while a readable denial (`DENIED`) can NEVER be
 * bypassed by parent confirmation.
 */
class MiuiBackgroundPopupPolicy1235Test {

    @Test
    fun `unreadable op 10021 on Xiaomi, Redmi, and POCO never silently counts as granted`() {
        for (oem in listOf("Xiaomi", "Redmi", "POCO", "xiaomi")) {
            assertEquals(
                "$oem with null op10021 must classify UNREADABLE",
                MiuiPopupState.UNREADABLE,
                MiuiBackgroundPopupPolicy.classifyState(oem, op10021Mode = null, op10020Mode = null),
            )
            assertFalse(
                "$oem with unreadable op10021 and no parent confirmation must NOT count as granted",
                MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(
                    manufacturer = oem,
                    op10021Mode = null,
                    op10020Mode = null,
                    parentConfirmed = false,
                ),
            )
            assertTrue(
                "$oem with unreadable op10021 succeeds once parent confirms after guided step",
                MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(
                    manufacturer = oem,
                    op10021Mode = null,
                    op10020Mode = null,
                    parentConfirmed = true,
                ),
            )
        }
    }

    @Test
    fun `unreadable op 10021 keeps OVERLAY in missingRequired and setup_incomplete fingerprint`() {
        val overlayGranted = MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(
            manufacturer = "Redmi",
            op10021Mode = null,
            op10020Mode = null,
            parentConfirmed = false,
        )
        val rows = OnboardingPolicy.rows(notificationCaptureAvailable = true) { grant ->
            if (grant == OnboardingPolicy.Grant.OVERLAY) overlayGranted else true
        }
        assertFalse("setup must NOT complete while Redmi op10021 is unreadable and unconfirmed", OnboardingPolicy.canComplete(rows))
        val missing = OnboardingPolicy.missingRequired(rows)
        assertEquals(listOf(OnboardingPolicy.Grant.OVERLAY), missing)
        assertEquals("OVERLAY", FirstRunOrderPolicy.missingGrantsFingerprint(missing))
    }

    @Test
    fun `readable DENIED on op 10021 or op 10020 can NEVER be overridden by parent confirmation`() {
        assertEquals(
            MiuiPopupState.DENIED,
            MiuiBackgroundPopupPolicy.classifyState("Redmi", op10021Mode = 1, op10020Mode = 0),
        )
        assertFalse(
            "parentConfirmed must NOT override explicit DENIED op10021",
            MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(
                manufacturer = "Redmi",
                op10021Mode = 1,
                op10020Mode = 0,
                parentConfirmed = true,
            ),
        )
        assertEquals(
            MiuiPopupState.DENIED,
            MiuiBackgroundPopupPolicy.classifyState("Xiaomi", op10021Mode = 0, op10020Mode = 1),
        )
        assertFalse(
            "parentConfirmed must NOT override explicit DENIED op10020",
            MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(
                manufacturer = "Xiaomi",
                op10021Mode = 0,
                op10020Mode = 1,
                parentConfirmed = true,
            ),
        )
        // osra-security#91: readable denial on either op MUST win even when the sibling op is null/unreadable.
        for (oem in listOf("Xiaomi", "Redmi", "POCO")) {
            assertEquals(
                "$oem: readable DENIED op10020 must beat unreadable null op10021",
                MiuiPopupState.DENIED,
                MiuiBackgroundPopupPolicy.classifyState(oem, op10021Mode = null, op10020Mode = 1),
            )
            assertFalse(
                "$oem: parentConfirmed must NOT override readable DENIED op10020 when op10021 is null",
                MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(
                    manufacturer = oem,
                    op10021Mode = null,
                    op10020Mode = 1,
                    parentConfirmed = true,
                ),
            )
            assertEquals(
                "$oem: readable DENIED op10021 must beat unreadable null op10020",
                MiuiPopupState.DENIED,
                MiuiBackgroundPopupPolicy.classifyState(oem, op10021Mode = 1, op10020Mode = null),
            )
            assertFalse(
                "$oem: parentConfirmed must NOT override readable DENIED op10021 when op10020 is null",
                MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(
                    manufacturer = oem,
                    op10021Mode = 1,
                    op10020Mode = null,
                    parentConfirmed = true,
                ),
            )
            // Safe confirmation path remains intact when op10021 is null and op10020 is ALLOWED (no denial).
            assertEquals(
                "$oem: null op10021 with ALLOWED op10020 stays UNREADABLE",
                MiuiPopupState.UNREADABLE,
                MiuiBackgroundPopupPolicy.classifyState(oem, op10021Mode = null, op10020Mode = 0),
            )
            assertFalse(
                MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(oem, op10021Mode = null, op10020Mode = 0, parentConfirmed = false),
            )
            assertTrue(
                MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(oem, op10021Mode = null, op10020Mode = 0, parentConfirmed = true),
            )
        }
    }

    @Test
    fun `non-Xiaomi devices remain ALLOWED even when MIUI ops are unreadable`() {
        for (oem in listOf("samsung", "Google", "OnePlus", null)) {
            assertEquals(
                MiuiPopupState.ALLOWED,
                MiuiBackgroundPopupPolicy.classifyState(oem, op10021Mode = null, op10020Mode = null),
            )
            assertTrue(
                MiuiBackgroundPopupPolicy.isBackgroundPopupAllowed(
                    manufacturer = oem,
                    op10021Mode = null,
                    op10020Mode = null,
                    parentConfirmed = false,
                ),
            )
        }
    }

    @Test
    fun `wiring hooks guided confirmation in PairingActivity, clears on unpair, and has EN-AR parity`() {
        val root = findAppSrcRoot()
        val activity = File(root, "java/com/familyshield/agent/setup/PairingActivity.kt").readText()
        val screen = File(root, "java/com/familyshield/agent/ui/pairing/OnboardingWelcomeAndStepsScreen.kt").readText()
        val settings = File(root, "java/com/familyshield/agent/data/AgentSettings.kt").readText()
        val enStrings = File(root, "res/values/strings.xml").readText()
        val arStrings = File(root, "res/values-ar/strings.xml").readText()

        assertTrue(activity.contains("MiuiBackgroundPopupPolicy.needsParentConfirmation(this)"))
        assertTrue(activity.contains("MiuiBackgroundPopupPolicy.confirmByParent(this@PairingActivity)"))
        assertTrue(screen.contains("onConfirm != null && copy.confirmButton != null"))
        assertTrue(settings.contains("MiuiBackgroundPopupPolicy.clearParentConfirmation(context)"))

        for (key in listOf("miui_popup_confirm_hint", "miui_popup_confirm_button")) {
            assertTrue("EN strings missing $key", enStrings.contains("name=\"$key\""))
            assertTrue("AR strings missing $key", arStrings.contains("name=\"$key\""))
        }
        assertTrue(
            arStrings.contains("لا يُبلغ هذا الهاتف عمّا إذا كانت النوافذ المنبثقة في الخلفية مفعّلة. لذا يلزم فتح «أذونات أخرى» وتفعيل «عرض النوافذ المنبثقة أثناء التشغيل في الخلفية»، ثم التأكيد أدناه."),
        )
        assertTrue(arStrings.contains("تم تفعيل النوافذ المنبثقة في الخلفية"))
    }

    private fun findAppSrcRoot(): File {
        var dir = File(System.getProperty("user.dir") ?: ".")
        repeat(5) {
            val candidate = File(dir, "src/main")
            if (candidate.isDirectory) return candidate
            val nested = File(dir, "app/src/main")
            if (nested.isDirectory) return nested
            dir = dir.parentFile ?: return candidate
        }
        return File("src/main")
    }
}
