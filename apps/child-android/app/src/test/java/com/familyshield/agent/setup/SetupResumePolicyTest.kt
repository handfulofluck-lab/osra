package com.familyshield.agent.setup

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * ADR-0010 §2: before a PIN exists the ungated window is the setup screen only. The #440 Flip4 run
 * relaunched the agent between Allow and the PIN step and landed on the status screen instead.
 */
class SetupResumePolicyTest {

    @Test
    fun `a paired device with no PIN resumes on the PIN step`() {
        assertEquals(PairedScreen.SET_PIN, SetupResumePolicy.pairedScreen(pinConfigured = false))
    }

    @Test
    fun `a paired device with a PIN shows the status screen`() {
        assertEquals(PairedScreen.STATUS, SetupResumePolicy.pairedScreen(pinConfigured = true))
    }

    @Test
    fun `every way into the status screen goes through the policy first`() {
        // The activity has many `showStatus()` call sites (relaunch, back, admin result…); the gate sits at
        // the top of showStatus itself so none of them can bypass it.
        var dir: File? = File(System.getProperty("user.dir")).absoluteFile
        var source: File? = null
        while (dir != null && source == null) {
            source = File(dir, "app/src/main/java/com/familyshield/agent/setup/PairingActivity.kt").takeIf { it.isFile }
            dir = dir.parentFile
        }
        val text = requireNotNull(source) { "PairingActivity.kt not found" }.readText()
        val body = text.substringAfter("private fun showStatus() {").lineSequence().drop(1).take(4).joinToString("\n")
        assertTrue("showStatus must start with the PIN gate:\n$body", body.contains("SetupResumePolicy.pairedScreen(pinStore.isConfigured()) == PairedScreen.SET_PIN"))
        assertTrue(body.contains("showSetPin()"))
    }
}
