package com.familyshield.agent.setup

import androidx.compose.ui.unit.dp
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
