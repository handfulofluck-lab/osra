package com.familyshield.agent.setup

import androidx.compose.ui.unit.dp
import com.familyshield.agent.ui.pairing.LARGE_TEXT_FONT_SCALE_THRESHOLD
import com.familyshield.agent.ui.pairing.PermissionStepActionPlacement
import com.familyshield.agent.ui.pairing.PermissionStepActionSlot
import com.familyshield.agent.ui.pairing.permissionStepActionPlacement
import com.familyshield.agent.ui.pairing.shouldScrollSecondaryActions
import com.familyshield.agent.ui.theme.OsraTokens
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

/**
 * U44 (#952): guards the branded first-launch welcome and one-permission-per-screen onboarding
 * against copy drift, token bypasses, raw-XML regressions, and activity route bypasses.
 */
class OnboardingWelcomeAndStepsTest {

    @Test
    fun `welcome EN and AR strings match UI-UX and Arabic Bureau wording`() {
        val en = loadStrings("src/main/res/values/strings.xml")
        val ar = loadStrings("src/main/res/values-ar/strings.xml")

        assertEquals("Let's set up this phone", en["setup_welcome_title"])
        assertEquals(
            "A few steps so your parent can help keep this phone safe.",
            en["setup_welcome_body"],
        )
        assertEquals("Start", en["setup_welcome_start"])

        assertEquals("لنبدأ إعداد هذا الهاتف", ar["setup_welcome_title"])
        assertEquals(
            "بضع خطوات ليساعدك أهلك في الحفاظ على أمان هذا الهاتف.",
            ar["setup_welcome_body"],
        )
        assertEquals("البدء", ar["setup_welcome_start"])

        val longestArWord = ar.getValue("setup_welcome_title").split(' ').maxOf { it.length }
        assertTrue("AR welcome title must stay compact across whole words", longestArWord <= 6)
    }

    @Test
    fun `welcome and permission step screens use OsraTheme locals and 52dp primary button height`() {
        assertEquals(52.dp, OsraTokens.sizes.primaryButtonHeight)
        val screenSrc = locate("src/main/java/com/familyshield/agent/ui/pairing/OnboardingWelcomeAndStepsScreen.kt").readText()
        assertTrue(screenSrc.contains("OsraTheme.LocalOsraPalette.current"))
        assertTrue(screenSrc.contains("OsraTheme.LocalOsraRadii.current"))
        assertTrue(screenSrc.contains("OsraTokens.sizes.primaryButtonHeight"))
        assertTrue(screenSrc.contains("maxLines = 2"))
        assertTrue(screenSrc.contains("TextDirection.Content"))
        assertFalse(
            "Welcome/step composables must not hardcode Color(0x...) literals",
            screenSrc.contains("Color(0x"),
        )
        assertFalse(
            "Welcome/step composables must not hardcode 0xFF... hex colors",
            screenSrc.contains("0xFF"),
        )
    }

    @Test
    fun `PairingActivity opens welcome on first launch and renders steps and checklist via Compose`() {
        val activitySrc = locate("src/main/java/com/familyshield/agent/setup/PairingActivity.kt").readText()
        assertTrue(activitySrc.contains("else -> showWelcome("))
        assertTrue(activitySrc.contains("nextUngrantedPermissionStep(rows)"))
        assertTrue(activitySrc.contains("showPermissionStep(rows, nextStep, firstRun)"))
        assertTrue(activitySrc.contains("OnboardingWelcomeScreen("))
        assertTrue(activitySrc.contains("OnboardingPairingStepScreen("))
        assertTrue(activitySrc.contains("OnboardingPermissionStepScreen("))
        assertTrue(activitySrc.contains("OnboardingChecklistScreen("))
        assertTrue(activitySrc.contains("OnboardingLoadingScreen("))
        // Ensure showChecklist fallback no longer drops into bare XML ProgressBar/addGrantRow.
        val checklistFn = activitySrc.substringAfter("private fun showChecklist(").substringBefore("private fun nextUngrantedPermissionStep(")
        assertFalse("showChecklist must render via Compose instead of bare XML", checklistFn.contains("addGrantRow("))
        assertFalse("showChecklist must not hardcode legacy hex colors", checklistFn.contains("0xFF"))
    }

    @Test
    fun `U85 lock_locked_body drops brand tail in EN and uses Arabic Bureau house term in AR`() {
        val en = loadStrings("src/main/res/values/strings.xml")
        val ar = loadStrings("src/main/res/values-ar/strings.xml")

        assertEquals("It will unlock when your parent allows it.", en["lock_locked_body"])
        assertFalse(en.getValue("lock_locked_body").contains("أسرة"))
        assertEquals("سيُفتح القفل عندما يسمح أهلك بذلك.", ar["lock_locked_body"])
        assertFalse(ar.getValue("lock_locked_body").contains("أسرة"))
        assertFalse(ar.getValue("lock_locked_body").contains("والدك"))
    }

    @Test
    fun `U97 LockActivity declares NoActionBar theme in manifest`() {
        val doc = DocumentBuilderFactory.newInstance().apply { isNamespaceAware = false }
            .newDocumentBuilder()
            .parse(locate("src/main/AndroidManifest.xml"))
        val activities = doc.getElementsByTagName("activity")
        val lockEntry = (0 until activities.length)
            .map { activities.item(it) as Element }
            .firstOrNull { it.getAttribute("android:name").endsWith(".commands.LockActivity") }
            ?: error("LockActivity missing from AndroidManifest.xml")
        assertEquals("@android:style/Theme.Material.NoActionBar", lockEntry.getAttribute("android:theme"))
    }

    @Test
    fun `U98 checklist first title drops brand tail and Arabic Bureau lock and Private DNS titles match`() {
        val en = loadStrings("src/main/res/values/strings.xml")
        val ar = loadStrings("src/main/res/values-ar/strings.xml")

        assertEquals("Finish protecting this device", en["setup_checklist_first_title"])
        assertFalse(en.getValue("setup_checklist_first_title").contains("أسرة"))
        assertEquals("أكمل حماية هذا الجهاز", ar["setup_checklist_first_title"])

        assertEquals("قفل أهلك هذا الجهاز", ar["lock_locked_title"])
        assertEquals("أوقف أهلك هذا الجهاز مؤقتًا", ar["lock_paused_title"])
        assertEquals("أوقف أهلك الإنترنت مؤقتًا", ar["lock_paused_internet_title"])
        assertEquals("إعداد DNS الخاص", ar["c05_grant_private_dns_title"])
    }

    @Test
    fun `U88 recommended chip drops brackets and skip button uses plain copy in EN and AR`() {
        val en = loadStrings("src/main/res/values/strings.xml")
        val ar = loadStrings("src/main/res/values-ar/strings.xml")

        assertEquals("Recommended", en["setup_recommended"])
        assertEquals("موصى به", ar["setup_recommended"])
        assertEquals("Skip for now", en["setup_skip"])
        assertEquals("التخطي الآن", ar["setup_skip"])
    }

    @Test
    fun `U90 permission step pins all active actions at normal text without duplicating or dropping any`() {
        assertEquals(1.5f, LARGE_TEXT_FONT_SCALE_THRESHOLD, 0f)
        assertFalse(shouldScrollSecondaryActions(1.0f))
        assertFalse(shouldScrollSecondaryActions(1.3f))

        val normal = permissionStepActionPlacement(
            fontScale = 1.0f,
            hasConfirmHint = true,
            hasConfirmButton = true,
            hasSkipButton = true,
            hasChecklistButton = true,
        )
        assertEquals(
            PermissionStepActionPlacement(
                scrollable = emptyList(),
                pinned = listOf(
                    PermissionStepActionSlot.PRIMARY_GRANT,
                    PermissionStepActionSlot.CONFIRM_HINT,
                    PermissionStepActionSlot.CONFIRM_BUTTON,
                    PermissionStepActionSlot.SKIP_BUTTON,
                    PermissionStepActionSlot.CHECKLIST_BUTTON,
                ),
            ),
            normal,
        )
        val combined = normal.scrollable + normal.pinned
        assertEquals("Every active action must appear exactly once", combined.size, combined.toSet().size)
    }

    @Test
    fun `U90 permission step pins only primary grant and scrolls secondary actions at 1_5x and 2_0x`() {
        assertTrue(shouldScrollSecondaryActions(1.5f))
        assertTrue(shouldScrollSecondaryActions(2.0f))

        for (scale in listOf(1.5f, 2.0f)) {
            val largeText = permissionStepActionPlacement(
                fontScale = scale,
                hasConfirmHint = true,
                hasConfirmButton = true,
                hasSkipButton = true,
                hasChecklistButton = true,
            )
            assertEquals(
                PermissionStepActionPlacement(
                    scrollable = listOf(
                        PermissionStepActionSlot.CONFIRM_HINT,
                        PermissionStepActionSlot.CONFIRM_BUTTON,
                        PermissionStepActionSlot.SKIP_BUTTON,
                        PermissionStepActionSlot.CHECKLIST_BUTTON,
                    ),
                    pinned = listOf(PermissionStepActionSlot.PRIMARY_GRANT),
                ),
                largeText,
            )
            val combined = largeText.scrollable + largeText.pinned
            assertEquals("Every active action must appear exactly once at scale $scale", combined.size, combined.toSet().size)
        }
    }

    @Test
    fun `U90 permission step omits inactive secondary slots and keeps confirm hint gated by confirm button`() {
        val batteryAtLargeText = permissionStepActionPlacement(
            fontScale = 2.0f,
            hasConfirmHint = true,
            hasConfirmButton = false,
            hasSkipButton = true,
            hasChecklistButton = true,
        )
        assertEquals(
            PermissionStepActionPlacement(
                scrollable = listOf(
                    PermissionStepActionSlot.SKIP_BUTTON,
                    PermissionStepActionSlot.CHECKLIST_BUTTON,
                ),
                pinned = listOf(PermissionStepActionSlot.PRIMARY_GRANT),
            ),
            batteryAtLargeText,
        )

        val requiredStepOnly = permissionStepActionPlacement(
            fontScale = 2.0f,
            hasConfirmHint = false,
            hasConfirmButton = false,
            hasSkipButton = false,
            hasChecklistButton = false,
        )
        assertEquals(
            PermissionStepActionPlacement(
                scrollable = emptyList(),
                pinned = listOf(PermissionStepActionSlot.PRIMARY_GRANT),
            ),
            requiredStepOnly,
        )
    }

    @Test
    fun `U90 screen renders actions exclusively through permissionStepActionPlacement slots`() {
        val screenSrc = locate("src/main/java/com/familyshield/agent/ui/pairing/OnboardingWelcomeAndStepsScreen.kt").readText()
        val permFn = screenSrc
            .substringAfter("fun OnboardingPermissionStepScreen(")
            .substringBefore("private fun RenderPermissionStepActionSlot(")
        assertTrue(permFn.contains("permissionStepActionPlacement("))
        assertEquals(
            "OnboardingPermissionStepScreen must invoke RenderPermissionStepActionSlot exactly twice (scrollable + pinned)",
            2,
            Regex("""RenderPermissionStepActionSlot\(""").findAll(permFn).count(),
        )
        assertFalse(
            "OnboardingPermissionStepScreen must not bypass placement by rendering OutlinedButton directly in the pinned area",
            permFn.substringAfter("val placement = permissionStepActionPlacement(")
                .substringAfter("Spacer(modifier = Modifier.height(if (placement.scrollable.isNotEmpty())")
                .contains("OutlinedButton("),
        )
    }

    private fun loadStrings(relativeToModule: String): Map<String, String> {
        val doc = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(locate(relativeToModule))
        val nodes = doc.getElementsByTagName("string")
        return (0 until nodes.length)
            .map { nodes.item(it) as Element }
            .associate { node ->
                node.getAttribute("name") to node.textContent
                    .replace("\\n", "\n")
                    .replace("\\'", "'")
                    .replace("\\\"", "\"")
            }
    }

    private fun locate(relativeToModule: String): File {
        val working = File(System.getProperty("user.dir") ?: ".").absoluteFile
        return generateSequence(working) { it.parentFile }
            .flatMap { sequenceOf(File(it, relativeToModule), File(it, "app/$relativeToModule")) }
            .firstOrNull { it.isFile }
            ?: error("Could not find $relativeToModule from ${working.path}")
    }
}
