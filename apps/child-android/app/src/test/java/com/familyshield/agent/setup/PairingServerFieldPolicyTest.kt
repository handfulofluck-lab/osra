package com.familyshield.agent.setup

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * G4 of the customer guide: a release build must not ask a child to type a server address the parent's screen
 * never shows — and a field that cannot be edited must never be empty.
 */
class PairingServerFieldPolicyTest {

    @Test
    fun `a scanned code wins over everything and locks the field`() {
        val field = PairingServerFieldPolicy.field(
            scannedUrl = "https://api.staging.osratech.com",
            builtInUrl = "https://api.osratech.com",
            typed = "192.168.1.5:3000",
        )
        assertEquals("https://api.staging.osratech.com", field.value)
        assertFalse("a scanned server is not a draft", field.editable)
        assertTrue(field.fromQr)
        assertFalse(field.fromBuild)
        // The scan carries the six digits too, so both fields lock together.
        assertFalse(PairingServerFieldPolicy.codeEditable(field))
    }

    @Test
    fun `a build with its own server prefills and locks it, and still asks for the code`() {
        val field = PairingServerFieldPolicy.field(
            scannedUrl = null,
            builtInUrl = "https://api.osratech.com",
            typed = "",
        )
        assertEquals("https://api.osratech.com", field.value)
        assertFalse("the child cannot mistype the server a store build was made for", field.editable)
        assertTrue(field.fromBuild)
        assertFalse(field.fromQr)
        assertTrue("the code is still read out of the parent's screen", PairingServerFieldPolicy.codeEditable(field))
    }

    @Test
    fun `a build with no server leaves today's behaviour alone`() {
        val field = PairingServerFieldPolicy.field(scannedUrl = null, builtInUrl = null, typed = "192.168.1.5:3000")
        assertEquals("192.168.1.5:3000", field.value)
        assertTrue("a tester must be able to type a LAN address", field.editable)
        assertFalse(field.fromBuild)
        assertTrue(PairingServerFieldPolicy.codeEditable(field))
    }

    @Test
    fun `a blank build value is not a server, and does not lock an empty field`() {
        // The failure this exists for: `API_BASE=""` in a build that never set it must not produce a locked,
        // empty field that no one can fix.
        for (blank in listOf("", "   ", null)) {
            val field = PairingServerFieldPolicy.field(scannedUrl = null, builtInUrl = blank, typed = "10.0.0.2:3000")
            assertTrue("[$blank] must leave the field editable", field.editable)
            assertEquals("10.0.0.2:3000", field.value)
        }
    }

    @Test
    fun `a failed scan keeps what the tester had typed`() {
        // `scannedUrl` is null after a failed scan, so the typist's work is not lost on the way back.
        val field = PairingServerFieldPolicy.field(scannedUrl = null, builtInUrl = "  ", typed = "192.168.1.5:3000")
        assertEquals("192.168.1.5:3000", field.value)
        assertTrue(field.editable)
    }

    @Test
    fun `whitespace around a real value is trimmed, not kept`() {
        assertEquals(
            "https://api.osratech.com",
            PairingServerFieldPolicy.field(scannedUrl = "  ", builtInUrl = " https://api.osratech.com ", typed = "").value,
        )
    }

    @Test
    fun `C-05 code-only step runs only for preset builds or scanned QR and falls back to manual form when server is editable blank`() {
        val presetBuild = PairingServerFieldPolicy.field(
            scannedUrl = null,
            builtInUrl = "https://api.osratech.com",
            typed = "",
        )
        assertTrue(
            "preset build must keep the C-05 code-only screen",
            PairingServerFieldPolicy.useCodeOnlyC05Step(c05Enabled = true, field = presetBuild),
        )
        assertFalse(
            "flag-off must keep the legacy form even on a preset build",
            PairingServerFieldPolicy.useCodeOnlyC05Step(c05Enabled = false, field = presetBuild),
        )

        val scannedQr = PairingServerFieldPolicy.field(
            scannedUrl = "https://api.staging.osratech.com",
            builtInUrl = "",
            typed = "",
        )
        assertTrue(
            "scanned QR on an unconfigured build carries its server and may use the C-05 review screen",
            PairingServerFieldPolicy.useCodeOnlyC05Step(c05Enabled = true, field = scannedQr),
        )

        for (blank in listOf("", "   ", null)) {
            val unconfiguredBlank = PairingServerFieldPolicy.field(
                scannedUrl = null,
                builtInUrl = blank,
                typed = "",
            )
            assertFalse(
                "unconfigured build ($blank) with editable blank field must fall back to manual server entry",
                PairingServerFieldPolicy.useCodeOnlyC05Step(c05Enabled = true, field = unconfiguredBlank),
            )
        }

        val unconfiguredTyped = PairingServerFieldPolicy.field(
            scannedUrl = null,
            builtInUrl = "",
            typed = "192.168.1.5:3000",
        )
        assertFalse(
            "unconfigured build with an editable typed LAN address stays on the manual form so edits survive rotation/cancel",
            PairingServerFieldPolicy.useCodeOnlyC05Step(c05Enabled = true, field = unconfiguredTyped),
        )

        val activity = locate("src/main/java/com/familyshield/agent/setup/PairingActivity.kt").readText()
        val showFormBody = activity.substringAfter("private fun showForm(").substringBefore("private fun showC05PairingStep(")
        assertTrue(
            "PairingActivity.showForm must gate showC05PairingStep through PairingServerFieldPolicy.useCodeOnlyC05Step",
            showFormBody.contains("PairingServerFieldPolicy.useCodeOnlyC05Step(ChildUxFlags.c05FirstRunEnabled, serverField)"),
        )
    }

    private fun locate(relativeToModule: String): File {
        val working = File(System.getProperty("user.dir") ?: ".").absoluteFile
        return generateSequence(working) { it.parentFile }
            .flatMap { sequenceOf(File(it, relativeToModule), File(it, "app/$relativeToModule")) }
            .firstOrNull { it.isFile }
            ?: error("Could not find $relativeToModule from ${working.path}")
    }
}
